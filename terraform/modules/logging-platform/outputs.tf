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
  description = "Vault's root token is never a Terraform output; retrieve it directly from the cluster only when interactive Vault CLI access is required."
  value       = "kubectl -n vault get secret vault-init -o jsonpath='{.data.root_token}' | base64 -d"
}
