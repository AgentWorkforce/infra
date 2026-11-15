terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
  # Local state for the first apply (the bucket doesn't exist yet). Afterwards,
  # move it into the bucket it creates: see README.md, "After the first apply".
}
