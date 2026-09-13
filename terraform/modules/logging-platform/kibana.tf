resource "kubectl_manifest" "kibana" {
  yaml_body = templatefile("${path.module}/templates/kibana.yaml.tpl", {
    namespace      = kubernetes_namespace_v1.elastic_system.metadata[0].name
    version        = var.elasticsearch.version # Kibana and ES versions must match — one source of truth
    replicas       = var.kibana.replicas
    domain_name    = var.domain_name
    cpu_request    = var.kibana.cpu_request
    cpu_limit      = var.kibana.cpu_limit
    memory_request = var.kibana.memory_request
    memory_limit   = var.kibana.memory_limit
  })

  # Depends on the actual health-poll gate, not just kubectl_manifest.elasticsearch
  # — Kibana's elasticsearchRef will sit unable to connect if ES accepted
  # the CR but hasn't actually finished coming up yet.
  depends_on = [null_resource.wait_for_elasticsearch]
}
