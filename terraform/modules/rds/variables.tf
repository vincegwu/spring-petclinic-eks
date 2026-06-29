variable "service_name" {
  description = "Short service name (e.g. customers, vets) — used for resource naming"
  type        = string
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for the DB subnet group"
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security group IDs allowed to reach port 3306 — typically the EKS node SG"
  type        = list(string)
}

variable "instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Initial storage in GiB"
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Database name created on the instance"
  type        = string
  default     = "petclinic"
}

variable "db_username" {
  description = "Master username for the RDS instance"
  type        = string
  default     = "petclinic"
}

variable "tags" {
  type    = map(string)
  default = {}
}
