# Jenkins runs outside the cluster security group, so kubectl and helm need
# explicit access to the EKS API endpoint. Without this the pipeline times out
# at the Configure kubectl stage.
resource "aws_security_group_rule" "cluster_api_from_jenkins" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = module.eks.cluster_primary_security_group_id
  source_security_group_id = aws_security_group.jenkins.id
  description              = "Jenkins to EKS API"
}