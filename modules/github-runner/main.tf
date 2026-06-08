data "aws_region" "current" {}
data "aws_caller_identity" "runner_account" {}

# ── Latest Ubuntu 22.04 LTS AMI (Canonical) ──────────────────────────────────
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── IAM Role & Instance Profile ───────────────────────────────────────────────
resource "aws_iam_role" "runner" {
  name = "${var.project}-${var.env}-github-runner-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = {
    Name    = "${var.project}-${var.env}-github-runner-role"
    Env     = var.env
    Project = var.project
  }
}

resource "aws_iam_role_policy" "runner" {
  name = "${var.project}-${var.env}-github-runner-policy"
  role = aws_iam_role.runner.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:DescribeImages",
        ]
        Resource = "arn:aws:ecr:*:${data.aws_caller_identity.runner_account.account_id}:repository/*"
      },
      {
        Sid      = "EKSRead"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster", "eks:ListClusters"]
        Resource = "*"
      },
      {
        Sid      = "SecretsManagerRunnerPAT"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = var.gh_pat_secret_arn
      },
      {
        Sid    = "SSMSessionManager"
        Effect = "Allow"
        Action = [
          "ssm:UpdateInstanceInformation",
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
          "ec2messages:AcknowledgeMessage",
          "ec2messages:DeleteMessage",
          "ec2messages:FailMessage",
          "ec2messages:GetEndpoint",
          "ec2messages:GetMessages",
          "ec2messages:SendReply",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "runner" {
  name = "${var.project}-${var.env}-github-runner-profile"
  role = aws_iam_role.runner.name

  tags = {
    Name    = "${var.project}-${var.env}-github-runner-profile"
    Env     = var.env
    Project = var.project
  }
}

# ── Security Group — egress only ──────────────────────────────────────────────
resource "aws_security_group" "runner" {
  name_prefix = "${var.project}-${var.env}-github-runner-"
  vpc_id      = var.vpc_id
  description = "GitHub Actions self-hosted runner - outbound only"

  egress {
    description = "All outbound to GitHub, ECR, Secrets Manager"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name    = "${var.project}-${var.env}-github-runner-sg"
    Env     = var.env
    Project = var.project
  }
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────
resource "aws_instance" "runner" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  iam_instance_profile   = aws_iam_instance_profile.runner.name
  vpc_security_group_ids = [aws_security_group.runner.id]

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/runner-init.sh.tftpl", {
    github_org        = var.github_org
    github_repo       = var.github_repo
    runner_labels     = join(",", var.runner_labels)
    gh_pat_secret_arn = var.gh_pat_secret_arn
    aws_region        = data.aws_region.current.name
    runner_name       = "${var.project}-${var.env}-runner"
    tf_version        = var.tf_version
  })

  tags = {
    Name    = "${var.project}-${var.env}-github-runner"
    Env     = var.env
    Project = var.project
    Role    = "github-actions-runner"
  }
}
