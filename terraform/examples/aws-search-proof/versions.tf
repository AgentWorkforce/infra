terraform {
  required_version = ">= 1.11, < 2.0"
  backend "local" {} # Dedicated private state/config; never use a shared product/foundation state.
  required_providers {
    aws = { source = "hashicorp/aws", version = "= 6.72.0" }
  }
}
provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]
}
