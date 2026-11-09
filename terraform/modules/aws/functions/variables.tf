variable "enabled" {
  description = "Enable queue consumption and schedules. Set false while provisioning the function, secret and database bootstrap; direct authorized invocations remain possible."
  type        = bool
  default     = true
}

variable "name" {
  description = "Prefix for the function, queues, rules, alarms and role (<name>-session-pipeline, <name>-session-events, ...)."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]{1,40}$", var.name))
    error_message = "name must be 1-40 letters, digits and hyphens."
  }
}

# --- Source bucket (bring your own; usually the object-storage module) ------

variable "bucket_name" {
  description = "The sessions (Locker) bucket that receives manifests: the same bucket as sessions-pipeline worker.locker.bucket."
  type        = string
}

variable "bucket_kms_key_arn" {
  description = "The bucket's customer managed KMS key, if any. The role may decrypt with it only through S3. With S3 Bucket Keys the encryption context is the bucket ARN, so the grant covers the bucket; object reads stay limited to key_prefix by s3:GetObject."
  type        = string
  default     = null
}

variable "key_prefix" {
  description = "Tenant key base the services write under (the services' TENANT_KEY_BASE, \"96bulls\")."
  type        = string
  default     = "96bulls"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.key_prefix))
    error_message = "key_prefix must be a non-empty run of letters, digits, dots, underscores and hyphens (no wildcards or slashes)."
  }
}

variable "layout_version" {
  description = "Object layout version the pipeline reads (<key_prefix>/<org>/<layout_version>/...)."
  type        = string
  default     = "v1"
}

variable "manage_bucket_notification" {
  description = "Create the bucket's S3 event notification (manifest.json puts and deletes to the queue). aws_s3_bucket_notification owns the bucket's whole notification configuration, so turn this off when anything else notifies from the bucket and add the queue configuration there (see the bucket_notification_queue_configuration output)."
  type        = bool
  default     = true
}

# --- Function package -------------------------------------------------------

variable "package" {
  description = <<-EOT
    The pipeline code, exactly one of: image_uri (a container image in ECR, package_type Image), s3_bucket + s3_key
    (a zip in S3), or filename (a local zip). The hosted stack builds src/session-pipeline/lambda.ts from
    AgentWorkforce/96BullSessions with export "handler".
  EOT
  type = object({
    image_uri         = optional(string)
    s3_bucket         = optional(string)
    s3_key            = optional(string)
    s3_object_version = optional(string)
    filename          = optional(string)
    source_code_hash  = optional(string)
  })

  validation {
    condition = length(compact([
      var.package.image_uri == null ? "" : "image",
      var.package.s3_bucket == null && var.package.s3_key == null ? "" : "s3",
      var.package.filename == null ? "" : "file",
    ])) == 1
    error_message = "Set exactly one of package.image_uri, package.s3_bucket + package.s3_key, or package.filename."
  }

  validation {
    condition     = (var.package.s3_bucket == null) == (var.package.s3_key == null)
    error_message = "package.s3_bucket and package.s3_key go together."
  }

  validation {
    condition     = var.package.image_uri == null || can(regex("@sha256:[0-9a-f]{64}$", var.package.image_uri))
    error_message = "package.image_uri must be pinned by digest (<repository>@sha256:<64 hex>)."
  }
}

variable "handler" {
  description = "Handler for zip packages (ignored for images)."
  type        = string
  default     = "index.handler"
}

variable "runtime" {
  description = "Runtime for zip packages (ignored for images). The hosted pipeline runs nodejs24.x."
  type        = string
  default     = "nodejs24.x"
}

variable "architecture" {
  description = "arm64 or x86_64 (must match the package)."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.architecture)
    error_message = "architecture must be arm64 or x86_64."
  }
}

variable "memory_size" {
  description = "Function memory in MB."
  type        = number
  default     = 3008
}

variable "timeout_seconds" {
  description = "Function timeout. The queue's visibility timeout is six times this (AWS guidance for SQS sources) plus maximum_batching_window_seconds."
  type        = number
  default     = 300

  validation {
    condition     = var.timeout_seconds >= 30 && var.timeout_seconds <= 900
    error_message = "timeout_seconds must be 30-900."
  }
}

variable "environment" {
  description = "Extra (non-secret) environment variables, merged over the module's defaults (see the README). Secrets go in the pipeline secret, never here."
  type        = map(string)
  default     = {}
}

variable "search_index_enabled" {
  description = "SEARCH_INDEX_ENABLED. Off: pointers only (Postgres pg_trgm search). On: the pipeline also writes the search index through its SearchIndexAdapter. ClickHouse credentials go in the pipeline secret; Amazon OpenSearch uses IAM instead: grant the execution role with additional_policy_statements and list it in the search module's additional_principal_arns."
  type        = bool
  default     = false
}

variable "max_concurrency" {
  description = "Maximum concurrent Lambda invocations from the queue (event source mapping scaling)."
  type        = number
  default     = 4

  validation {
    condition     = var.max_concurrency >= 2 && var.max_concurrency <= 1000
    error_message = "max_concurrency must be 2-1000."
  }
}

