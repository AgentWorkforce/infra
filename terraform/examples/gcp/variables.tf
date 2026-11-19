variable "project_id" {
  description = "GCP project."
  type        = string
}

variable "region" {
  description = "GCP region."
  type        = string
}

variable "name" {
  description = "Name prefix for every resource."
  type        = string
  default     = "agent-relay"
}

variable "labels" {
  description = "Labels for every resource that supports them."
  type        = map(string)
  default     = {}
}

variable "deletion_protection" {
  description = "Prevent deletion of Cloud SQL, Memorystore and Pub/Sub data resources. Disable only for a disposable proof environment."
  type        = bool
  default     = true
}

variable "kms_key_name" {
  description = "CMEK key for Cloud SQL and the bucket (null: Google-managed). Grant the service agents on it first."
  type        = string
  default     = null
}

variable "admin_secret_kms_key_name" {
  description = "CMEK key for the Secret Manager secret that holds the Cloud SQL admin password (null: Google-managed, automatic replication). The key must be in var.region; the secret is then replicated to that region only. Grant the Secret Manager service agent (service-<project number>@gcp-sa-secretmanager.iam.gserviceaccount.com) roles/cloudkms.cryptoKeyEncrypterDecrypter on it first. Set at creation: a secret's replication cannot be changed afterwards."
  type        = string
  default     = null
}

# --- Bring your own network and cluster ----------------------------------------

variable "network_self_link" {
  description = "Existing VPC with Private Services Access configured (Cloud SQL private IP)."
  type        = string
}

variable "vpc_connector" {
  description = "Existing Serverless VPC Access connector for the pipeline function (reaches the private Cloud SQL). Required with enable_functions."
  type        = string
  default     = null

  validation {
    condition     = !var.enable_functions || var.vpc_connector != null
    error_message = "enable_functions needs vpc_connector: the function has no other route to the private Cloud SQL."
  }
}

variable "gke_cluster_name" {
  description = "Existing GKE cluster that runs agent-relay (only for enable_search)."
  type        = string
  default     = null
}

variable "gke_cluster_location" {
  description = "Its region or zone."
  type        = string
  default     = null
}

variable "gke_use_private_endpoint" {
  description = "Reach the control plane on its private endpoint."
  type        = bool
  default     = true
}

variable "namespace" {
  description = "agent-relay release namespace."
  type        = string
  default     = "agent-relay"
}

variable "release_name" {
  description = "agent-relay Helm release name."
  type        = string
  default     = "agent-relay"
}

# --- Components ---------------------------------------------------------------

variable "sessions_bucket_name" {
  description = "Globally unique GCS bucket name for session objects."
  type        = string
}

variable "pipeline_redis_memory_size_gb" {
  description = "Memorystore capacity for the native Sessions pipeline."
  type        = number
  default     = 5
}

variable "pipeline_redis_version" {
  description = "Memorystore Redis version."
  type        = string
  default     = "REDIS_7_2"
}

variable "pipeline_redis_reserved_ip_range" {
  description = "Optional PSA allocated range name for Memorystore. null lets Google choose from the connection."
  type        = string
  default     = null
}

variable "pipeline_pubsub_kms_key_name" {
  description = "Optional CMEK key for the native Sessions pipeline Pub/Sub topics."
  type        = string
  default     = null
}

variable "pipeline_redis_kms_key_name" {
  description = "CMEK key for the pipeline Redis instance at rest (null: Google-managed). Same region as the instance; grant the Memorystore service agent (service-<project number>@cloud-redis.iam.gserviceaccount.com) roles/cloudkms.cryptoKeyEncrypterDecrypter on it first. Set at creation: changing it replaces the instance."
  type        = string
  default     = null
}

variable "pipeline_message_retention" {
  description = "Pub/Sub topic and subscription retention for the native Sessions pipeline."
  type        = string
  default     = "604800s"
}

variable "enable_search" {
  description = "Install the optional OpenSearch cluster on GKE."
  type        = bool
  default     = false
}

variable "search_admin_credentials_secret_name" {
  description = "Existing Secret (in the search namespace) with the OpenSearch admin username and password."
  type        = string
  default     = "opensearch-admin"
}

variable "search_security_config_secret_name" {
  description = "Existing Secret (in the search namespace) with the security plugin configuration."
  type        = string
  default     = "opensearch-security-config"
}

variable "search_storage_class" {
  description = "StorageClass for OpenSearch volumes."
  type        = string
  default     = null
}

