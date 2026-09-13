resource "kubectl_manifest" "cluster_issuer" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = "letsencrypt-route53" }
    spec = {
      acme = {
        server              = "https://acme-v02.api.letsencrypt.org/directory"
        email               = var.alert_email
        privateKeySecretRef = { name = "letsencrypt-route53-key" }
        solvers = [{
          dns01 = {
            route53 = {
              region       = var.aws_region
              hostedZoneID = var.route53_hosted_zone_id
            }
          }
          selector = {
            dnsZones = ["qyonlimited.com"]
          }
        }]
      }
    }
  })

  depends_on = [
    helm_release.cert_manager,
    aws_eks_pod_identity_association.cert_manager,
  ]
}

resource "kubernetes_ingress_v1" "kibana" {
  metadata {
    name      = "kibana"
    namespace = kubernetes_namespace_v1.elastic_system.metadata[0].name
    annotations = {
      "cert-manager.io/cluster-issuer"               = "letsencrypt-route53"
      "nginx.ingress.kubernetes.io/backend-protocol" = "HTTPS"
      "nginx.ingress.kubernetes.io/ssl-passthrough"  = "false"
      "nginx.ingress.kubernetes.io/proxy-body-size"  = "10m"
    }
  }
  spec {
    ingress_class_name = "nginx"
    tls {
      hosts       = ["kibana.${var.domain_name}"]
      secret_name = "kibana-ingress-tls"
    }
    rule {
      host = "kibana.${var.domain_name}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "logging-kb-http"
              port { number = 5601 }
            }
          }
        }
      }
    }
  }
  depends_on = [
    kubectl_manifest.cluster_issuer,
    kubectl_manifest.kibana,
    helm_release.ingress_nginx,
    helm_release.external_dns,
  ]
}

# Separate Ingress/host from Kibana so it can be reasoned about (and
# network-policied) independently. Referenced by scripts/perf-test.js.
resource "kubernetes_ingress_v1" "order_api" {
  metadata {
    name      = "order-api"
    namespace = kubernetes_namespace_v1.applications.metadata[0].name
    annotations = {
      "cert-manager.io/cluster-issuer"              = "letsencrypt-route53"
      "nginx.ingress.kubernetes.io/proxy-body-size" = "1m"
    }
  }
  spec {
    ingress_class_name = "nginx"
    tls {
      hosts       = ["order-api.${var.domain_name}"]
      secret_name = "order-api-ingress-tls"
    }
    rule {
      host = "order-api.${var.domain_name}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.order_api.metadata[0].name
              port { number = 8080 }
            }
          }
        }
      }
    }
  }
  depends_on = [
    kubectl_manifest.cluster_issuer,
    kubernetes_deployment_v1.order_api,
    helm_release.ingress_nginx,
    helm_release.external_dns,
  ]
}
