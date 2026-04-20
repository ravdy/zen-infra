terraform {
  backend "s3" {
    bucket         = "zen-pharma-terraform-state-pavan27user"
    key            = "envs/dev/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-lock-table"
  }
}
