provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}

data "aws_caller_identity" "current" {}

# Configured from module.logging_platform's own outputs, not a static
# kubeconfig file — this is what lets `terraform apply` create the EKS
# cluster AND deploy everything into it (addons, Vault, Elasticsearch,
# the app) in one run, with no manual `aws eks update-kubeconfig` step in
# between. Auth uses `aws eks get-token` (the current non-deprecated exec
# plugin approach).
locals {
  eks_auth_args = ["eks", "get-token", "--cluster-name", module.logging_platform.cluster_name, "--region", var.aws_region]
}

provider "kubernetes" {
  host                   = module.logging_platform.cluster_endpoint
  cluster_ca_certificate = base64decode(module.logging_platform.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.eks_auth_args
  }
}

provider "helm" {
  kubernetes {
    host                   = module.logging_platform.cluster_endpoint
    cluster_ca_certificate = base64decode(module.logging_platform.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.eks_auth_args
    }
  }
}

provider "kubectl" {
  host                   = module.logging_platform.cluster_endpoint
  cluster_ca_certificate = base64decode(module.logging_platform.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.eks_auth_args
  }
}

# Talks to the LOCAL Docker daemon (same one `docker build` on your
# machine already uses) to build and push the Order API image — no
# manual `docker build`/`docker push`/`docker login` step. ECR auth comes
# from a live token (data.aws_ecr_authorization_token), not a static
# credential.
provider "docker" {
  registry_auth {
    address  = data.aws_ecr_authorization_token.this.proxy_endpoint
    username = data.aws_ecr_authorization_token.this.user_name
    password = data.aws_ecr_authorization_token.this.password
  }
}

data "aws_ecr_authorization_token" "this" {}
