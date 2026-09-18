variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "azs" {
  type = list(string)
}

variable "single_nat_gateway" {
  type = bool
}

variable "es_node_instance_type" {
  type = string
}

variable "general_node_instance_type" {
  type = string
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
  type = string
}

variable "snapshot_retention_days" {
  type = number
}

variable "route53_hosted_zone_id" {
  type = string
}

variable "tags" {
  type = map(string)
}
