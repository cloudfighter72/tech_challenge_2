#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/user-data.log) 2>&1

dnf update -y
dnf install -y java-21-amazon-corretto-headless git wget tar unzip docker

# --- Jenkins ---
wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
dnf install -y jenkins

# --- Docker (jenkins must be able to build images) ---
systemctl enable --now docker
usermod -aG docker jenkins

# --- AWS CLI v2 ---
curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update

# --- kubectl ---
curl -sSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/v1.30.4/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

# --- Helm ---
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Pre-seed kubeconfig for the jenkins user so the pipeline's first run works.
# Harmless if the cluster isn't up yet - the pipeline refreshes it every build.
# chown must come before update-kubeconfig: mkdir runs as root, so the jenkins
# user can't write to .kube until ownership is fixed.
mkdir -p /var/lib/jenkins/.kube
chown -R jenkins:jenkins /var/lib/jenkins/.kube
su - jenkins -s /bin/bash -c \
  "aws eks update-kubeconfig --name ${cluster_name} --region ${region}" || true
  
systemctl enable --now jenkins
