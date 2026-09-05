output "cluster_name" {
  description = "Feed this to: aws eks update-kubeconfig --name <value>"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "configure_kubectl" {
  description = "Copy-paste command to get kubectl talking to the cluster."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

output "ecr_repository_url" {
  description = "Image repository for docker push and helm --set image.repository."
  value       = aws_ecr_repository.app.repository_url
}

output "jenkins_url" {
  value = "http://${aws_eip.jenkins.public_ip}:8080"
}

output "jenkins_ssh_key" {
  description = "SSH with your key pair. Empty if jenkins_key_name was not set."
  value       = var.jenkins_key_name != "" ? "ssh -i ~/.ssh/${var.jenkins_key_name}.pem ec2-user@${aws_eip.jenkins.public_ip}" : "(no key pair - use jenkins_ssh below)"
}

output "jenkins_ssh" {
  description = "SSH via SSM (no key pair needed)."
  value       = "aws ssm start-session --target ${aws_instance.jenkins.id} --region ${var.aws_region}"
}

output "github_actions_role_arn" {
  description = "Set as the role-to-assume in the gitops CI workflow."
  value       = aws_iam_role.github_actions.arn
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}
