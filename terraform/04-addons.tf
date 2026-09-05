# Cluster add-ons installed as Helm releases so the whole platform comes up
# from a single `terraform apply`.
#
# Helm provider v3 syntax: `set` is a list of nested objects, not repeated blocks.

# HPA reads pod metrics from here. Without it every HPA reports <unknown>/50%.
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = "3.12.1"
  namespace  = "kube-system"

  set = [
    {
      name  = "args[0]"
      value = "--kubelet-insecure-tls"
    }
  ]

  depends_on = [module.eks]
}

# Turns Ingress objects into real ALBs.
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.8.1"
  namespace  = "kube-system"

  set = [
    {
      name  = "clusterName"
      value = module.eks.cluster_name
    },
    {
      name  = "region"
      value = var.aws_region
    },
    {
      name  = "vpcId"
      value = module.vpc.vpc_id
    },
    {
      name  = "serviceAccount.create"
      value = "true"
    },
    {
      name  = "serviceAccount.name"
      value = "aws-load-balancer-controller"
    },
    {
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = module.lb_controller_irsa.iam_role_arn
    },
    # Single replica: a t3.small has room for ~11 pods and the baseline node
    # must also fit CoreDNS, metrics-server, the autoscaler and the app.
    {
      name  = "replicaCount"
      value = "1"
    }
  ]

  depends_on = [module.eks, module.lb_controller_irsa]
}

# Adds nodes when pods are Pending, removes them when they go idle.
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = "9.37.0"
  namespace  = "kube-system"

  set = [
    {
      name  = "autoDiscovery.clusterName"
      value = module.eks.cluster_name
    },
    {
      name  = "awsRegion"
      value = var.aws_region
    },
    {
      name  = "rbac.serviceAccount.name"
      value = "cluster-autoscaler"
    },
    {
      name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = module.cluster_autoscaler_irsa.iam_role_arn
    },
    # Shorter than the 10m default so scale-down is demonstrable in a screenshot.
    {
      name  = "extraArgs.scale-down-unneeded-time"
      value = "3m"
    }
  ]

  depends_on = [module.eks, module.cluster_autoscaler_irsa]
}
