terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
  # S3 state in the prod account, configured at init:
  # terraform init -backend-config=backend.hcl (see backend.hcl.example).
  # Tests run with -backend=false.
  backend "s3" {}
}
