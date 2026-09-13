# Default-deny in every namespace, then explicit allow rules for the only
# paths that should exist. Kept as kubectl_manifest with the original YAML
# verbatim rather than translated into native kubernetes_network_policy_v1
# blocks — this content has already been incident-tested (see
# docs/troubleshooting.md), and hand-transcribing 9 policies' worth of
# nested selector logic into HCL block syntax is exactly the kind of
# subtle-error-prone busywork this project's redesign is trying to avoid,
# not reproduce elsewhere.
#
# Identical across all three environments — dev/sit/prod are fully
# separate clusters, not shared namespaces, so there's no per-environment
# templating needed here.

resource "kubectl_manifest" "netpol_elastic_system_deny" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata   = { name = "default-deny-all", namespace = kubernetes_namespace_v1.elastic_system.metadata[0].name }
    spec       = { podSelector = {}, policyTypes = ["Ingress", "Egress"] }
  })
  depends_on = [kubernetes_namespace_v1.elastic_system]
}

resource "kubectl_manifest" "netpol_es_allow" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata   = { name = "es-allow-internal-and-kibana-and-filebeat", namespace = kubernetes_namespace_v1.elastic_system.metadata[0].name }
    spec = {
      podSelector = { matchLabels = { "elasticsearch.k8s.elastic.co/cluster-name" = "logging" } }
      policyTypes = ["Ingress", "Egress"]
      ingress = [{
        from = [
          { podSelector = { matchLabels = { "elasticsearch.k8s.elastic.co/cluster-name" = "logging" } } },
          { podSelector = { matchLabels = { "kibana.k8s.elastic.co/name" = "logging" } } },
          { namespaceSelector = { matchLabels = { name = "logging" } } },
        ]
        ports = [{ port = 9200, protocol = "TCP" }, { port = 9300, protocol = "TCP" }]
      }]
      egress = [
        {
          to    = [{ podSelector = { matchLabels = { "elasticsearch.k8s.elastic.co/cluster-name" = "logging" } } }]
          ports = [{ port = 9300, protocol = "TCP" }]
        },
        { # DNS — resolves the S3 API endpoint hostname (ES's S3 access is
          # static-credential-based, not IRSA/Pod-Identity — see
          # elasticsearch.tf — so there's no STS token-exchange call here)
          to    = []
          ports = [{ port = 53, protocol = "UDP" }]
        },
        { # S3 snapshot access over 443
          to    = []
          ports = [{ port = 443, protocol = "TCP" }]
        },
      ]
    }
  })
  depends_on = [kubernetes_namespace_v1.elastic_system]
}

resource "kubectl_manifest" "netpol_kibana_allow" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata   = { name = "kibana-allow-ingress-and-es-egress", namespace = kubernetes_namespace_v1.elastic_system.metadata[0].name }
    spec = {
      podSelector = { matchLabels = { "kibana.k8s.elastic.co/name" = "logging" } }
      policyTypes = ["Ingress", "Egress"]
      ingress = [{
        from  = [{ namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = "ingress-nginx" } } }]
        ports = [{ port = 5601, protocol = "TCP" }]
      }]
      egress = [
        {
          to    = [{ podSelector = { matchLabels = { "elasticsearch.k8s.elastic.co/cluster-name" = "logging" } } }]
          ports = [{ port = 9200, protocol = "TCP" }]
        },
        { to = [], ports = [{ port = 53, protocol = "UDP" }] },
      ]
    }
  })
  depends_on = [kubernetes_namespace_v1.elastic_system]
}

resource "kubectl_manifest" "netpol_logging_deny" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata   = { name = "default-deny-all", namespace = kubernetes_namespace_v1.logging.metadata[0].name }
    spec       = { podSelector = {}, policyTypes = ["Ingress", "Egress"] }
  })
  depends_on = [kubernetes_namespace_v1.logging]
}

