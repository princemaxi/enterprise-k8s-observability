#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
infra_dir="$repo_root/terraform/infrastructure/environments/dev"
platform_dir="$repo_root/terraform/platform/environments/dev"
infra_backend_file="${TF_INFRA_BACKEND_FILE:-$repo_root/terraform/backend-dev-infrastructure.hcl}"
platform_backend_file="${TF_PLATFORM_BACKEND_FILE:-$repo_root/terraform/backend-dev-platform.hcl}"

if [[ ! -f "$infra_backend_file" || ! -f "$platform_backend_file" ]]; then
  echo "Missing infrastructure or platform backend config." >&2
  echo "Copy both backend.hcl.example files to terraform/backend-dev-infrastructure.hcl and terraform/backend-dev-platform.hcl." >&2
  exit 1
fi

terraform -chdir="$infra_dir" init -backend-config="$infra_backend_file"
terraform -chdir="$infra_dir" plan -out=tfplan
terraform -chdir="$infra_dir" apply tfplan

cluster_name="$(terraform -chdir="$infra_dir" output -raw cluster_name)"
aws_region="$(terraform -chdir="$infra_dir" output -raw aws_region)"
aws eks wait cluster-active --name "$cluster_name" --region "$aws_region"
aws eks update-kubeconfig --name "$cluster_name" --region "$aws_region"
kubectl get nodes

terraform -chdir="$platform_dir" init -backend-config="$platform_backend_file"
terraform -chdir="$platform_dir" plan -out=tfplan
terraform -chdir="$platform_dir" apply tfplan

kubectl get nodes
kubectl get pods -A
