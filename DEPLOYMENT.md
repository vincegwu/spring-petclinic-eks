# Deployment Guide

Everything in this deployment is driven by Terraform and GitHub Actions. No manual AWS CLI, Helm, or kubectl commands are required after the initial setup steps below.

---

## What Terraform provisions end-to-end

Running `terraform apply` across the two stages below provisions and configures the entire stack — no post-apply manual steps:

| What | How |
|---|---|
| VPC, public + private subnets, Internet Gateway | `module.vpc` |
| EKS cluster + node group | `module.eks` |
| IRSA role for EBS CSI driver (`AmazonEBSCSIDriverPolicy`) | `module.eks` |
| ECR repositories (8 services) | `module.ecr` |
| RDS MySQL instance per data service | `module.rds_*` |
| GitHub Actions OIDC provider + trust roles (dev & prod) | `terraform/bootstrap` (one-time) |
| Azure OpenAI credentials in Secrets Manager | `aws_secretsmanager_secret_version.azure_openai` |
| External Secrets Operator | `helm_release.external_secrets` |
| ClusterSecretStore → Secrets Manager | `kubernetes_manifest.cluster_secret_store` |
| ArgoCD | `helm_release.argocd` |
| ArgoCD Application (petclinic-dev/prod) | `kubernetes_manifest.argocd_app` |
| Prometheus + Grafana + AlertManager | `helm_release.kube_prometheus_stack` |
| AWS Load Balancer Controller (**prod only**) | `helm_release.aws_load_balancer_controller` in `terraform/environments/prod/main.tf` |
| ArgoCD ALB Ingress, HTTPS via ACM, dedicated ALB (**prod only**) | `kubectl_manifest.argocd_ingress` in `terraform/environments/prod/main.tf` |
| Grafana ALB Ingress, HTTPS via ACM, shares the api-gateway ALB (**prod only**) | `kubectl_manifest.grafana_ingress` in `terraform/environments/prod/main.tf` |

> Dev has no AWS Load Balancer Controller and no ALB Ingress for ArgoCD/Grafana — it stays on plain NodePort. The `api-gateway` ALB Ingress (also prod-only) is a Kustomize-managed Kubernetes manifest (`k8s/overlays/prod/ingress/api-gateway.yaml`), not Terraform, so ArgoCD applies it as part of the normal GitOps sync — it isn't in the table above. Grafana's Ingress joins the same `IngressGroup` (`alb.ingress.kubernetes.io/group.name: petclinic-prod`) as api-gateway's, so they share one ALB and are routed by hostname rather than each getting a separate ALB.

---

## Prerequisites

