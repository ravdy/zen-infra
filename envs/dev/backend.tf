terraform {
  backend "s3" {
    bucket       = "zen-pharma-tfstate-rkoneru"  # Replace with your S3 bucket name
    key          = "envs/dev/terraform.tfstate"
    region       = "eu-west-2"
    encrypt      = true
    use_lockfile = true   # S3 native locking
  }
}
