output "eso_role_arn" {
  description = "ARN of the External Secrets Operator IAM role"
  value       = aws_iam_role.eso_role.arn
}

output "argocd_role_arn" {
  description = "ARN of the ArgoCD IAM role"
  value       = aws_iam_role.argocd_role.arn
}

output "gitlab_runner_role_arn" {
  description = "ARN of the GitLab Runner IAM role"
  value       = aws_iam_role.gitlab_runner_role.arn
}