Install these tools once on your machine:

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.6
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) — configured with credentials that have `AdministratorAccess` for the bootstrap and first apply
- [Helm](https://helm.sh/docs/intro/install/) >= 3 — the Terraform Helm provider uses the local repo cache; repos must be added before `terraform apply`
- [Git](https://git-scm.com/)

---

## Step 1 — Clone with submodules

```
git clone --recurse-submodules <your-repo-url>
```

If you already cloned without the flag, initialise `upstream/` with:

```
git submodule update --init
```

---

## Step 2 — Prime the Helm repo cache

The Terraform Helm provider resolves charts from the local machine's Helm cache. Run this once (and again on any new machine):

```
helm repo add external-secrets https://charts.external-secrets.io
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

---

## Step 3 — Configure `terraform.tfvars`

Edit both environment files with your repository URL (the only value that varies per environment):

```
terraform/environments/dev/terraform.tfvars
terraform/environments/prod/terraform.tfvars
```

```hcl
github_repo_url = "https://github.com/your-github-username-or-org/spring-petclinic-eks.git"
```

`github_org` and `github_repo` are no longer needed in the environment `tfvars` — they are consumed by the bootstrap step below.

> **CI doesn't need this value** — `terraform.yml` derives `github_repo_url` automatically from the repository it's running in (`TF_VAR_github_repo_url`). The `tfvars` setting above only matters when you run `terraform apply` locally.

If you (or another developer) want permanent `kubectl` access to a cluster from your own machine — see [Accessing services](#accessing-services) — add your IAM user/role ARN to `extra_cluster_admin_arns` in `terraform/environments/<env>/variables.tf`:

```hcl
variable "extra_cluster_admin_arns" {
  default = ["arn:aws:iam::<account-id>:user/<your-iam-user>"]
}
```

Without this, only whichever identity last ran `terraform apply` (typically the `github-actions-dev`/`github-actions-prod` CI role) has cluster access.

---

## Step 4 — Bootstrap Terraform remote state + OIDC

This creates the S3 bucket and DynamoDB table for remote state, and — critically — the GitHub Actions OIDC provider and IAM trust roles. It runs once with your local AWS credentials (the only time static credentials are needed):

```
cd terraform/bootstrap
terraform init
terraform apply \
  -var="github_org=your-github-username-or-org" \
  -var="github_repo=spring-petclinic-eks"
```

Note the two role ARN outputs — you will need them in Step 6:

```
terraform output github_actions_role_arn_dev
terraform output github_actions_role_arn_prod
```

> **Why bootstrap owns OIDC:** GitHub Actions authenticates to AWS via OIDC before it can run Terraform. If the OIDC provider and IAM roles were inside the environment configs, nothing could go first — a classic chicken-and-egg. Bootstrap runs once with local credentials to break the cycle.
>
> The roles are granted `AdministratorAccess` (needed to provision VPC, EKS, RDS, IAM, etc.) plus explicit S3/DynamoDB permissions scoped to the state bucket and lock table. The OIDC trust policy limits who can assume the role to GitHub Actions on the specific repo and branch, so `AdministratorAccess` does not mean the role is unrestricted.

---

## Step 5 — Provision the dev environment

```
cd terraform/environments/dev
terraform init
terraform apply
```

Terraform runs in two internal stages automatically (see `terraform.yml` for how CI does the same):
- **Stage 1** — VPC, EKS, ECR, RDS, IAM (infrastructure layer)
- **Stage 2** — ESO, ArgoCD, kube-prometheus-stack, ClusterSecretStore, ArgoCD Application (add-ons layer; requires Stage 1 to complete first)

The full apply takes 20–30 minutes (EKS cluster creation dominates).

At the end, note the ECR registry output (used in Step 8):

```
terraform output ecr_registry
```

---

## Step 6 — Add GitHub repository secrets

In your repository → **Settings → Secrets and variables → Actions**, add these secrets:

| Secret name | Value |
|---|---|
| `AWS_ROLE_ARN_DEV` | `terraform output github_actions_role_arn_dev` from `terraform/bootstrap` (Step 4) |
| `AWS_ROLE_ARN_PROD` | `terraform output github_actions_role_arn_prod` from `terraform/bootstrap` (Step 4) |
| `AZURE_OPENAI_KEY` | Your Azure OpenAI API key (from the Azure Portal → your resource → Keys and Endpoint) |
| `AZURE_OPENAI_ENDPOINT` | Your Azure OpenAI endpoint URL (e.g. `https://<resource-name>.openai.azure.com/`) |
| `GH_PAT` | A GitHub Personal Access Token with `repo` write scope — needed for CI to commit updated image tags back to the branch |
| `GRAFANA_ADMIN_PASSWORD` | Initial Grafana admin password — set to any strong password |
| `ACM_CERT_ARN` | ARN of an ACM certificate covering your domain (used for the prod `api-gateway` and ArgoCD ALB Ingresses). Request one with `aws acm request-certificate` and validate via a DNS CNAME record at your DNS provider |
| `ALERTMANAGER_SLACK_WEBHOOK_URL` | Slack incoming webhook URL for AlertManager notifications. Optional — leave the secret unset/empty to fall back to a null receiver (no Slack alerts) |

---

## Step 7 — Provision the prod environment

```
cd terraform/environments/prod
terraform init
terraform apply
```

---

## Step 8 — Update the ECR registry placeholder in Kustomize overlays

After running Terraform for either environment, replace `ACCOUNT` and `REGION` in both overlay files with the actual ECR registry hostname from `terraform output ecr_registry`:

```
k8s/overlays/dev/kustomization.yaml
k8s/overlays/prod/kustomization.yaml
```

For example, change:
```yaml
newName: ACCOUNT.dkr.ecr.REGION.amazonaws.com/spring-petclinic/api-gateway
```
to:
```yaml
newName: 123456789012.dkr.ecr.us-east-1.amazonaws.com/spring-petclinic/api-gateway
```

Commit and push this change to the `dev` branch. After this, all image tag updates are handled automatically by the CI workflow.

---

## Step 9 — Trigger the first deployment

Push any change to the `upstream/` directory on the `dev` branch, or simply push the kustomization update from Step 6. The CI workflow will:

1. Build all 8 microservices with Maven
2. Build and push Docker images to ECR
3. Update image tags in `k8s/overlays/dev/kustomization.yaml`
4. Commit the change — ArgoCD detects it and syncs the cluster

---

## Deploying to production

```
git checkout main
git merge dev
git push origin main
```

The same CI pipeline runs for `main`, pushing `prod-<sha>` images and updating `k8s/overlays/prod/kustomization.yaml`. ArgoCD picks up the change. Because `selfHeal` is disabled for prod, ArgoCD will show the diff in its UI — approve the sync there.

---

## Rolling back

Revert the kustomization commit on the relevant branch and push. ArgoCD will sync back to the previous image tags within seconds.

---

## Ongoing infrastructure changes

Any change to files under `terraform/` triggers the `terraform.yml` workflow automatically:
- **Pull requests** → plan output is posted as a PR comment
- **Merge to `dev` or `main`** → apply runs in two stages

The workflow uses a `filter` job to select only the environment that matches the triggering branch (dev → dev environment, main → prod environment), so a push to `dev` never touches the prod state.

You can also re-run apply manually without changing any files — **Actions → Terraform — Plan and Apply → Run workflow**. This only works against `dev`: pick `dev` in "Use workflow from", or the `filter` job fails with an error before anything plans/applies. There is no manual-run path to prod — prod apply only happens via a push to `main`.

The `azure_openai_key` is read from the `AZURE_OPENAI_KEY` GitHub secret at apply time and is never written to the state file in plaintext (it is stored as a `sensitive` variable and encrypted in Secrets Manager alongside the endpoint URL).

---

## Destroying an environment

To tear down all resources for an environment without using your local machine:

1. Go to **Actions → Terraform — Destroy → Run workflow**
2. Pick the `environment` input (`dev` or `prod`)
3. In the `confirm_destroy` input, type the environment name exactly (`dev` or `prod`)
4. Run the workflow

Leaving `confirm_destroy` blank, or entering anything that doesn't exactly match the chosen environment, aborts the run with no changes — this is the only way `terraform destroy` can run from CI. There is no undo; RDS instances are not protected by `deletion_protection` in dev, and the dev `cluster_admin_arns`/`extra_cluster_admin_arns` grants do not change this.

---

## Accessing services

Dev and prod use different access patterns: dev exposes everything via NodePort on the node's public IP (IGW-based, no load balancer); prod fronts `api-gateway` and ArgoCD with an internet-facing ALB over HTTPS, and keeps Grafana/Zipkin internal-only (`ClusterIP`, port-forward).

For NodePort access, get any node's public IP with:

```bash
aws eks update-kubeconfig --name petclinic-dev --region us-east-1   # or petclinic-prod
kubectl get nodes -o wide
# Use the EXTERNAL-IP column
```

Run `aws eks update-kubeconfig` any time `kubectl` reports a DNS resolution error for the cluster endpoint — this refreshes a stale kubeconfig with the current API server address.

This requires your IAM identity to have an EKS access entry — see `extra_cluster_admin_arns` in [Step 3](#step-3--configure-terraformtfvars). Without it, `kubectl` commands fail with `Unauthorized`.

### Dev — NodePort

| Service | NodePort | URL |
|---|---|---|
| PetClinic app (api-gateway) | 30080 | `http://<node-ip>:30080` |
| ArgoCD UI | 30880 | `http://<node-ip>:30880` |
| Grafana | 30300 | `http://<node-ip>:30300` |
| Zipkin | 30411 | `http://<node-ip>:30411` |

### Prod — ALB (HTTPS) for api-gateway, Grafana, and ArgoCD

`api-gateway` and Grafana share **one** internet-facing ALB via an AWS Load Balancer Controller `IngressGroup` (`alb.ingress.kubernetes.io/group.name: petclinic-prod` on both Ingresses), routed by hostname. ArgoCD gets its **own dedicated** ALB. All three are TLS-terminated with the certificate in `ACM_CERT_ARN`.

Get each ALB's hostname:

```bash
kubectl -n petclinic-prod get ingress api-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
kubectl -n monitoring get ingress grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'   # same hostname as api-gateway's — shared ALB
kubectl -n argocd get ingress argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Point a DNS record at each hostname (a CNAME, set to DNS-only/not proxied if your DNS provider offers a proxy mode like Cloudflare's — the ALB itself terminates TLS, so proxying would double up or break validation). ArgoCD's Ingress sets no `host` rule, so its dedicated ALB accepts any hostname routed to it; `api-gateway` and `grafana` each require an exact `host` match (`petclinic.berryexcel.online` / `grafana.berryexcel.online`) since they share one ALB and are disambiguated by hostname.

| Service | Access |
|---|---|
| PetClinic app (api-gateway) | `https://petclinic.<your-domain>` → shared ALB → `api-gateway` Service (`ClusterIP`, ALB targets pods directly in IP mode) |
| Grafana | `https://grafana.<your-domain>` → same shared ALB → `kube-prometheus-stack-grafana` Service (`ClusterIP`) |
| ArgoCD UI | `https://<argocd-subdomain>` → dedicated ALB → `argocd-server` Service (`ClusterIP`) |
| Zipkin | `ClusterIP` only — `kubectl port-forward -n petclinic-prod svc/zipkin 9411:9411` |

---

## Monitoring details

### Grafana

Dev Grafana is at `http://<node-ip>:30300` (see the table above for how to get the node IP). Login: `admin` / value of `GRAFANA_ADMIN_PASSWORD`.

Pre-loaded dashboards under the **PetClinic** folder:
- **JVM Micrometer** — heap, GC, threads per pod
- **Spring Boot Statistics** — request rate, latency, error rate per service

Prod Grafana is reachable at `https://grafana.<your-domain>` (see [Accessing services](#accessing-services) above) — its Service stays `ClusterIP`, fronted by an ALB Ingress sharing the api-gateway ALB. If you need direct access bypassing DNS/ALB, port-forward still works:

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Then open `http://localhost:3000`.

### Zipkin

Dev Zipkin is at `http://<node-ip>:30411`.

Prod Zipkin uses `ClusterIP` — access via port-forward:

```bash
kubectl port-forward -n petclinic-prod svc/zipkin 9411:9411
```

Then open `http://localhost:9411`.

---

## Troubleshooting

### DB-dependent pods stuck in CrashLoopBackOff at startup

**Symptom:** `customers-service`, `vets-service`, `visits-service`, or `genai-service` crash repeatedly. Logs show HikariPool starting, then the pod is killed with no error — or the pod is killed mid-startup with a `Connection timed out` error to the RDS endpoint.

**Cause A — TCP timeout (SG egress missing):** The node security group (`petclinic-<env>-nodes-sg`) restricts egress to HTTPS and DNS by default. TCP 3306 to each RDS security group must be explicitly allowed. This is managed by `aws_security_group_rule` resources in `terraform/environments/<env>/main.tf`. If you provisioned the infrastructure before these rules existed, run `terraform apply` to add them.

**Cause B — Liveness probe kills pod before startup completes:** JVM + Spring Boot + MySQL schema initialisation takes 60–80 s on first boot. The liveness probe is protected by a `startupProbe` (15 × 10 s = 150 s) in all four DB-service deployments. If you see the pod reach `Started ... in Xs` in logs immediately followed by shutdown hooks, the startup probe budget has been exceeded — check that the probe configuration in `k8s/base/<service>/deployment.yaml` matches the current values.

### visits-service fails with `Failed to open the referenced table 'pets'`

The visits-service MySQL schema previously contained `FOREIGN KEY (pet_id) REFERENCES pets(id)`. The `pets` table lives in the customers-service RDS instance — a separate database — so this FK always fails on fresh installs. The FK has been removed from `upstream/spring-petclinic-visits-service/src/main/resources/db/mysql/schema.sql`.

If you are running an older image (before this fix), the schema uses `CREATE TABLE IF NOT EXISTS`, so you can unblock the service by creating the table manually:

```bash
# Get credentials
SECRET=$(aws secretsmanager get-secret-value \
  --secret-id petclinic/dev/visits-service/db \
  --query SecretString --output text)

HOST=$(echo $SECRET | jq -r .host)
USER=$(echo $SECRET | jq -r .username)
PASS=$(echo $SECRET | jq -r .password)

# Create the table from a temporary pod inside the cluster
kubectl run mysql-init -n petclinic-dev --image=mysql:8.0 --restart=Never \
  --env="MYSQL_PWD=$PASS" --command -- \
  mysql -h "$HOST" -u "$USER" petclinic \
  -e "CREATE TABLE IF NOT EXISTS visits (
        id INT(4) UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
        pet_id INT(4) UNSIGNED NOT NULL,
        visit_date DATE,
        description VARCHAR(8192)
      ) engine=InnoDB;"

kubectl delete pod mysql-init -n petclinic-dev
```

Then `kubectl rollout restart deployment/visits-service -n petclinic-<env>`.

### Destroy workflow — AuthFailure on ENI detach

If the destroy workflow logs show `AuthFailure` when detaching ENIs, these are EKS control-plane or other service-owned ENIs that cannot be touched by the account. They are cleaned up automatically when Terraform destroys the EKS cluster and VPC. The errors are non-fatal (`|| true`) and the destroy proceeds normally.
