variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.35"
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs — node group is placed here so pods are reachable via the ALB (or via IGW NodePort in dev)"
  type        = list(string)
}

variable "vpc_cidr" {
  description = "VPC CIDR block — when set, allows the ALB to reach pod ports via IP-mode target groups"
  type        = string
  default     = ""
}

variable "allow_internet_nodeport_access" {
  description = "Open NodePort range 30000-32767 to 0.0.0.0/0. Set false in prod when using AWS LBC with an ALB."
  type        = bool
  default     = true
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "cluster_admin_arns" {
  description = "IAM principal ARNs granted EKS cluster-admin access (e.g. the Terraform caller)"
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
