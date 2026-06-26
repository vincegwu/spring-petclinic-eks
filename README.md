# Spring PetClinic on AWS EKS

A production-ready GitOps deployment of the [Spring PetClinic Microservices](https://github.com/spring-petclinic/spring-petclinic-microservices) application on AWS EKS, using Terraform for infrastructure, GitHub Actions for CI, and ArgoCD for continuous delivery.

The application source lives in `upstream/` (tracked as a [git submodule](https://github.com/spring-petclinic/spring-petclinic-microservices)). Everything else in this repository is the deployment infrastructure.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         GitHub Repository                           │
│                                                                     │
│   dev branch ──── GitHub Actions CI ────▶ ECR (dev-<sha> tags)     │
│                           │                        │                │
│                   updates kustomization    ArgoCD polls            │
│                           │                        │                │
│                           ▼                        ▼                │
│   main branch ─── GitHub Actions CI ────▶ ECR (prod-<sha> tags)    │
└─────────────────────────────────────────────────────────────────────┘
                                                     │
                          ┌──────────────────────────┘
                          │
              ┌───────────▼────────────┐
              │       AWS EKS          │
              │                        │
              │  ┌─────────────────┐   │       ┌──────────────────────┐
              │  │ petclinic-dev   │   │       │  AWS Secrets Manager │
              │  │   namespace     │◀──┼───────│                      │
              │  └─────────────────┘   │  ESO  │ petclinic/dev/*/db   │
              │                        │       │ petclinic/prod/*/db  │
              │  ┌─────────────────┐   │       └──────────────────────┘
              │  │ petclinic-prod  │   │
              │  │   namespace     │   │       ┌──────────────────────┐
              │  └─────────────────┘   │       │   RDS MySQL 8.0      │
              │                        │       │  (one per service)   │
              │  ┌─────────────────┐   │       │                      │
              │  │     argocd      │   │       │ • customers-service  │
              │  │   namespace     │   │       │ • vets-service       │
              │  └─────────────────┘   │       │ • visits-service     │
              └────────────────────────┘       │ • genai-service      │
                                               └──────────────────────┘
```

---

## Microservices

The application is composed of eight Spring Boot microservices. Services are started in dependency order: config-server → discovery-server → everything else.

| Service | Port | Database | Description |
|---|---|---|---|
| `api-gateway` | 8080 | — | Spring Cloud Gateway — public entry point, routes all API traffic, hosts the AngularJS UI |
| `config-server` | 8888 | — | Spring Cloud Config Server — centralised configuration for all services |
| `discovery-server` | 8761 | — | Netflix Eureka Server — service registry and discovery |
| `admin-server` | 9090 | — | Spring Boot Admin — monitoring dashboard for all microservices |
| `customers-service` | 8081 | MySQL | Manages pet owners and their pets |
| `vets-service` | 8083 | MySQL | Manages veterinarians and their specialities |
| `visits-service` | 8082 | MySQL | Manages pet visit records |
| `genai-service` | 8084 | MySQL | Spring AI-powered assistant (Azure OpenAI — gpt-4.1-mini deployment) |

Each service that requires a database gets its **own isolated RDS MySQL 8.0 instance** — there is no shared database.

---

## Branch → Environment Mapping

| Branch | Environment | EKS Cluster | K8s Namespace | Image Tag |
|---|---|---|---|---|
| `dev` | Development | `petclinic-dev` | `petclinic-dev` | `dev-<git-sha>` |
| `main` | Production | `petclinic-prod` | `petclinic-prod` | `prod-<git-sha>` |

A push to either branch triggers the full CI/CD pipeline automatically. Pull requests to either branch run tests and a Terraform plan without deploying.

---

## Infrastructure Components

### Terraform (`terraform/`)

| Module / config | Resources provisioned |
|---|---|
| `bootstrap/` | S3 state bucket, DynamoDB lock table, GitHub Actions OIDC provider, `github-actions-dev` + `github-actions-prod` IAM roles — **run once manually before anything else** |
| `modules/vpc` | VPC (10.0/10.1.0.0/16), 3 public + 3 private subnets across AZs, Internet Gateway, route tables (no NAT — nodes are in public subnets; private subnets are RDS-only with no egress) |
| `modules/eks` | EKS cluster (Kubernetes 1.31), managed node group (in public subnets for IGW-based NodePort access), OIDC provider, IRSA roles for External Secrets Operator and EBS CSI driver, CoreDNS / kube-proxy / VPC CNI / EBS CSI add-ons |
| `modules/ecr` | 8 ECR repositories under `spring-petclinic/<service>`, lifecycle policy (30 tagged / expire untagged after 7 days), push permissions for GitHub Actions |
| `modules/rds` | RDS MySQL 8.0 per data service — random 24-char password, Secrets Manager secret, private subnet group, security group (port 3306 from EKS nodes only), Multi-AZ and deletion protection enabled in prod |

Environment configurations (`environments/dev`, `environments/prod`) wire the modules together. The GitHub Actions OIDC provider and trust roles are created by `terraform/bootstrap` (run once manually) so that CI can authenticate before any environment Terraform has run.

| Setting | Dev | Prod |
|---|---|---|
| Node type | `t3.medium` | `t3.large` |
| Node count | 2–4 | 2–8 |
| RDS instance | `db.t3.micro` | `db.t3.small` |
| RDS Multi-AZ | No | Yes |
| Deletion protection | No | Yes |
| Replicas per service | 1 | 2 |

### Kubernetes (`k8s/`)

Manifests are managed with **Kustomize**:

```
k8s/
├── base/               # Deployments and Services for all 8 microservices
└── overlays/
    ├── dev/            # dev namespace, 1 replica, dev image tags, dev ExternalSecrets
    └── prod/           # prod namespace, 2 replicas, prod image tags, prod ExternalSecrets
```

Database credentials and the Azure OpenAI credentials are injected from Kubernetes secrets that are kept in sync with AWS Secrets Manager by **External Secrets Operator** (ESO). Each overlay contains `ExternalSecret` resources referencing `petclinic/<env>/<service>/db` (database) and `petclinic/<env>/genai-service/azure-openai` (API key + endpoint) in Secrets Manager.

### ArgoCD (`argocd/`)

ArgoCD runs inside the EKS cluster in the `argocd` namespace and watches the Git repository for changes to the overlay directories.

| Application | Watches | Target namespace | Auto-sync |
|---|---|---|---|
| `petclinic-dev` | `k8s/overlays/dev` on branch `dev` | `petclinic-dev` | Yes, with self-heal |
| `petclinic-prod` | `k8s/overlays/prod` on branch `main` | `petclinic-prod` | Yes, manual approval for drift |

### Monitoring (`monitoring` namespace)

Prometheus, Grafana, and AlertManager are installed by Terraform via the **kube-prometheus-stack** Helm chart. Zipkin distributed tracing runs alongside the application services.

| Component | Description |
|---|---|
| **Prometheus** | Scrapes all services via `ServiceMonitor` CRDs. Discovers monitors across all namespaces including `petclinic-dev` and `petclinic-prod` |
| **Grafana** | Pre-loaded dashboards: JVM Micrometer (gnetId 4701) and Spring Boot Statistics (gnetId 11955). Exposed as NodePort 30300 in dev, ClusterIP in prod |
| **AlertManager** | Ships with the kube-prometheus-stack. Rules cover service availability, P95 latency >2 s, error rate >5%, JVM heap >90%, and GC pause >500 ms |
| **Zipkin** | In-memory tracing server. All 8 services send spans via `MANAGEMENT_ZIPKIN_TRACING_ENDPOINT`. Sampling: 100% dev, 10% prod |

---

## CI/CD Pipeline

### `.github/workflows/ci.yml` — Build, Push, Update Tags

Triggers on push to `dev` or `main` (when `upstream/**` changes), or manually via **Actions → Run workflow** (`workflow_dispatch`) — useful for rebuilding without an `upstream/` change, e.g. after fixing the pipeline itself.

```
1. Matrix-build all 8 service JARs with Maven (parallel)
2. Build Docker image per service using upstream/docker/Dockerfile
   - ARTIFACT_NAME = path to built JAR
   - EXPOSED_PORT  = service port
3. Push to ECR: spring-petclinic/<service>:<prefix>-<sha>
4. Update image tags in k8s/overlays/<env>/kustomization.yaml via kustomize
5. Commit and push the updated kustomization (ArgoCD detects and syncs)
```

AWS authentication uses **GitHub OIDC** — no long-lived credentials are stored in GitHub.

### `.github/workflows/terraform.yml` — Infrastructure Changes

Triggers on push or PR to `dev`/`main` (when `terraform/**` changes), or manually via **Actions → Run workflow** (`workflow_dispatch`).

- **Pull request** → `terraform plan`, output posted as a PR comment
- **Push** → `terraform apply`
- **Manual (`workflow_dispatch`)** → `terraform apply`, same as a push, but only against `dev`. The `filter` job fails fast if you pick anything other than `dev` in "Use workflow from" — manual runs against `main`/prod must go through a push instead.

A `filter` job runs first to select only the environment matching the triggering branch (dev → dev, main → prod), then passes a single-entry matrix to the `terraform` job. This avoids the GitHub Actions limitation where `matrix` context is unavailable in job-level `if` conditions, and ensures a push to `dev` never touches prod state.

### `.github/workflows/destroy.yml` — Destroy an Environment

Manual only (`workflow_dispatch`). Pick the `environment` input (`dev`/`prod`) and type the same name into `confirm_destroy` to run `terraform destroy` — any other value (including blank) aborts with no changes. See [DEPLOYMENT.md](./DEPLOYMENT.md#destroying-an-environment).

### `.github/workflows/pr-checks.yml` — PR Validation

Runs on any pull request to `dev` or `main`:

- Maven `verify` for all 8 services (parallel matrix)
- `kustomize build` validation on both overlays

---

## Repository Structure

```
spring-petclinic-eks/
├── upstream/                          # Spring PetClinic Microservices source
│   ├── spring-petclinic-api-gateway/
│   ├── spring-petclinic-config-server/
│   ├── spring-petclinic-discovery-server/
│   ├── spring-petclinic-admin-server/
│   ├── spring-petclinic-customers-service/
│   ├── spring-petclinic-vets-service/
│   ├── spring-petclinic-visits-service/
│   ├── spring-petclinic-genai-service/
│   └── docker/Dockerfile              # Shared multi-stage Docker build
│
├── terraform/
│   ├── bootstrap/                     # One-time: S3 state bucket + DynamoDB lock table + GitHub Actions OIDC + IAM roles
│   ├── modules/
│   │   ├── vpc/                       # VPC, subnets, NAT
│   │   ├── eks/                       # EKS cluster, node group, IRSA roles
│   │   ├── ecr/                       # ECR repositories
│   │   └── rds/                       # RDS MySQL + Secrets Manager secret
│   └── environments/
│       ├── dev/                       # Dev: infra + ESO + ArgoCD + ArgoCD Application
│       └── prod/                      # Prod: same, separate state and sizing
│
├── k8s/
│   ├── base/                          # Kustomize base (Deployments + Services)
│   │   ├── config-server/
│   │   ├── discovery-server/
│   │   ├── admin-server/
│   │   ├── api-gateway/
│   │   ├── customers-service/
│   │   ├── vets-service/
│   │   ├── visits-service/
│   │   ├── genai-service/
│   │   └── monitoring/               # Zipkin, ServiceMonitors, PrometheusRules, tracing ConfigMap
│   └── overlays/
│       ├── dev/                       # Dev: namespace, images, 1 replica, ExternalSecrets, Zipkin NodePort
│       └── prod/                      # Prod: namespace, images, 2 replicas, ExternalSecrets, 10% sampling
│
├── argocd/
│   ├── dev/petclinic-dev.yaml         # ArgoCD Application reference (created by Terraform)
│   └── prod/petclinic-prod.yaml       # ArgoCD Application reference (created by Terraform)
│
├── .github/workflows/
│   ├── ci.yml                         # Build → ECR → update image tags
│   ├── terraform.yml                  # Terraform plan / apply
│   └── pr-checks.yml                  # Tests + kustomize validation on PRs
│
└── DEPLOYMENT.md                      # Step-by-step bootstrap and operations guide
```

---

## Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| AWS CLI | v2 | Authentication for the initial Terraform runs |
| Terraform | >= 1.6 | All infrastructure provisioning (VPC, EKS, ECR, RDS, Helm add-ons, ArgoCD) |
| Helm | >= 3 | Required locally to prime the Terraform Helm provider's repo cache (`helm repo add` + `helm repo update`) before `terraform apply` |
| Git | any | Clone with `--recurse-submodules` to initialise `upstream/` |
| Java | 17 | Local development only |
| Maven | 3.x (wrapper included) | Local development only |

> **kubectl** and **kustomize** are not required to deploy — Terraform installs and configures all Kubernetes add-ons, and the CI workflow handles Kustomize. You'll still want `kubectl` locally for day-2 operations (checking pod status, port-forwarding Grafana/Zipkin in prod, finding a node's public IP) — see `extra_cluster_admin_arns` in [DEPLOYMENT.md](./DEPLOYMENT.md) for granting your IAM identity cluster access.

---

## Getting Started

Everything is driven by `terraform apply` and GitHub Actions — no manual kubectl, Helm, or AWS CLI commands after setup. See **[DEPLOYMENT.md](./DEPLOYMENT.md)** for the full guide.

High-level sequence:

1. **Clone with submodules** — `git clone --recurse-submodules <repo-url>` (or `git submodule update --init` after a plain clone)
2. **Prime the Helm repo cache** — run once on any machine that will execute `terraform apply`:
   ```bash
   helm repo add external-secrets https://charts.external-secrets.io
   helm repo add argo https://argoproj.github.io/argo-helm
   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
   helm repo update
   ```
3. **Fill in `terraform.tfvars`** — set `github_repo_url` in both environment files (`github_org` and `github_repo` are now passed to bootstrap, not the environments)
4. **`terraform apply` in `terraform/bootstrap/`** — creates S3 bucket, DynamoDB lock table, the GitHub Actions OIDC provider, and the `github-actions-dev` / `github-actions-prod` IAM roles (one-time, with your local AWS credentials). Note the two role ARN outputs.
5. **`terraform apply` in `terraform/environments/dev/`** — provisions VPC, EKS, ECR, four RDS instances, installs ESO, ArgoCD, and registers the ArgoCD Application, all in a single apply
6. **Add six GitHub secrets** — `AWS_ROLE_ARN_DEV` and `AWS_ROLE_ARN_PROD` come from the bootstrap outputs; also add `AZURE_OPENAI_KEY`, `AZURE_OPENAI_ENDPOINT`, `GH_PAT`, `GRAFANA_ADMIN_PASSWORD`
7. **`terraform apply` in `terraform/environments/prod/`** — same as dev for the prod cluster
8. **Update ECR registry placeholders** in `k8s/overlays/*/kustomization.yaml` with the value from `terraform output ecr_registry`, then commit
9. **Push to `dev`** — GitHub Actions builds all services, pushes images, updates image tags; ArgoCD syncs automatically

---

## Local Development

To run the application locally without Kubernetes, follow the instructions in [upstream/README.md](./upstream/README.md). The quickest path uses Docker Compose:

```bash
cd upstream
./mvnw clean install -P buildDocker
docker compose up
```

Services will be available at:

| Service | URL |
|---|---|
| Application UI (API Gateway) | http://localhost:8080 |
| Eureka Dashboard | http://localhost:8761 |
| Spring Boot Admin | http://localhost:9090 |
| Config Server | http://localhost:8888 |
| Zipkin Tracing | http://localhost:9411 |
| Grafana | http://localhost:3030 |
| Prometheus | http://localhost:9091 |

---

## Tech Stack

| Layer | Technology |
|---|---|
| Application | Spring Boot 4.0.1, Spring Cloud 2025.1.0, Spring AI 2.0 |
| Container runtime | Java 17 (Eclipse Temurin), Docker |
| Container registry | AWS ECR |
| Orchestration | AWS EKS (Kubernetes 1.31) |
| Infrastructure as Code | Terraform 1.6+ — provisions AWS resources, Helm add-ons, and the ArgoCD Application in one apply |
| CI | GitHub Actions (OIDC — no long-lived AWS keys stored anywhere) |
| CD | ArgoCD (GitOps, Kustomize) |
| Secrets | AWS Secrets Manager + External Secrets Operator (both configured by Terraform) |
| Databases | AWS RDS MySQL 8.0 (one instance per data service) |
| Networking | AWS VPC, Internet Gateway, NodePort services (nodes in public subnets — no load balancer) |
| Service discovery | Netflix Eureka |
| Observability | Micrometer, Prometheus, Grafana, Zipkin |

---

## License

The application source in `upstream/` is licensed under the [Apache 2.0 License](./upstream/LICENSE).
