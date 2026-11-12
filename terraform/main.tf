data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

locals {
  name = var.cluster_name
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Project    = local.name
    ManagedBy  = "terraform"
    Repository = "eks-platform-reference"
  }
}

################################################################################
# Network: three AZs, private subnets for nodes, public subnets for load balancers
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.16"

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  # /20 private subnets for pods (VPC CNI gives each pod a VPC IP), small /24 public subnets.
  private_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 48)]

  enable_nat_gateway = true
  single_nat_gateway = var.single_nat_gateway

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Karpenter discovers which subnets to launch nodes into by this tag.
    "karpenter.sh/discovery" = local.name
  }
}

################################################################################
# EKS cluster with a small, tainted system node group.
# Application capacity comes from Karpenter, not from this node group.
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = local.name
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.api_allowed_cidrs

  # Grants the identity running Terraform cluster-admin through an EKS access entry.
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
    # Pod Identity is used for Karpenter and Fluent Bit instead of IRSA annotations.
    eks-pod-identity-agent = {
      before_compute = true
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.system_instance_types

      min_size     = 2
      max_size     = 3
      desired_size = 2

      labels = {
        "node-role" = "system"
      }

      # Keep application pods off the system nodes; Karpenter and CoreDNS tolerate this taint.
      taints = {
        critical = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  # Karpenter selects this security group for the nodes it launches.
  # If the discovery tag is missing, nodes launch but never join (NodeNotFound / NotReady).
  node_security_group_tags = {
    "karpenter.sh/discovery" = local.name
  }
}
