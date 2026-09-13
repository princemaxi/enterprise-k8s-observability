# EKS Pod Identity — the modern replacement for IRSA. No OIDC provider
# federation, no ServiceAccount annotations, simpler trust policies
# (trust `pods.eks.amazonaws.com` directly rather than a per-cluster OIDC
# issuer URL). Used here for every AWS-facing workload EXCEPT
# Elasticsearch's S3 snapshot access — see the long comment in s3.tf for
# why that one specific case still uses a plain IAM user.
#
# Requires the eks-pod-identity-agent addon (eks.tf) to be running before
# any association here actually does anything.

# --- cert-manager: Route53 DNS-01 solver --------------------------------
resource "aws_iam_role" "cert_manager" {
  name = "${var.cluster_name}-cert-manager"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "cert_manager_route53" {
  name = "${var.cluster_name}-cert-manager-route53-dns01"
  role = aws_iam_role.cert_manager.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Scoped to exactly the shared zone — not every hosted zone in
        # the account.
        Effect   = "Allow"
        Action   = "route53:ChangeResourceRecordSets"
        Resource = "arn:aws:route53:::hostedzone/${var.route53_hosted_zone_id}"
      },
      {
        # These two Route53 actions don't support resource-level
        # restriction at all (AWS API limitation, not a scoping choice
        # here) — cert-manager needs ListHostedZonesByName to locate the
        # zone and GetChange to poll propagation status of the record it
        # just wrote.
        Effect   = "Allow"
        Action   = ["route53:ListHostedZonesByName", "route53:GetChange"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "cert_manager" {
  cluster_name    = module.eks.cluster_name
  namespace       = "cert-manager"
  service_account = "cert-manager"
  role_arn        = aws_iam_role.cert_manager.arn
}

# --- EBS CSI driver: provision/attach volumes for ES StatefulSets ------
resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
}

# --- Vault: KMS auto-unseal ---------------------------------------------
# Vault needs to call kms:Encrypt/Decrypt/DescribeKey against the key in
# vault.tf every time it seals/unseals — which, with auto-unseal
# configured, means every single pod start/restart, not just the one-time
# init. Without this association, Vault would come up sealed on every
# restart and need manual `vault operator unseal` forever, defeating the
# entire point of "automated to start up on terraform apply."
resource "aws_iam_role" "vault_kms" {
  name = "${var.cluster_name}-vault-kms"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "vault_kms" {
  name = "${var.cluster_name}-vault-kms-unseal"
  role = aws_iam_role.vault_kms.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
      Resource = aws_kms_key.vault_unseal.arn
    }]
  })
}

resource "aws_eks_pod_identity_association" "vault" {
  cluster_name    = module.eks.cluster_name
  namespace       = "vault"
  service_account = "vault"
  role_arn        = aws_iam_role.vault_kms.arn
}

# --- AWS Load Balancer Controller ---------------------------------------
# Without this, `Service` objects of type LoadBalancer (ingress-nginx's
# own Service, specifically) never get an EXTERNAL-IP — EKS has no
# built-in in-tree cloud provider to provision an ELB automatically on
# recent Kubernetes versions; that responsibility now belongs entirely to
# this controller, and nothing provisions it unless something explicitly
# does. Found the hard way: ingress-nginx's Service sat in
# EXTERNAL-IP=<pending> indefinitely with zero error, because there was
# nothing installed to notice it and act.
#
# Policy document is Elastic Load Balancing's own, fetched directly from
# the upstream project rather than hand-copied — re-fetch it if this ever
# needs updating:
#   curl -o policies/aws-load-balancer-controller-iam-policy.json \
#     https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
resource "aws_iam_role" "aws_load_balancer_controller" {
  name = "${var.cluster_name}-aws-lb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "aws_load_balancer_controller" {
  name   = "${var.cluster_name}-aws-lb-controller"
  role   = aws_iam_role.aws_load_balancer_controller.id
  policy = file("${path.module}/policies/aws-load-balancer-controller-iam-policy.json")
}

resource "aws_eks_pod_identity_association" "aws_load_balancer_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller" # must match the Helm chart's ServiceAccount name exactly
  role_arn        = aws_iam_role.aws_load_balancer_controller.arn
}
