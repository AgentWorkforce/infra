# Every value here is hosted-specific and comes from the private tfvars (SSM SecureString read by CI).
# Nothing hosted is committed: the defaults are the session pipeline's own constants, not hosted values.

variable "account_id" {
  description = "The hosted sessions account. The provider refuses any other."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be 12 digits."
  }
}

variable "region" {
  description = "The hosted sessions region."
  type        = string
}

variable "name_prefix" {
  description = "Prefix every pipeline resource name carries (the old stack's 96bulls-<stage>)."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{2,40}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 4-42 lowercase letters, digits or hyphens."
  }
}

variable "tags" {
  description = "Tags on the pipeline resources, exactly as live (the old stack's stack/component/repo tags)."
  type        = map(string)
  default     = {}
}

# --- The existing function and its role (imported as-is) ---

variable "function_name" {
  description = "The existing session-pipeline Lambda. Its code and environment stay with the pipeline's deploy until it publishes a pinned artifact (phase 2); this root wires everything around it."
  type        = string
}

variable "function_timeout_seconds" {
  description = "The function's live timeout. The queue's visibility timeout must be at least this."
  type        = number
  default     = 300
}

variable "role" {
  description = "The function's execution role, imported into state as-is (Khaliq, 2026-11-27). Every field must equal live, or the plan shows a diff and nothing is applied."
  type = object({
    name                 = string
    path                 = optional(string, "/")
    description          = optional(string, "")
    assume_role_policy   = string # JSON, as live
    max_session_duration = optional(number, 3600)
    permissions_boundary = optional(string)
    inline_policies      = optional(map(string), {}) # name => JSON policy document, as live
    managed_policy_arns  = optional(set(string), [])
    tags                 = optional(map(string), {})
  })
}

variable "log_group" {
  description = "The function's log group, if it exists and should be managed. null leaves it alone."
  type = object({
    retention_in_days = number
    tags              = optional(map(string), {})
  })
  default = null
}

# --- Transcripts bucket and key ---

variable "bucket_name" {
  description = "The transcripts bucket."
  type        = string
}

variable "key_prefix" {
  description = "Tenant key base under which manifests are written (TENANT_KEY_BASE)."
  type        = string
  default     = "96bulls"
}

variable "layout_version" {
  description = "Object layout version the pipeline reads (LAYOUT_VERSION)."
  type        = string
  default     = "v1"
}

variable "bucket_policy_other_statements" {
  description = "JSON array of every transcripts-bucket policy statement this root does not render (other stacks' grants, TLS and encryption denies, the ingest-edge cross-account grants), exactly as live. Private: never committed."
  type        = string
  validation {
    condition     = can(regex("^\\s*\\[", var.bucket_policy_other_statements)) && can(length(jsondecode(var.bucket_policy_other_statements)))
    error_message = "bucket_policy_other_statements must be a JSON array."
  }
}

variable "bucket_policy_id" {
  description = "The bucket policy's Id field, if live has one."
  type        = string
  default     = null
}

variable "kms_policy_id" {
  description = "The key policy's Id field, if live has one."
  type        = string
  default     = null
}

variable "kms_key_id" {
  description = "The transcripts KMS key (id or ARN)."
  type        = string
}

variable "kms_policy_other_statements" {
  description = "JSON array of every transcripts-key policy statement this root does not render (key administration, other stacks, the ingest-edge cross-account grants), exactly as live. Private: never committed."
  type        = string
  validation {
    condition     = can(regex("^\\s*\\[", var.kms_policy_other_statements)) && can(length(jsondecode(var.kms_policy_other_statements)))
    error_message = "kms_policy_other_statements must be a JSON array."
  }
}

variable "analysis_results" {
  description = "Analysis jobs (lane F1): the role may write, version-list and erase analysis results, and get data keys for them."
  type        = bool
  default     = false
}

variable "other_notifications" {
  description = "Every other live notification on the transcripts bucket, verbatim (for example the upload-inbox queue). aws_s3_bucket_notification owns the bucket's WHOLE notification configuration, so anything live that is missing here would be removed (the gate refuses that plan)."
  type = object({
    queues = optional(list(object({
      id            = string
      queue_arn     = string
      events        = list(string)
      filter_prefix = optional(string)
      filter_suffix = optional(string)
    })), [])
    lambda_functions = optional(list(object({
      id                  = string
      lambda_function_arn = string
      events              = list(string)
      filter_prefix       = optional(string)
      filter_suffix       = optional(string)
    })), [])
    topics = optional(list(object({
      id            = string
      topic_arn     = string
      events        = list(string)
      filter_prefix = optional(string)
      filter_suffix = optional(string)
    })), [])
    eventbridge = optional(bool, false)
  })
  default = {}
}

# --- Queues and mapping ---

variable "visibility_timeout_seconds" {
  description = "session-events visibility timeout (old stack: 6 x 300 = 1800)."
  type        = number
  default     = 1800
}

variable "max_concurrency" {
  description = "Event source mapping MaximumConcurrency. Self-host's module default is 4; the hosted value is set in the private tfvars, equal to live."
  type        = number
  default     = 4
  validation {
    condition     = var.max_concurrency >= 2 && var.max_concurrency <= 1000
    error_message = "max_concurrency must be 2-1000."
  }
}

# --- Schedules ---

variable "reconcile_minutes" {
  description = "Reconcile schedule period."
  type        = number
  default     = 30
}

variable "briefs_enabled" {
  description = "The brief schedule's state. Enabling briefs in production needs its own go from Khaliq."
  type        = bool
  default     = false
}

variable "optional_schedules" {
  description = "Optional schedule groups the old stack declared per stage (analysisCache, semanticCopy, analysisJob, bufferedSearchFeed, bufferedErasureDelete): key => enabled. Absent keys plan nothing."
  type        = map(bool)
  default     = {}
  validation {
    condition     = alltrue([for k in keys(var.optional_schedules) : contains(["analysisCache", "semanticCopy", "analysisJob", "bufferedSearchFeed", "bufferedErasureDelete"], k)])
    error_message = "optional_schedules keys: analysisCache, semanticCopy, analysisJob, bufferedSearchFeed, bufferedErasureDelete."
  }
}

# --- Secret ---

variable "secret_name" {
  description = "The pipeline secret container's name. Its value is set out of band and never managed here."
  type        = string
}

variable "secret_description" {
  description = "The secret's description, as live."
  type        = string
  default     = "96bulls session pipeline: Supabase HoopDb URL and ClickHouse ingest credentials (JSON)"
}

# --- Import ids (live identifiers; private) ---

variable "import_ids" {
  description = "Live identifiers for the first plan's imports. Once in state, the import blocks are no-ops."
  type = object({
    event_source_mapping_uuid = string
    secret_arn                = string
    # permission key (reconcile, reconcile_continue, brief, or an optional schedule's) => live statement id
    permission_statement_ids = map(string)
  })
}

variable "import_existing" {
  description = "Plan the first-run imports. true for every real plan; false only for offline rendering tests (mock providers cannot import)."
  type        = bool
  default     = true
}
