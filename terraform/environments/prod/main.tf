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

  # EKS access entries require the underlying IAM role ARN, not the STS
  # assumed-role session ARN that aws_caller_identity returns when Terraform
  # is running as an assumed role (e.g. via GitHub Actions OIDC).
  caller_arn = data.aws_caller_identity.current.arn
  caller_admin_arn = (
    can(regex("^arn:aws:sts::[0-9]+:assumed-role/", local.caller_arn))
    ? replace(local.caller_arn, "/^arn:aws:sts::(\\d+):assumed-role/([^/]+)/.*$/", "arn:aws:iam::$1:role/$2")
    : local.caller_arn
  )
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
  source             = "../../modules/eks"
  cluster_name       = var.cluster_name
  environment        = local.env
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids
  node_instance_type = var.node_instance_type
  node_min_size      = var.node_min_size
  node_max_size      = var.node_max_size
  node_desired_size  = var.node_desired_size
  cluster_admin_arns = [local.caller_admin_arn]
  tags               = local.tags
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

# ── Node → RDS egress rules ───────────────────────────────────────────────────
# The node SG only allows egress to itself (node-to-node), HTTPS, and DNS.
# Without these rules pods cannot open TCP 3306 connections to RDS even though
# the RDS SGs already allow inbound from the node SG.
locals {
  rds_security_group_ids = {
    customers = module.rds_customers.security_group_id
    vets      = module.rds_vets.security_group_id
    visits    = module.rds_visits.security_group_id
    genai     = module.rds_genai.security_group_id
  }
}

resource "aws_security_group_rule" "nodes_to_rds" {
  for_each = local.rds_security_group_ids

  type                     = "egress"
  description              = "MySQL to ${each.key} RDS"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = module.eks.node_security_group_id
  source_security_group_id = each.value
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

# ── gp3 StorageClass (EBS CSI) ───────────────────────────────────────────────
# Must exist before any Helm release that requests PersistentVolumeClaims.
# The in-tree gp2 StorageClass created by EKS is not marked as default and uses
# the deprecated kubernetes.io/aws-ebs provisioner. This resource creates a gp3
# class backed by the EBS CSI driver (installed as an EKS add-on) and marks it
# as the cluster default so PVCs without an explicit storageClassName are bound.
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [module.eks]
}

# ── metrics-server (required by HPA for CPU/memory metrics) ──────────────────
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = "3.13.1"
  namespace  = "kube-system"

  set {
    name  = "args[0]"
    value = "--kubelet-insecure-tls"
  }

  depends_on = [module.eks]
}

# ── Cluster Autoscaler ────────────────────────────────────────────────────────
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = "9.58.0"
  namespace  = "kube-system"

  set {
    name  = "autoDiscovery.clusterName"
    value = var.cluster_name
  }
  set {
    name  = "awsRegion"
    value = var.aws_region
  }
  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eks.cluster_autoscaler_role_arn
  }
  set {
    name  = "extraArgs.balance-similar-node-groups"
    value = "true"
  }
  set {
    name  = "extraArgs.skip-nodes-with-local-storage"
    value = "false"
  }
  set {
    name  = "extraArgs.expander"
    value = "least-waste"
  }
  set {
    name  = "extraArgs.scale-down-enabled"
    value = "true"
  }
  set {
    name  = "extraArgs.scale-down-delay-after-add"
    value = "10m0s"
  }
  set {
    name  = "extraArgs.scale-down-unneeded-time"
    value = "10m0s"
  }

  depends_on = [module.eks]
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
  timeout          = 900

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
                storageClassName = "gp3"
                accessModes      = ["ReadWriteOnce"]
                resources        = { requests = { storage = "50Gi" } }
              }
            }
          }
        }
      }
      grafana = {
        adminPassword = var.grafana_admin_password
        service       = { type = "ClusterIP" }
        persistence = {
          enabled          = true
          storageClassName = "gp3"
          size             = "10Gi"
          accessModes      = ["ReadWriteOnce"]
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
                storageClassName = "gp3"
                accessModes      = ["ReadWriteOnce"]
                resources        = { requests = { storage = "10Gi" } }
              }
            }
          }
        }
      }
    })
  ]

  depends_on = [module.eks, kubernetes_storage_class.gp3]
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
  version          = "8.6.4"
  namespace        = "argocd"
  create_namespace = true
  timeout          = 600

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
        cm = {
          # Prevents schema validation errors on K8s 1.35 fields not yet in
          # older ArgoCD bundled schemas (e.g. .status.terminatingReplicas).
          # Safe to remove once ArgoCD natively bundles the K8s 1.35 schema.
          "resource.compareoptions" = "ignoreResourceStatusField: all"
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
      ignoreDifferences = [
        {
          group         = "apps"
          kind          = "Deployment"
          jsonPointers  = ["/spec/replicas"]
        }
      ]
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
          "RespectIgnoreDifferences=true",
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
