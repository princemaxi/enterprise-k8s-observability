#!/usr/bin/env bash
# Called by null_resource.es_bootstrap (elasticsearch.tf) via local-exec.
# Idempotent — the ILM policy/index template/snapshot repo/SLM
# policy/Watcher are all PUT calls (safe to re-apply with identical
# content), and the bootstrap index check explicitly skips if it already
# exists. Safe to re-run on every `terraform apply`.
set -euo pipefail

: "${CLUSTER_NAME:?CLUSTER_NAME env var required}"
: "${AWS_REGION:?AWS_REGION env var required}"
: "${NAMESPACE:?NAMESPACE env var required}"
: "${SNAPSHOT_BUCKET:?SNAPSHOT_BUCKET env var required}"
: "${SLM_EXPIRE_AFTER:?SLM_EXPIRE_AFTER env var required}"
: "${ALERT_EMAIL:?ALERT_EMAIL env var required}"

echo "==> Configuring kubectl for ${CLUSTER_NAME}"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null

echo "==> Retrieving elastic user password"
ES_PASS=$(kubectl -n "${NAMESPACE}" get secret logging-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)

echo "==> Picking a master pod to run the bootstrap from"
ES_POD=$(kubectl -n "${NAMESPACE}" get pods -l elasticsearch.k8s.elastic.co/statefulset-name=logging-es-master \
  -o jsonpath='{.items[0].metadata.name}')
if [ -z "$ES_POD" ]; then
  echo "ERROR: no master pod found in namespace ${NAMESPACE}" >&2
  exit 1
fi
echo "    using ${ES_POD}"

# Transported as base64 over stdin, not interpolated into a heredoc or a
# `bash -c` argument — this sidesteps the multi-layer shell-quoting
# hazards of nesting several large JSON payloads (each with their own
# quotes/braces/dollar-signs) inside kubectl exec inside a local-exec
# provisioner. The remote script is decoded and executed as one opaque,
# already-correct unit.
SCRIPT_B64=$(base64 -w0 "$(dirname "$0")/es-bootstrap-remote.sh" 2>/dev/null || base64 "$(dirname "$0")/es-bootstrap-remote.sh")

echo "$SCRIPT_B64" | kubectl -n "${NAMESPACE}" exec -i "${ES_POD}" -- \
  env ES_PASS="${ES_PASS}" \
      NAMESPACE="${NAMESPACE}" \
      SNAPSHOT_BUCKET="${SNAPSHOT_BUCKET}" \
      AWS_REGION="${AWS_REGION}" \
      SLM_EXPIRE_AFTER="${SLM_EXPIRE_AFTER}" \
      ALERT_EMAIL="${ALERT_EMAIL}" \
      bash -c 'base64 -d | bash'

unset ES_PASS
echo "==> Elasticsearch bootstrap done."
