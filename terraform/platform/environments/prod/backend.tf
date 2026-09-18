# Kubernetes platform state only. Infrastructure is read through
# data.terraform_remote_state and is never managed from this root.
terraform {
  backend "s3" {}
}
