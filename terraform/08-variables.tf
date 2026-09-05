variable "project_name" {
  description = "Name prefix applied to every resource."
  type        = string
  default     = "tc2"
}

variable "aws_region" {
  description = "AWS region. Must match the region of the S3 state bucket."
  type        = string
  default     = "us-east-2"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "tc2-eks"
}

variable "cluster_version" {
  description = "Kubernetes control plane version."
  type        = string
  default     = "1.30"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "node_instance_type" {
  description = "Worker node instance type. Fixed at t3.small by the challenge brief."
  type        = string
  default     = "t3.small"
}

variable "node_min_size" {
  description = "Minimum nodes. 1 satisfies 'one node active at all times'."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum nodes the Cluster Autoscaler may add. Capped at 4 by the brief."
  type        = number
  default     = 4
}

variable "node_desired_size" {
  description = "Starting node count. Autoscaler takes over from here."
  type        = number
  default     = 1
}

variable "ecr_repo_name" {
  description = "ECR repository for the application image."
  type        = string
  default     = "hello-world"
}

variable "jenkins_instance_type" {
  description = "Instance type for the Jenkins controller."
  type        = string
  default     = "t3.medium"
}

variable "jenkins_key_name" {
  description = "EC2 key pair name for SSH access to Jenkins. Leave empty to use SSM Session Manager only."
  type        = string
  default     = ""
}

variable "my_ip_cidr" {
  description = "Your public IP in CIDR form (e.g. 203.0.113.4/32). Locks down Jenkins SSH/UI. Never use 0.0.0.0/0."
  type        = string
}

variable "github_repo" {
  description = "GitHub repo in owner/name form, used for the Actions OIDC trust policy."
  type        = string
  default     = "cloudfighter72/tech_challenge_2"
}
