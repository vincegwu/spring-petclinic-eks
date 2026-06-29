output "endpoint" {
  description = "RDS instance hostname"
  value       = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "db_name" {
  value = aws_db_instance.this.db_name
}

output "secret_arn" {
  description = "Secrets Manager secret ARN containing all connection details"
  value       = aws_secretsmanager_secret.db.arn
}

output "secret_name" {
  description = "Secrets Manager secret name — used in ExternalSecret manifests"
  value       = aws_secretsmanager_secret.db.name
}

output "security_group_id" {
  description = "ID of the RDS security group — used to add egress rules on caller SGs"
  value       = aws_security_group.rds.id
}
