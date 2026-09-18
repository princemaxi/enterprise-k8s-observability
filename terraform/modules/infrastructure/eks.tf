# EKS cluster with 3 managed node groups:
#   es-master  -> dedicated master-eligible ES nodes (quorum, no data)
#   es-data    -> dedicated ES data nodes (memory-optimized, EBS-backed)
#   general    -> Kibana, Filebeat DaemonSet, ingress controller, the app
#
# Node group sizes come entirely from the environment's variables — dev
# can run 1 master / 1 data / 1 general, prod runs 3/3/3. `max_size` scales
# with `desired_size` (desired + headroom) rather than being a hardcoded
# ceiling, so dev doesn't advertise room to scale to 9 nodes it'll never
# use.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  # EKS Pod Identity Agent addon — this is what makes
  # aws_eks_pod_identity_association (pod-identity.tf) actually work. No
  # OIDC provider federation, no ServiceAccount annotations required on
  # the Kubernetes side, unlike the IRSA pattern this replaced.
  cluster_addons = {
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    vpc-cni                = { most_recent = true }
    eks-pod-identity-agent = { most_recent = true }
    # aws-ebs-csi-driver's IAM identity comes from a Pod Identity
    # association (pod-identity.tf), not from a service_account_role_arn
    # here — that field is specifically the IRSA wiring mechanism and
    # doesn't apply to Pod Identity at all.
    aws-ebs-csi-driver = { most_recent = true }
  }

  eks_managed_node_groups = {
    es-master = {
      instance_types = [var.es_node_instance_type]
      min_size       = var.es_master_node_desired_count
      max_size       = var.es_master_node_desired_count + 2
      desired_size   = var.es_master_node_desired_count
      capacity_type  = "ON_DEMAND" # ES masters are not a place to save money with spot, in any environment
      labels = {
        role = "es-master"
      }
      taints = {
        dedicated = {
          key    = "dedicated"
          value  = "es-master"
          effect = "NO_SCHEDULE"
        }
      }
    }

    es-data = {
      instance_types = [var.es_node_instance_type]
      min_size       = var.es_data_node_desired_count
      max_size       = var.es_data_node_desired_count + 3
      desired_size   = var.es_data_node_desired_count
      capacity_type  = "ON_DEMAND"
      labels = {
        role = "es-data"
      }
      taints = {
        dedicated = {
          key    = "dedicated"
          value  = "es-data"
          effect = "NO_SCHEDULE"
        }
      }
    }

    general = {
      instance_types = [var.general_node_instance_type]
      min_size       = var.general_node_desired_count
      max_size       = var.general_node_desired_count + 3
      desired_size   = var.general_node_desired_count
      capacity_type  = "SPOT" # Kibana/Filebeat/app/Vault tolerate interruption fine, in any environment
      labels = {
        role = "general"
      }
    }
  }

  # Cluster creator gets admin — tighten this with aws-auth / access entries
  # per engineer before treating this as shared infrastructure, especially
  # for sit/prod where more than one person needs access.
  enable_cluster_creator_admin_permissions = true

  tags = var.tags
}
