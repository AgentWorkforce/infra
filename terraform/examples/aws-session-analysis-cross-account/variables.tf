variable "account_id" {
  description = "The EKS cluster account. The provider refuses any other account."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account id."
  }
}

variable "region" {
  description = "The EKS cluster region."
  type        = string
}

variable "eks_cluster_name" {
  description = "The EKS cluster that runs session-analysis and has the Pod Identity Agent add-on."
  type        = string
}

variable "namespace" {
  description = "Namespace of the agent-relay release."
  type        = string
}

variable "service_account" {
  description = "Dedicated session-analysis ServiceAccount; never share the ingest or general worker identity."
  type        = string
  default     = "agent-relay-worker-session-analysis"
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.service_account)) && !contains(["default", "agent-relay-worker", "agent-relay-ingest-edge"], var.service_account)
    error_message = "service_account must be a dedicated Kubernetes ServiceAccount name, not a shared worker or ingest identity."
  }
}

variable "role_name" {
  description = "Name of the runner IAM role in the EKS cluster account."
  type        = string
}

variable "role_path" {
  description = "IAM path for the role."
  type        = string
  default     = "/"
}

variable "permissions_boundary_arn" {
  description = "Optional permissions boundary for the runner role."
  type        = string
  default     = null
}

variable "sessions_bucket_arn" {
  description = "Canonical sessions bucket ARN in the other account, with no key path."
  type        = string
  validation {
    condition     = can(regex("^arn:aws:s3:::[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.sessions_bucket_arn))
    error_message = "sessions_bucket_arn must be a bucket ARN (no key path)."
  }
}

variable "sessions_kms_key_arn" {
  description = "The bucket SSE-KMS key ARN, not an alias."
  type        = string
  validation {
    condition     = can(regex("^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/([0-9a-f-]{36}|mrk-[0-9a-f]{32})$", var.sessions_kms_key_arn))
    error_message = "sessions_kms_key_arn must be a KMS key ARN."
  }
}

variable "key_base" {
  description = "Bare canonical key root; session objects live under <key_base>/<org>/v1/."
  type        = string
  default     = "96bulls"
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.key_base))
    error_message = "key_base must be a plain path segment."
  }
}

variable "tags" {
  description = "Tags for the role and Pod Identity association."
  type        = map(string)
  default     = {}
}
