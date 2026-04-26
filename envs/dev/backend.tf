terraform {
  backend "s3" {
    bucket       = "zen-pharma-terraform-pallamrajub"  # Replace with your S3 bucket name
    key          = "envs/dev/terraform.tfstate"  #terraform statefile location
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true   # S3 native locking
  }
}
