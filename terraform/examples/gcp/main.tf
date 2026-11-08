terraform {
  # The postgres module writes the admin password with write-only attributes.
  required_version = ">= 1.11"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.0, < 8.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0, < 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.30, < 4.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Helm and Kubernetes are used only by the optional search module, against the
# existing GKE cluster that runs agent-relay.
data "google_client_config" "this" {}

data "google_container_cluster" "this" {
  count = var.enable_search ? 1 : 0

  project  = var.project_id
  location = var.gke_cluster_location
  name     = var.gke_cluster_name
}

locals {
  gke_cluster = var.enable_search ? data.google_container_cluster.this[0] : null
  gke_private = try(local.gke_cluster.private_cluster_config[0].private_endpoint, "")
  gke_host    = var.enable_search ? "https://${var.gke_use_private_endpoint && local.gke_private != "" ? local.gke_private : local.gke_cluster.endpoint}" : null
  gke_ca      = var.enable_search ? base64decode(data.google_container_cluster.this[0].master_auth[0].cluster_ca_certificate) : null
}

provider "kubernetes" {
  host                   = local.gke_host
  token                  = data.google_client_config.this.access_token
  cluster_ca_certificate = local.gke_ca
}

provider "helm" {
  kubernetes = {
    host                   = local.gke_host
    token                  = data.google_client_config.this.access_token
    cluster_ca_certificate = local.gke_ca
  }
}

# Postgres for relaycontrol (relay-control), relayhistory and HoopDb
# (sessions). Add a database here if you enable durable-actors.
module "postgres" {
  source = "../../modules/gcp/postgres"

  project_id        = var.project_id
  region            = var.region
  name              = "${var.name}-pg"
  network_self_link = var.network_self_link
  kms_key_name      = var.kms_key_name
  databases         = ["relaycontrol", "relayhistory", "hoopdb"]
  labels            = var.labels
}

# Session objects (Locker), read and written by the worker and alleyoop pods
# through GKE Workload Identity (direct principals; no Google service account).
module "sessions_bucket" {
  source = "../../modules/gcp/object-storage"

  project_id   = var.project_id
  bucket_name  = var.sessions_bucket_name
  location     = var.region
  kms_key_name = var.kms_key_name
  workload_identity = {
    direct_kubernetes_service_accounts = [
      for sa in ["worker", "alleyoop"] : { namespace = var.namespace, name = "${var.release_name}-${sa}" }
    ]
  }
  labels = var.labels
}

# Optional: OpenSearch on GKE as the transcript search index.
module "search" {
  source = "../../modules/gcp/search"
  count  = var.enable_search ? 1 : 0

  admin_credentials_secret_name = var.search_admin_credentials_secret_name
  security_config_secret_name   = var.search_security_config_secret_name
  storage_class                 = var.search_storage_class
  labels                        = var.labels
  network_policy = {
    allowed_namespaces = [var.namespace]
  }
}

# Optional: the sessions pipeline's event-driven mode (GCS -> Pub/Sub -> Cloud
# Run functions), instead of the long-running worker stages.
module "functions" {
  source = "../../modules/gcp/functions"
  count  = var.enable_functions ? 1 : 0

  project_id            = var.project_id
  region                = var.region
  name                  = var.name
  bucket_name           = module.sessions_bucket.bucket_name
  source_archive        = var.pipeline_source_archive
  vpc_connector         = var.vpc_connector
  notification_channels = var.notification_channels
  labels                = var.labels
}
