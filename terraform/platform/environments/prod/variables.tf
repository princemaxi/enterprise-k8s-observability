variable "state_bucket" {
  type    = string
  default = "qyon-terraform-state"
}

variable "state_region" {
  type    = string
  default = "eu-west-2"
}

variable "infrastructure_state_key" {
  type    = string
  default = "enterprise-k8s-logging/prod/infrastructure/terraform.tfstate"
}

variable "alert_email" {
  type    = string
  default = "admin@qyonlimited.com"
}

variable "domain_name" {
  description = "Base domain for Kibana/Order-API ingress (delegated zone) — informational, not wired into any Terraform resource; the plain-YAML ingress manifests must be kept in sync with this by hand"
  type        = string
  default     = "logging.qyonlimited.com"
}

variable "tags" {
  type = map(string)
  default = {
    Project     = "enterprise-k8s-logging"
    ManagedBy   = "terraform"
    Environment = "prod"
    Owner       = "Qyon Limited"
  }
}

variable "route53_hosted_zone_id" {
  description = "Route53 hosted zone ID for the shared qyonlimited.com zone (same zone for all three environments — DNS-01 is zone-scoped). Required, no default — get it with: aws route53 list-hosted-zones-by-name --dns-name qyonlimited.com --query \"HostedZones[0].Id\" --output text"
  type        = string
}

variable "elasticsearch" {
  type = object({
    version            = optional(string, "8.15.0")
    master_count       = number
    master_storage_gb  = number
    master_cpu_request = string
    master_cpu_limit   = string
    master_memory      = string
    master_heap        = string
    data_count         = number
    data_storage_gb    = number
    data_cpu_request   = string
    data_cpu_limit     = string
    data_memory        = string
    data_heap          = string
  })
  default = {
    master_count       = 3
    master_storage_gb  = 30
    master_cpu_request = "1"
    master_cpu_limit   = "2"
    master_memory      = "4Gi"
    master_heap        = "2g"
    data_count         = 3
    data_storage_gb    = 1000 # ~1TB/node x 3 nodes with 1 replica ≈ workable headroom over the 2.5TB/30d estimate, see docs/capacity-planning.md
    data_cpu_request   = "2"
    data_cpu_limit     = "4"
    data_memory        = "8Gi"
    data_heap          = "4g"
  }
}

variable "kibana" {
  type = object({
    replicas       = number
    cpu_request    = string
    cpu_limit      = string
    memory_request = string
    memory_limit   = string
  })
  default = {
    replicas       = 2
    cpu_request    = "500m"
    cpu_limit      = "1"
    memory_request = "1Gi"
    memory_limit   = "2Gi"
  }
}

variable "order_api" {
  type = object({
    replicas       = number
    log_level      = optional(string, "INFO")
    cpu_request    = string
    cpu_limit      = string
    memory_request = string
    memory_limit   = string
    image_tag      = string
  })
  default = {
    replicas       = 3
    cpu_request    = "100m"
    cpu_limit      = "500m"
    memory_request = "128Mi"
    memory_limit   = "256Mi"
    image_tag      = "v1.0.0" # pin to a real release tag before applying — never :latest in prod
  }
}

variable "slm_expire_after" {
  type    = string
  default = "90d"
}
