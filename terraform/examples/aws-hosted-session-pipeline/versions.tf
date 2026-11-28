terraform {
  # Import blocks with expressions and for_each.
  required_version = ">= 1.11"

  # Backend settings come from the private CI configuration (state bucket, key, lock, KMS).
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]
}
