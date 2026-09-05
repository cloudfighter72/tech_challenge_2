# Tech Challenge 2 — Execution Plan

Ordered build plan for the 72-hour window. Each phase lists the work, what "done" looks
like, and which screenshots to capture (`SS-nn`). Do not start a phase until the previous
one is green — every phase depends on the artifacts of the one before it.

Suggested budget: Phases 0–4 about 2 hours, Phases 5–8 about 5 hours, Phase 9 about 2
hours, Phase 10 about 3 hours, Phases 11–12 about 4 hours. Leave an evening of slack for
EKS and ALB debugging.

---

## Phase 0 — Accounts, tooling, guardrails

On Windows and Git Bash, run these two first. CRLF line endings in
`06-jenkins_userdata.sh` break the Jenkins bootstrap with no visible error.

```bash
git config --global core.autocrlf input
export MSYS_NO_PATHCONV=1
```

Then:

1. Confirm AWS access with `aws sts get-caller-identity`.
2. Confirm the region with `aws configure get region`. Everything here assumes `us-east-2`.
3. Install `terraform` 1.6+, `awscli` v2, `kubectl`, `helm` v3, `docker`, `git`.
4. Set a billing alarm. The EKS control plane is about USD 0.10 per hour and the NAT
   gateway about USD 0.045 per hour, so this stack is not free.
5. Create the Terraform state backend by hand. Terraform cannot bootstrap its own backend.

```bash
aws s3api create-bucket --bucket tc2-tfstate-185196963048 \
  --region us-east-2 \
  --create-bucket-configuration LocationConstraint=us-east-2

aws s3api put-bucket-versioning --bucket tc2-tfstate-185196963048 \
  --versioning-configuration Status=Enabled

aws dynamodb create-table --table-name tc2-tf-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

Screenshots: `SS-01` caller identity and region, `SS-02` the bucket and table.

---

## Phase 1 — Repository

1. Create the GitHub repo and set it to Private before the first push.
2. Unpack the scaffold into the project folder.
3. Run `git init`, then `git add .`, then inspect `git status`.
4. Confirm no `.pem` file and no `09-terraform.auto.tfvars` appear in the staged list.
5. Commit, push `main`, then create and push the `gitops` branch.
6. Add the mentor as a collaborator now rather than at hour 71.

From here on, Jenkins work lands on `main` and GitHub Actions work lands on `gitops`. The
two branches are never merged.

Screenshots: `SS-03` repo settings showing Private and both branches.

---

## Phase 2 — Web application

The Flask app is written at `app/app.py`. It serves `/` returning "Hello, World!",
`/healthz` for probes, and `/load` which burns CPU and holds memory so the HPA has
something to react to in Phase 8.

```bash
pip install -r app/requirements.txt
python app/app.py
```

Verify `curl localhost:8080` returns the greeting.

Screenshots: `SS-04` the browser on `localhost:8080`.

---

## Phase 3 — Dockerize

The Dockerfile uses `python:3.12-slim`, installs dependencies in a separate layer for
caching, runs as a non-root user, and serves through gunicorn.

```bash
docker build -t hello-world:local ./app
docker run -d -p 8080:8080 hello-world:local
curl localhost:8080/healthz
```

Screenshots: `SS-05` the build output, `SS-06` `docker ps` plus the browser.

---

## Phase 4 — ECR repository

Create the registry before the cluster so a working image exists as a fallback if Jenkins
misbehaves later.

```bash
cd terraform
terraform init
terraform apply -target=aws_ecr_repository.app
```

Then push a manual image:

```bash
aws ecr get-login-password --region us-east-2 | \
  docker login --username AWS --password-stdin 185196963048.dkr.ecr.us-east-2.amazonaws.com

docker tag hello-world:local 185196963048.dkr.ecr.us-east-2.amazonaws.com/hello-world:manual-1
docker push 185196963048.dkr.ecr.us-east-2.amazonaws.com/hello-world:manual-1
```

Screenshots: `SS-07` the ECR console showing the pushed tag.

---

## Phase 5 — Terraform: VPC, EKS, node group

Copy the tfvars example and set `my_ip_cidr` to your public IP with a `/32` suffix. Get it
from `curl -s https://checkip.amazonaws.com`.

