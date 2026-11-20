terraform {
  required_version = ">= 1.11"

  # Short-lived root: one runner for the Neon -> Supabase copy. State is kept
  # privately by the operator who applies it (never a shared product state).
  backend "local" {}

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
  default_tags {
    tags = var.tags
  }
}
