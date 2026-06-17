locals {
  project = "pharma"
  env     = "dev"
  region  = "us-east-1"
}

data "aws_caller_identity" "current" {}

# ─── VPC ─────────────────────────────────────────────────────────────────────
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${local.project}-${local.env}-vpc"
  cidr = "10.0.0.0/16"

  azs              = ["${local.region}a", "${local.region}b"]
  public_subnets   = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets  = ["10.0.3.0/24", "10.0.4.0/24"]
  database_subnets = ["10.0.5.0/24", "10.0.6.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  enable_dns_hostnames   = true
  enable_dns_support     = true
  create_database_subnet_group = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"                            = "1"
    "kubernetes.io/cluster/${local.project}-${local.env}-cluster" = "owned"
  }

  tags = {
    Project = local.project
    Env     = local.env
  }
}

# ─── EKS ─────────────────────────────────────────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  cluster_name    = "${local.project}-${local.env}-cluster"
  cluster_version = "1.33"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true

  enable_irsa = true

  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    main = {
      instance_types = ["t3.small"]
      min_size       = 1
      max_size       = 4
      desired_size   = 3
    }
  }

  tags = {
    Project = local.project
    Env     = local.env
  }
}

# ─── RDS Security Group ──────────────────────────────────────────────────────
resource "aws_security_group" "rds" {
  name        = "${local.project}-${local.env}-rds-sg"
  description = "Security group for RDS PostgreSQL instance"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "PostgreSQL from EKS worker nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${local.project}-${local.env}-rds-sg"
    Project = local.project
    Env     = local.env
  }
}

# ─── RDS ─────────────────────────────────────────────────────────────────────
module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 7.0"

  identifier = "${local.project}-${local.env}-postgres"

  engine               = "postgres"
  engine_version       = "17.9"
  family               = "postgres17"
  major_engine_version = "17"
  instance_class       = "db.t3.micro"

  allocated_storage = 20
  storage_type      = "gp3"

  db_name                     = "pharmadb"
  username                    = "pharmaadmin"
  manage_master_user_password = false
  password                    = var.db_password

  multi_az               = false
  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.rds.id]

  skip_final_snapshot     = true
  backup_retention_period = 0
  storage_encrypted       = true
  deletion_protection     = false
  publicly_accessible     = false

  create_db_option_group = false

  tags = {
    Name    = "${local.project}-${local.env}-postgres"
    Project = local.project
    Env     = local.env
  }
}

# ─── ECR ─────────────────────────────────────────────────────────────────────
module "ecr" {
  source = "../../modules/ecr"

  project = local.project
  env     = local.env
  repositories = [
    "api-gateway",
    "auth-service",
    "drug-catalog-service",
    "inventory-service",
    "manufacturing-service",
    "notification-service",
    "pharma-ui",
    "supplier-service",
    "qc-service",
  ]
}

# ─── IAM (IRSA Roles) ───────────────────────────────────────────────────────
module "iam" {
  source = "../../modules/iam"

  project           = local.project
  env               = local.env
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.cluster_oidc_issuer_url
  aws_account_id    = data.aws_caller_identity.current.account_id
  github_org        = var.github_org
}

# ─── Secrets Manager ────────────────────────────────────────────────────────
module "secrets_manager" {
  source = "../../modules/secrets-manager"

  project     = local.project
  env         = local.env
  db_username = "pharmaadmin"
  db_password = var.db_password
  db_host     = module.rds.db_instance_endpoint
  jwt_secret  = var.jwt_secret
}
