# The S3 snapshot keystore Secret — previously required a manual
# `kubectl create secret` / `make es-secrets` step after `terraform
# apply` finished, reading Terraform outputs by hand. Now populated
# directly from the infrastructure state's IAM access key output.
resource "kubernetes_secret_v1" "es_snapshot_credentials" {
  metadata {
    name      = "es-snapshot-credentials"
    namespace = kubernetes_namespace_v1.elastic_system.metadata[0].name
  }
  data = {
    "s3.client.default.access_key" = var.es_snapshot_access_key_id
    "s3.client.default.secret_key" = var.es_snapshot_secret_access_key
  }
}

resource "kubectl_manifest" "elasticsearch" {
  yaml_body = templatefile("${path.module}/templates/elasticsearch.yaml.tpl", {
    namespace          = kubernetes_namespace_v1.elastic_system.metadata[0].name
    version            = var.elasticsearch.version
    master_count       = var.elasticsearch.master_count
    master_storage_gb  = var.elasticsearch.master_storage_gb
    master_cpu_request = var.elasticsearch.master_cpu_request
    master_cpu_limit   = var.elasticsearch.master_cpu_limit
    master_memory      = var.elasticsearch.master_memory
    master_heap        = var.elasticsearch.master_heap
    data_count         = var.elasticsearch.data_count
    data_storage_gb    = var.elasticsearch.data_storage_gb
    data_cpu_request   = var.elasticsearch.data_cpu_request
    data_cpu_limit     = var.elasticsearch.data_cpu_limit
    data_memory        = var.elasticsearch.data_memory
    data_heap          = var.elasticsearch.data_heap
  })

  # kubectl_manifest (alekc/kubectl provider), not kubernetes_manifest
  # (hashicorp/kubernetes) — the latter validates against the CRD's
  # schema at PLAN time, which explicitly cannot work when the CRD
  # (installed by helm_release.eck_operator) is created in the same
  # apply as the resource that needs it. kubectl_manifest does a live
  # dry-run apply against the API server instead, sidestepping that.
  depends_on = [
    helm_release.eck_operator,
    kubernetes_storage_class_v1.es_gp3,
    kubernetes_secret_v1.es_snapshot_credentials,
  ]
}

# kubectl_manifest's own "apply succeeded" doesn't mean the ECK operator
# has finished reconciling — StatefulSets still need to schedule, pods
# still need to actually come up and join the cluster. Kibana,
# Filebeat's credentials (filebeat.tf), and the Order API's Vault secret
# all need a genuinely healthy Elasticsearch, not just "the API accepted
# the CR" — so this polls real cluster health the same way
# vault-bootstrap.sh polls real Vault status, and everything downstream
# depends on THIS, not on kubectl_manifest.elasticsearch directly.
resource "null_resource" "wait_for_elasticsearch" {
  triggers = {
    es_manifest_id = kubectl_manifest.elasticsearch.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.module}/scripts/wait-for-elasticsearch.sh"
    environment = {
      CLUSTER_NAME = var.cluster_name
      AWS_REGION   = var.aws_region
      NAMESPACE    = kubernetes_namespace_v1.elastic_system.metadata[0].name
    }
  }

  depends_on = [kubectl_manifest.elasticsearch]
}

# Read once Elasticsearch is confirmed green — ECK auto-generates both of
# these; Terraform can't know them ahead of time, only read them back.
data "kubernetes_secret_v1" "es_elastic_user" {
  metadata {
    name      = "logging-es-elastic-user"
    namespace = kubernetes_namespace_v1.elastic_system.metadata[0].name
  }
  depends_on = [null_resource.wait_for_elasticsearch]
}

data "kubernetes_secret_v1" "es_http_ca" {
  metadata {
    name      = "logging-es-http-certs-public"
    namespace = kubernetes_namespace_v1.elastic_system.metadata[0].name
  }
  depends_on = [null_resource.wait_for_elasticsearch]
}

# ILM policy, index template, the S3 snapshot repository, SLM policy, and
# the high-error-rate Watcher alert — previously a manual run of
# scripts/snapshot-setup.sh plus a separate manual `curl -X PUT
# .../_watcher/watch/high_error_rate` after `terraform apply` finished.
# Idempotent (see scripts/es-bootstrap.sh's header comment) — safe on
# every re-apply.
resource "null_resource" "es_bootstrap" {
  triggers = {
    es_manifest_id = kubectl_manifest.elasticsearch.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.module}/scripts/es-bootstrap.sh"
    environment = {
      CLUSTER_NAME     = var.cluster_name
      AWS_REGION       = var.aws_region
      NAMESPACE        = kubernetes_namespace_v1.elastic_system.metadata[0].name
      SNAPSHOT_BUCKET  = var.es_snapshot_bucket
      SLM_EXPIRE_AFTER = var.slm_expire_after
      ALERT_EMAIL      = var.alert_email
    }
  }

  depends_on = [null_resource.wait_for_elasticsearch]
}
