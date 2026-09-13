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

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.34" # 1.30 reached end of EKS extended support Aug 2026 — always passed
  # explicitly by every environment's main.tf, so this default is a
  # safety net only, for any future environment that forgets to pass it.
}

variable "route53_hosted_zone_id" {
  description = "Route53 hosted zone ID for the shared qyonlimited.com zone — scopes the cert-manager IRSA role to only this zone's DNS-01 challenge records, not every zone in the account. Get it with: aws route53 list-hosted-zones-by-name --dns-name qyonlimited.com --query \"HostedZones[0].Id\" --output text"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for this environment's VPC — must not overlap other environments if they're ever peered"
  type        = string
}

variable "azs" {
  description = "Availability zones to spread nodes/storage across"
  type        = list(string)
  default     = ["eu-west-2a", "eu-west-2b", "eu-west-2c"]
}

variable "single_nat_gateway" {
  description = "Use one shared NAT gateway instead of one-per-AZ. Fine for dev/sit (cost saving, no HA requirement); never set true for prod — a single NAT is a single point of egress failure across all 3 AZs."
  type        = bool
  default     = false
}

variable "es_node_instance_type" {
  description = "Instance type for Elasticsearch data/master nodes"
  type        = string
}

variable "general_node_instance_type" {
  description = "Instance type for general workloads (Kibana, Filebeat, app, ingress)"
  type        = string
}

variable "es_data_node_desired_count" {
  type = number
}

variable "es_master_node_desired_count" {
  type = number
}

variable "general_node_desired_count" {
  type = number
}

variable "snapshot_bucket_name" {
  description = "S3 bucket for Elasticsearch snapshots (must be globally unique — include the environment name)"
  type        = string
}

variable "snapshot_retention_days" {
  description = "Days before S3 snapshots expire. Prod should outlive the 30-day hot index retention for real DR; dev/sit can be much shorter since they're not protecting production data."
  type        = number
  default     = 90
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
