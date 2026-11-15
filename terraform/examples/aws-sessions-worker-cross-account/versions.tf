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

# The cluster's account. The sessions bucket and its key live in another account,
# whose owner merges output.resource_policy_statements into their policies.
provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]
}
