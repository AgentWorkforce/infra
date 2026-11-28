terraform {
  required_version = ">= 1.11"
  # Bootstrap: applied once by an account administrator (pre-approved, #owner-decisions 252346480703528960).
  # Its own state goes in the bucket it creates, after a first local apply and `terraform init -migrate-state`.
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
