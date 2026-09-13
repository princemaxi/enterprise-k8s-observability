# Previously required two manual `kubectl create secret` commands after
# `terraform apply` finished, copying values read out of ECK's
# auto-generated secrets by hand. Now done directly via data sources
# (elasticsearch.tf) — Terraform reads the real, ECK-generated password
# and CA cert and copies them into the `logging` namespace itself.

resource "kubernetes_secret_v1" "filebeat_es_credentials" {
  metadata {
    name      = "filebeat-es-credentials"
    namespace = kubernetes_namespace_v1.logging.metadata[0].name
  }

  data = {
    username = "elastic"
    password = data.kubernetes_secret_v1.es_elastic_user.data["elastic"]
  }
}

resource "kubernetes_secret_v1" "filebeat_es_ca" {
  metadata {
    name      = "logging-es-http-certs-public"
    namespace = kubernetes_namespace_v1.logging.metadata[0].name
  }

  data = {
    "ca.crt" = data.kubernetes_secret_v1.es_http_ca.data["ca.crt"]
  }
}

resource "helm_release" "filebeat" {
  name       = "filebeat"
  repository = "https://helm.elastic.co"
  chart      = "filebeat"
  version    = "8.5.1"
  namespace  = kubernetes_namespace_v1.logging.metadata[0].name

  values = [
    yamlencode({
      imageTag = "8.15.0"

      daemonset = {
        resources = {
          requests = {
            cpu    = "100m"
            memory = "100Mi"
          }

          limits = {
            cpu    = "500m"
            memory = "300Mi"
          }
        }

        extraEnvs = [
          {
            name  = "ELASTICSEARCH_HOSTS"
            value = "https://logging-es-http.${kubernetes_namespace_v1.elastic_system.metadata[0].name}.svc:9200"
          },
          {
            name = "ELASTICSEARCH_USERNAME"

            valueFrom = {
              secretKeyRef = {
                name = kubernetes_secret_v1.filebeat_es_credentials.metadata[0].name
                key  = "username"
              }
            }
          },
          {
            name = "ELASTICSEARCH_PASSWORD"

            valueFrom = {
              secretKeyRef = {
                name = kubernetes_secret_v1.filebeat_es_credentials.metadata[0].name
                key  = "password"
              }
            }
          }
        ]

        secretMounts = [
          {
            name       = "es-ca-cert"
            secretName = kubernetes_secret_v1.filebeat_es_ca.metadata[0].name
            path       = "/usr/share/filebeat/certs"
          }
        ]

        filebeatConfig = {
          "filebeat.yml" = <<-EOT
            setup.ilm.enabled: false
            setup.template.enabled: false

            filebeat.autodiscover:
              providers:
                - type: kubernetes
                  node: $${NODE_NAME}
                  hints.enabled: false
                  templates:
                    - condition:
                        equals:
                          kubernetes.annotations.co_elastic_logs/enabled: "true"
                      config:
                        - type: container
                          paths:
                            - "/var/log/containers/*$${data.kubernetes.container.id}.log"

                          json.keys_under_root: true
                          json.add_error_key: true
                          json.message_key: message

                          multiline.type: pattern
                          multiline.pattern: '^\{'
                          multiline.negate: true
                          multiline.match: after
                          multiline.max_lines: 50
                          multiline.timeout: 5s

            processors:
              - add_kubernetes_metadata:
                  host: $${NODE_NAME}
                  matchers:
                    - logs_path:
                        logs_path: "/var/log/containers/"

              - drop_event:
                  when:
                    contains:
                      http.path: "/health"

            queue.mem:
              events: 4096
              flush.min_events: 512
              flush.timeout: 5s

            output.elasticsearch:
              hosts: ["$${ELASTICSEARCH_HOSTS}"]
              username: "$${ELASTICSEARCH_USERNAME}"
              password: "$${ELASTICSEARCH_PASSWORD}"

              ssl.certificate_authorities:
                - "/usr/share/filebeat/certs/ca.crt"

              index: "app-logs"
              bulk_max_size: 200
              worker: 2
              max_retries: 3
              backoff.init: 1s
              backoff.max: 60s

            logging.metrics.enabled: true
            monitoring.enabled: false
          EOT
        }
      }

      tolerations = [
        {
          key      = "dedicated"
          operator = "Equal"
          value    = "es-data"
          effect   = "NoSchedule"
        },
        {
          key      = "dedicated"
          operator = "Equal"
          value    = "es-master"
          effect   = "NoSchedule"
        },
        {
          key      = "node.kubernetes.io/not-ready"
          operator = "Exists"
          effect   = "NoExecute"
        }
      ]
    })
  ]

  depends_on = [
    null_resource.wait_for_elasticsearch,
    kubernetes_secret_v1.filebeat_es_credentials,
    kubernetes_secret_v1.filebeat_es_ca,
  ]
}
