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

variable "kms_key_name" {
  description = "CMEK key for Cloud SQL and the bucket (null: Google-managed). Grant the service agents on it first."
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
