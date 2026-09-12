# Tech Challenge 2 — Containerization, IaC, Kubernetes & CI/CD

A "Hello, World!" Flask application, containerized with Docker, provisioned onto **AWS EKS**
with **Terraform**, exposed through an **ALB**, autoscaled with **HPA + Cluster Autoscaler**,
and deployed continuously by **Jenkins** (`main`) or **GitHub Actions + Argo CD** (`gitops`).

**Live application:** `http://k8s-hellowor-hellowor-a7c7be98d6-1367070398.us-east-2.elb.amazonaws.com`

> **Note on state:** this URL was live at the time of submission, and the screenshots in
> `docs/screenshots/` were captured against the running deployment. The infrastructure has
> since been destroyed with `terraform destroy` to avoid ongoing AWS charges (roughly
> $8/day for the cluster, ALB, NAT gateway and Jenkins instance). The URL will no longer
> resolve. Everything is reproducible from this repository by following
> [Deploying the infrastructure](#deploying-the-infrastructure) — note that a new ALB is
> allocated on each deploy, so the DNS name will differ.

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
│   ├── 07-sg_jenkins_eks.tf        # SG rule: Jenkins → EKS API on 443
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
├── argocd/                         # gitops branch only
│   ├── install-values.yaml         # Helm values for Argo CD itself
│   └── application.yaml            # the bootstrap Application
├── Jenkinsfile                     # main branch
├── .github/workflows/ci.yml        # gitops branch only
├── Makefile                        # shortcuts for the commands below
├── docs/
│   ├── DOC-STYLE.md
│   ├── mdcheck.py
│   └── screenshots/
├── .markdownlint.json
├── .gitattributes                  # forces LF - see Windows notes
├── PLAN.md
└── README.md
```

**Branching:** `main` = Jenkins. `gitops` = GitHub Actions + Argo CD. Kept separate on
purpose. `argocd/` and `.github/workflows/ci.yml` exist only on `gitops`.

> Merging `main` into `gitops` replays the commit that removed those files from `main` and
> deletes them from `gitops` as well. Bring shared fixes across with `git cherry-pick` of
> the specific commits instead.

### Placeholders to replace before first run

| File | Placeholder | Value |
| --- | --- | --- |
| `terraform/00-provider.tf` | `tc2-tfstate-<account-id>` | your S3 state bucket |
| `terraform/09-terraform.auto.tfvars` | — | copy from `.example`, set `my_ip_cidr` |
| `helm/hello-world/values.yaml` | `ACCOUNT_ID.dkr.ecr...` | overridden by CI; set for manual installs |
| `argocd/application.yaml` | `cloudfighter72/tech_challenge_2` | your GitHub repo |

The Jenkinsfile needs no account ID — it resolves one at runtime from the instance profile
via `aws sts get-caller-identity`.

---

## Windows / Git Bash notes

Developed and run from Git Bash (MINGW64). Four things bite on Windows:

**1. Line endings.** `.gitattributes` forces LF on every file Linux executes. Without it,
`terraform/06-jenkins_userdata.sh` can reach the EC2 instance with CRLF and die with
`bad interpreter: /bin/bash^M` — user-data fails silently and Jenkins never starts on
port 8080. Set this once before cloning or committing:

```bash
git config --global core.autocrlf input
```

If the repo was already committed with CRLF, renormalize:

```bash
git add --renormalize .
git commit -m "normalize line endings to LF"
```

**2. Path conversion.** MSYS rewrites arguments that look like Unix paths. This bit during
the HPA load test: `kubectl run ... -- /bin/sh -c ...` was rewritten to a Windows path and
the container failed with
`exec: "C:/Program Files/Git/usr/bin/sh": no such file or directory`. Export this in every
shell you work in:

```bash
export MSYS_NO_PATHCONV=1
```

Or prefix a single command, or use `//bin/sh` — Git Bash strips the leading slash and the
container receives `/bin/sh` correctly.

**3. `make` is not installed by default.** Either install it —

```bash
winget install ezwinports.make      # or: choco install make / scoop install make
```

— or skip the Makefile entirely; every target is a one-line shell command you can read out
of the file and run directly. The walkthrough below uses direct commands.

**4. Docker Desktop must be running** before `docker build`, with WSL2 backend enabled.

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

aws s3api create-bucket --bucket tc2-tfstate-$ACCT --region us-east-2 \
  --create-bucket-configuration LocationConstraint=us-east-2
aws s3api put-bucket-versioning --bucket tc2-tfstate-$ACCT \
  --versioning-configuration Status=Enabled
```

The bucket name embeds the account ID because S3 bucket names are globally unique. That is
why the account ID appears in `00-provider.tf` and is not treated as a secret — it is an
identifier, not a credential.

Then set your variables:

```bash
cd terraform
cp 09-terraform.auto.tfvars.example 09-terraform.auto.tfvars
curl -s https://checkip.amazonaws.com      # set my_ip_cidr to this value + /32
```

`my_ip_cidr` restricts the Jenkins security group to your address on ports 22 and 8080.
If your public IP changes, update it and re-apply or you will be locked out of the UI.

---

## Running locally

```bash
docker build -t hello-world:local ./app
docker run -d -p 8080:8080 hello-world:local
curl localhost:8080
curl localhost:8080/healthz
```

The image is `python:3.12-slim`, installs dependencies in a separate layer for caching,
runs as a **non-root** user, and serves through `gunicorn` rather than the Flask dev server.
`/load` burns CPU and holds memory for five seconds — it exists purely to give the HPA
something to react to.

---

## Deploying the infrastructure

**Apply in two passes.** The Helm releases in `04-addons.tf` depend on `module.eks`, which
guarantees the cluster resources exist but not that a node has joined and gone `Ready`.
Applied in one pass, the add-on pods are scheduled against a cluster with no capacity and
Helm times out. Provision the cluster first, wait for the node, then apply the rest:

```bash
cd terraform
terraform init
terraform apply -target=module.vpc -target=module.eks    # ~15-20 minutes
```

Terraform warns that `-target` is for exceptional use. That is expected; the unrestricted
apply that follows reconciles everything.

```bash
aws eks update-kubeconfig --name tc2-eks --region us-east-2
kubectl get nodes                       # wait for STATUS: Ready
terraform apply                         # add-ons, ECR, Jenkins, OIDC
```

Verify the platform came up:

```bash
kubectl get deploy -n kube-system       # metrics-server, ALB controller, autoscaler
kubectl top nodes                       # numbers here mean metrics-server is serving
```

`kubectl top` returning an error means the HPA will report `<unknown>/50%` and nothing will
scale. Fix that before going further.

Confirm the autoscaler can discover its ASG — the tags are set on the node group, and
propagation to the underlying Auto Scaling group is worth verifying rather than assuming:

```bash
aws autoscaling describe-auto-scaling-groups --region us-east-2 \
  --query 'AutoScalingGroups[].[AutoScalingGroupName,Tags[?starts_with(Key,`k8s.io/cluster-autoscaler`)].Key]'
```

Outputs: `cluster_name`, `ecr_repository_url`, `jenkins_url`, `jenkins_ssh`,
`github_actions_role_arn`, `configure_kubectl`.

### A note on Kubernetes versions

`var.cluster_version` is pinned to `1.30`. EKS auto-upgraded the control plane to `1.31`
during this project while the managed node group stayed on `1.30`. That skew is supported,
and the variable was deliberately left at `1.30`: raising it to match queues a rolling
replacement of every node, which is 10-20 minutes of churn for no functional gain. Raise it
when you actually intend to upgrade the node group.

---

## Deploying the application

Terraform builds the platform; Helm deploys the app. CI/CD runs the same Helm command.

```bash
ECR=$(terraform -chdir=terraform output -raw ecr_repository_url)

aws ecr get-login-password --region us-east-2 | docker login --username AWS --password-stdin $ECR
docker build -t $ECR:v1 ./app
docker push $ECR:v1

helm upgrade --install hello-world ./helm/hello-world \
  --namespace hello-world --create-namespace \
  --set image.repository=$ECR --set image.tag=v1 \
  --wait --timeout 5m
```

The namespace matters: the Jenkins pipeline deploys to `hello-world`, so a manual install
into a different namespace leaves you with two releases.

```bash
kubectl get ingress -n hello-world -w     # ALB takes 2-4 minutes to get an ADDRESS
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
pods permanently `Pending` past four replicas instead of stacking up. With two metrics the
HPA takes whichever recommends *more* replicas, which is exactly the "CPU **or** memory"
behaviour requested.

**Kubernetes has no per-node replica cap.** "3 pods per node" is therefore expressed as a
total ceiling of 12 replicas plus an even-spread constraint, not as a hard per-node limit.
In the observed load test, 11 replicas landed 4 / 3 / 4 across three nodes — above three per
node, because `maxSkew: 1` balances across whatever nodes exist rather than enforcing a
cap. This is the expected behaviour of the chosen primitives.

### Sizing the requests

HPA percentages are computed against **requests**, so the Deployment sets them explicitly:

```yaml
resources:
  requests: { cpu: 100m, memory: 256Mi }
  limits:   { cpu: 500m, memory: 512Mi }
```

Omit the requests and the HPA reports `<unknown>/50%` forever.

The memory request was raised from 128Mi to 256Mi. A Flask app under gunicorn idles around
60-90 MiB; against a 128Mi request that is 47-70% utilization at rest, which would drive the
HPA to `maxReplicas` before any load was applied and make the scaling demonstration
meaningless. At 256Mi the observed idle figure is 21%, leaving CPU as the metric that
actually responds to traffic.

### Demonstrating it

```bash
MSYS_NO_PATHCONV=1 kubectl run load1 --rm -it --image=busybox --restart=Never -n hello-world -- \
  //bin/sh -c "while true; do wget -q -O- http://hello-world > /dev/null; done"
```

A single sequential `wget` loop will not push a Flask pod past 50% of a 100m CPU request.
Run three or four in separate terminals. Watch from another:

```bash
kubectl get hpa -n hello-world -w
kubectl get nodes -w
```

`-w` accepts one resource type at a time, and nodes are cluster-scoped, so these need
separate terminals.

Observed behaviour: CPU peaked at 389%, replicas went 1 → 5 → 8 → 11, nodes went 1 → 3.
Scale-down ran 11 → 5 → 3 → 2 → 1 over roughly eight minutes, then nodes were cordoned and
removed. Scale-down is deliberately slower than scale-up: the HPA uses a 120-second
stabilization window and the highest recommendation from the preceding five minutes. The
autoscaler's `scale-down-unneeded-time` is set to `3m` (down from the 10m default) in
`04-addons.tf` so the scale-down evidence does not cost a coffee break.

**A note on node capacity:** with system pods only, a `t3.small` sits at roughly 50% memory —
CoreDNS ×2, metrics-server, the ALB controller and the autoscaler leave about 700 MiB of
~1.44 GiB allocatable. Three app pods at 256Mi exceed that, so pods go `Pending` sooner than
a strict 3-per-node reading suggests and the autoscaler adds nodes earlier. That is the
autoscaler working, not a failure. The ALB controller is pinned to `replicaCount: 1` to
leave room.

---

## Terraform explained

**`00-provider.tf`** — pins provider versions and configures the S3 backend. The
`kubernetes` and `helm` providers authenticate to the cluster this same config creates,
using an `exec` block that fetches a fresh token on every apply rather than baking in a
short-lived one — that is what makes re-applies work hours later.

**`01-vpc.tf`** — `terraform-aws-modules/vpc/aws`. Public subnets for the ALB, private subnets
for nodes, a single NAT gateway (cost over HA, ~$32/month instead of ~$64). The subnet tags
matter more than they look: `kubernetes.io/role/elb=1` on public subnets is how the AWS Load
Balancer Controller discovers where to place an internet-facing ALB. Missing tags is the
usual reason an Ingress never gets an `ADDRESS`, and it fails silently.

The `k8s.io/cluster-autoscaler/*` tags on the private subnets are inert — Cluster Autoscaler
discovers Auto Scaling groups by **ASG** tag, not subnet tag. The tags that matter are on the
node group in `02-eks.tf`. The subnet copies are harmless and left in place for parity.

**`02-eks.tf`** — `terraform-aws-modules/eks/aws` v20. Control plane, OIDC provider (required
for IRSA), and one managed node group sized 1/1/4 on `t3.small` with the AL2023 AMI.
`enable_cluster_creator_admin_permissions` means kubectl works the moment the apply
finishes. The node role gets `AmazonEC2ContainerRegistryReadOnly` so pods can pull from ECR,
and `AmazonSSMManagedInstanceCore` so nodes are reachable without a key pair. The
`access_entries` block maps the Jenkins IAM role to `AmazonEKSClusterAdminPolicy` — skipping
this is the single most common cause of *"You must be logged in to the server"*.

> **Do not** make `06-ec2-jenkins.tf` reference `module.eks`. `02-eks.tf` already reads
> `aws_iam_role.jenkins.arn`, so `06-ec2-jenkins.tf` uses `var.cluster_name` instead. The
> security group rule that bridges the two lives in its own file, `07-sg_jenkins_eks.tf`,
> to keep that separation honest.

**`03-iam_irsa.tf`** — IAM Roles for Service Accounts via
`iam-role-for-service-accounts-eks`. Each controller assumes a scoped role through the
cluster's OIDC provider instead of inheriting broad permissions from the node instance
profile: `attach_load_balancer_controller_policy` for the ALB controller,
`attach_cluster_autoscaler_policy` scoped to this cluster's ASGs for the autoscaler.

**`04-addons.tf`** — three `helm_release` resources: **metrics-server** (feeds the HPA),
**AWS Load Balancer Controller** (turns Ingress objects into real ALBs), **Cluster
Autoscaler** (adds and removes nodes). Managing them in Terraform keeps the whole platform
reproducible from a single apply — subject to the two-pass ordering described above.

metrics-server needs `--kubelet-insecure-tls` passed as a **list**, not a scalar. In the
Helm provider's `set` block that is written `value = "{--kubelet-insecure-tls}"`; the braces
are Helm's list syntax. Without them the chart iterates over a string and the container spec
comes out malformed.

**`05-ecr.tf`** — private registry, scan-on-push, lifecycle policy keeping the last 10 images,
`force_delete = true` so `terraform destroy` isn't blocked by stored images.

**`06-ec2-jenkins.tf` / `06-jenkins_userdata.sh`** — `t3.medium` EC2 with an Elastic IP and a
security group restricted to the operator's IP on 22/8080. `user_data` installs Java,
Jenkins, Docker (adding `jenkins` to the `docker` group), AWS CLI v2, kubectl and Helm, then
pre-seeds a kubeconfig for the `jenkins` user. The instance profile grants ECR push and
`eks:DescribeCluster`; actual in-cluster rights come from the EKS access entry, not IAM.
Jenkins therefore stores **no** AWS credentials.

**`07-sg_jenkins_eks.tf`** — the cluster's primary security group allows traffic only from
itself. Jenkins runs on its own security group outside the cluster, so `kubectl` and `helm`
hang on the private API endpoint until an explicit ingress rule on 443 is added. Without
this the pipeline fails at the **Configure kubectl** stage with an i/o timeout.

**`07-iam_github_oidc.tf`** — GitHub OIDC provider plus a role trusted only by
`repo:<owner>/<repo>:*`, used by the `gitops` workflow so Actions never needs static keys.

**Design notes:** community modules over hand-rolled resources; IRSA over node-level IAM
(least privilege); everything but the state backend codified.

---

## Jenkins pipeline explained

`Jenkinsfile`, declarative, runs on `main`:

| Stage | Action |
| --- | --- |
| **Resolve Account** | `aws sts get-caller-identity` → sets `AWS_ACCOUNT`, `REGISTRY`, `IMAGE` |
| **Checkout** | Clone the triggering commit |
| **Build Image** | `docker build` tagged `${BUILD_NUMBER}` and `latest` |
| **Smoke Test** | Run the container, curl `/healthz` and `/`, fail before anything is pushed |
| **Push to ECR** | `aws ecr get-login-password` via the instance profile, push both tags |
| **Configure kubectl** | `aws eks update-kubeconfig`, then `kubectl get nodes` |
| **Deploy with Helm** | `helm upgrade --install --wait --timeout 5m` with the new tag |
| **Verify Rollout** | `kubectl rollout status`, print the live ALB URL |
| **post** | `docker rmi` local images; on failure, dump recent namespace events |

Three choices worth defending. **The account ID is resolved at runtime**, not committed —
an `environment` block cannot run `sh` steps, so the lookup lives in its own first stage.
**Build-number tags, never bare `latest`** — deploying by `latest` makes rollbacks guesswork.
And **`helm upgrade --install` is idempotent**, so the first run and the hundredth run are
the same command; Helm's release history gives you `helm rollback` for free.

**Trigger:** GitHub webhook to `http://<jenkins-ip>:8080/github-webhook/`, or SCM polling
(`H/5 * * * *`) if the host isn't publicly reachable.

**Jenkins setup:** unlock with
`sudo cat /var/lib/jenkins/secrets/initialAdminPassword`, install the suggested plugins,
then create a Pipeline job with **Pipeline script from SCM**, Git, this repo, branch
`*/main`, script path `Jenkinsfile`.

> This repository is **private**. The Jenkins job and Argo CD both need read credentials —
> a GitHub personal access token added as a Jenkins credential and selected in the job's
> SCM configuration. Builds #1 and #2 in the screenshots were run while the repository was
> still public and required no credential.

Before the first build, confirm the agent has what the pipeline needs:

```bash
sudo -u jenkins docker ps
sudo -u jenkins kubectl get nodes
```

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
  -f argocd/install-values.yaml --wait --timeout 10m
```

Because the repository is private, Argo CD needs a credential before it can read the chart.
Register one as a labelled secret in the `argocd` namespace:

```bash
kubectl create secret generic tc2-repo -n argocd \
  --from-literal=type=git \
  --from-literal=url=https://github.com/cloudfighter72/tech_challenge_2.git \
  --from-literal=username=<github-username> \
  --from-literal=password=<classic-pat-with-repo-scope>

kubectl label secret tc2-repo -n argocd argocd.argoproj.io/secret-type=repository
```

Use a **classic** personal access token with the top-level `repo` scope. A fine-grained
token must additionally be granted access to this specific repository and given at least
`Contents: Read`; without that, Argo CD reports
`authorization failed: Write access to repository not granted`, which is misleading — it
only ever needs read.

Then bootstrap the Application:

```bash
kubectl apply -f argocd/application.yaml
kubectl get application -n argocd
```

If the status sits at `Unknown` after a credential change, Argo CD is serving a cached
failure. Restart the repo server and force a refresh:

```bash
kubectl rollout restart deploy argocd-repo-server -n argocd
kubectl patch application hello-world -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

`install-values.yaml` sets `server.insecure: true` so TLS terminates at the ALB — without it
the ALB health check fails against an HTTPS-only pod — and trims resource requests to fit
the `t3.small` fleet. It also enables an Ingress, so Argo CD provisions its **own** ALB
alongside the application's; both must be removed at teardown. For local access, note that
insecure mode serves plain HTTP, so the port-forward maps to port 80, not 443:

```bash
kubectl port-forward service/argocd-server -n argocd 8080:80
# then browse to http://localhost:8080 (not https)
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

`application.yaml` watches `targetRevision: gitops`, path `helm/hello-world`, with
`automated` sync: `prune` deletes resources removed from Git, `selfHeal` reverts manual
`kubectl` drift.

**Why this differs from Jenkins:** Git is the single source of truth, cluster credentials
never leave the cluster, and deployed state is auditable from commit history. The trade-off
is an extra indirection — the image tag must be committed back before anything deploys.

Set repo secret `AWS_ROLE_ARN` to the `github_actions_role_arn` Terraform output, and set
**Settings → Actions → General → Workflow permissions** to *Read and write*, which the
tag-bump commit requires.

Note: editors with Kubernetes schema validation flag `argocd/application.yaml` with
"apiVersion and/or kind does not reference a known schema". `argoproj.io/v1alpha1` is a CRD
installed by Argo CD itself, so the warning is expected until Argo CD is running.

### Status at submission

Argo CD is installed, authenticated against this private repository, and reporting
`Synced` / `Healthy` against the `gitops` branch, managing the live Deployment, Service,
Ingress, HPA and ServiceAccount. The pull-based CD half of the GitOps model is working and
is evidenced below.

The GitHub Actions half fails at the OIDC step with
`Not authorized to perform sts:AssumeRoleWithWebIdentity`. The IAM configuration was
verified and is correct as far as it can be inspected from the AWS side: the provider
exists at `token.actions.githubusercontent.com`, its `ClientIDList` contains
`sts.amazonaws.com`, and the role's trust policy matches
`repo:cloudfighter72/tech_challenge_2:*` with the `sts.amazonaws.com` audience. Resolving it
requires decoding the `sub` claim from a live workflow token to find where the mismatch
actually is, which was not pursued within the challenge window. Image build and push to ECR
are demonstrated by the Jenkins pipeline, which performs the same operations against the
same registry.

---

## Verification and screenshots

```bash
kubectl get nodes -o wide                    # node count and instance type
kubectl get pods -o wide -n hello-world      # pod distribution across nodes
kubectl get hpa -n hello-world               # cpu/mem against 50%
helm history hello-world -n hello-world      # deployment history
```

Screenshots capture point-in-time state during the load test and CI/CD runs — for example,
11 pods across 3 nodes at peak, against a cluster that returns to 1 node and 1 replica at
rest. They are evidence of behaviour under load, not of steady state.

### Repository and submission

Private repository with the mentor invited as a collaborator.

![Private repository with mentor invited](docs/screenshots/github_collab_private.png)

### Infrastructure

Terraform plan before the first apply — 64 resources, including the cluster KMS key and
node group validation.

![Terraform plan, 64 resources to add](docs/screenshots/tfplan.png)

First pass complete: VPC and EKS control plane only.

![Terraform apply pass 1 complete](docs/screenshots/tf_apply_complete.png)

The node reaches `Ready` before the add-ons are applied. This ordering is the whole reason
for the two-pass apply.

![First node Ready](docs/screenshots/node_ready.png)

![Node Ready at min size with kubeconfig context](docs/screenshots/kubectl_get_nodes.png)

Second pass: add-ons, ECR, Jenkins and the GitHub OIDC role — 20 resources.

![Terraform apply pass 2 complete with outputs](docs/screenshots/tf_apply_complete_2.png)

All four `kube-system` deployments available, and `kubectl top nodes` returning real
figures — the prerequisite for the HPA to function at all.

![kube-system deployments and node metrics](docs/screenshots/kube_nodes.png)

### Application

Local image build: layered dependency install, non-root `appuser`.

![Local docker build](docs/screenshots/ECR_image1.png)

Manual push to ECR as a fallback image before CI/CD exists.

![Manual push to ECR](docs/screenshots/ECR_image2.png)

First Helm release: one pod running, HPA reporting real percentages, Ingress resolved to an
ALB hostname.

![Pod, HPA and Ingress after first Helm install](docs/screenshots/Helm_ALB.png)

The application served through the ALB.

![Hello World served through the ALB](docs/screenshots/browser_hello_world.png)

The ALB itself — internet-facing, spanning two availability zones.

![ALB active in the EC2 console](docs/screenshots/ALB_console.png)

Target group health. The registered target is a **pod IP**, not a node — confirming
`alb.ingress.kubernetes.io/target-type: ip` is in effect.

![Target group with one healthy pod IP](docs/screenshots/ALB_target_group.png)

### Scaling

Three parallel load generators. One sequential `wget` loop is not enough to push a Flask pod
past 50% of a 100m CPU request.

![Load generator 1](docs/screenshots/load_test_01.png)

![Load generator 2](docs/screenshots/load_test_02.png)

![Load generator 3](docs/screenshots/load_test_03.png)

HPA scale-up. CPU peaks at 389% of target, replicas climb 1 → 5 → 8, then utilization falls
as the new pods absorb the load. Memory stays flat at 21% throughout — CPU is the driving
metric, which is what the 256Mi request was sized to allow.

![HPA scaling up under load](docs/screenshots/load_test_works.png)

Cluster Autoscaler adds nodes as pods become unschedulable, then cordons and drains them on
the way back down.

![Nodes scaling 1 to 3 and draining](docs/screenshots/node_scaling1.png)

The Auto Scaling group at desired capacity 3, within the configured 1–4 limits.

![ASG at desired capacity 3](docs/screenshots/ASG_console.png)

Pod distribution at peak: 11 replicas spread 4 / 3 / 4 across three nodes. The
`topologySpreadConstraints` balance rather than stack.

![11 pods distributed across three nodes](docs/screenshots/ALB_scaling.png)

Scale-down. The HPA steps 11 → 5 → 3 → 2 → 1 rather than dropping at once, because it uses a
120-second stabilization window and the highest recommendation from the preceding five
minutes.

![HPA scaling back down to one replica](docs/screenshots/ALB_scaling2.png)

### CI/CD — Jenkins

The Jenkins user reaching the EKS API — verification that the security group rule in
`07-sg_jenkins_eks.tf` works. Without it the pipeline hangs at **Configure kubectl**.

![Jenkins user running kubectl against the cluster](docs/screenshots/ssh_ec2.png)

Build #1, checked out at the triggering commit.

![Jenkins build 1 status](docs/screenshots/Jenkins_UI_build.png)

![Jenkins build 1 stage view](docs/screenshots/Jenkins_UI_stages.png)

Builds #1 and #2, every stage green. Build #2 picked up two commits and completed in 34
seconds.

![Jenkins builds 1 and 2, all stages green](docs/screenshots/Jenkins_build_2.png)

The **Push to ECR** stage. Authentication comes from the EC2 instance profile — no AWS
credentials are stored in Jenkins.

![Jenkins pushing the image to ECR](docs/screenshots/Jenkins_ecr_push.png)

The **Deploy with Helm** and **Verify Rollout** stages. `REVISION: 2` shows the pipeline
upgraded the existing release rather than creating a parallel one, and the pipeline echoes
the live URL.

![Jenkins helm upgrade and rollout verification](docs/screenshots/Jenkins_helm_upgrade.png)

ECR after both builds: `v1` from the manual push, then `1` and `2, latest` from Jenkins,
each with a distinct digest and a "last pulled" timestamp proving the cluster consumed them.

![ECR image tags with timestamps](docs/screenshots/AWS_ECR_tags.png)

The deployed change, live. `deployed by Jenkins` and `version build-2` confirm the pipeline
delivers code changes to the running cluster — not just that it exits zero.

![Application showing the Jenkins-deployed change](docs/screenshots/browser_deployed_by_Jenkins.png)

### CI/CD — GitOps

Argo CD tracking the `gitops` branch at `helm/hello-world`, `Healthy` and `Synced`.

![Argo CD applications list showing hello-world synced](docs/screenshots/argo_login.png)

The application resource tree. Argo CD owns the Deployment, Service, Ingress, HPA and
ServiceAccount, and the ReplicaSet history shows the revisions it has managed through.

![Argo CD resource tree for hello-world](docs/screenshots/argo_view.png)

The classic personal access token created for Argo CD's repository access, confirmed by
GitHub's notification. A classic token with `repo` scope is required here — a fine-grained
token fails with a misleading "Write access not granted" error.

![GitHub notification confirming the classic PAT was created](docs/screenshots/argocd_email.png)

The same state from the CLI after a hard refresh.

![kubectl get application showing Synced and Healthy](docs/screenshots/argocd_health.png)

The GitHub Actions half, failing at the OIDC credential step — see
[Status at submission](#status-at-submission) for the diagnosis.

![GitHub Actions workflow run failing](docs/screenshots/git_ops_fail.png)

### Teardown

Argo CD and the application uninstalled first, so the controller releases both load
balancers before Terraform touches the VPC. Note that Argo CD's CRDs are retained by its
own resource policy — they are removed with the namespace.

![Argo CD Application deleted and Helm releases uninstalled](docs/screenshots/argo_teardown.png)

Both ALBs gone. Terraform has no knowledge of these — they were created by the AWS Load
Balancer Controller in response to Ingress objects — so destroying the VPC while they are
still attached stalls on a dependency Terraform cannot see. The empty result here is the
signal that it is safe to continue.

![No load balancers remaining in the region](docs/screenshots/ALB_teardown.png)

`terraform destroy` complete: 85 resources removed, ending with the VPC itself.

![terraform destroy complete, 85 resources destroyed](docs/screenshots/tf_destroy.png)

No EKS clusters remain in `us-east-2`.

![aws eks list-clusters returning an empty list](docs/screenshots/eks_teardown.png)

All three EC2 instances terminated — the two `t3.small` worker nodes and the `t3.medium`
Jenkins controller. With the cluster, both ALBs, the NAT gateway and these instances gone,
the project incurs no further charges.

![EC2 console showing all instances terminated](docs/screenshots/ec2_terminated.png)

---

## Troubleshooting

Issues actually hit during this build, and their fixes:

| Symptom | Cause | Fix |
| --- | --- | --- |
| Jenkins service fails to start, restarts 5× | Jenkins 2.568 requires Java 21; AL2023 installed Java 17 | `dnf install -y java-21-amazon-corretto-headless`, then restart |
| Jenkins `kubectl` returns Jenkins' own login HTML | Empty kubeconfig, so kubectl fell back to `localhost:8080` | `sudo -u jenkins aws eks update-kubeconfig --name tc2-eks --region us-east-2` |
| Jenkins `kubectl` times out on `10.x.x.x:443` | Cluster SG allows only itself; Jenkins SG not permitted | Add the 443 ingress rule in `07-sg_jenkins_eks.tf` |
| `Permission denied: /var/lib/jenkins/.kube/config` in user-data | `chown` ran after `update-kubeconfig`, not before | Reorder the two steps in `06-jenkins_userdata.sh` |
| Helm add-on releases time out on first apply | Releases scheduled before any node was `Ready` | Two-pass apply — see [Deploying the infrastructure](#deploying-the-infrastructure) |
| HPA pinned at `maxReplicas` with no traffic | Memory request too low; idle usage near the 50% target | Raise the memory request until idle sits well under target |
| `kubectl run` fails with a `C:/Program Files/Git/...` path | MSYS path conversion | `MSYS_NO_PATHCONV=1`, or use `//bin/sh` |
| Terraform plans an EKS version downgrade | Control plane auto-upgraded; `var.cluster_version` left behind | Match the variable to the live version, or target only the resource you want |
| Terraform reports "no changes" after adding a file | The `.tf` file was saved outside `terraform/` | Terraform reads only its own working directory |
| Jenkins UI unreachable on 8080 | `my_ip_cidr` no longer matches your public IP | `curl -s https://checkip.amazonaws.com`, update tfvars, re-apply |
| Argo CD: `Write access to repository not granted` | Fine-grained PAT without this repo granted | Use a classic PAT with `repo` scope |
| Argo CD stuck `Unknown` after fixing credentials | Repo server cached the failure | Restart `argocd-repo-server`, then hard-refresh the Application |
| Argo CD port-forward resets the connection | `server.insecure: true` serves HTTP, not TLS | Forward to `:80` and browse over `http://` |
| GitHub Actions: `Not authorized to perform sts:AssumeRoleWithWebIdentity` | OIDC subject mismatch — unresolved | See [Status at submission](#status-at-submission) |
| GitOps files vanish from the `gitops` branch | `git merge main` replayed the deletion commit from `main` | `git checkout <commit> -- <paths>`; use cherry-pick instead of merge |
| Ingress has no `ADDRESS` | Missing `kubernetes.io/role/elb` subnet tags, or ALB controller IRSA | `kubectl logs -n kube-system deploy/aws-load-balancer-controller` |
| HPA shows `<unknown>/50%` | metrics-server absent, or no resource **requests** | Install metrics-server; set requests |
| Pods `Pending`, node count flat | Autoscaler can't discover the ASG | Check `k8s.io/cluster-autoscaler/*` tags on the ASG; read autoscaler logs |
| Jenkins: "You must be logged in to the server" | Jenkins IAM role not mapped into EKS | Confirm the `access_entries` block in `02-eks.tf` applied |
| Jenkins: `docker: permission denied` | `jenkins` not in the `docker` group | `usermod -aG docker jenkins && systemctl restart jenkins` |
| `ImagePullBackOff` | Node role lacks ECR read | `iam_role_additional_policies` in `02-eks.tf` |

### State recovery

If a network interruption kills an apply mid-write, Terraform writes `errored.tfstate`
locally and leaves the remote lock held. Recover in this order:

```bash
terraform force-unlock <LOCK_ID>          # ID is in the error message
terraform state push errored.tfstate
terraform plan                            # confirm 0 to destroy before applying
rm errored.tfstate
```

---

## Teardown

Take your screenshots first — this is irreversible.

Order matters. Terraform does not know about the load balancers and security groups the
controller created, and will hang on the VPC delete if they are still present. There are
**two** ALBs to release: the application's and Argo CD's.

```bash
kubectl delete -f argocd/application.yaml     # gitops branch only
helm uninstall argocd -n argocd               # gitops branch only
helm uninstall hello-world -n hello-world
kubectl delete ingress --all -A
# wait until both ALBs are gone from the EC2 console
cd terraform
terraform destroy
```

Then confirm in the console that no ALBs, NAT gateways, Elastic IPs or orphaned ENIs remain.
Running cost with the cluster, both ALBs, NAT gateway and Jenkins instance up is roughly
$8/day.

Finally, revoke the GitHub personal access tokens created for Jenkins and Argo CD — they
are no longer needed once the cluster is gone.
