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

data "google_project" "this" {
  project_id = var.project_id
}

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

# Postgres for relaycontrol, Relaycast and HoopDb (native Sessions history).
# relayhistory is retained so applying this root to a legacy installation can
# never schedule deletion of its history database. The native profile does not
# connect to it. Add a database here if you enable durable-actors or Relayfile.
module "postgres" {
  source = "../../modules/gcp/postgres"

  project_id          = var.project_id
  region              = var.region
  name                = "${var.name}-pg"
  network_self_link   = var.network_self_link
  kms_key_name        = var.kms_key_name
  databases           = ["relaycontrol", "relaycast", "hoopdb", "relayhistory"]
  deletion_protection = var.deletion_protection
  server_ca_mode      = "GOOGLE_MANAGED_CAS_CA"
  labels              = var.labels
}

# Shared-CA Cloud SQL certificates carry the instance DNS identity. Resolve
# that identity to the private address inside this VPC so every service can use
# sslmode=verify-full without a proxy or public IP.
resource "google_dns_managed_zone" "cloud_sql" {
  project     = var.project_id
  name        = "${var.name}-cloud-sql"
  dns_name    = "${module.postgres.dns_name}."
  description = "Private verified-DNS route to ${var.name} Cloud SQL"
  visibility  = "private"

  lifecycle {
    precondition {
      condition     = can(regex("^[^.].*\\.sql-psa\\.goog$", module.postgres.dns_name))
      error_message = "Cloud SQL did not return a private-services-access DNS identity; refusing to create an empty or root private DNS zone."
    }
  }

  private_visibility_config {
    networks {
      network_url = var.network_self_link
    }
  }
}

resource "google_dns_record_set" "cloud_sql" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.cloud_sql.name
  name         = "${module.postgres.dns_name}."
  type         = "A"
  ttl          = 300
  rrdatas      = [module.postgres.private_ip_address]
}

# Session objects (Locker), read and written by the native pipeline pods
# through GKE Workload Identity (direct principals; no Google service account).
module "sessions_bucket" {
  source = "../../modules/gcp/object-storage"

  project_id   = var.project_id
  bucket_name  = var.sessions_bucket_name
  location     = var.region
  kms_key_name = var.kms_key_name
  workload_identity = {
    direct_kubernetes_service_accounts = [
      { namespace = var.namespace, name = "${var.release_name}-worker" },
      { namespace = var.namespace, name = "agent-relay-session-ingest-api" },
      { namespace = var.namespace, name = "agent-relay-read-api" },
      { namespace = var.namespace, name = "agent-relay-search-indexer" },
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
