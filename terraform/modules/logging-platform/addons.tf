# Every controller/operator this cluster needs, as Terraform-managed Helm
# releases. This is the core of "terraform apply and it comes up live" —
# previously every one of these was a manual `helm install`/`kubectl
# apply` step run by hand, in a specific order, with no guarantee the
# order was actually followed. Terraform's dependency graph (via
# depends_on and direct references) now enforces that ordering instead
# of a person's memory of a runbook.

# --- AWS Load Balancer Controller ----------------------------------------
# Provisions the actual ALB/NLB behind ingress-nginx's Service and any
# Ingress objects. See the long comment on its Pod Identity wiring in
# pod-identity.tf for why this exists at all — its absence was a real
# incident (ingress-nginx's Service stuck at EXTERNAL-IP=<pending>
# forever, with no error anywhere to point at why).
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.8.1"
  namespace  = "kube-system"

  values = [
    yamlencode({
      clusterName = module.eks.cluster_name
      region      = var.aws_region
      vpcId       = module.vpc.vpc_id
      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller" # must match aws_eks_pod_identity_association.aws_load_balancer_controller
      }
    })
  ]

  depends_on = [
    module.eks,
    aws_eks_pod_identity_association.aws_load_balancer_controller,
  ]
}

# --- ingress-nginx ---------------------------------------------------------
# The actual ingress controller — routes by host/path to Kibana and the
# Order API. Its Service is type: LoadBalancer, which is what the ALB
# controller above actually provisions a real load balancer for.
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.15.1"
  namespace        = "ingress-nginx"
  create_namespace = true

  values = [
    yamlencode({
      controller = {
        service = {
          type = "LoadBalancer"
          annotations = {
            "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
            "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
            "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internet-facing"
          }
        }
      }
    })
  ]

  depends_on = [helm_release.aws_load_balancer_controller]
}

# --- cert-manager ------------------------------------------------------------
# Issues TLS certs for Kibana/Order-API/Vault via Route53 DNS-01 — no
# ServiceAccount annotation needed (Pod Identity, see pod-identity.tf),
# just the chart's default ServiceAccount name matching the association.
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.21.1" # cert-manager's chart version genuinely includes the "v" prefix (unusual — most charts don't)
  namespace        = "cert-manager"
  create_namespace = true

  set {
    name  = "installCRDs"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "cert-manager" # must match aws_eks_pod_identity_association.cert_manager
  }

  depends_on = [
    module.eks,
    aws_eks_pod_identity_association.cert_manager,
  ]
}

# --- external-dns -------------------------------------------------------------
# Automatically creates/updates Route53 records for any Ingress it sees —
# the last manual step in this project (pointing DNS at the load
# balancer's hostname by hand) is what this eliminates. Scoped to only
# the shared qyonlimited.com zone via the same IAM pattern as
# cert-manager, not every zone in the account.
resource "aws_iam_role" "external_dns" {
  name = "${var.cluster_name}-external-dns"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "external_dns" {
  name = "${var.cluster_name}-external-dns-route53"
  role = aws_iam_role.external_dns.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "route53:ChangeResourceRecordSets"
        Resource = "arn:aws:route53:::hostedzone/${var.route53_hosted_zone_id}"
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones", "route53:ListResourceRecordSets"]
        Resource = "*" # ListHostedZones/ListResourceRecordSets don't support resource-level restriction — AWS API limitation, not a scoping choice
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "external_dns" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-dns"
  service_account = "external-dns"
  role_arn        = aws_iam_role.external_dns.arn
}

resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns/"
  chart            = "external-dns"
  version          = "1.21.1"
  namespace        = "external-dns"
  create_namespace = true

  values = [
    yamlencode({
      provider = {
        name = "aws" # current chart schema — the old top-level `provider: aws` string form is deprecated
      }
      extraArgs = [
        "--aws-zone-type=public", # Route53 has no regional endpoints (it's a global service) — no region setting needed here
        "--zone-id-filter=${var.route53_hosted_zone_id}"
      ]
      domainFilters = ["qyonlimited.com"]
      policy        = "sync" # removes DNS records when the matching Ingress is deleted, not just "upsert"
      serviceAccount = {
        create = true
        name   = "external-dns" # must match aws_eks_pod_identity_association.external_dns
      }
      # dev/sit/prod are separate clusters but share one Route53 zone —
      # each external-dns instance is scoped to its own subdomain via
      # domainFilters above, and this TXT registry identifier keeps their
      # ownership records from colliding with each other.
      txtOwnerId = var.cluster_name
    })
  ]

  depends_on = [
    module.eks,
    aws_eks_pod_identity_association.external_dns,
  ]
}

# --- ECK operator (Elastic Cloud on Kubernetes) --------------------------
# Manages the Elasticsearch/Kibana custom resources defined in
# elasticsearch.tf/kibana.tf. Elastic publishes an official Helm chart —
# using it here instead of the old `kubectl apply -f
# https://download.elastic.co/...crds.yaml` + `operator.yaml` two-step,
# which was a manual step run by hand in a specific order relative to
# everything else.
resource "helm_release" "eck_operator" {
  name       = "elastic-operator"
  repository = "https://helm.elastic.co"
  chart      = "eck-operator"
  version    = "2.14.0"
  namespace  = kubernetes_namespace_v1.elastic_system.metadata[0].name

  depends_on = [module.eks, kubernetes_namespace_v1.elastic_system]
}