variable "reserved_concurrent_executions" {
  description = "Reserved concurrency for the function (-1: unreserved)."
  type        = number
  default     = -1
}

variable "batch_size" {
  description = "SQS messages per invocation."
  type        = number
  default     = 10
}

variable "maximum_batching_window_seconds" {
  description = "How long the mapping waits to fill a batch."
  type        = number
  default     = 20
}

variable "delivery_delay_seconds" {
  description = "Queue delivery delay, so a burst of manifest writes coalesces."
  type        = number
  default     = 30
}

variable "max_receive_count" {
  description = "Receives before a message moves to the DLQ."
  type        = number
  default     = 8
}

variable "queue_retention_seconds" {
  description = "session-events retention."
  type        = number
  default     = 345600
}

variable "dlq_retention_seconds" {
  description = "DLQ retention (14 days, the SQS maximum)."
  type        = number
  default     = 1209600
}

variable "queue_kms_key_arn" {
  description = "Customer managed KMS key for both queues. null uses SQS-managed SSE. A CMK's key policy must let s3.amazonaws.com use it (kms:GenerateDataKey, kms:Decrypt) for the bucket notification."
  type        = string
  default     = null
}

variable "reconcile_minutes" {
  description = "Reconcile schedule (lost notifications). The lookback (PIPELINE_RECONCILE_LOOKBACK_MINUTES) is twice this."
  type        = number
  default     = 30

  validation {
    condition     = var.reconcile_minutes >= 15 && var.reconcile_minutes <= 120
    error_message = "reconcile_minutes must be 15-120."
  }
}

variable "briefs_enabled" {
  description = "Session briefs: enables the brief schedule and sets SESSION_BRIEF_ENABLED. Model calls also need openai_api_key in the pipeline secret."
  type        = bool
  default     = false
}

variable "brief_schedule_expression" {
  description = "Brief tick schedule."
  type        = string
  default     = "rate(1 minute)"
}

# --- Secret -----------------------------------------------------------------

variable "create_secret" {
  description = "Create an empty Secrets Manager secret (a container; set its JSON value out of band: HoopDb URL and, with search on, the search backend credentials). Only the pipeline role may read it."
  type        = bool
  default     = true
}

variable "secret_arn" {
  description = "Existing pipeline secret ARN, when create_secret is false."
  type        = string
  default     = null
}

variable "secret_kms_key_arn" {
  description = "KMS key for the created secret. null uses aws/secretsmanager."
  type        = string
  default     = null
}

variable "secret_recovery_window_days" {
  description = "Recovery window when the secret is deleted."
  type        = number
  default     = 7
}

# --- Network, logs, role ----------------------------------------------------

variable "vpc_subnet_ids" {
  description = "Private subnets for the function ENIs. Needed to reach a private HoopDb (RDS/Aurora); the subnets need a route to S3, SQS, Secrets Manager and CloudWatch (NAT or VPC endpoints). Empty runs outside a VPC."
  type        = list(string)
  default     = []
}

variable "vpc_security_group_ids" {
  description = "Security groups for the function ENIs (egress to Postgres 5432 and HTTPS)."
  type        = list(string)
  default     = []
}

variable "code_signing_config_arn" {
  description = "Lambda code signing configuration for zip packages (null: no signature check)."
  type        = string
  default     = null
}

variable "lambda_kms_key_arn" {
  description = "KMS key for the function's environment variables. null uses the AWS managed key."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "Function log group retention."
  type        = number
  default     = 30
}

variable "log_kms_key_arn" {
  description = "KMS key for the function log group (its key policy must allow CloudWatch Logs)."
  type        = string
  default     = null
}

variable "tracing_mode" {
  description = "X-Ray tracing (PassThrough or Active)."
  type        = string
  default     = "PassThrough"
}

variable "existing_execution_role_arn" {
  description = "Existing same-account Lambda execution role. Null creates the role and inline policy; otherwise this module authors neither. The operator must verify trust, permissions, boundary and guards separately."
  type        = string
  default     = null

  validation {
    condition     = var.existing_execution_role_arn == null ? true : can(regex("^arn:[a-z0-9-]+:iam::[0-9]{12}:role/([A-Za-z0-9_+=,.@-]+/)*[A-Za-z0-9_+=,.@-]+$", var.existing_execution_role_arn))
    error_message = "existing_execution_role_arn must be an exact IAM role ARN with a conventional role path, without wildcards."
  }
}

variable "role_path" {
  description = "IAM path for the managed execution role; unused with existing_execution_role_arn."
  type        = string
  default     = "/"
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for the managed execution role; unused with existing_execution_role_arn."
  type        = string
  default     = null
}

variable "additional_policy_statements" {
  description = "Extra statements in execution_role_policy_json, attached only for a managed role (for example es:ESHttpPost/Put on an OpenSearch domain once the services have that backend)."
  type        = any
  default     = []
}

variable "alarm_actions" {
  description = "SNS topic ARNs for the DLQ, backlog-age and error alarms. Empty creates the alarms with actions disabled."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
