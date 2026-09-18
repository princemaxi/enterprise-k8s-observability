output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${data.terraform_remote_state.infrastructure.outputs.aws_region} --name ${data.terraform_remote_state.infrastructure.outputs.cluster_name}"
}
output "cluster_name" { value = data.terraform_remote_state.infrastructure.outputs.cluster_name }
output "kibana_url" { value = module.logging_platform.kibana_url }
output "order_api_url" { value = module.logging_platform.order_api_url }
output "vault_init_secret_retrieval_command" { value = module.logging_platform.vault_init_secret_retrieval_command }
