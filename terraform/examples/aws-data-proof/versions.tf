terraform {
  required_version = ">= 1.11, < 2.0"
  # Isolated local state is deliberate for this bounded disposable proof. Keep
  # its private directory and recovery copies until independent native absence.
  required_providers {
    aws    = { source = "hashicorp/aws", version = "= 6.72.0" }
    random = { source = "hashicorp/random", version = "= 3.9.1" }
  }
}
provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]
}
