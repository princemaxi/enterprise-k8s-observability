# Previously applied by hand via `kubectl apply -f storageclass.yaml`,
# strictly before anything that needed it (Vault's PVC, Elasticsearch's
# PVCs). That manual ordering requirement is exactly what broke on a real
# apply: Vault's helm_release tried to provision its PVC before anyone
# had run the kubectl step, and `null_resource.vault_init` timed out
# waiting for a pod that could never schedule.
#
# As a native Terraform resource, every other resource that needs this
# StorageClass can express that with a normal reference or depends_on,
# and Terraform's own dependency graph — not a human running commands in
# the right order — guarantees it exists first.
resource "kubernetes_storage_class_v1" "es_gp3" {
  metadata {
    name = "es-gp3"
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

}
