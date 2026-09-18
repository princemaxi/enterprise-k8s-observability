variable "environment" {
  description = "Environment name (dev, sit, prod) — used in tags and resource naming"
  type        = string
  validation {
    condition     = contains(["dev", "sit", "prod"], var.environment)
    error_message = "environment must be one of: dev, sit, prod."
  }
}

variable "aws_region" {
  description = "AWS region — used directly in Vault's awskms seal stanza (vault.tf), not just for provider config"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name — should already be environment-scoped, e.g. logging-eks-dev"
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "es_snapshot_bucket" {
  type = string
}

variable "es_snapshot_access_key_id" {
  type      = string
  sensitive = true
}

variable "es_snapshot_secret_access_key" {
  type      = string
  sensitive = true
}

variable "vault_unseal_kms_key_id" {
  type = string
}

variable "order_api_ecr_repository_url" {
  type = string
}

variable "route53_hosted_zone_id" {
  description = "Route53 hosted zone ID for the shared qyonlimited.com zone — scopes the cert-manager IRSA role to only this zone's DNS-01 challenge records, not every zone in the account. Get it with: aws route53 list-hosted-zones-by-name --dns-name qyonlimited.com --query \"HostedZones[0].Id\" --output text"
  type        = string
}

variable "domain_name" {
  description = "Base domain for Kibana/Order-API ingress in this environment"
  type        = string
}

variable "tags" {
  type = map(string)
}

# --- Elasticsearch/Kibana sizing -----------------------------------------
# Grouped as objects rather than 20+ scalar variables — each environment's
# main.tf passes one value per group, matching the "base = prod, other
# envs are smaller" convention used throughout this project.

variable "elasticsearch" {
  description = "Elasticsearch sizing for this environment"
  type = object({
    version            = optional(string, "8.15.0")
    master_count       = number
    master_storage_gb  = number
    master_cpu_request = string
    master_cpu_limit   = string
    master_memory      = string # used for both requests and limits — ES shouldn't burst above its heap-backing memory
    master_heap        = string # e.g. "1g" — should be ~50% of master_memory
    data_count         = number
    data_storage_gb    = number
    data_cpu_request   = string
    data_cpu_limit     = string
    data_memory        = string
    data_heap          = string
  })
}

variable "kibana" {
  description = "Kibana sizing for this environment"
  type = object({
    replicas       = number
    cpu_request    = string
    cpu_limit      = string
    memory_request = string
    memory_limit   = string
  })
}

# --- Order API -------------------------------------------------------------
variable "order_api" {
  description = "Order API sizing/config for this environment"
  type = object({
    replicas       = number
    log_level      = optional(string, "INFO")
    cpu_request    = string
    cpu_limit      = string
    memory_request = string
    memory_limit   = string
    image_tag      = string # tag PREFIX, e.g. "dev-latest", "v1.0.0" — order-api.tf appends "-<8-char source hash>" automatically, so the actual pushed tag is e.g. "v1.0.0-a3f8e21c". Never ":latest" bare, and note prod's ECR repo is IMMUTABLE — a fixed tag with no hash suffix would fail to re-push on any code change.
  })
}

variable "app_source_path" {
  description = "Path to the Order API's source directory (containing the Dockerfile) — used as the Docker build context"
  type        = string
  default     = "../../../app"
}

# --- Vault / SLM -----------------------------------------------------------
variable "slm_expire_after" {
  description = "How long SLM keeps snapshot metadata — MUST NOT exceed snapshot_retention_days above, or SLM tries to manage snapshots the S3 lifecycle rule already deleted"
  type        = string
}

variable "alert_email" {
  description = "Email address for the high-error-rate Watcher alert"
  type        = string
  default     = "admin@qyonlimited.com"
}

variable "enable_service_monitor" {
  description = "Create a Prometheus ServiceMonitor for the Order API — only if a Prometheus Operator (e.g. kube-prometheus-stack) is already deployed in this cluster; the CRD doesn't exist otherwise and applying one without it fails the whole apply."
  type        = bool
  default     = false
}

variable "prometheus_release_label" {
  description = "Value for the ServiceMonitor's release label — must match whatever your Prometheus instance's serviceMonitorSelector actually matches. Only used when enable_service_monitor = true."
  type        = string
  default     = "kube-prometheus-stack"
}
