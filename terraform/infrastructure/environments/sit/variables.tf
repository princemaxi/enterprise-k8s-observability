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
