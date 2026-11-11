terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # ECC_NIST_EDWARDS25519 key specs are accepted from the 6.72 line used by the AWS roots.
      version = ">= 6.72, < 7.0"
    }
  }
}
