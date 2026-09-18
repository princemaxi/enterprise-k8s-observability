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
  default = "enterprise-k8s-logging/sit/infrastructure/terraform.tfstate"
}

variable "alert_email" {
  type    = string
  default = "admin@qyonlimited.com"
}

variable "domain_name" {
  type    = string
  default = "sit.logging.qyonlimited.com"
}

variable "tags" {
  type = map(string)
  default = {
    Project     = "enterprise-k8s-logging"
    ManagedBy   = "terraform"
    Environment = "sit"
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
  # Full 3-master quorum (same as prod — sit's entire purpose is proving
  # HA/failover behavior works before it's trusted in prod) with 2 data
  # nodes and resources sized for r6i.large rather than prod's r6i.xlarge.
  default = {
    master_count       = 3
    master_storage_gb  = 20
    master_cpu_request = "500m"
    master_cpu_limit   = "1"
    master_memory      = "2Gi"
    master_heap        = "1g"
    data_count         = 2
    data_storage_gb    = 200
    data_cpu_request   = "1"
    data_cpu_limit     = "2"
    data_memory        = "4Gi"
    data_heap          = "2g"
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
    replicas       = 2 # enough to exercise anti-affinity/rolling updates without prod's full count
    cpu_request    = "300m"
    cpu_limit      = "750m"
    memory_request = "768Mi"
    memory_limit   = "1536Mi"
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
    replicas       = 2 # enough to exercise rolling updates without prod's full 3
    cpu_request    = "75m"
    cpu_limit      = "350m"
    memory_request = "112Mi"
    memory_limit   = "224Mi"
    image_tag      = "sit-latest"
  }
}

variable "slm_expire_after" {
  type    = string
  default = "14d"
}
