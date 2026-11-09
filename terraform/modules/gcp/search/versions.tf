terraform {
  required_version = ">= 1.6"

  # Configure both providers in the root module against the existing GKE
  # cluster (see examples/gcp). The module never creates a cluster.
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.17, < 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.30, < 4.0"
    }
  }
}