```bash
cd terraform
cp 09-terraform.auto.tfvars.example 09-terraform.auto.tfvars
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

The apply takes 15 to 20 minutes. Note that `02-eks.tf` reads `aws_iam_role.jenkins.arn`,
so `06-ec2-jenkins.tf` must keep using `var.cluster_name` rather than
`module.eks.cluster_name`. Reversing that creates a dependency cycle.

Verify:

```bash
aws eks update-kubeconfig --name tc2-eks --region us-east-2
kubectl get nodes
```

You should see exactly one `t3.small` node.

Screenshots: `SS-08` the apply output and outputs, `SS-09` the EKS console showing Active,
`SS-10` `kubectl get nodes -o wide`.

---

## Phase 6 — Cluster add-ons

All three add-ons are already `helm_release` resources in `04-addons.tf`, with their IRSA
roles in `03-iam_irsa.tf`. They come up as part of the Phase 5 apply, so this phase is
verification rather than work.

- metrics-server. Without it every HPA reads `<unknown>/50%`.
- AWS Load Balancer Controller. Turns Ingress objects into real ALBs. Pinned to one
  replica so it fits on a `t3.small`.
- Cluster Autoscaler. Adds and removes nodes. Its `scale-down-unneeded-time` is shortened
  to three minutes so the Phase 8 scale-down is screenshot-able.

```bash
kubectl top nodes
kubectl get deploy -n kube-system
kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=20
```

Screenshots: `SS-11` `kubectl top nodes`, `SS-12` the add-on deployments Ready.

---

## Phase 7 — Helm deploy and the ALB URL

The chart lives at `helm/hello-world`. Details already baked in, worth checking if
anything misbehaves:

- Resource requests are set. Without them the HPA percentage targets are meaningless.
- `topologySpreadConstraints` on `kubernetes.io/hostname` with `maxSkew: 1` and
  `whenUnsatisfiable: ScheduleAnyway`.
- Ingress annotations for an internet-facing ALB with `target-type: ip` and a health check
  on `/healthz`.
- Readiness and liveness probes on `/healthz`.

```bash
make deploy TAG=manual-1
make url
```

The ALB takes two to four minutes to become active. That URL is what you submit as the
deployed application.

Screenshots: `SS-13` pods, services and ingress, `SS-14` the browser on the ALB URL,
`SS-15` the load balancer in the EC2 console.

---

## Phase 8 — HPA and autoscaling proof

This phase carries the most evaluation weight and produces transient state. Open two panes
before you start, because re-running costs another half hour.

1. Confirm the HPA reads `<x>%/50%` for both CPU and memory, with `minReplicas: 1` and
   `maxReplicas: 12`.
2. Start the load with `make load`. Raise `replicas` in `k8s/loadtest.yaml` if utilization
   will not cross 50 percent.
3. Watch three things happen in order. The HPA raises replicas, pods go Pending, the
   Cluster Autoscaler adds nodes toward the maximum of four.
4. Stop the load with `make unload` and confirm scale-down. The HPA takes about two
   minutes and the nodes about three.

```bash
make watch
```

Screenshots: `SS-16` the HPA with utilization climbing, `SS-17` the node count rising,
`SS-18` pods spread across nodes, `SS-19` scale-down back to baseline.

---

## Phase 9 — Jenkins configuration

The EC2 instance, IAM role, security group and EKS access entry were all applied in Phase
5 from `06-ec2-jenkins.tf` and `02-eks.tf`. This phase is configuration only.

1. Get the URL from `terraform output jenkins_url`.
2. Connect with `terraform output jenkins_ssh` for SSM, or `jenkins_ssh_key` for SSH.
3. Read the unlock password from `/var/lib/jenkins/secrets/initialAdminPassword`.
4. Install the Git, Pipeline, Docker Pipeline, Amazon ECR, AWS Credentials, Kubernetes CLI
   and GitHub Integration plugins.
5. Add a `github-pat` credential. Do not add AWS keys, since the instance profile covers
   it.

The user-data script takes about four minutes after boot. If port 8080 refuses, read
`/var/log/user-data.log` before assuming the security group is wrong.

Verify as the jenkins user:

```bash
sudo -u jenkins docker ps
sudo -u jenkins helm version
sudo -u jenkins kubectl get nodes
```

Screenshots: `SS-20` the dashboard, `SS-21` installed plugins, `SS-22` credentials,
`SS-23` `kubectl get nodes` as the jenkins user.

---

## Phase 10 — Jenkins pipeline end to end

Usually the longest phase. First runs rarely pass.

1. The `Jenkinsfile` is at the repo root with the account ID already set.
2. Create a Pipeline job pointed at the repo, script path `Jenkinsfile`, branch `main`.
3. Run it. Fix what breaks. Run it again.
4. Prove continuous deployment by changing the page text, pushing to `main`, and watching
   the live URL change.

Stages run in this order: Checkout, Build Image, Smoke Test, Push to ECR, Configure
kubectl, Deploy with Helm, Verify Rollout.

Screenshots: `SS-24` the green stage view, `SS-25` the console log of the push and helm
upgrade, `SS-26` ECR with the build-numbered tag, `SS-27` the browser showing updated text.

---

## Phase 11 — GitOps branch

Work on the `gitops` branch only.

Install Argo CD with the provided values. They set `server.insecure: true` so the ALB
health check passes, and trim resource requests to fit the `t3.small` fleet.

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  -f argocd/install-values.yaml
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

Then:

1. Set the repo secret `AWS_ROLE_ARN` to the `github_actions_role_arn` output. The role
   and trust policy were created in Phase 5 by `07-iam_github_oidc.tf`.
2. The workflow at `.github/workflows/ci.yml` authenticates through OIDC, builds, pushes
   tagged with the commit SHA, then rewrites the image tag in `values.yaml` and commits
   back with a skip-ci marker.
3. Bootstrap Argo CD once with `kubectl apply -f argocd/application.yaml`.
4. Push a text change to `gitops` and watch Argo CD sync on its own.

Screenshots: `SS-28` the green workflow run, `SS-29` the auto-commit, `SS-30` the Argo CD
app Healthy and Synced, `SS-31` the sync history, `SS-32` the live URL serving the GitOps
build.

---

## Phase 12 — Documentation and submission

1. Drop screenshots into `docs/screenshots/` and check the filenames match the README
   table.
2. Put the live ALB URL at the top of the README.
3. Add an architecture diagram. Cheap marks, high impact.
4. Push both branches and confirm each holds the right pipeline.
5. Set the repository to Private and confirm the mentor is a collaborator.
6. After the screenshots are safely committed, tear down with `make destroy`.

Check the EC2 and VPC consoles by hand afterwards. Orphaned load balancers and NAT
gateways keep billing you.

Screenshots: `SS-33` the mentor added as a collaborator, `SS-34` both branches on GitHub.

---

## Screenshot checklist

| Phase | Shots | Proves |
| --- | --- | --- |
| 0 to 1 | 01 to 03 | AWS access, state backend, private repo |
| 2 to 3 | 04 to 06 | App works, container works |
| 4 | 07 | ECR and manual push |
| 5 | 08 to 10 | Terraform provisioned a live EKS cluster |
| 6 | 11 to 12 | metrics-server, ALB controller, autoscaler |
| 7 | 13 to 15 | App deployed via Helm and reachable through the ALB |
| 8 | 16 to 19 | HPA and node autoscaling work |
| 9 | 20 to 23 | Jenkins configured with cluster access |
| 10 | 24 to 27 | Full CI/CD loop, code change to live change |
| 11 | 28 to 32 | GitOps loop via Actions and Argo CD |
| 12 | 33 to 34 | Submission requirements met |

Phases 8 and 10 carry the most weight, since the brief grades the functionality of the
hosted application and the proper execution of the pipeline. Spend slack time there.

---

## Failure modes to expect

| Symptom | Cause | Fix |
| --- | --- | --- |
| Ingress has no address | Subnet tags missing, or the ALB controller has no IRSA | Read the controller logs and re-check subnet tags |
| HPA shows unknown | No metrics-server, or no resource requests | Install metrics-server and set requests |
| Pods Pending, nodes flat | The autoscaler cannot discover the ASG | Verify the cluster-autoscaler tags on the node group |
| Jenkins cannot reach the cluster | The Jenkins role is not mapped into EKS | Confirm the access entry in `02-eks.tf` applied |
| Jenkins docker permission denied | The jenkins user is not in the docker group | Add it and restart Jenkins |
| ImagePullBackOff | The node role lacks ECR read | Check the additional policies in `02-eks.tf` |
| Terraform reports a cycle | `06-ec2-jenkins.tf` was changed to reference the EKS module | Revert to `var.cluster_name` |
| Argo CD stuck OutOfSync | Wrong target revision, or the bot lacks write permission | Confirm the branch and workflow permissions |
