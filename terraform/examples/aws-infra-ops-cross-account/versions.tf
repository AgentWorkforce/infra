terraform {
  required_version = ">= 1.11"

  # Supply the backend per account (-backend-config); no state is kept here.
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}

# The account being opened to the operator. The provider refuses any other, so
# a wrong profile cannot create the role somewhere else.
provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]
}
