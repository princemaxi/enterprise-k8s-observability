variable "aws_region" {
  type    = string
  default = "eu-west-2"
}

variable "cluster_name" {
  type    = string
  default = "logging-eks-dev"
}

variable "cluster_version" {
  type    = string
  default = "1.34" # 1.30 reached end of EKS extended support Aug 2026 — verify current validity with:
  # aws eks describe-addon-versions --kubernetes-version <candidate> --addon-name aws-ebs-csi-driver
}

variable "vpc_cidr" {
  description = "Must not overlap sit (10.22.0.0/16) or prod (10.20.0.0/16)"
  type        = string
  default     = "10.21.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["eu-west-2a", "eu-west-2b", "eu-west-2c"]
}

# Dev doesn't need cross-AZ egress resilience — one shared NAT is a real
# cost saving here (2 fewer NAT gateways than prod) with no functional
# downside for a non-HA environment.
variable "single_nat_gateway" {
  type    = bool
  default = true
}

# Smaller/cheaper than prod's r6i.xlarge — dev is for functional
# correctness, not for validating memory/IO headroom under load.
variable "es_node_instance_type" {
  type    = string
  default = "r6i.large"
}

variable "general_node_instance_type" {
  type    = string
  default = "t3.medium"
}

# 1 master + 1 data — no quorum, no HA. This is intentional: dev is for
# verifying the application and manifests work, not for testing failover
# behavior (that's what sit is for).
variable "es_data_node_desired_count" {
  type    = number
  default = 1
}

variable "es_master_node_desired_count" {
  type    = number
  default = 1
}

variable "general_node_desired_count" {
  type    = number
  default = 2
}

variable "snapshot_bucket_name" {
  type    = string
  default = "qyon-logging-es-snapshots-dev"
}

# Dev isn't protecting real data — a week of snapshot history is plenty,
# and it keeps S3 cost near zero.
variable "snapshot_retention_days" {
  type    = number
  default = 7
}

variable "domain_name" {
  type    = string
  default = "dev.logging.qyonlimited.com"
}

variable "tags" {
  type = map(string)
  default = {
    Project     = "enterprise-k8s-logging"
    ManagedBy   = "terraform"
    Environment = "dev"
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
  # 1 master + 1 data, small heap/storage. No HA — dev is for functional
  # testing, not resilience testing (that's what sit is for).
  default = {
    master_count       = 1
    master_storage_gb  = 10
    master_cpu_request = "500m"
    master_cpu_limit   = "1"
    master_memory      = "1Gi"
    master_heap        = "512m"
    data_count         = 1
    data_storage_gb    = 50
    data_cpu_request   = "1"
    data_cpu_limit     = "2"
    data_memory        = "2Gi"
    data_heap          = "1g"
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
    replicas       = 1 # no HA requirement in dev
    cpu_request    = "200m"
    cpu_limit      = "500m"
    memory_request = "512Mi"
    memory_limit   = "1Gi"
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
    replicas       = 1       # no HA requirement in dev
    log_level      = "DEBUG" # more verbose than prod's INFO — dev is for debugging
    cpu_request    = "50m"
    cpu_limit      = "200m"
    memory_request = "96Mi"
    memory_limit   = "192Mi"
    image_tag      = "dev-latest"
  }
}

# Must match snapshot_retention_days above — SLM's own retention must
# never outlive the S3 bucket lifecycle rule that's actually deleting the
# underlying objects.
variable "slm_expire_after" {
  type    = string
  default = "7d"
}

variable "alert_email" {
  description = "Notification email address for platform alerts and cert-manager ACME registrations"
  type        = string
}
