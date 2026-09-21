#!/usr/bin/env bash
# Called by null_resource.vault_bootstrap (vault.tf) via local-exec.
# Fully idempotent — safe to re-run on every `terraform apply`. Does
# everything the old setup-vault-auth.sh script + a manual `vault kv put`
# used to require by hand: init, Kubernetes auth method, the Order API's
# policy/role, and the Order API's KV secret (generated once, never
# overwritten on subsequent runs).
#
# Runs entirely via `kubectl exec` into the Vault pod itself — no local
# Vault CLI, no port-forward, no VAULT_ADDR/VAULT_TOKEN export needed on
# the machine running `terraform apply`. This also means it works
# unmodified from a CI runner, not just an engineer's laptop.
#
# Never prints the root token, recovery key, or generated secret values
# to stdout — all go straight into Kubernetes Secrets / Vault's KV store.
set -euo pipefail

: "${CLUSTER_NAME:?CLUSTER_NAME env var required}"
: "${AWS_REGION:?AWS_REGION env var required}"
: "${NAMESPACE:?NAMESPACE env var required}"
: "${ENVIRONMENT:?ENVIRONMENT env var required}"

# Runs a vault CLI command inside the vault-0 pod itself.
vexec() {
  kubectl -n "${NAMESPACE}" exec vault-0 -- vault "$@"
}

echo "==> Configuring kubectl for ${CLUSTER_NAME}"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null

echo "==> Waiting for vault-0 to exist and be scheduled"
for _ in {1..30}; do
  if kubectl -n "${NAMESPACE}" get pod vault-0 >/dev/null 2>&1; then
    break
  fi
  sleep 10
done
kubectl -n "${NAMESPACE}" wait --for=condition=PodScheduled pod/vault-0 --timeout=300s

# vault-0 won't pass its own readiness probe until it's unsealed, which
# hasn't happened yet on a first run — so we can't `wait --for=ready`
# here. Instead poll `vault status`'s exit code directly:
#   0 = initialized AND unsealed
#   1 = a real error (vault binary/API unreachable)
#   2 = running but sealed or uninitialized (the case we're waiting past)
echo "==> Waiting for the Vault API to respond"
for _ in {1..30}; do
  set +e
  kubectl -n "${NAMESPACE}" exec vault-0 -- vault status >/tmp/vault-status.out 2>&1
  code=$?
  set -e
  if [ "$code" -eq 0 ] || [ "$code" -eq 2 ]; then
    break
  fi
  sleep 10
done

if ! grep -q "Initialized.*true" /tmp/vault-status.out; then
  echo "==> Vault is not yet initialized — running one-time operator init"
  # -recovery-shares=1 -recovery-threshold=1: single recovery key rather
  # than the default 5-share/3-threshold quorum. Deliberate simplification
  # for this project's single-operator scope — tighten this (and restrict
  # who can read the Secret below via RBAC) before treating this as a real
  # production secret store.
  kubectl -n "${NAMESPACE}" exec vault-0 -- vault operator init \
    -recovery-shares=1 \
    -recovery-threshold=1 \
    -format=json > /tmp/vault-init.json

  ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('/tmp/vault-init.json'))['root_token'])")
  RECOVERY_KEY=$(python3 -c "import json; print(json.load(open('/tmp/vault-init.json'))['recovery_keys_b64'][0])")

  echo "==> Writing root token + recovery key to Secret ${NAMESPACE}/vault-init (never printed here)"
  kubectl -n "${NAMESPACE}" delete secret vault-init --ignore-not-found
  kubectl -n "${NAMESPACE}" create secret generic vault-init \
    --from-literal=root_token="${ROOT_TOKEN}" \
    --from-literal=recovery_key="${RECOVERY_KEY}"

  shred -u /tmp/vault-init.json 2>/dev/null || rm -f /tmp/vault-init.json
else
  echo "==> Vault is already initialized — skipping init (idempotent no-op)"
fi
rm -f /tmp/vault-status.out

# Every subsequent vault command needs the root token as its auth context
# — kubectl exec doesn't preserve one shell's env across calls, so it's
# passed explicitly via VAULT_TOKEN on each exec.
ROOT_TOKEN=$(kubectl -n "${NAMESPACE}" get secret vault-init -o jsonpath='{.data.root_token}' | base64 -d)
vexecauth() {
  kubectl -n "${NAMESPACE}" exec vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" vault "$@"
}

echo "==> Writing order-api policy (idempotent — same content every run)"
kubectl -n "${NAMESPACE}" exec -i vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" vault policy write "order-api-policy-${ENVIRONMENT}" - <<POLICY
path "secret/data/logging-eks-${ENVIRONMENT}/order-api" {
  capabilities = ["read"]
}
POLICY

# dev, sit, and prod are fully separate EKS clusters (see
# terraform/platform/environments/), so each needs its OWN Kubernetes auth mount
# pointed at that cluster's own API server — a single shared
# auth/kubernetes mount can only validate JWTs from one cluster's service
# account issuer.
AUTH_PATH="kubernetes-${ENVIRONMENT}"
echo "==> Ensuring auth/${AUTH_PATH} is enabled"
vexecauth auth enable -path="${AUTH_PATH}" kubernetes 2>/dev/null || \
  echo "    already enabled"

echo "==> Configuring ${AUTH_PATH} against this cluster's API server"
vexecauth write "auth/${AUTH_PATH}/config" \
  kubernetes_host="https://kubernetes.default.svc"

vexecauth write "auth/${AUTH_PATH}/role/order-api" \
  bound_service_account_names=order-api \
  bound_service_account_namespaces=applications \
  policies="order-api-policy-${ENVIRONMENT}" \
  ttl=1h

# Ensure the KV v2 secrets engine exists at secret/
echo "==> Ensuring KV v2 secrets engine is enabled at secret/"
vexecauth secrets enable -path=secret kv-v2 2>/dev/null || \
  echo "    secret/ already enabled"

echo "==> Populating the order-api KV secret (only if it doesn't already exist)"
if kubectl -n "${NAMESPACE}" exec vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" \
    vault kv get "secret/logging-eks-${ENVIRONMENT}/order-api" >/dev/null 2>&1; then
  echo "    already populated — leaving existing values untouched"
else
  DB_PASSWORD=$(openssl rand -base64 24)
  EXTERNAL_API_KEY=$(openssl rand -hex 16)
  kubectl -n "${NAMESPACE}" exec -i vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN}" \
    vault kv put "secret/logging-eks-${ENVIRONMENT}/order-api" \
    db_password="${DB_PASSWORD}" \
    external_api_key="${EXTERNAL_API_KEY}"
  unset DB_PASSWORD EXTERNAL_API_KEY
fi

unset ROOT_TOKEN
echo "==> Vault fully bootstrapped for ${ENVIRONMENT}: initialized, unsealed, auth configured, order-api secret populated."
echo "==> Root token retrieval (only if you need interactive Vault CLI access):"
echo "    kubectl -n ${NAMESPACE} get secret vault-init -o jsonpath='{.data.root_token}' | base64 -d"
