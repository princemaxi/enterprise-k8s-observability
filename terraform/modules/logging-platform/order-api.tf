# --- Docker build + push, no manual `docker build`/`docker push`/`docker login` ---
locals {
  # Rebuilds the image whenever any file under app_source_path changes —
  # not on every `terraform apply` regardless of whether the app changed.
  app_source_files = fileset(var.app_source_path, "**")
  app_source_hash  = sha1(join("", [for f in local.app_source_files : filesha1("${var.app_source_path}/${f}")]))
  # Content-addressable tag, not just var.order_api.image_tag alone —
  # this removes any ambiguity about whether docker_registry_image
  # actually detects and re-pushes a code change: every source change
  # produces a genuinely different tag string, so the Kubernetes
  # Deployment (which references this same value) is guaranteed to see a
  # new image reference and roll out, rather than depending on digest
  # comparison inside the registry_image resource to catch it.
  order_api_image = "${var.order_api_ecr_repository_url}:${var.order_api.image_tag}-${substr(local.app_source_hash, 0, 8)}"
}

resource "docker_image" "order_api" {
  name = local.order_api_image
  build {
    context = var.app_source_path
  }
  triggers = {
    source_hash = local.app_source_hash
  }
}

resource "docker_registry_image" "order_api" {
  name          = docker_image.order_api.name
  keep_remotely = var.environment == "prod" # prod: never let a push delete a previous tag's remote image out from under a rollback; dev/sit: fine to let old pushes get GC'd
}

# --- Kubernetes resources ----------------------------------------------------
resource "kubernetes_service_account_v1" "order_api" {
  metadata {
    name      = "order-api"
    namespace = kubernetes_namespace_v1.applications.metadata[0].name
  }
}

resource "kubernetes_deployment_v1" "order_api" {
  metadata {
    name      = "order-api"
    namespace = kubernetes_namespace_v1.applications.metadata[0].name
  }

  spec {
    replicas = var.order_api.replicas

    selector {
      match_labels = { app = "order-api" }
    }

    template {
      metadata {
        labels = { app = "order-api" }
        annotations = {
          # Opt-in flag Filebeat's autodiscover config checks for — see filebeat.tf
          "co.elastic.logs/enabled" = "true"

          # Vault Agent sidecar injection — directly environment-scoped
          # here (var.environment), rather than the old base=prod +
          # per-env-overlay-patch pattern this replaced. Each
          # environment's own `terraform apply` generates its own
          # correctly-scoped resource; there's no shared "base" to patch.
          "vault.hashicorp.com/agent-inject"                     = "true"
          "vault.hashicorp.com/auth-path"                        = "auth/kubernetes-${var.environment}"
          "vault.hashicorp.com/role"                             = "order-api"
          "vault.hashicorp.com/agent-inject-secret-config.env"   = "secret/data/logging-eks-${var.environment}/order-api"
          "vault.hashicorp.com/agent-inject-template-config.env" = <<-EOT
            {{- with secret "secret/data/logging-eks-${var.environment}/order-api" -}}
            DB_PASSWORD={{ .Data.data.db_password }}
            EXTERNAL_API_KEY={{ .Data.data.external_api_key }}
            {{- end -}}
          EOT
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.order_api.metadata[0].name
        node_selector        = { role = "general" }

        security_context {
          run_as_non_root = true
          run_as_user     = 10001
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name  = "order-api"
          image = docker_registry_image.order_api.name

          port {
            name           = "http"
            container_port = 8080
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            run_as_user                = 10001
            capabilities {
              drop = ["ALL"]
            }
            seccomp_profile {
              type = "RuntimeDefault"
            }
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp" # gunicorn's worker heartbeat writes here by default — see docs/troubleshooting.md for the incident this fixed
          }

          env {
            name  = "ENVIRONMENT"
            value = var.environment
          }
          env {
            name  = "LOG_LEVEL"
            value = var.order_api.log_level
          }

          resources {
            requests = {
              cpu    = var.order_api.cpu_request
              memory = var.order_api.memory_request
            }
            limits = {
              cpu    = var.order_api.cpu_limit
              memory = var.order_api.memory_limit
            }
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 20
          }
        }

        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [docker_registry_image.order_api]
}

resource "kubernetes_service_v1" "order_api" {
  metadata {
    name      = "order-api"
    namespace = kubernetes_namespace_v1.applications.metadata[0].name
  }
  spec {
    selector = { app = "order-api" }
    port {
      name        = "http"
      port        = 8080
      target_port = "http"
    }
  }
}

# Optional — only created if a Prometheus Operator (e.g. kube-prometheus-stack)
# is already deployed in this cluster; the ServiceMonitor CRD doesn't
# exist otherwise, and applying one without its CRD would fail the whole
# apply. Off by default; see variables.tf.
resource "kubectl_manifest" "order_api_service_monitor" {
  count = var.enable_service_monitor ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "order-api"
      namespace = kubernetes_namespace_v1.applications.metadata[0].name
      labels    = { release = var.prometheus_release_label }
    }
    spec = {
      selector  = { matchLabels = { app = "order-api" } }
      endpoints = [{ port = "http", path = "/metrics", interval = "15s" }]
    }
  })

  depends_on = [kubernetes_service_v1.order_api]
}
