terraform {
  backend "s3" {

    bucket       = "zen-pharma-terraform-state-pavan27user" # Replace with your S3 bucket name
    key          = "envs/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true # S3 native locking — requires Terraform 1.10+, no DynamoDB needed
=======
    bucket         = "zen-pharma-terraform-state-pavan27user"
    key            = "envs/dev/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-lock-table"
  }
}
