output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value     = module.eks.cluster_certificate_authority_data
  sensitive = true
}

output "cluster_version" {
  value = module.eks.cluster_version
}

output "aws_region" {
  value = var.aws_region
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "es_snapshot_bucket" {
  value = aws_s3_bucket.es_snapshots.bucket
}

output "es_snapshot_access_key_id" {
  value     = aws_iam_access_key.es_snapshots.id
  sensitive = true
}

output "es_snapshot_secret_access_key" {
  value     = aws_iam_access_key.es_snapshots.secret
  sensitive = true
}

output "vault_unseal_kms_key_arn" {
  value = aws_kms_key.vault_unseal.arn
}

output "order_api_ecr_repository_url" {
  value = aws_ecr_repository.order_api.repository_url
}

output "cert_manager_role_arn" {
  value = aws_iam_role.cert_manager.arn
}
