terraform {
  required_version = ">= 1.11"

  # Supply the backend per environment (-backend-config); no state is kept here.
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}

# The cluster's account: the ledger bucket and the roles that use it live here.
provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]
}
