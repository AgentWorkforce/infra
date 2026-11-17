variable "account_id" {
  description = "The EKS cluster's AWS account (the bucket and both roles live here). The provider refuses any other."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account id."
  }
}

variable "region" {
  description = "The EKS cluster's region: the ledger bucket is created here, next to the ingest edge."
  type        = string
}

variable "bucket_name" {
  description = "The ledger bucket (ingestEdge.ledgerBucket.bucket). Must differ from the Locker bucket."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name)) && !strcontains(var.bucket_name, "..")
    error_message = "bucket_name must be an S3 bucket name."
  }
}

variable "key_root" {
  description = "INGEST_KEY_ROOT of the ingest edge."
  type        = string
  default     = "96bulls"
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,62}$", var.key_root))
    error_message = "key_root must be a plain path segment."
  }
}

variable "consumer_role_name" {
  description = "The ingest edge's existing Pod Identity role (its ServiceAccount is ingestEdge.serviceAccountName). Gets read/write on the ledger bucket's key root; nothing else about the role changes."
  type        = string
}

variable "rearm_sweeper_role_name" {
  description = "The re-arm sweeper's existing Pod Identity role, or null when the sweeper runs elsewhere. Gets read on the ledger objects and create on the completion records."
  type        = string
  default     = null
}

variable "sse_kms_key_arn" {
  description = "null (default): SSE-S3 (AES256), no KMS call per request. A KMS key ARN: SSE-KMS with S3 Bucket Keys, and both roles get the key through S3 only."
  type        = string
  default     = null
  validation {
    condition     = var.sse_kms_key_arn == null || can(regex("^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/([0-9a-f-]{36}|mrk-[0-9a-f]{32})$", var.sse_kms_key_arn))
    error_message = "sse_kms_key_arn must be null or a KMS key ARN."
  }
}

variable "noncurrent_version_days" {
  description = "Days a replaced or deleted ledger object version is kept (versioning is on, for recovery)."
  type        = number
  default     = 30
  validation {
    condition     = var.noncurrent_version_days >= 1 && var.noncurrent_version_days <= 3650
    error_message = "noncurrent_version_days must be 1..3650."
  }
}

variable "tags" {
  description = "Tags for the bucket."
  type        = map(string)
  default     = {}
}

variable "cross_account_ledger_reader_role_arns" {
  description = "IAM role ARNs in other accounts that may list the ledger prefixes and read the ledger objects and the ledger-home marker (bucket policy). Each role's own identity policy, in its account, must grant the same actions on this bucket. Not supported with sse_kms_key_arn."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for a in var.cross_account_ledger_reader_role_arns : can(regex("^arn:aws:iam::[0-9]{12}:role/.+", a))])
    error_message = "cross_account_ledger_reader_role_arns must be IAM role ARNs (arn:aws:iam::<12 digits>:role/<name>)."
  }
}

variable "cross_account_ledger_writer_role_arns" {
  description = "IAM role ARNs in other accounts that get the reader access plus PutObject on the ledger objects (bucket policy; no delete, no version actions). Each role's own identity policy, in its account, must grant the same actions on this bucket. Not supported with sse_kms_key_arn."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for a in var.cross_account_ledger_writer_role_arns : can(regex("^arn:aws:iam::[0-9]{12}:role/.+", a))])
    error_message = "cross_account_ledger_writer_role_arns must be IAM role ARNs (arn:aws:iam::<12 digits>:role/<name>)."
  }
}
