output "db_secret_arn" {
  description = "ARN of the database credentials secret"
  value       = aws_secretsmanager_secret.db_credentials.arn
}

output "jwt_secret_arn" {
  description = "ARN of the JWT signing secret"
  value       = aws_secretsmanager_secret.jwt_secret.arn
}

output "github_runner_pat_secret_arn" {
  description = "ARN of the GitHub runner PAT secret"
  value       = aws_secretsmanager_secret.github_runner_pat.arn
}
