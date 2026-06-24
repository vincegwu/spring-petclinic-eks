terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

data "aws_caller_identity" "current" {}

resource "random_password" "db" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# ── KMS key for Secrets Manager encryption ───────────────────────────────────
resource "aws_kms_key" "secrets" {
  description             = "KMS key for ${var.service_name} Secrets Manager secret"
  enable_key_rotation     = true
  deletion_window_in_days = var.environment == "prod" ? 30 : 7

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

  tags = var.tags
}

# ── Secrets Manager ──────────────────────────────────────────────────────────
#checkov:skip=CKV2_AWS_57:RDS password rotation via Lambda is not configured — IAM auth is enabled as the preferred auth method
resource "aws_secretsmanager_secret" "db" {
  name                    = "petclinic/${var.environment}/${var.service_name}/db"
  description             = "RDS credentials for ${var.service_name} (${var.environment})"
  recovery_window_in_days = var.environment == "prod" ? 7 : 0
  kms_key_id              = aws_kms_key.secrets.arn
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    host     = aws_db_instance.this.address
    port     = tostring(aws_db_instance.this.port)
    dbname   = var.db_name
    url      = "jdbc:mysql://${aws_db_instance.this.address}:${aws_db_instance.this.port}/${var.db_name}?useSSL=true&requireSSL=true"
  })

  depends_on = [aws_db_instance.this]
}

# ── Networking ───────────────────────────────────────────────────────────────
resource "aws_db_subnet_group" "this" {
  name        = "${var.environment}-${var.service_name}-subnet-group"
  subnet_ids  = var.subnet_ids
  description = "Subnet group for ${var.service_name} RDS instance"
  tags        = merge(var.tags, { Name = "${var.environment}-${var.service_name}-subnet-group" })
}

resource "aws_security_group" "rds" {
  name        = "${var.environment}-${var.service_name}-rds-sg"
  description = "Allow MySQL traffic from EKS worker nodes to ${var.service_name} RDS"
  vpc_id      = var.vpc_id

  ingress {
    description     = "MySQL from EKS nodes"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = var.allowed_security_group_ids
  }

  # No egress rules — RDS does not initiate outbound connections

  tags = merge(var.tags, { Name = "${var.environment}-${var.service_name}-rds-sg" })
}

# ── Parameter Group ──────────────────────────────────────────────────────────
resource "aws_db_parameter_group" "this" {
  name        = "${var.environment}-${var.service_name}-mysql8"
  family      = "mysql8.0"
  description = "MySQL 8.0 parameter group for ${var.service_name}"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  parameter {
    name  = "max_connections"
    value = "100"
  }

  parameter {
    name         = "require_secure_transport"
    value        = "ON"
    apply_method = "immediate"
  }

  tags = var.tags
}

# ── Enhanced monitoring IAM role ─────────────────────────────────────────────
resource "aws_iam_role" "rds_monitoring" {
  name = "${var.environment}-${var.service_name}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ── RDS Instance ─────────────────────────────────────────────────────────────
resource "aws_db_instance" "this" {
  identifier     = "${var.environment}-${var.service_name}"
  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.instance_class

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.allocated_storage * 2
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.this.name

  multi_az               = var.environment == "prod"
  publicly_accessible    = false
  deletion_protection    = var.environment == "prod"
  skip_final_snapshot    = var.environment != "prod"
  final_snapshot_identifier = var.environment == "prod" ? "${var.environment}-${var.service_name}-final" : null

  backup_retention_period   = var.environment == "prod" ? 7 : 1
  backup_window             = "03:00-04:00"
  maintenance_window        = "Mon:04:00-Mon:05:00"
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot     = true

  iam_database_authentication_enabled = true

  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  enabled_cloudwatch_logs_exports = ["error", "slowquery"]

  tags = merge(var.tags, { Name = "${var.environment}-${var.service_name}" })
}
