terraform {
  # Write-only attributes (password_wo, secret_data_wo) and ephemeral
  # resources keep the admin password out of state and plan files. They need
  # Terraform >= 1.11 or OpenTofu >= 1.11.
  required_version = ">= 1.11"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.0, < 8.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.7, < 4.0"
    }
  }
}