resource "kubectl_manifest" "netpol_filebeat_egress" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata   = { name = "filebeat-egress-to-es-and-k8s-api", namespace = kubernetes_namespace_v1.logging.metadata[0].name }
    spec = {
      podSelector = { matchLabels = { "app.kubernetes.io/name" = "filebeat" } }
      policyTypes = ["Egress"]
      egress = [
        {
          to    = [{ namespaceSelector = { matchLabels = { name = "elastic-system" } } }]
          ports = [{ port = 9200, protocol = "TCP" }]
        },
        { # Kubernetes API (autodiscover) + DNS
          to    = []
          ports = [{ port = 443, protocol = "TCP" }, { port = 53, protocol = "UDP" }]
        },
      ]
    }
  })
  depends_on = [kubernetes_namespace_v1.logging]
}

resource "kubectl_manifest" "netpol_applications_deny" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata   = { name = "default-deny-all", namespace = kubernetes_namespace_v1.applications.metadata[0].name }
    spec       = { podSelector = {}, policyTypes = ["Ingress", "Egress"] }
  })
  depends_on = [kubernetes_namespace_v1.applications]
}

resource "kubectl_manifest" "netpol_order_api_allow" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata   = { name = "order-api-allow-ingress-and-vault", namespace = kubernetes_namespace_v1.applications.metadata[0].name }
    spec = {
      podSelector = { matchLabels = { app = "order-api" } }
      policyTypes = ["Ingress", "Egress"]
      ingress = [
        {
          from  = [{ namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = "ingress-nginx" } } }]
          ports = [{ port = 8080, protocol = "TCP" }]
        },
        { # Prometheus scraping /metrics, if enabled — see var.enable_service_monitor
          from  = [{ namespaceSelector = { matchLabels = { name = "monitoring" } } }]
          ports = [{ port = 8080, protocol = "TCP" }]
        },
      ]
      egress = [
        {
          to    = [{ namespaceSelector = { matchLabels = { name = "vault" } } }]
          ports = [{ port = 8200, protocol = "TCP" }]
        },
        { # DNS + any external API calls the Order API itself makes.
          # Vault is in-cluster (already covered above) — this isn't for
          # reaching Vault, just everything else.
          to    = []
          ports = [{ port = 53, protocol = "UDP" }, { port = 443, protocol = "TCP" }]
        },
      ]
    }
  })
  depends_on = [kubernetes_namespace_v1.applications]
}

resource "kubectl_manifest" "netpol_vault_deny" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata   = { name = "default-deny-all", namespace = kubernetes_namespace_v1.vault.metadata[0].name }
    spec       = { podSelector = {}, policyTypes = ["Ingress", "Egress"] }
  })
  depends_on = [kubernetes_namespace_v1.vault]
}

resource "kubectl_manifest" "netpol_vault_allow" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata   = { name = "vault-allow-ingress-and-kms-egress", namespace = kubernetes_namespace_v1.vault.metadata[0].name }
    spec = {
      podSelector = {}
      policyTypes = ["Ingress", "Egress"]
      ingress = [{
        from = [
          { namespaceSelector = { matchLabels = { name = "applications" } } }, # order-api's Vault Agent init container
          { podSelector = {} },                                                # raft peer traffic within the vault namespace itself — a no-op at single-replica, kept ready for the HA upgrade path noted in vault.tf
        ]
        ports = [{ port = 8200, protocol = "TCP" }, { port = 8201, protocol = "TCP" }]
      }]
      egress = [
        {
          to    = [{ podSelector = {} }]
          ports = [{ port = 8200, protocol = "TCP" }, { port = 8201, protocol = "TCP" }]
        },
        { # DNS, and HTTPS to the AWS KMS API for auto-unseal — every
          # seal/unseal cycle needs this, not just the one-time init.
          to    = []
          ports = [{ port = 53, protocol = "UDP" }, { port = 443, protocol = "TCP" }]
        },
      ]
    }
  })
  depends_on = [kubernetes_namespace_v1.vault]
}
# NOTE: this does not attempt to scope the Vault Agent Injector's own
# mutating-webhook path (the EKS control plane calling back into the
# injector pod on its webhook port) — that's a control-plane-to-pod path
# whose exact NetworkPolicy semantics vary by CNI/version, and getting it
# subtly wrong is worse than leaving it flagged here. If Vault Agent
# injection stops working only after this policy applies, this is the
# first thing to investigate.
