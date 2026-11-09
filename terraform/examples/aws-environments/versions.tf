terraform {
  required_version = ">= 1.11"

  # Supply a different backend configuration and TF_DATA_DIR per environment.
  # Credentials come from the runner (pippen sandbox exec for sandbox proofs).
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
