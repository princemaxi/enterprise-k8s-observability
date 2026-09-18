#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
infra_dir="$repo_root/terraform/infrastructure/environments/dev"
platform_dir="$repo_root/terraform/platform/environments/dev"
infra_backend_file="${TF_INFRA_BACKEND_FILE:-$repo_root/terraform/backend-dev-infrastructure.hcl}"
platform_backend_file="${TF_PLATFORM_BACKEND_FILE:-$repo_root/terraform/backend-dev-platform.hcl}"

if [[ ! -f "$infra_backend_file" || ! -f "$platform_backend_file" ]]; then
  echo "Missing infrastructure or platform backend config." >&2
  exit 1
fi

terraform -chdir="$platform_dir" init -backend-config="$platform_backend_file"
terraform -chdir="$platform_dir" destroy

terraform -chdir="$infra_dir" init -backend-config="$infra_backend_file"
terraform -chdir="$infra_dir" destroy
