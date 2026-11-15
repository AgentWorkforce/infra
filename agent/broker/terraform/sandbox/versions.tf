terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
  # No backend here on purpose: whoever applies this (Khaliq) picks the state
  # backend. Never apply it from an agent.
}
