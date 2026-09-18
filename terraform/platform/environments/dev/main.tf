data "terraform_remote_state" "infrastructure" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = var.infrastructure_state_key
    region = var.state_region
  }
}

module "logging_platform" {
  source = "../../../modules/logging-platform"

  environment                   = "dev"
  aws_region                    = data.terraform_remote_state.infrastructure.outputs.aws_region
  cluster_name                  = data.terraform_remote_state.infrastructure.outputs.cluster_name
  vpc_id                        = data.terraform_remote_state.infrastructure.outputs.vpc_id
  es_snapshot_bucket            = data.terraform_remote_state.infrastructure.outputs.es_snapshot_bucket
  es_snapshot_access_key_id     = data.terraform_remote_state.infrastructure.outputs.es_snapshot_access_key_id
  es_snapshot_secret_access_key = data.terraform_remote_state.infrastructure.outputs.es_snapshot_secret_access_key
  vault_unseal_kms_key_id       = data.terraform_remote_state.infrastructure.outputs.vault_unseal_kms_key_arn
  order_api_ecr_repository_url  = data.terraform_remote_state.infrastructure.outputs.order_api_ecr_repository_url

  route53_hosted_zone_id = var.route53_hosted_zone_id
  domain_name            = var.domain_name
  tags                   = var.tags
  elasticsearch          = var.elasticsearch
  kibana                 = var.kibana
  order_api              = var.order_api
  slm_expire_after       = var.slm_expire_after
  alert_email            = var.alert_email
}
