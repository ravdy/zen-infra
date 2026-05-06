output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Endpoint for the EKS cluster API server"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_ca" {
  description = "Base64 encoded certificate authority data for the EKS cluster"
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC Provider for IRSA"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  description = "URL of the OIDC Provider for IRSA"
  value       = aws_iam_openid_connect_provider.eks.url
}

output "node_group_arn" {
  description = "ARN of the EKS Node Group"
  value       = aws_eks_node_group.main.arn
}

output "cluster_security_group_id" {
  description = "Security group ID automatically created by EKS and attached to managed nodes"
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}
