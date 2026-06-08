variable "project" {
  description = "Project name"
  type        = string
}

variable "env" {
  description = "Environment name (dev, qa, prod)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to place the runner in"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID for the runner instance (must have outbound internet access)"
  type        = string
}

variable "github_org" {
  description = "GitHub organization or username"
  type        = string
}

variable "github_repo" {
  description = "Repo-level runner target (e.g. zen-pharma-frontend). Leave empty for org-level runner."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance type for the runner"
  type        = string
  default     = "t3.medium"
}

variable "gh_pat_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the GitHub Classic PAT (repo scope). Fine-grained PATs are NOT supported by the runner registration API."
  type        = string
}

variable "runner_labels" {
  description = "Labels applied to the runner (used in runs-on)"
  type        = list(string)
  default     = ["self-hosted", "linux", "x64"]
}

variable "tf_version" {
  description = "Terraform version to install on the runner"
  type        = string
  default     = "1.10.0"
}
