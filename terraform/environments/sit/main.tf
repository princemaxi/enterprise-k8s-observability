module "logging_platform" {
  source = "../../modules/logging-platform"

  environment     = "sit"
  aws_region      = var.aws_region
  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version
  vpc_cidr        = var.vpc_cidr
  azs             = var.azs

  single_nat_gateway = var.single_nat_gateway

  es_node_instance_type      = var.es_node_instance_type
  general_node_instance_type = var.general_node_instance_type

  es_data_node_desired_count   = var.es_data_node_desired_count
  es_master_node_desired_count = var.es_master_node_desired_count
  general_node_desired_count   = var.general_node_desired_count

  snapshot_bucket_name    = var.snapshot_bucket_name
  snapshot_retention_days = var.snapshot_retention_days

  domain_name = var.domain_name
  tags        = var.tags

  route53_hosted_zone_id = var.route53_hosted_zone_id

  elasticsearch    = var.elasticsearch
  kibana           = var.kibana
  order_api        = var.order_api
  slm_expire_after = var.slm_expire_after
}
