module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  # Gives the IAM identity running `terraform apply` cluster-admin, so kubectl
  # works immediately after the apply finishes.
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    eks-pod-identity-agent = { most_recent = true }
    vpc-cni = {
      most_recent    = true
      before_compute = true
    }
  }

  eks_managed_node_groups = {
    default = {
      name = "${var.project_name}-ng"

      instance_types = [var.node_instance_type]
      capacity_type  = "ON_DEMAND"
      ami_type       = "AL2023_x86_64_STANDARD"
      disk_size      = 20

      min_size     = var.node_min_size # 1 node always on
      max_size     = var.node_max_size # scalable to 4
      desired_size = var.node_desired_size

      # Nodes pull the app image straight from ECR
      iam_role_additional_policies = {
        ecr_read = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
        ssm      = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      # Redundant with the subnet tags above but harmless, and makes the
      # autoscaler's discovery explicit at the ASG level.
      tags = {
        "k8s.io/cluster-autoscaler/enabled"             = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
      }
    }
  }

  # Jenkins authenticates to the cluster as its instance-profile role.
  # Skipping this is the #1 cause of "You must be logged in to the server".
  access_entries = {
    jenkins = {
      principal_arn = aws_iam_role.jenkins.arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  tags = {
    Project = var.project_name
  }
}
