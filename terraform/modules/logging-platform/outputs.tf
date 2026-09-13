output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

# Needed by the root module's helm/kubernetes/kubectl provider blocks —
# Terraform can configure a provider from a child module's outputs in the
# same apply, which is what lets this project bring up the cluster AND
# deploy everything into it (addons, Vault, Elasticsearch, the app) in a
# single `terraform apply`, no manual kubeconfig step in between.
output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "es_snapshot_bucket" {
  value = aws_s3_bucket.es_snapshots.bucket
}

# Deliberately NOT an IRSA/Pod-Identity role ARN — see the comment on
# aws_iam_user.es_snapshots in s3.tf for why Elasticsearch's S3 access
# uses a plain IAM user instead. These feed the keystore Secret directly
# (kubernetes_secret_v1.es_snapshot_credentials in elasticsearch.tf) — no
# manual `kubectl create secret` step exists anymore. Marked sensitive
# purely as defense in depth; nothing should ever need to print these.
output "es_snapshot_access_key_id" {
  value     = aws_iam_access_key.es_snapshots.id
  sensitive = true
}

output "es_snapshot_secret_access_key" {
  value     = aws_iam_access_key.es_snapshots.secret
  sensitive = true
}

output "cert_manager_role_arn" {
  description = "Informational only — Pod Identity associations don't require this to be referenced anywhere in Kubernetes manifests, unlike IRSA's ServiceAccount annotation."
  value       = aws_iam_role.cert_manager.arn
}

output "vault_unseal_kms_key_arn" {
  value = aws_kms_key.vault_unseal.arn
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "order_api_ecr_repository_url" {
  value = aws_ecr_repository.order_api.repository_url
}

output "order_api_image" {
  value = docker_registry_image.order_api.name
}

output "kibana_url" {
  value = "https://kibana.${var.domain_name}"
}

output "order_api_url" {
  value = "https://order-api.${var.domain_name}"
}

output "vault_init_secret_retrieval_command" {
  description = "Vault's root token is never a Terraform output — retrieve it directly from the cluster only if you need interactive Vault CLI access."
  value       = "kubectl -n vault get secret vault-init -o jsonpath='{.data.root_token}' | base64 -d"
}
