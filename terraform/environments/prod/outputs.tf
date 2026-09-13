output "cluster_name" {
  value = module.logging_platform.cluster_name
}

output "cluster_endpoint" {
  value = module.logging_platform.cluster_endpoint
}

output "configure_kubectl" {
  description = "Only needed for manual kubectl/troubleshooting access — Terraform itself never depends on you having run this."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.logging_platform.cluster_name}"
}

output "oidc_provider_arn" {
  value = module.logging_platform.oidc_provider_arn
}

output "es_snapshot_bucket" {
  value = module.logging_platform.es_snapshot_bucket
}

# Sensitive — these feed the Elasticsearch keystore Secret directly
# (kubernetes_secret_v1.es_snapshot_credentials, created by Terraform
# itself). No manual step reads these; exposed only for troubleshooting.
output "es_snapshot_access_key_id" {
  value     = module.logging_platform.es_snapshot_access_key_id
  sensitive = true
}

output "es_snapshot_secret_access_key" {
  value     = module.logging_platform.es_snapshot_secret_access_key
  sensitive = true
}

output "cert_manager_role_arn" {
  value = module.logging_platform.cert_manager_role_arn
}

output "vault_unseal_kms_key_arn" {
  value = module.logging_platform.vault_unseal_kms_key_arn
}

output "vpc_id" {
  value = module.logging_platform.vpc_id
}

output "private_subnet_ids" {
  value = module.logging_platform.private_subnet_ids
}

output "order_api_ecr_repository_url" {
  value = module.logging_platform.order_api_ecr_repository_url
}

output "kibana_url" {
  value = module.logging_platform.kibana_url
}

output "order_api_url" {
  value = module.logging_platform.order_api_url
}

output "vault_init_secret_retrieval_command" {
  value = module.logging_platform.vault_init_secret_retrieval_command
}
