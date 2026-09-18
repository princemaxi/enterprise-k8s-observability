output "cluster_name" { value = module.infrastructure.cluster_name }
output "cluster_endpoint" { value = module.infrastructure.cluster_endpoint }
output "cluster_certificate_authority_data" {
  value     = module.infrastructure.cluster_certificate_authority_data
  sensitive = true
}
output "aws_region" { value = module.infrastructure.aws_region }
output "vpc_id" { value = module.infrastructure.vpc_id }
output "private_subnet_ids" { value = module.infrastructure.private_subnet_ids }
output "es_snapshot_bucket" { value = module.infrastructure.es_snapshot_bucket }
output "es_snapshot_access_key_id" {
  value     = module.infrastructure.es_snapshot_access_key_id
  sensitive = true
}
output "es_snapshot_secret_access_key" {
  value     = module.infrastructure.es_snapshot_secret_access_key
  sensitive = true
}
output "vault_unseal_kms_key_arn" { value = module.infrastructure.vault_unseal_kms_key_arn }
output "order_api_ecr_repository_url" { value = module.infrastructure.order_api_ecr_repository_url }
output "cert_manager_role_arn" { value = module.infrastructure.cert_manager_role_arn }
