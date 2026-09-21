# Vault is deployed and initialized entirely by `terraform apply` — no
# manual `helm install`, no manual `vault operator init`, no manual
# `vault operator unseal`, and (new in this redesign) no manual
# `vault kv put` or auth-role setup either — vault-bootstrap.sh below
# handles all of it, idempotently, via `kubectl exec` straight into the
# Vault pod. That's a deliberate choice over the `hashicorp/vault`
# Terraform provider: the provider would need network reachability to
# Vault's API from wherever `terraform apply` runs, which — since Vault
# only has a ClusterIP Service — would mean either exposing it publicly
# (worse security) or a local port-forward the Terraform process would
# have to babysit mid-apply (fragile, doesn't generalize to CI).
# `kubectl exec` tunnels through the EKS API server instead, which is
# already reachable by definition.
#
# How each piece fits:
#   1. KMS key below -> Vault's seal mechanism (auto-unseal). Vault still
#      needs to be initialized ONCE (this generates the root token and
#      recovery keys), but after that, every pod restart auto-unseals via
#      KMS with zero human involvement — no `vault operator unseal` ever.
#   2. helm_release below -> installs Vault itself, configured for raft
#      (persistent, survives pod restarts) storage with the awskms seal
#      stanza baked into its server config.
#   3. null_resource below -> runs vault-bootstrap.sh, which is fully
#      idempotent: init, auth method, policy, role, and the Order API's
#      KV secret are all checked-then-created, so re-running
#      `terraform apply` never re-inits, never re-authors a policy that
#      already matches, and never overwrites an already-set secret with
#      a fresh random value. The root token is written straight into a
#      Kubernetes Secret — never printed, never in Terraform state.

resource "helm_release" "vault" {
  name       = "vault"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  version    = "0.34.1"
  namespace  = kubernetes_namespace_v1.vault.metadata[0].name

  # Single replica across every environment for now — raft technically
  # supports multi-node HA, but that's genuine additional complexity
  # (leader election, join process) intentionally deferred; see
  # docs/architecture.md for the trade-off note. KMS auto-unseal is the
  # part that actually matters for "no manual steps," and that's true at
  # any replica count.
  values = [
    yamlencode({
      injector = {
        enabled = true
      }
      server = {
        dev = { enabled = false } # dev-mode is in-memory — defeats the point of persistent auto-unseal
        dataStorage = {
          enabled      = true
          size         = "10Gi"
          storageClass = kubernetes_storage_class_v1.es_gp3.metadata[0].name
        }
        ha = {
          enabled  = true
          replicas = 1
          raft = {
            enabled = true
            config  = <<-EOT
              ui = true
              listener "tcp" {
                address     = "[::]:8200"
                cluster_address = "[::]:8201"
                # TLS termination intentionally deferred for this project's
                # scope (see docs/security.md) — Vault traffic never leaves
                # the cluster network. Revisit before treating this as a
                # real production secret store.
                tls_disable = true
              }
              storage "raft" {
                path = "/vault/data"
              }
              seal "awskms" {
                region     = "${var.aws_region}"
                kms_key_id = "${var.vault_unseal_kms_key_id}"
              }
            EOT
          }
        }
      }
    })
  ]

  # kubernetes_storage_class_v1.es_gp3 must exist before Vault's PVC can
  # bind — this dependency is the direct fix for a real incident: without
  # it, Vault's pod scheduled but its PVC could never bind (StorageClass
  # didn't exist yet), and the init step below timed out waiting for a
  # pod that could never actually come up.
  depends_on = [
    kubernetes_storage_class_v1.es_gp3,
    kubernetes_namespace_v1.vault,
    helm_release.aws_load_balancer_controller,
  ]
}

resource "null_resource" "vault_bootstrap" {
  triggers = {
    # Re-runs (harmlessly — the script itself is idempotent throughout)
    # whenever the Vault release changes, so a chart upgrade always gets
    # a fresh check.
    vault_release_id = helm_release.vault.metadata[0].revision
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.module}/scripts/vault-bootstrap.sh"
    environment = {
      CLUSTER_NAME = var.cluster_name
      AWS_REGION   = var.aws_region
      NAMESPACE    = "vault"
      ENVIRONMENT  = var.environment
    }
  }

  depends_on = [helm_release.vault]
}
