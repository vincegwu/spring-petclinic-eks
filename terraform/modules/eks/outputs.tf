output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_oidc_issuer_url" {
  value = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.this.arn
}

output "node_security_group_id" {
  description = "Security group ID of EKS worker nodes — used to allow RDS ingress"
  value       = aws_security_group.nodes.id
}

output "eso_role_arn" {
  description = "IRSA role ARN for the External Secrets Operator"
  value       = aws_iam_role.eso.arn
}

output "cluster_autoscaler_role_arn" {
  description = "IRSA role ARN for the Cluster Autoscaler"
  value       = aws_iam_role.cluster_autoscaler.arn
}

