variable "services" {
  description = "List of service names — one ECR repository is created per service under the spring-petclinic/ prefix"
  type        = list(string)
}

variable "github_actions_role_arn" {
  description = "ARN of the GitHub Actions OIDC IAM role that is allowed to push images"
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
