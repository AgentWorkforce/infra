variable "project_id" {
  description = "Project that owns the bucket."
  type        = string
}

variable "bucket_name" {
  description = "Globally unique bucket name. Feeds sessions-pipeline worker.locker.bucket and alleyoop.locker.bucket (provider gcs), or durable-actors storage.bucket."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3-63 lowercase letters, digits, dots, hyphens and underscores."
  }
}

variable "location" {
  description = "Bucket location (a region such as us-central1, a dual-region or a multi-region). The sessions services expect the bucket's region in locker.region."
  type        = string
}

variable "storage_class" {
  description = "Default storage class."
  type        = string
  default     = "STANDARD"
}

variable "kms_key_name" {
  description = "CMEK key for default object encryption. The Cloud Storage service agent needs roles/cloudkms.cryptoKeyEncrypterDecrypter on it first. null uses Google-managed encryption."
  type        = string
  default     = null
}

variable "versioning_enabled" {
  description = "Keep noncurrent object versions."
  type        = bool
  default     = true
}

variable "noncurrent_version_retention_days" {
  description = "Delete noncurrent versions this many days after they become noncurrent (0 keeps them)."
  type        = number
  default     = 30
}

variable "soft_delete_retention_seconds" {
  description = "Soft delete retention (0 disables; 604800 = 7 days is the GCS default)."
  type        = number
  default     = 604800

  validation {
    condition     = floor(var.soft_delete_retention_seconds) == var.soft_delete_retention_seconds && (var.soft_delete_retention_seconds == 0 || (var.soft_delete_retention_seconds >= 604800 && var.soft_delete_retention_seconds <= 7776000))
    error_message = "soft_delete_retention_seconds must be a whole number: 0 or 604800-7776000 (7-90 days)."
  }
}

variable "abort_incomplete_multipart_upload_days" {
  description = "Abort incomplete XML API multipart uploads after this many days."
  type        = number
  default     = 7
}

variable "lifecycle_rules" {
  description = "Extra lifecycle rules: action (Delete or SetStorageClass with storage_class) and condition fields."
  type = list(object({
    action_type        = string
    storage_class      = optional(string)
    age_days           = optional(number)
    matches_prefix     = optional(list(string))
    with_state         = optional(string)
    num_newer_versions = optional(number)
  }))
  default = []
}

variable "access_log_bucket" {
  description = "Existing bucket for usage logs. null disables usage logging."
  type        = string
  default     = null
}

variable "force_destroy" {
  description = "Allow destroy to delete every object. Keep false for real data."
  type        = bool
  default     = false
}

variable "workload_identity" {
  description = <<-EOT
    Optional GKE Workload Identity access with roles/storage.objectUser on this bucket (read, write, list, delete objects; no IAM).
    google_service_account: creates a Google service account the listed Kubernetes service accounts may impersonate
    (annotate them iam.gke.io/gcp-service-account=<email>; durable-actors takes it as serviceAccount.googleServiceAccount).
    direct_kubernetes_service_accounts: grants the Kubernetes service accounts directly through the workload pool
    principal (no Google service account, no annotation).
  EOT
  type = object({
    google_service_account = optional(object({
      account_id   = string
      display_name = optional(string)
      kubernetes_service_accounts = list(object({
        namespace = string
        name      = string
      }))
    }))
    direct_kubernetes_service_accounts = optional(list(object({
      namespace = string
      name      = string
    })), [])
    # <project>.svc.id.goog of the cluster's project (default: project_id).
    workload_pool = optional(string)
  })
  default = null
}

variable "iam_members" {
  description = "Extra bucket IAM bindings: role => members."
  type        = map(list(string))
  default     = {}
}

variable "labels" {
  description = "Labels applied to the bucket."
  type        = map(string)
  default     = {}
}
