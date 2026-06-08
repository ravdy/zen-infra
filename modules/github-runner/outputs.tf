output "instance_id" {
  description = "EC2 instance ID of the GitHub Actions runner"
  value       = aws_instance.runner.id
}

output "security_group_id" {
  description = "Security group ID of the runner instance"
  value       = aws_security_group.runner.id
}

output "iam_role_arn" {
  description = "ARN of the IAM role attached to the runner instance"
  value       = aws_iam_role.runner.arn
}
