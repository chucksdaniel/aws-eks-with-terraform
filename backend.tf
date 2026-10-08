terraform {
  backend "s3" {
    bucket         = "opumaks-terraform-state"           # from bootstrap output: state_bucket_name
    # The environment wrapper supplies a distinct key with terraform init.
    region         = "us-east-1"

    use_lockfile = true
    encrypt        = true
    profile        = "chuks"
  }
}
