variable "aws_region" {
  type    = string
  default = "eu-west-2"
}

variable "cluster_name" {
  type    = string
  default = "logging-eks-sit"
}

variable "cluster_version" {
  type    = string
  default = "1.34" # 1.30 reached end of EKS extended support Aug 2026 — verify current validity with:
  # aws eks describe-addon-versions --kubernetes-version <candidate> --addon-name aws-ebs-csi-driver
}

variable "vpc_cidr" {
  description = "Must not overlap dev (10.21.0.0/16) or prod (10.20.0.0/16)"
  type        = string
  default     = "10.22.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["eu-west-2a", "eu-west-2b", "eu-west-2c"]
}

# Same cost-saving reasoning as dev — sit's job is validating application
# and cluster *behavior* (failover, rolling upgrades, ILM), not validating
# multi-AZ network resilience, so a single NAT is an acceptable trade here.
variable "single_nat_gateway" {
  type    = bool
  default = true
}

variable "es_node_instance_type" {
  type    = string
  default = "r6i.large"
}

variable "general_node_instance_type" {
  type    = string
  default = "m6i.large"
}

# 2 data nodes rather than dev's 1 — enough to actually exercise shard
# allocation/replica placement, unlike dev's single-node "cluster".
variable "es_data_node_desired_count" {
  type    = number
  default = 2
}

# Full 3-node quorum, same as prod — sit exists specifically to prove HA
# behavior (master election, rolling restarts, node loss) works before
# anyone trusts it in prod. Scaling this down to 1 would defeat the point
# of having a sit environment at all.
variable "es_master_node_desired_count" {
  type    = number
  default = 3
}

variable "general_node_desired_count" {
  type    = number
  default = 2
}

variable "snapshot_bucket_name" {
  type    = string
  default = "qyon-logging-es-snapshots-sit"
}

variable "snapshot_retention_days" {
  type    = number
  default = 14
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
    data_heap           = "2g"
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
