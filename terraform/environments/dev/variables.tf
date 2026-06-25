variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "petclinic-dev"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
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
  default = 3
}

variable "rds_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "github_repo_url" {
  description = "Full HTTPS URL of the GitHub repository — used by ArgoCD to poll for changes"
  type        = string
}

variable "azure_openai_key" {
  description = "Azure OpenAI API key for the genai-service. Passed via TF_VAR_azure_openai_key in CI."
  type        = string
  sensitive   = true
}

variable "azure_openai_endpoint" {
  description = "Azure OpenAI endpoint URL for the genai-service. Passed via TF_VAR_azure_openai_endpoint in CI."
  type        = string
}

variable "github_token" {
  description = "GitHub PAT with repo read scope — used by ArgoCD to pull manifests from a private repository. Passed via TF_VAR_github_token in CI. Leave empty for public repositories."
  type        = string
  sensitive   = true
  default     = ""
}

variable "grafana_admin_password" {
  description = "Initial Grafana admin password. Passed via TF_VAR_grafana_admin_password in CI."
  type        = string
  sensitive   = true
}
