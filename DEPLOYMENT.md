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

The `azure_openai_key` is read from the `AZURE_OPENAI_KEY` GitHub secret at apply time and is never written to the state file in plaintext (it is stored as a `sensitive` variable and encrypted in Secrets Manager alongside the endpoint URL).

---

## Accessing services

All public-facing services use NodePort. Get any node's public IP with:

```bash
kubectl get nodes -o wide
# Use the EXTERNAL-IP column
```

| Service | NodePort | URL |
|---|---|---|
| PetClinic app (api-gateway) | 30080 | `http://<node-ip>:30080` |
| ArgoCD UI | 30880 | `http://<node-ip>:30880` |
| Grafana (dev only) | 30300 | `http://<node-ip>:30300` |
| Zipkin (dev only) | 30411 | `http://<node-ip>:30411` |

---

## Monitoring details

### Grafana

Dev Grafana is at `http://<node-ip>:30300` (see the table above for how to get the node IP). Login: `admin` / value of `GRAFANA_ADMIN_PASSWORD`.

Pre-loaded dashboards under the **PetClinic** folder:
- **JVM Micrometer** — heap, GC, threads per pod
- **Spring Boot Statistics** — request rate, latency, error rate per service

Prod Grafana uses `ClusterIP` — access via port-forward:

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
