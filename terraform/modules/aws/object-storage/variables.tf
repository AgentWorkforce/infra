variable "bucket_name" {
  description = "Globally unique S3 bucket name. Feeds sessions-pipeline worker.locker.bucket and alleyoop.locker.bucket (or durable-actors storage.bucket)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3-63 lowercase letters, digits, dots and hyphens."
  }
}

variable "kms_key_arn" {
  description = "Customer managed KMS key for SSE-KMS (with an S3 Bucket Key). null uses SSE-KMS with the AWS managed aws/s3 key."
  type        = string
  default     = null
}

variable "versioning_enabled" {
  description = "Keep object versions (recovery from overwrites and deletes)."
  type        = bool
  default     = true
}

variable "noncurrent_version_expiration_days" {
  description = "Delete noncurrent object versions after this many days (0 keeps them forever)."
  type        = number
  default     = 30

  validation {
    condition     = var.noncurrent_version_expiration_days >= 0
    error_message = "noncurrent_version_expiration_days must be 0 or more."
  }
}

variable "abort_incomplete_multipart_upload_days" {
  description = "Abort incomplete multipart uploads after this many days."
  type        = number
  default     = 7
}

variable "lifecycle_rules" {
  description = "Extra lifecycle rules: id, optional prefix, and optional expiration_days / transition (days, storage_class)."
  type = list(object({
    id              = string
    prefix          = optional(string, "")
    expiration_days = optional(number)
    transitions = optional(list(object({
      days          = number
      storage_class = string
    })), [])
  }))
  default = []
}

variable "access_log_bucket" {
  description = "Existing bucket for S3 server access logs. null disables access logging."
  type        = string
  default     = null
}

variable "access_log_prefix" {
  description = "Key prefix for access logs."
  type        = string
  default     = null
}

variable "force_destroy" {
  description = "Allow destroy to delete every object. Keep false for real data."
  type        = bool
  default     = false
}

variable "object_lock_enabled" {
  description = "Create the bucket with Object Lock enabled (cannot be changed later)."
  type        = bool
  default     = false
}

variable "additional_policy_statements" {
  description = "Extra bucket policy statements (decoded IAM statement objects), merged after the TLS-only denies."
  type        = any
  default     = []
}

variable "access_role" {
  description = <<-EOT
    Optional IAM role for workloads that read and write the bucket (the sessions worker and alleyoop, durable-actors).
    The trust policy admits EKS Pod Identity (pods.eks.amazonaws.com) and, when oidc_provider_arn is set, IRSA for
    the listed service accounts. prefixes limits object access to those key prefixes (empty: the whole bucket).
    pod_identity_associations creates aws_eks_pod_identity_association resources on an existing cluster.
  EOT
  type = object({
    name                     = string
    path                     = optional(string, "/")
    prefixes                 = optional(list(string), [])
    allow_delete             = optional(bool, true)
    oidc_provider_arn        = optional(string)
    permissions_boundary_arn = optional(string)
    pod_identity_associations = optional(list(object({
      cluster_name    = string
      namespace       = string
      service_account = string
    })), [])
    irsa_service_accounts = optional(list(object({
      namespace       = string
      service_account = string
    })), [])
  })
  default = null

  validation {
    condition     = var.access_role == null || length(try(var.access_role.irsa_service_accounts, [])) == 0 || try(var.access_role.oidc_provider_arn, null) != null
    error_message = "access_role.irsa_service_accounts needs access_role.oidc_provider_arn."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
