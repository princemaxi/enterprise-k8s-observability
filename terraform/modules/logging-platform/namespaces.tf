# One namespace per concern, each with Pod Security Standards enforced at
# the namespace level — baseline for elastic-system and vault (both need
# a few privileges: ECK's init containers, Vault's raft storage),
# restricted everywhere else. Native resources rather than a `kubectl
# apply -f namespaces.yaml` step — everything downstream (Elasticsearch,
# Kibana, Order API, NetworkPolicies) references these directly, so
# Terraform's own dependency graph orders them correctly instead of
# relying on a human running commands in sequence.
#
# cert-manager, ingress-nginx, external-dns, and vault get their own
# namespaces created automatically by their Helm releases
# (create_namespace = true in addons.tf/vault.tf) — not duplicated here.

resource "kubernetes_namespace_v1" "elastic_system" {
  metadata {
    name = "elastic-system"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "name"                               = "elastic-system"
    }
  }
}

resource "kubernetes_namespace_v1" "logging" {
  metadata {
    name = "logging"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
      "name"                               = "logging"
    }
  }
}

resource "kubernetes_namespace_v1" "applications" {
  metadata {
    name = "applications"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "name"                               = "applications"
    }
  }
}

resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "name"                               = "monitoring"
    }
  }
}

# vault gets its own explicit resource (rather than helm_release.vault's
# create_namespace = true) specifically so it gets the same
# Pod-Security-Standards labeling as every other managed namespace —
# create_namespace alone produces a bare, unlabeled namespace.
resource "kubernetes_namespace_v1" "vault" {
  metadata {
    name = "vault"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline" # Vault's raft storage + init needs a bit more than "restricted" allows
      "name"                               = "vault"
    }
  }
}
