variable "db_password" {
  description = "Master password for the RDS PostgreSQL database"
  type        = string
  sensitive   = true
}

variable "jwt_secret" {
  description = "JWT signing secret for the application"
  type        = string
  sensitive   = true
}

variable "github_org" {
  description = "GitHub username or organization that owns zen-pharma-frontend and zen-pharma-backend (e.g. john-smith)"
  type        = string
  default     = "ravdy"
}

variable "github_runner_pat" {
  description = "GitHub PAT for self-hosted runner registration (stored in Secrets Manager at /pharma/dev/github-runner-pat)"
  type        = string
  sensitive   = true
}

variable "github_runner_repo" {
  description = "Repo-level runner target. Personal accounts must set this — org-level runners require a GitHub Organisation."
  type        = string
  default     = "zen-pharma-frontend"
}
