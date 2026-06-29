output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "eso_role_arn" {
  value = module.eks.eso_role_arn
}

output "ecr_registry" {
  value = "${module.ecr.registry_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "rds_secret_names" {
  value = {
    customers = module.rds_customers.secret_name
    vets      = module.rds_vets.secret_name
    visits    = module.rds_visits.secret_name
    genai     = module.rds_genai.secret_name
  }
}

output "github_actions_role_arn" {
  description = "IAM role assumed by GitHub Actions via OIDC (created by terraform/bootstrap)"
  value       = data.aws_iam_role.github_actions.arn
}
