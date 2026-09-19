# Tech Challenge 2 — Build Log

This is a step-by-step record of how I built the challenge, in the order I
actually did it, with the output of each step underneath. It includes the
things that broke and how I worked them out, because that was most of the
work.

For the design reasoning behind the Terraform, the Helm chart and the
Jenkins pipeline, see [ARCHITECTURE.md](ARCHITECTURE.md).

The AI conversations I used during the build are in the
[AI conversation log](docs/ai-conversation/README.md).

**Live application at time of submission:**
`http://k8s-hellowor-hellowor-a7c7be98d6-1367070398.us-east-2.elb.amazonaws.com`

The infrastructure has since been destroyed (see [Part 7](#part-7--teardown)),
so this URL no longer resolves. Everything is reproducible from this repo.

**Environment:** Windows 11, Git Bash (MINGW64), AWS region `us-east-2`.

---

## Contents

- [Part 1 — Repository and code review](#part-1--repository-and-code-review)
- [Part 2 — Building the infrastructure](#part-2--building-the-infrastructure)
- [Part 3 — Deploying the application](#part-3--deploying-the-application)
- [Part 4 — Proving the autoscaling works](#part-4--proving-the-autoscaling-works)
- [Part 5 — Jenkins CI/CD](#part-5--jenkins-cicd)
- [Part 6 — GitOps with Argo CD](#part-6--gitops-with-argo-cd)
- [Part 7 — Teardown](#part-7--teardown)
- [What I would do differently](#what-i-would-do-differently)

---

## Part 1 — Repository and code review

### Step 1 — Securing the repo before pushing

I wrote the application, Dockerfile, Terraform and Helm chart with AI
assistance before starting this run. Before pushing any of it, I checked
what was about to leave my machine.

The first thing I found was an EC2 private key sitting inside the
`terraform/` directory. `.gitignore` covered it, but a gitignored secret is
one `git add -f` away from being committed, so I moved it out of the repo
entirely:

```bash
mkdir -p ~/.ssh/tc2
mv terraform/ec2-lab-app.pem ~/.ssh/tc2/
chmod 600 ~/.ssh/tc2/ec2-lab-app.pem
```

Then I verified that git would actually skip the dangerous files rather
than assuming the `.gitignore` was right:

```bash
git check-ignore -v \
  terraform/09-terraform.auto.tfvars \
  terraform/tfplan \
  terraform/.terraform/ \
  terraform/ec2-lab-app.pem
```

All four matched. I also checked that nothing sensitive had ever been
committed in an earlier session:

```bash
git log --all --oneline -- '*.pem' '*.tfvars' 'terraform/tfplan'
```

Empty output, so the history was clean.

### Step 2 — Making the repo private and inviting my mentor

The brief asks for a private repository shared with the mentor.

![Private repository with mentor invited](docs/screenshots/github_collab_private.png)

The repository has since been made public at my instructor's request so the
screenshots in this document render for reviewers.

### Step 3 — Separating the Jenkins and GitOps branches

The brief wants Jenkins on the main branch and the GitOps approach on a
separate one. Both sets of files had ended up on `main`, so I branched
`gitops` and then removed the Argo CD and GitHub Actions files from `main`:

```bash
git checkout -b gitops
git push -u origin gitops
git checkout main
git rm -r --cached argocd .github/workflows/ci.yml
git commit -m "Remove GitOps config from main branch"
git push
```

This caused a problem later — see [Step 21](#step-21--losing-the-gitops-files-to-a-merge).

### Step 4 — Reviewing the config before spending money

Rather than apply straight away, I read through the Terraform and Helm
files against the requirements. An EKS cluster bills by the hour, so a
config error found before `apply` is a lot cheaper than one found after.

I found four things worth changing.

**The memory request would have broken the HPA demo.** The deployment
requested `128Mi`. A Flask app under gunicorn idles around 60–90 MiB, which
against a 128Mi request is roughly 50–70% utilization with no traffic at
all. Because the HPA takes whichever metric recommends more replicas, that
would have pinned it at `maxReplicas` from startup and there would have
been nothing to demonstrate. I raised it to `256Mi`:

```yaml
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

**metrics-server's argument was a string, not a list.** The Helm provider
had `args` set to `"--kubelet-insecure-tls"`. The chart iterates over that
value, so it needs Helm's list syntax with braces:

```hcl
set = [
  {
    name  = "args"
    value = "{--kubelet-insecure-tls}"
  }
]
```

Without metrics-server serving, the HPA reads `<unknown>/50%` and nothing
scales — so this would have blocked the entire scaling requirement.

**The AWS account ID was hardcoded in the Jenkinsfile.** I changed it to
resolve at runtime from the EC2 instance profile. A Jenkins `environment`
block can't run shell steps, so the lookup needed its own stage:

```groovy
stage('Resolve Account') {
    steps {
        script {
            env.AWS_ACCOUNT = sh(
                script: 'aws sts get-caller-identity --query Account --output text',
                returnStdout: true
            ).trim()
            env.REGISTRY = "${env.AWS_ACCOUNT}.dkr.ecr.${env.AWS_REGION}.amazonaws.com"
            env.IMAGE    = "${env.REGISTRY}/${env.ECR_REPO}"
        }
    }
}
```

**The cluster name had to match.** The Jenkinsfile hardcoded
`CLUSTER_NAME = 'tc2-eks'`. I checked it against the Terraform variable
default and they agreed, so no change — but a mismatch here would have
failed the pipeline's kubectl stage.

I committed these separately so the history shows the reasoning rather than
one undifferentiated dump.

---

## Part 2 — Building the infrastructure

### Step 5 — Confirming a clean starting point

Before applying I checked I wasn't already being billed for a half-built
cluster from an earlier attempt:

```bash
aws eks list-clusters --region us-east-2
aws autoscaling describe-auto-scaling-groups --region us-east-2
```

Both empty. Starting from zero.

### Step 6 — Planning the apply

```bash
cd terraform
terraform init
terraform plan
```

![Terraform plan, 64 resources to add](docs/screenshots/tfplan.png)

64 resources: the VPC and its subnets, the EKS control plane and its KMS
key, the node group, IRSA roles, ECR, and the Jenkins instance.

### Step 7 — Applying in two passes

I applied the VPC and cluster on their own first, rather than everything at
once:

```bash
terraform apply -target=module.vpc -target=module.eks
```

The reason is that the three Helm releases in `04-addons.tf` depend on
`module.eks`, which guarantees the *cluster resources* exist but not that a
node has joined and gone `Ready`. In a single-pass apply, the add-on pods
get scheduled against a cluster with no capacity and Helm times out after
five minutes. Terraform warns that `-target` is for exceptional use, which
is true, but the unrestricted apply afterwards reconciles everything.

![Terraform apply pass 1 complete](docs/screenshots/tf_apply_complete.png)

### Step 8 — Recovering from a dropped connection

Partway through the second apply my internet connection dropped. Terraform
lost the ability to write state and left a lock held in S3:

```text
Error: Failed to save state
Error saving state: failed to upload state: dial tcp: lookup
tc2-tfstate-185196963048.s3.us-east-2.amazonaws.com: no such host
```

Three different AWS endpoints failed DNS simultaneously, which pointed at my
connection rather than at AWS. I confirmed that first:

```bash
nslookup sts.us-east-2.amazonaws.com
aws sts get-caller-identity
```

Once both worked again, I recovered in this order — unlock, push the state
Terraform had captured in memory but couldn't write, then verify:

```bash
terraform force-unlock 6381c380-cfc2-4178-2f51-3c9ce68a924a
terraform state push errored.tfstate
terraform plan
```

The plan came back **20 to add, 0 to change, 0 to destroy**, which told me
nothing had been lost and the 64 resources from pass one were intact. If it
had wanted to destroy anything I would have stopped and investigated rather
than applying.

### Step 9 — Waiting for the node, then the second pass

```bash
aws eks update-kubeconfig --name tc2-eks --region us-east-2
kubectl get nodes
```

![First node Ready](docs/screenshots/node_ready.png)

![Node Ready with kubeconfig context set](docs/screenshots/kubectl_get_nodes.png)

One `t3.small` node, `Ready`, which is `min_size`. With capacity available I
ran the unrestricted apply:

```bash
terraform apply
```

![Terraform apply pass 2 complete with outputs](docs/screenshots/tf_apply_complete_2.png)

20 resources — the add-ons, ECR, the Jenkins EC2 instance and the GitHub
OIDC role.

### Step 10 — Verifying the platform before building on it

Two checks here decide whether the rest of the challenge is possible:

```bash
kubectl get deploy -n kube-system
kubectl top nodes
```

![kube-system deployments and node metrics](docs/screenshots/kube_nodes.png)

All four deployments available, and `kubectl top` returning real numbers —
which confirms the metrics-server argument fix from Step 4 worked. If this
had errored, the HPA would never have functioned.

I also confirmed Cluster Autoscaler could actually discover its Auto Scaling
group. Tags are set on the node group in Terraform, but propagation to the
underlying ASG is worth verifying rather than assuming:

```bash
aws autoscaling describe-auto-scaling-groups --region us-east-2 \
  --query 'AutoScalingGroups[].[AutoScalingGroupName,Tags[?starts_with(Key,`k8s.io/cluster-autoscaler`)].Key]'
```

Both `k8s.io/cluster-autoscaler/enabled` and
`k8s.io/cluster-autoscaler/tc2-eks` were present. Without these, node
scaling silently never happens.

---

## Part 3 — Deploying the application

### Step 11 — Building and pushing the image by hand

I pushed one image manually before wiring up Jenkins, so there would be
something in ECR for Helm to pull and I could separate "does the app work"
from "does the pipeline work".

```bash
ECR=$(terraform -chdir=terraform output -raw ecr_repository_url)
aws ecr get-login-password --region us-east-2 \
  | docker login --username AWS --password-stdin $ECR
docker build -t $ECR:v1 ./app
docker push $ECR:v1
```

![Local docker build](docs/screenshots/ECR_image1.png)

![Manual push to ECR](docs/screenshots/ECR_image2.png)

### Step 12 — First Helm install

```bash
helm upgrade --install hello-world ./helm/hello-world \
  --namespace hello-world --create-namespace \
  --set image.repository=$ECR --set image.tag=v1 \
  --wait --timeout 5m
```

I used the `hello-world` namespace deliberately because that is what the
Jenkinsfile deploys into — installing into a different one would have left
me with two separate releases.

```bash
kubectl get pods,hpa -n hello-world
kubectl get ingress -n hello-world -w
```

![Pod, HPA and Ingress after first Helm install](docs/screenshots/Helm_ALB.png)

The HPA reads `cpu: 1%/50%, memory: 21%/50%`. That memory figure is the
direct result of the 256Mi change in Step 4 — at 128Mi it would have been
sitting around 42% and the autoscaler would have started scaling on its own
before I applied any load.

### Step 13 — The application, live

![Hello World served through the ALB](docs/screenshots/browser_hello_world.png)

![ALB active in the EC2 console](docs/screenshots/ALB_console.png)

I also checked the target group rather than trusting that the load balancer
existing meant traffic was flowing:

![Target group with one healthy pod IP](docs/screenshots/ALB_target_group.png)

The registered target is a **pod IP** (`10.0.27.170:8080`), not a node,
which confirms `alb.ingress.kubernetes.io/target-type: ip` is working as
configured.

---

## Part 4 — Proving the autoscaling works

### Step 14 — Git Bash mangled the load test command

My first attempt at a load generator failed before the container started:

```text
OCI runtime create failed: unable to start container process:
exec: "C:/Program Files/Git/usr/bin/sh": no such file or directory
```

This is MSYS path conversion — Git Bash saw `/bin/sh` in the arguments and
helpfully rewrote it as a Windows path before kubectl ever sent it. It looks
like a cluster problem but is purely a shell quirk. Two fixes work:
`MSYS_NO_PATHCONV=1`, or `//bin/sh`, because Git Bash strips the leading
slash and the container receives the correct path. I used both:

```bash
MSYS_NO_PATHCONV=1 kubectl run load1 --rm -it --image=busybox \
  --restart=Never -n hello-world -- \
  //bin/sh -c "while true; do wget -q -O- http://hello-world > /dev/null; done"
```

![Load generator 1](docs/screenshots/load_test_01.png)

![Load generator 2](docs/screenshots/load_test_02.png)

![Load generator 3](docs/screenshots/load_test_03.png)

I ran three in separate terminals. One sequential `wget` loop does not
generate enough load to push a Flask pod past 50% of a 100m CPU request.

### Step 15 — Watching the HPA scale up

```bash
kubectl get hpa -n hello-world -w
```

![HPA scaling up under load](docs/screenshots/load_test_works.png)

The whole behaviour is visible in one frame: baseline at 1%, CPU spiking to
389% of target, replicas climbing 1 → 5 → 8, then utilization dropping back
as the new pods absorb the traffic and settling around 41–51% as the HPA
converges. Memory stays flat at 21% throughout, which confirms CPU is the
metric actually driving the scaling.

### Step 16 — Node autoscaling and pod distribution

`-w` only accepts one resource type at a time, and nodes are cluster-scoped,
so I watched nodes in a separate terminal:

```bash
kubectl get nodes -w
kubectl get pods -n hello-world -o wide
```

![Nodes scaling 1 to 3 and draining](docs/screenshots/node_scaling1.png)

![11 pods distributed across three nodes](docs/screenshots/ALB_scaling.png)

Eleven pods distributed 4 / 3 / 4 across three nodes. The
`topologySpreadConstraints` with `maxSkew: 1` balance across nodes rather
than stacking onto one.

This is more than the "3 pods per node" the brief describes, and it is worth
being explicit about why. Kubernetes has no per-node replica cap. I
expressed the requirement as a total ceiling of 12 replicas (3 × 4 nodes)
plus an even-spread constraint. Using a hard `DoNotSchedule` anti-affinity
on hostname would enforce one pod per node, but it would also make three
pods per node impossible — the two parts of the requirement contradict each
other, and this is the reading that satisfies both as closely as the
primitives allow.

![ASG at desired capacity 3](docs/screenshots/ASG_console.png)

The Auto Scaling group at desired capacity 3, within its configured 1–4
limits.

### Step 17 — Scale-down

![HPA scaling back down to one replica](docs/screenshots/ALB_scaling2.png)

After stopping the load, the HPA stepped down 11 → 5 → 3 → 2 → 1 over about
eight minutes rather than dropping at once. That is the 120-second
stabilization window combined with the HPA using the highest recommendation
from the preceding five minutes. The node screenshot above also shows
Cluster Autoscaler cordoning a node (`SchedulingDisabled`) and draining it
before termination, rather than killing it outright.

I initially thought the delay meant something was broken. It is the
documented behaviour.

---

## Part 5 — Jenkins CI/CD

This part took the longest, and none of it was the pipeline itself.

### Step 18 — Jenkins would not start

```bash
curl -I http://3.139.227.252:8080
curl: (7) Failed to connect
```

I checked the security group first since it was quickest to rule out — it
allowed 8080 from `70.191.10.145/32`, and `curl -s https://checkip.amazonaws.com`
confirmed that was still my address. So the network was fine and Jenkins
itself was not running.

SSM Session Manager reported the instance as not connected, so I used SSH:

```bash
ssh -i ~/.ssh/tc2/ec2-lab-app.pem ec2-user@3.139.227.252
sudo systemctl status jenkins
```

The service had failed and restarted five times before giving up. The cloud-init
log showed Jenkins, Docker, kubectl, Helm and the AWS CLI had all installed
successfully, so the install wasn't the problem. Running the binary directly
gave the answer:

```bash
sudo /usr/bin/jenkins 2>&1 | head -20
```

```text
Running with Java 17 from /usr/lib/jvm/java-17-amazon-corretto.x86_64,
which is older than the minimum required version (Java 21).
Supported Java versions are: [21, 25]
```

Amazon Linux 2023 pulled in Java 17 as a dependency, but Jenkins 2.568
requires 21 or 25. The user-data script never pinned a version:

```bash
sudo dnf install -y java-21-amazon-corretto-headless
sudo alternatives --set java /usr/lib/jvm/java-21-amazon-corretto/bin/java
sudo systemctl restart jenkins
```

### Step 19 — Jenkins could not reach the cluster

With Jenkins running, I checked the pipeline's dependencies before touching
the UI. Docker worked. kubectl returned something strange:

```text
couldn't get current server API group list: <html><head>...
Authentication required
You are authenticated as: anonymous
```

That is Jenkins' own web UI. The `jenkins` user's kubeconfig was empty — the
user-data script had run `chown` on `.kube` *after* `update-kubeconfig`
rather than before, so the write failed with a permission error — and
kubectl had fallen back to its historical default of `localhost:8080`, where
Jenkins happened to be listening.

Regenerating the kubeconfig moved the problem along but didn't solve it:

```text
dial tcp 10.0.21.190:443: i/o timeout
```

Now kubectl was reaching the real EKS endpoint and timing out. The cluster's
primary security group only permits traffic from itself:

```bash
aws ec2 describe-security-groups --group-ids sg-07707987cd39db17a \
  --region us-east-2 --query 'SecurityGroups[].IpPermissions'
```

Jenkins runs on its own security group, outside the cluster, so nothing it
sent was allowed in. I added the rule in Terraform rather than clicking it
into the console, in its own file to keep the dependency direction clean:

```hcl
resource "aws_security_group_rule" "cluster_api_from_jenkins" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = module.eks.cluster_primary_security_group_id
  source_security_group_id = aws_security_group.jenkins.id
  description              = "Jenkins to EKS API"
}
```

Applying it surfaced something unrelated: the plan wanted to change 6
resources, including downgrading the EKS control plane. EKS had
auto-upgraded the control plane to 1.31 while my `cluster_version` variable
still said 1.30, and AWS rejects downgrades outright. Rather than accept a
rolling replacement of every node for no functional gain, I applied only the
rule I wanted:

```bash
terraform apply -target=aws_security_group_rule.cluster_api_from_jenkins
```

Then verified from the instance:

![Jenkins user running kubectl against the cluster](docs/screenshots/ssh_ec2.png)

### Step 20 — Running the pipeline

With every dependency verified, I set up the job: Pipeline script from SCM,
Git, branch `*/main`, script path `Jenkinsfile`.

![Jenkins build 1 status](docs/screenshots/Jenkins_UI_build.png)

![Jenkins build 1 stage view](docs/screenshots/Jenkins_UI_stages.png)

Build #1 passed every stage on the first run. The console output for the two
stages that matter:

![Jenkins pushing the image to ECR](docs/screenshots/Jenkins_ecr_push.png)

Authentication here comes from the EC2 instance profile — Jenkins stores no
AWS credentials.

![Jenkins helm upgrade and rollout verification](docs/screenshots/Jenkins_helm_upgrade.png)

`REVISION: 2` shows the pipeline upgraded the release I created manually in
Step 12 rather than creating a parallel one, which is the point of using
`helm upgrade --install`.

A green pipeline only proves the pipeline runs, not that it deploys. So I
changed the application's greeting, pushed, and ran it again:

![Jenkins builds 1 and 2, all stages green](docs/screenshots/Jenkins_build_2.png)

![ECR image tags with timestamps](docs/screenshots/AWS_ECR_tags.png)

ECR now shows `v1` from my manual push at 10:47, `1` from build #1 at 12:34,
and `2, latest` from build #2 at 12:59 — each with a distinct digest and a
"last pulled" timestamp showing the cluster actually consumed them.

![Application showing the Jenkins-deployed change](docs/screenshots/browser_deployed_by_Jenkins.png)

"deployed by Jenkins" and `version build-2` on the live URL. That is the
pipeline delivering a code change to a running cluster.

---

## Part 6 — GitOps with Argo CD

### Step 21 — Losing the GitOps files to a merge

The `gitops` branch was still at its original commit and needed the fixes
from Step 4. I merged `main` into it, which was a mistake:

```bash
git checkout gitops
git merge main
cat .github/workflows/ci.yml
# cat: .github/workflows/ci.yml: No such file or directory
```

Removing those files from `main` in Step 3 was recorded as a deletion, and
merging replayed that deletion onto the branch whose entire purpose was to
keep them. Recovering was straightforward since nothing is ever really lost
in git:

```bash
git checkout d8b2b91 -- .github/workflows/ci.yml argocd/
git add .github/workflows/ci.yml argocd/
git commit -m "Restore GitOps files removed by merge from main"
```

The correct approach for bringing shared fixes across two intentionally
divergent branches is `git cherry-pick` of the specific commits, not a
merge.

### Step 22 — Installing Argo CD

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  -f argocd/install-values.yaml --wait --timeout 10m
```

### Step 23 — The token that said the wrong thing

With the repository private, Argo CD needs a credential to read the chart. I
created a fine-grained personal access token and registered it:

```bash
kubectl create secret generic tc2-repo -n argocd \
  --from-literal=type=git \
  --from-literal=url=https://github.com/cloudfighter72/tech_challenge_2.git \
  --from-literal=username=cloudfighter72 \
  --from-literal=password=<token>
kubectl label secret tc2-repo -n argocd argocd.argoproj.io/secret-type=repository
```

The application came back `Unknown`:

```text
failed to list refs: authorization failed:
Write access to repository not granted.
```

That message is misleading — Argo CD only needs read access. It is GitHub's
generic rejection for a token that cannot authenticate at all. Fine-grained
tokens require the specific repository to be granted explicitly and
permissions set individually, which is easy to get wrong. I replaced it with
a classic token carrying the top-level `repo` scope:

![GitHub notification confirming the classic PAT was created](docs/screenshots/argocd_email.png)

Swapping the secret alone didn't fix it, because the repo server caches
authentication failures:

```bash
kubectl rollout restart deploy argocd-repo-server -n argocd
kubectl patch application hello-world -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

![kubectl get application showing Synced and Healthy](docs/screenshots/argocd_health.png)

### Step 24 — Argo CD managing the deployment

Reaching the UI needed one more adjustment. `install-values.yaml` sets
`server.insecure: true` so that TLS terminates at the ALB rather than the
pod, which means the port-forward has to target port 80 over plain HTTP —
forwarding to 443 and browsing over `https://` resets the connection,
because there is no TLS listener on the pod to answer it:

```bash
kubectl port-forward service/argocd-server -n argocd 8080:80
```

![Argo CD applications list showing hello-world synced](docs/screenshots/argo_login.png)

![Argo CD resource tree for hello-world](docs/screenshots/argo_view.png)

Argo CD owns the Deployment, Service, Ingress, HPA and ServiceAccount, with
the ReplicaSet history showing the revisions it has managed through.

### Step 25 — The GitHub Actions half, unresolved

The CI side of the GitOps branch does not work. It fails at the OIDC
credential step:

![GitHub Actions workflow run failing](docs/screenshots/git_ops_fail.png)

```text
Error: Could not assume role with OIDC:
Not authorized to perform sts:AssumeRoleWithWebIdentity
```

I verified everything inspectable from the AWS side:

```bash
aws iam get-role --role-name tc2-github-actions \
  --query 'Role.AssumeRolePolicyDocument'
aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn arn:aws:iam::185196963048:oidc-provider/token.actions.githubusercontent.com
```

The provider exists at `token.actions.githubusercontent.com`, its
`ClientIDList` contains `sts.amazonaws.com`, and the role's trust policy
matches `repo:cloudfighter72/tech_challenge_2:*` with the correct audience
condition. The workflow requests `id-token: write`, and the `AWS_ROLE_ARN`
repository secret exists. I also set Workflow permissions to "Read and
write", which the tag-bump commit needs.

Every component checks out individually and the assumption is still
rejected. Resolving it properly means adding a debug step that prints the
decoded `sub` claim from a live workflow token and comparing it against the
trust policy character by character, rather than continuing to guess at
configuration that already looks correct. I ran out of time in the
challenge window before doing that.

What this means in practice: the pull-based CD half of GitOps works and is
demonstrated above. The image build and push to ECR, which is what the
Actions workflow would do, is demonstrated by the Jenkins pipeline
performing the same operations against the same registry.

---

## Part 7 — Teardown

### Step 26 — Releasing the load balancers first

Order matters here. Terraform has no knowledge of the ALBs — they were
created by the AWS Load Balancer Controller in response to Ingress objects —
so destroying the VPC while they are still attached stalls on a dependency
Terraform cannot see. There were two: the application's and Argo CD's own.

```bash
kubectl delete -f argocd/application.yaml
helm uninstall argocd -n argocd
helm uninstall hello-world -n hello-world
kubectl delete ingress --all -A
```

![Argo CD Application deleted and Helm releases uninstalled](docs/screenshots/argo_teardown.png)

Then I waited for both to actually disappear rather than assuming:

```bash
aws elbv2 describe-load-balancers --region us-east-2 \
  --query 'LoadBalancers[].LoadBalancerName' --output text
```

![No load balancers remaining in the region](docs/screenshots/ALB_teardown.png)

### Step 27 — Destroying the infrastructure

```bash
cd terraform
terraform destroy
```

![terraform destroy complete, 85 resources destroyed](docs/screenshots/tf_destroy.png)

85 resources removed, ending with the VPC itself.

### Step 28 — Confirming nothing is still billing

```bash
aws eks list-clusters --region us-east-2
```

![aws eks list-clusters returning an empty list](docs/screenshots/eks_teardown.png)

![EC2 console showing all instances terminated](docs/screenshots/ec2_terminated.png)

All three instances terminated — the two `t3.small` workers and the
`t3.medium` Jenkins controller. I also revoked the GitHub personal access
tokens created for Argo CD, since they were no longer needed.

Running cost with everything up was roughly $8/day.

---

## What I would do differently

**Verify metrics before the load test, not during.** `kubectl top nodes`
and the HPA's idle percentages are two commands that determine whether the
entire scaling requirement is demonstrable. Both fail silently.

**Check Java before installing Jenkins.** The user-data script installed
Jenkins successfully and the service still would not start. Pinning
`java-21-amazon-corretto-headless` in the script would have avoided the
whole detour.

**Never merge between intentionally divergent branches.** Cherry-pick.

**Use classic tokens for Argo CD.** Fine-grained tokens fail with an error
message that describes the wrong problem.

**Debug the OIDC claim early.** I spent the end of the window checking
configuration that was already correct. Printing the actual token subject
would have been faster than inspecting every component that produces it.

---

## AI assistance

The application code, Terraform, Helm chart and Jenkinsfile were initially
generated with AI assistance, then reviewed and corrected by me as described
in Step 4. I used AI throughout the build as a debugging aid — working
through the Java version failure, the security group timeout, the HPA
sizing problem and the Argo CD token issue. Screenshots of those
conversations are in [docs/ai-conversation/](docs/ai-conversation/).

Not everything it suggested was right. It proposed a Jenkinsfile edit that I
applied incorrectly and wiped 106 lines of the pipeline, which I recovered
from git history. It also suggested several fixes for the OIDC failure that
turned out to be wrong, which is part of why that one is still unresolved —
I was checking suggested causes instead of reading the actual token claim.
