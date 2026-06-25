locals {
  env = "prod"

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

# IAM role was created by terraform/bootstrap — look it up by name
data "aws_iam_role" "github_actions" {
  name = "github-actions-${local.env}"
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
  github_actions_role_arn = data.aws_iam_role.github_actions.arn
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

# ── KMS key for application secrets ─────────────────────────────────────────
resource "aws_kms_key" "secrets" {
  description             = "KMS key for application secrets (${local.env})"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EnableRootAccess"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })

  tags = local.tags
}

# ── Azure OpenAI credentials in Secrets Manager ──────────────────────────────
resource "aws_secretsmanager_secret" "azure_openai" {
  #checkov:skip=CKV2_AWS_57:External API key — Lambda rotation is not applicable
  name                    = "petclinic/${local.env}/genai-service/azure-openai"
  description             = "Azure OpenAI credentials for genai-service (${local.env})"
  recovery_window_in_days = 7
  kms_key_id              = aws_kms_key.secrets.arn
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
          serviceMonitorNamespaceSelector = {}
          serviceMonitorSelector          = {}
          podMonitorNamespaceSelector     = {}
          podMonitorSelector              = {}
          ruleNamespaceSelector           = {}
          ruleSelector                    = {}
          retention                       = "30d"
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                accessModes = ["ReadWriteOnce"]
                resources = { requests = { storage = "50Gi" } }
              }
            }
          }
        }
      }
      grafana = {
        adminPassword = var.grafana_admin_password
        service = { type = "ClusterIP" }
        persistence = {
          enabled      = true
          size         = "10Gi"
          accessModes  = ["ReadWriteOnce"]
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
        alertmanagerSpec = {
          storage = {
            volumeClaimTemplate = {
              spec = {
                accessModes = ["ReadWriteOnce"]
                resources = { requests = { storage = "10Gi" } }
              }
            }
          }
        }
      }
    })
  ]

  depends_on = [module.eks]
}

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
        targetRevision = "main"
        path           = "k8s/overlays/${local.env}"
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "petclinic-${local.env}"
      }
      syncPolicy = {
        automated = {
          prune      = true
          selfHeal   = false
          allowEmpty = false
        }
        syncOptions = [
          "CreateNamespace=true",
          "PrunePropagationPolicy=foreground",
          "PruneLast=true",
          "ServerSideApply=true",
        ]
        retry = {
          limit = 3
          backoff = {
            duration    = "30s"
            factor      = 2
            maxDuration = "5m"
          }
        }
      }
    }
  })

  depends_on = [helm_release.argocd]
}
