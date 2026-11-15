terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
  # Applied 2026-11-15. The state lives in the bucket this root created:
  # terraform init -backend-config=backend.hcl (see backend.hcl.example).
  # Tests run with -backend=false.
  backend "s3" {}
}
