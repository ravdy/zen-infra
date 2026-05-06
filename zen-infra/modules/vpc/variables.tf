variable "project" {
  description = "Project name"
  type        = string
}

variable "env" {
  description = "Environment name (dev, qa, prod)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "List of CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_eks_subnet_cidrs" {
  description = "List of CIDR blocks for private EKS subnets"
  type        = list(string)
  default     = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "private_rds_subnet_cidrs" {
  description = "List of CIDR blocks for private RDS subnets"
  type        = list(string)
  default     = ["10.0.5.0/24", "10.0.6.0/24"]
}
