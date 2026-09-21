variable "aws_region" {
  description = "AWS region for the logging cluster"
  type        = string
  default     = "eu-west-2"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "logging-eks" # unsuffixed — this is the original/primary environment
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.34" # 1.30 reached end of EKS extended support Aug 2026 — verify current validity with:
  # aws eks describe-addon-versions --kubernetes-version <candidate> --addon-name aws-ebs-csi-driver
}

variable "vpc_cidr" {
  description = "CIDR block for this environment's VPC — must not overlap dev/sit if ever peered"
  type        = string
  default     = "10.20.0.0/16"
}

variable "azs" {
  description = "Availability zones to spread nodes/storage across"
  type        = list(string)
  default     = ["eu-west-2a", "eu-west-2b", "eu-west-2c"]
}

# One NAT gateway per AZ — a single NAT would be a single point of egress
# failure across all 3 AZs. This is the one dimension prod should never
# compromise on for cost, unlike node counts/instance sizes.
variable "single_nat_gateway" {
  type    = bool
  default = false
}

# Elasticsearch runs as a stateful, memory/IO-heavy workload, so it gets its
# own node group separate from general workloads (app, filebeat, kibana).
variable "es_node_instance_type" {
  description = "Instance type for Elasticsearch data/master nodes"
  type        = string
  default     = "r6i.xlarge" # memory-optimized: ES is JVM-heap and page-cache hungry
}

variable "general_node_instance_type" {
  description = "Instance type for general workloads (Kibana, Filebeat, app, ingress)"
  type        = string
  default     = "m6i.large"
}

variable "es_data_node_desired_count" {
  type    = number
  default = 3
}

variable "es_master_node_desired_count" {
  type    = number
  default = 3
}

variable "general_node_desired_count" {
  type    = number
  default = 3
}

variable "snapshot_bucket_name" {
  description = "S3 bucket for Elasticsearch snapshots (must be globally unique)"
  type        = string
  default     = "qyon-logging-es-snapshots"
}

# Snapshots outlive the 30-day hot index retention for genuine DR — this
# is real production data, so keep it longer than dev/sit need to.
variable "snapshot_retention_days" {
  type    = number
  default = 90
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
