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

# The account that owns the downloads bucket and the distribution.
provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]
}

# CloudFront only accepts ACM certificates from us-east-1.
provider "aws" {
  alias               = "us_east_1"
  region              = "us-east-1"
  allowed_account_ids = [var.account_id]
}
