output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "eso_role_arn" {
  description = "Paste this into argocd/base/cluster-secret-store.yaml"
  value       = module.eks.eso_role_arn
}

output "ecr_registry" {
  description = "ECR registry hostname (account.dkr.ecr.region.amazonaws.com)"
  value       = "${module.ecr.registry_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "rds_secret_names" {
  description = "Secrets Manager secret names — paste into k8s ExternalSecret manifests"
  value = {
    customers = module.rds_customers.secret_name
    vets      = module.rds_vets.secret_name
    visits    = module.rds_visits.secret_name
    genai     = module.rds_genai.secret_name
  }
}

output "github_actions_role_arn" {
  description = "Add this as AWS_ROLE_ARN secret in GitHub repository settings"
  value       = aws_iam_role.github_actions.arn
}
