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
