terraform {
  backend "s3" {
    bucket         = "opumaks-terraform-state"           # from bootstrap output: state_bucket_name
    key            = "dev/vpc-staging-env/terraform.tfstate" # unique path per project/env
    region         = "us-east-1"

    use_lockfile = true
    encrypt        = true
    profile        = "chuks"
  }
}
