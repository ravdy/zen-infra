output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "private_eks_subnet_ids" {
  description = "IDs of the private EKS subnets"
  value       = aws_subnet.private_eks[*].id
}

output "private_rds_subnet_ids" {
  description = "IDs of the private RDS subnets"
  value       = aws_subnet.private_rds[*].id
}

output "nat_gateway_id" {
  description = "ID of the NAT Gateway"
  value       = aws_nat_gateway.main.id
}