variable "enable_functions" {
  description = "Create the optional event-driven pipeline (Cloud Run functions)."
  type        = bool
  default     = false
}

variable "pipeline_source_archive" {
  description = "Function source zip in GCS. Required with enable_functions."
  type = object({
    bucket     = string
    object     = string
    generation = optional(number)
  })
  default = null

  validation {
    condition     = !var.enable_functions || var.pipeline_source_archive != null
    error_message = "enable_functions needs pipeline_source_archive (bucket and object of the function zip)."
  }
}

variable "notification_channels" {
  description = "Cloud Monitoring notification channels for the pipeline alerts."
  type        = list(string)
  default     = []
}

# --- Image mirror (image-mirror.tf) ------------------------------------------

variable "image_mirror_repository" {
  description = "Artifact Registry repository for the release images (guide step 5), created in var.region. Empty: no repository and no grant."
  type        = string
  default     = ""

  validation {
    condition     = var.image_mirror_repository == "" || can(regex("^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", var.image_mirror_repository))
    error_message = "image_mirror_repository must be a repository id: lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "image_mirror_kms_key_name" {
  description = "CMEK key for the image mirror repository (null: Google-managed). Grant the Artifact Registry service agent (service-<project number>@gcp-sa-artifactregistry.iam.gserviceaccount.com) roles/cloudkms.cryptoKeyEncrypterDecrypter on it first. Set at creation: changing it replaces the repository."
  type        = string
  default     = null
}

variable "gke_node_service_account" {
  description = "Email of the GKE node pool's service account, granted roles/artifactregistry.reader on the mirror. Empty: the project's default Compute Engine service account (a node pool whose serviceAccount is \"default\")."
  type        = string
  default     = ""

  validation {
    condition     = var.gke_node_service_account == "" || can(regex("^[^@\\s]+@[^@\\s]+\\.iam\\.gserviceaccount\\.com$", var.gke_node_service_account))
    error_message = "gke_node_service_account must be a service account email (…@….iam.gserviceaccount.com)."
  }
}

variable "desktop_feed_bucket_name" {
  description = "Globally unique bucket for relay-control's signed Desktop feed (SELFHOST_DESKTOP_FEED_GCS_BUCKET). Empty disables it."
  type        = string
  default     = ""
}

variable "desktop_feed_service_account_id" {
  description = "account_id of the Google service account relay-control uses for the Desktop feed bucket (6-30 characters)."
  type        = string
  default     = "agent-relay-control"
}

variable "relay_control_service_account" {
  description = "relay-control's Kubernetes service account. charts/agent-relay/values-gcp.yaml sets fullnameOverride: relay-control, so it is relay-control."
  type        = string
  default     = "relay-control"
}

variable "edge_ssl_policy" {
  description = "Compute SSL policy for the GKE Ingress HTTPS listener, exported as gkeIngress.sslPolicy in chart_values. create = false leaves Google's default policy (TLS 1.0 and later)."
  type = object({
    create          = optional(bool, true)
    profile         = optional(string, "MODERN")
    min_tls_version = optional(string, "TLS_1_2")
  })
  default = {}
}

variable "edge_security_policy" {
  description = "Cloud Armor policy for every GKE Ingress backend (modules/gcp/edge-security security_policy: create, waf, rate_limits, source_ip_allowlist, cloudflare, client_ip_header, client_ip_rules). Off unless create = true. It is exported as gkeIngress.securityPolicy in output.edge, not in chart_values, because the chart then also needs the dashboard Service's backend-config annotation."
  type        = any
  default     = {}
}

variable "edge_origin_secret_header" {
  description = "Shared-secret request header a fronting proxy adds; requests without one of the accepted values (1-3, for rotation) are denied (modules/gcp/edge-security origin_secret_header). Stored in state."
  type = object({
    name   = string
    values = list(string)
  })
  default   = null
  sensitive = true
}

variable "edge_max_subexpressions" {
  description = "Subexpressions per Cloud Armor rule expression (modules/gcp/edge-security max_subexpressions). 10 is what the API accepts; lower it only if your project refuses a rule."
  type        = number
  default     = 10
}

variable "edge_max_advanced_rules" {
  description = "Rules with an expression one Cloud Armor policy may hold (modules/gcp/edge-security max_advanced_rules). Google fixes it at 20; a plan that needs more is refused."
  type        = number
  default     = 20
}
