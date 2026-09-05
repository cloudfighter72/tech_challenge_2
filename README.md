# Tech Challenge 2 — Containerization, IaC, Kubernetes & CI/CD

A "Hello, World!" Flask application, containerized with Docker, provisioned onto **AWS EKS**
with **Terraform**, exposed through an **ALB**, autoscaled with **HPA + Cluster Autoscaler**,
and deployed continuously by **Jenkins** (`main`) or **GitHub Actions + Argo CD** (`gitops`).

**Live application:** `http://<alb-dns-name>.us-east-2.elb.amazonaws.com`

---

## Contents

- [Architecture](#architecture)
- [Repository layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Environment setup](#environment-setup)
- [Windows / Git Bash notes](#windows--git-bash-notes)
- [Running locally](#running-locally)
- [Deploying the infrastructure](#deploying-the-infrastructure)
- [Deploying the application](#deploying-the-application)
- [Scaling design](#scaling-design)
- [Terraform explained](#terraform-explained)
- [Jenkins pipeline explained](#jenkins-pipeline-explained)
- [GitOps branch](#gitops-branch--github-actions--argo-cd)
- [Verification and screenshots](#verification-and-screenshots)
- [Troubleshooting](#troubleshooting)
- [Teardown](#teardown)

---

## Architecture

```text
Developer ── git push ──► GitHub (main)
                              │
                              ▼
                        Jenkins (EC2)
                    build → smoke test → push
                              │
                              ▼
                        Amazon ECR ──────────┐
                              │              │
                    helm upgrade --install   │ image pull
                              │              │
                              ▼              ▼
   Internet ──► ALB ──► Ingress ──► Service ──► Pods (Deployment)
                                                 ▲        ▲
                                     HPA (cpu/mem 50%)    │
                                                          │
                                  Cluster Autoscaler (1 → 4 × t3.small)
```

The `gitops` branch swaps the Jenkins box for GitHub Actions (build + push) and Argo CD
running inside the cluster (pull-based sync from Git).

---

## Repository layout

```text
.
├── app/
│   ├── app.py                      # Flask: /, /healthz, /load
│   ├── requirements.txt
│   ├── Dockerfile
│   └── .dockerignore
├── terraform/                      # NN-name.tf, applied in read order
│   ├── 00-provider.tf              # required_providers, S3 backend, provider config
│   ├── 01-vpc.tf                   # VPC, subnets, NAT, ELB + autoscaler tags
│   ├── 02-eks.tf                   # cluster, node group, access entries
│   ├── 03-iam_irsa.tf              # IAM roles for service accounts
│   ├── 04-addons.tf                # metrics-server, ALB controller, autoscaler
│   ├── 05-ecr.tf                   # registry + lifecycle policy
│   ├── 06-ec2-jenkins.tf           # Jenkins EC2, SG, instance profile, EIP
│   ├── 06-jenkins_userdata.sh      # bootstraps Java/Jenkins/Docker/kubectl/Helm
│   ├── 07-iam_github_oidc.tf       # OIDC role for GitHub Actions (gitops)
│   ├── 08-variables.tf
│   ├── 09-terraform.auto.tfvars.example
│   └── A-outputs.tf                # 'A-' sorts last
├── helm/hello-world/
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── _helpers.tpl
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── ingress.yaml
│       ├── hpa.yaml
│       └── serviceaccount.yaml
├── k8s/loadtest.yaml               # load generator for the HPA demo
├── argocd/
│   ├── install-values.yaml         # Helm values for Argo CD itself
│   └── application.yaml            # the bootstrap Application
├── Jenkinsfile                     # main branch
├── .github/workflows/ci.yml        # gitops branch
├── Makefile                        # shortcuts for every command below
├── docs/screenshots/
├── .gitattributes                  # forces LF - see Windows notes
├── PLAN.md
└── README.md
```

**Branching:** `main` = Jenkins. `gitops` = GitHub Actions + Argo CD. Kept separate on
purpose; never merged.

### Placeholders to replace before first run

| File | Placeholder | Value |
| --- | --- | --- |
| `terraform/00-provider.tf` | `tc2-tfstate-CHANGEME` | your S3 state bucket |
| `terraform/terraform.auto.tfvars` | — | copy from `.example`, set `my_ip_cidr` |
| `Jenkinsfile` | `AWS_ACCOUNT = '123456789012'` | your AWS account ID |
| `argocd/application.yaml` | `cloudfighter72/tech_challenge_2` | your GitHub repo |

---

## Windows / Git Bash notes

Developed and run from Git Bash (MINGW64). Four things bite on Windows:

**1. Line endings.** `.gitattributes` forces LF on every file Linux executes. Without it,
`terraform/06-jenkins_userdata.sh` can reach the EC2 instance with CRLF and die with
`bad interpreter: /bin/bash^M` — user-data fails silently and Jenkins simply never starts on
port 8080. Set this once before cloning or committing:

```bash
git config --global core.autocrlf input
```

If the repo was already committed with CRLF, renormalize:

```bash
git add --renormalize .
git commit -m "normalize line endings to LF"
```

**2. Path conversion.** MSYS rewrites arguments that look like Unix paths, which mangles
`jsonpath` expressions, `docker run -c` commands and `aws ssm start-session`. Export this in
every shell you work in:

```bash
export MSYS_NO_PATHCONV=1
```

Or prefix a single command: `MSYS_NO_PATHCONV=1 kubectl get ingress ...`

**3. `make` is not installed by default.** Either install it —

```bash
winget install ezwinports.make      # or: choco install make / scoop install make
```

— or skip the Makefile entirely; every target is a one-line shell command you can read out
of the file and run directly.

**4. Docker Desktop must be running** before `docker build`, with WSL2 backend enabled.
`make run-local` fails with a daemon-connection error otherwise.

---

## Prerequisites

| Tool | Version | Purpose |
| --- | --- | --- |
| AWS account | — | IAM user with admin-equivalent rights |
| AWS CLI | v2 | authentication, kubeconfig |
| Terraform | >= 1.6 | infrastructure |
| kubectl | ~1.30 | cluster access |
| Helm | v3 | chart deployment |
| Docker | latest | image build |

---

## Environment setup

Terraform cannot bootstrap its own backend, so the state bucket comes first:

```bash
export ACCT=$(aws sts get-caller-identity --query Account --output text)

aws s3api create-bucket --bucket tc2-tfstate-$ACCT --region us-east-2
aws s3api put-bucket-versioning --bucket tc2-tfstate-$ACCT \
  --versioning-configuration Status=Enabled
aws dynamodb create-table --table-name tc2-tf-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH --billing-mode PAY_PER_REQUEST

# then edit terraform/00-provider.tf and set the bucket name
cd terraform && cp 09-terraform.auto.tfvars.example terraform.auto.tfvars
# set my_ip_cidr:  curl -s https://checkip.amazonaws.com
```

---

## Running locally

```bash
make run-local          # docker build + run on :8080
curl localhost:8080     # Hello, World!
curl localhost:8080/healthz
```

The image is `python:3.12-slim`, installs dependencies in a separate layer for caching,
runs as a **non-root** user, and serves through `gunicorn` rather than the Flask dev server.
`/load` burns CPU and holds 20MB for five seconds — it exists purely to give the HPA
something to react to in Phase 8.

---

## Deploying the infrastructure

```bash
make ecr-only           # Phase 4: registry first, so a manual image exists as a fallback
make tf-init tf-plan tf-apply     # Phase 5-6: ~15-20 minutes
make kubeconfig
kubectl get nodes
kubectl top nodes       # confirms metrics-server is alive
```

Outputs: `cluster_name`, `ecr_repository_url`, `jenkins_url`, `jenkins_ssh`,
`github_actions_role_arn`, `configure_kubectl`.

---

## Deploying the application

Terraform builds the platform; Helm deploys the app. CI/CD runs the same Helm command.

```bash
make push TAG=manual-1
make deploy TAG=manual-1
make url                # the ALB takes 2-4 minutes to become active
make status
```

---

## Scaling design

The brief asks for four nodes with one always active, one pod per node, and an HPA allowing
up to three pods per node. The last two are in tension — a hard one-pod-per-node constraint
makes three pods per node impossible. Resolved as follows:

| Requirement | Implementation |
| --- | --- |
| 4 nodes, 1 always active | `min_size=1`, `desired_size=1`, `max_size=4` in `02-eks.tf` |
| `t3.small` nodes | `instance_types = ["t3.small"]` |
| Scalable to 4 | Cluster Autoscaler adds nodes when pods are `Pending` |
| 1 pod per node | `topologySpreadConstraints`, `maxSkew: 1`, key `kubernetes.io/hostname`, `whenUnsatisfiable: ScheduleAnyway` |
| Max 3 pods per node | `maxReplicas: 12` (3 × 4 nodes) |
| 50% CPU **or** 50% memory | Two HPA `Resource` metrics, each `averageUtilization: 50` |

`ScheduleAnyway` rather than `DoNotSchedule` is deliberate: a hard constraint would leave
pods permanently `Pending` past four replicas instead of stacking up to three per node.
With two metrics the HPA takes whichever recommends *more* replicas, which is exactly the
"CPU **or** memory" behaviour requested.

HPA percentages are computed against **requests**, so the Deployment sets them explicitly:

```yaml
resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits:   { cpu: 500m, memory: 512Mi }
```

Omit the requests and the HPA reports `<unknown>/50%` forever.

**Demonstrating it:**

```bash
make load       # 4 busybox pods hammering /load
make watch      # HPA replicas climb, then node count climbs
make unload     # scale-down (HPA ~2 min, nodes ~3 min)
```

Scale-down is deliberately slower than scale-up. The autoscaler's
`scale-down-unneeded-time` is set to `3m` (down from the 10m default) in `04-addons.tf` so the
scale-down screenshot doesn't cost a coffee break.

**A note on node capacity:** a `t3.small` allows ~11 pods, and the baseline node also runs
CoreDNS, metrics-server, the ALB controller and the autoscaler. Some app pods may go
`Pending` on the first deploy — that is the Cluster Autoscaler's cue to add node two, not a
failure. The ALB controller is pinned to `replicaCount: 1` to leave room.

---

## Terraform explained

**`00-provider.tf`** — pins provider versions and configures the S3 backend with DynamoDB
locking. The `kubernetes` and `helm` providers authenticate to the cluster this same config
creates, using an `exec` block that fetches a fresh token on every apply rather than baking
in a short-lived one — that's what makes re-applies work hours later.

**`01-vpc.tf`** — `terraform-aws-modules/vpc/aws`. Public subnets for the ALB, private subnets
for nodes, a single NAT gateway (cost over HA). The subnet tags matter more than they look:
`kubernetes.io/role/elb=1` on public subnets is how the AWS Load Balancer Controller
discovers where to place an internet-facing ALB, and `k8s.io/cluster-autoscaler/*` on
private subnets is how the autoscaler finds its ASG. Missing tags is the usual reason an
Ingress never gets an `ADDRESS`.

**`02-eks.tf`** — `terraform-aws-modules/eks/aws` v20. Control plane, OIDC provider (required
for IRSA), and one managed node group sized 1/1/4 on `t3.small` with the AL2023 AMI.
`enable_cluster_creator_admin_permissions` means kubectl works the moment the apply
finishes. The node role gets `AmazonEC2ContainerRegistryReadOnly` so pods can pull from ECR,
and `AmazonSSMManagedInstanceCore` so nodes are reachable without a key pair. The
`access_entries` block maps the Jenkins IAM role to `AmazonEKSClusterAdminPolicy` — skipping
this is the single most common cause of *"You must be logged in to the server"*.

> **Do not** make `06-ec2-jenkins.tf` reference `module.eks`. `02-eks.tf` already reads
> `aws_iam_role.jenkins.arn`, so `06-ec2-jenkins.tf` uses `var.cluster_name` instead. Adding the
> reverse reference creates a dependency cycle and Terraform will refuse to plan.

**`03-iam_irsa.tf`** — IAM Roles for Service Accounts via
`iam-role-for-service-accounts-eks`. Each controller assumes a scoped role through the
cluster's OIDC provider instead of inheriting broad permissions from the node instance
profile: `attach_load_balancer_controller_policy` for the ALB controller,
`attach_cluster_autoscaler_policy` scoped to this cluster's ASGs for the autoscaler.

**`04-addons.tf`** — three `helm_release` resources: **metrics-server** (feeds the HPA),
**AWS Load Balancer Controller** (turns Ingress objects into real ALBs), **Cluster
Autoscaler** (adds and removes nodes). Managing them in Terraform keeps the whole platform
reproducible from a single `apply`.

**`05-ecr.tf`** — private registry, scan-on-push, lifecycle policy keeping the last 10 images,
`force_delete = true` so `terraform destroy` isn't blocked by stored images.

**`06-ec2-jenkins.tf` / `06-jenkins_userdata.sh`** — `t3.medium` EC2 with an Elastic IP and a security
group restricted to the operator's IP on 22/8080. `user_data` installs Java 17, Jenkins,
Docker (adding `jenkins` to the `docker` group), AWS CLI v2, kubectl and Helm, then
pre-seeds a kubeconfig for the `jenkins` user. The instance profile grants ECR push and
`eks:DescribeCluster`; actual in-cluster rights come from the EKS access entry, not IAM.
Jenkins therefore stores **no** AWS credentials.

**`07-iam_github_oidc.tf`** — GitHub OIDC provider plus a role trusted only by
`repo:<owner>/<repo>:*`, used by the `gitops` workflow so Actions never needs static keys.

**Design notes:** community modules over hand-rolled resources; IRSA over node-level IAM
(least privilege); everything but the state backend codified.

---

## Jenkins pipeline explained

`Jenkinsfile`, declarative, runs on `main`:

| Stage | Action |
| --- | --- |
| **Checkout** | Clone the triggering commit |
| **Build Image** | `docker build` tagged `${BUILD_NUMBER}` and `latest` |
| **Smoke Test** | Run the container, curl `/healthz` and `/`, fail before anything is pushed |
| **Push to ECR** | `aws ecr get-login-password` via the instance profile, push both tags |
| **Configure kubectl** | `aws eks update-kubeconfig`, then `kubectl get nodes` |
| **Deploy with Helm** | `helm upgrade --install --wait --timeout 5m` with the new tag |
| **Verify Rollout** | `kubectl rollout status`, print the live ALB URL |
| **post** | `docker rmi` local images; on failure, dump recent namespace events |

Two choices worth defending. **Build-number tags, never bare `latest`** — deploying by
`latest` makes rollbacks guesswork and can leave Kubernetes with nothing to roll back to.
And **`helm upgrade --install` is idempotent**, so the first run and the hundredth run are
the same command; Helm's release history gives you `helm rollback` for free.

**Trigger:** GitHub webhook to `http://<jenkins-ip>:8080/github-webhook/`, or SCM polling
(`H/5 * * * *`) if the host isn't publicly reachable.

**Jenkins setup:** unlock with
`sudo cat /var/lib/jenkins/secrets/initialAdminPassword`, install Git, Pipeline, Docker
Pipeline, Amazon ECR, AWS Credentials, Kubernetes CLI and GitHub Integration, add a
`github-pat` credential, then create a Pipeline job pointed at this repo with script path
`Jenkinsfile`.

---

## GitOps branch — GitHub Actions + Argo CD

On `gitops`, push-based CD is replaced by pull-based CD.

**CI — `.github/workflows/ci.yml`** (on push to `gitops`):

1. Assume the AWS role via **OIDC** (`permissions: id-token: write`) — no stored keys
2. `aws-actions/amazon-ecr-login`
3. Build and push tagged with `github.sha`
4. Rewrite `image.repository` and `image.tag` in `helm/hello-world/values.yaml` and commit
   back with `[skip ci]` — the `if:` guard stops that commit re-triggering the workflow

**CD — Argo CD**, installed in-cluster and bootstrapped once:

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  -f argocd/install-values.yaml
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
kubectl apply -f argocd/application.yaml
```

`install-values.yaml` sets `server.insecure: true` so TLS terminates at the ALB — without it
the ALB health check fails against an HTTPS-only pod — and trims resource requests to fit
the `t3.small` fleet. `application.yaml` watches `targetRevision: gitops`, path
`helm/hello-world`, with `automated` sync: `prune` deletes resources removed from Git,
`selfHeal` reverts manual `kubectl` drift.

**Why this differs from Jenkins:** Git is the single source of truth, cluster credentials
never leave the cluster, and deployed state is auditable from commit history. The trade-off
is an extra indirection — the image tag must be committed back before anything deploys.

Set repo secret `AWS_ROLE_ARN` to the `github_actions_role_arn` Terraform output.

---

## Verification and screenshots

```bash
kubectl get nodes -o wide                    # node count and instance type
kubectl get pods -o wide -n hello-world      # pod distribution across nodes
kubectl get hpa -n hello-world               # cpu/mem against 50%
make url && curl $(make -s url)              # Hello, World!
helm history hello-world -n hello-world      # deployment history
```

Evidence in `docs/screenshots/` — see `PLAN.md` for the full 34-shot checklist.

| File | Shows |
| --- | --- |
| `01-terraform-apply.png` | Successful provisioning |
| `02-eks-cluster.png` | EKS cluster Active |
| `03-kubectl-nodes.png` | t3.small nodes |
| `04-app-alb.png` | Application served through the ALB |
| `05-hpa-scaling.png` | HPA scaling on CPU/memory |
| `06-node-autoscaling.png` | 1 → 4 nodes |
| `07-jenkins-pipeline.png` | Green pipeline |
| `08-ecr-images.png` | Tagged images in ECR |
| `09-argocd-synced.png` | Argo CD Healthy / Synced |

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Ingress has no `ADDRESS` | Missing `kubernetes.io/role/elb` subnet tags, or ALB controller IRSA | `kubectl logs -n kube-system deploy/aws-load-balancer-controller` |
| HPA shows `<unknown>/50%` | metrics-server absent, or no resource **requests** | Install metrics-server; set requests |
| Pods `Pending`, node count flat | Autoscaler can't discover the ASG | Check `k8s.io/cluster-autoscaler/*` tags; read autoscaler logs |
| Jenkins: "You must be logged in to the server" | Jenkins IAM role not mapped into EKS | Confirm the `access_entries` block in `02-eks.tf` applied |
| Jenkins: `docker: permission denied` | `jenkins` not in the `docker` group | `usermod -aG docker jenkins && systemctl restart jenkins` |
| `ImagePullBackOff` | Node role lacks ECR read | `iam_role_additional_policies` in `02-eks.tf` |
| Terraform: "Cycle" error | `06-ec2-jenkins.tf` was changed to reference `module.eks` | Revert to `var.cluster_name` |
| Argo CD stuck `OutOfSync` | Wrong `targetRevision`, or the bot lacks write permission | Confirm branch `gitops` and workflow `contents: write` |

---

## Teardown

Take your screenshots first — this is irreversible.

```bash
make destroy      # uninstalls the Helm release (releasing the ALB), then terraform destroy
```

Then confirm in the console that no ALBs, NAT gateways, Elastic IPs or orphaned ENIs remain.
Destroying the cluster before the Helm release can strand a load balancer that keeps billing.
