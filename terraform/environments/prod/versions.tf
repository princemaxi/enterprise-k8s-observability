terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    # alekc/kubectl, NOT gavinbunney/kubectl — the original is unmaintained
    # (no updates in 2+ years). This is the actively-maintained fork,
    # used in production by 200+ teams per its own README. Needed
    # specifically because hashicorp/kubernetes' own kubernetes_manifest
    # resource explicitly can't create a CRD-backed resource (our
    # Elasticsearch/Kibana CRs) in the same apply as the CRD itself —
    # kubectl_manifest does a live dry-run apply instead of static
    # plan-time schema validation, which sidesteps that limitation.
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}
