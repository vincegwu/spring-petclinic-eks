locals {
  env = "dev"

  all_services = [
    "api-gateway",
    "config-server",
    "discovery-server",
    "admin-server",
    "customers-service",
    "vets-service",
    "visits-service",
    "genai-service",
  ]

  tags = {
    Project     = "spring-petclinic"
    Environment = local.env
    ManagedBy   = "terraform"
  }
}

data "aws_caller_identity" "current" {}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

# ── GitHub Actions OIDC provider ──────────────────────────────────────────────
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
  tags            = local.tags
}

resource "aws_iam_role" "github_actions" {
  name = "github-actions-${local.env}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/dev"
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "github_actions_ecr" {
  name = "ecr-push"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ecr:GetAuthorizationToken"]
      Resource = "*"
    }]
  })
}

# ── VPC ───────────────────────────────────────────────────────────────────────
module "vpc" {
  source       = "../../modules/vpc"
  cluster_name = var.cluster_name
  vpc_cidr     = var.vpc_cidr
  tags         = local.tags
}

# ── ECR ───────────────────────────────────────────────────────────────────────
module "ecr" {
  source                  = "../../modules/ecr"
  services                = local.all_services
  github_actions_role_arn = aws_iam_role.github_actions.arn
  tags                    = local.tags
}

# ── EKS ───────────────────────────────────────────────────────────────────────
module "eks" {
  source              = "../../modules/eks"
  cluster_name        = var.cluster_name
  environment         = local.env
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  public_subnet_ids   = module.vpc.public_subnet_ids
  node_instance_type  = var.node_instance_type
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  node_desired_size   = var.node_desired_size
  cluster_admin_arns  = [data.aws_caller_identity.current.arn]
  tags                = local.tags
}

# ── RDS — one instance per data service ──────────────────────────────────────
module "rds_customers" {
  source                     = "../../modules/rds"
  service_name               = "customers-service"
  environment                = local.env
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.private_subnet_ids
  allowed_security_group_ids = [module.eks.node_security_group_id]
  instance_class             = var.rds_instance_class
  tags                       = local.tags
}

module "rds_vets" {
  source                     = "../../modules/rds"
  service_name               = "vets-service"
  environment                = local.env
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.private_subnet_ids
  allowed_security_group_ids = [module.eks.node_security_group_id]
  instance_class             = var.rds_instance_class
  tags                       = local.tags
}

module "rds_visits" {
  source                     = "../../modules/rds"
  service_name               = "visits-service"
  environment                = local.env
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.private_subnet_ids
  allowed_security_group_ids = [module.eks.node_security_group_id]
  instance_class             = var.rds_instance_class
  tags                       = local.tags
}

module "rds_genai" {
  source                     = "../../modules/rds"
  service_name               = "genai-service"
  environment                = local.env
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.private_subnet_ids
  allowed_security_group_ids = [module.eks.node_security_group_id]
  instance_class             = var.rds_instance_class
  tags                       = local.tags
}

# ── Azure OpenAI credentials in Secrets Manager ──────────────────────────────
resource "aws_secretsmanager_secret" "azure_openai" {
  name                    = "petclinic/${local.env}/genai-service/azure-openai"
  description             = "Azure OpenAI credentials for genai-service (${local.env})"
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "azure_openai" {
  secret_id     = aws_secretsmanager_secret.azure_openai.id
  secret_string = jsonencode({ api-key = var.azure_openai_key, endpoint = var.azure_openai_endpoint })
}

# ── External Secrets Operator ─────────────────────────────────────────────────
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "0.10.7"
  namespace        = "external-secrets"
  create_namespace = true

  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "external-secrets"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eks.eso_role_arn
  }

  depends_on = [module.eks]
}

# ClusterSecretStore connects ESO to AWS Secrets Manager using the IRSA role.
resource "kubectl_manifest" "cluster_secret_store" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = "aws-secrets-manager"
    }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.aws_region
          auth = {
            jwt = {
              serviceAccountRef = {
                name      = "external-secrets"
                namespace = "external-secrets"
              }
            }
          }
        }
      }
    }
  })

  depends_on = [helm_release.external_secrets]
}

# ── ArgoCD ────────────────────────────────────────────────────────────────────
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.7.21"
  namespace        = "argocd"
  create_namespace = true

  values = [
    yamlencode({
      server = {
        service = {
          type         = "NodePort"
          nodePortHttp = 30880
        }
      }
      configs = {
        params = {
          "server.insecure" = true
        }
      }
    })
  ]

  depends_on = [module.eks]
}

# ArgoCD repository credentials — required for private repositories.
# ArgoCD recognises this Secret by its label and uses it when syncing the Application.
# For a public repository, this resource is created but unused (empty token is harmless).
resource "kubernetes_secret" "argocd_repo_creds" {
  metadata {
    name      = "spring-petclinic-eks-repo"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type     = "git"
    url      = var.github_repo_url
    username = "git"
    password = var.github_token
  }

  depends_on = [helm_release.argocd]
}

# ── Prometheus + Grafana (kube-prometheus-stack) ─────────────────────────────
resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "65.3.1"
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 600

  values = [
    yamlencode({
      prometheus = {
        prometheusSpec = {
          # Discover ServiceMonitors in all namespaces (services are in petclinic-dev)
          serviceMonitorNamespaceSelector = {}
          serviceMonitorSelector          = {}
          podMonitorNamespaceSelector     = {}
          podMonitorSelector              = {}
          ruleNamespaceSelector           = {}
          ruleSelector                    = {}
        }
      }
      grafana = {
        adminPassword = var.grafana_admin_password
        service = {
          type     = "NodePort"
          nodePort = 30300
        }
        dashboardProviders = {
          "dashboardproviders.yaml" = {
            apiVersion = 1
            providers = [{
              name            = "default"
              orgId           = 1
              folder          = "PetClinic"
              type            = "file"
              disableDeletion = false
              options = { path = "/var/lib/grafana/dashboards/default" }
            }]
          }
        }
        dashboards = {
          default = {
            jvm-micrometer = {
              gnetId     = 4701
              revision   = 1
              datasource = "Prometheus"
            }
            spring-boot-statistics = {
              gnetId     = 11955
              revision   = 1
              datasource = "Prometheus"
            }
          }
        }
      }
      alertmanager = {
        enabled = true
      }
    })
  ]

  depends_on = [module.eks]
}

# ArgoCD Application — watches k8s/overlays/dev on the dev branch.
resource "kubectl_manifest" "argocd_app" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "petclinic-${local.env}"
      namespace  = "argocd"
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.github_repo_url
        targetRevision = "dev"
        path           = "k8s/overlays/${local.env}"
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "petclinic-${local.env}"
      }
      syncPolicy = {
        automated = {
          prune      = true
          selfHeal   = true
          allowEmpty = false
        }
        syncOptions = [
          "CreateNamespace=true",
          "PrunePropagationPolicy=foreground",
          "PruneLast=true",
          "ServerSideApply=true",
        ]
        retry = {
          limit = 5
          backoff = {
            duration    = "10s"
            factor      = 2
            maxDuration = "3m"
          }
        }
      }
    }
  })

  depends_on = [helm_release.argocd]
}
