variable "project_id" {
  description = "Project for the function, topics, subscriptions and jobs."
  type        = string
}

variable "region" {
  description = "Region for the function (and, unless scheduler_region is set, the Cloud Scheduler jobs)."
  type        = string
}

variable "name" {
  description = "Prefix for every resource (<name>-session-pipeline, <name>-session-events, ...)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,28}$", var.name))
    error_message = "name must be 1-29 lowercase letters, digits and hyphens, starting with a letter."
  }
}

# --- Source bucket ----------------------------------------------------------

variable "bucket_name" {
  description = "The sessions (Locker) bucket: the same bucket as sessions-pipeline worker.locker.bucket."
  type        = string
}

variable "key_prefix" {
  description = "Tenant key base the services write under (TENANT_KEY_BASE, \"96bulls\"). GCS notifications filter on this prefix; they cannot filter on the manifest.json suffix, so the handler ignores other objects."
  type        = string
  default     = "96bulls"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.key_prefix))
    error_message = "key_prefix must be a non-empty run of letters, digits, dots, underscores and hyphens (no wildcards or slashes)."
  }
}

# --- Function ---------------------------------------------------------------

variable "source_archive" {
  description = "Function source: a zip in GCS (bucket, object, optional generation). Cloud Build builds it with the runtime's buildpack."
  type = object({
    bucket     = string
    object     = string
    generation = optional(number)
  })
}

variable "runtime" {
  description = "Cloud Run functions runtime."
  type        = string
  default     = "nodejs22"
}

variable "entry_point" {
  description = "Exported HTTP handler. It receives Pub/Sub push envelopes ({message: {data, attributes}, subscription}) and Cloud Scheduler bodies ({\"reconcile\": true} or {\"brief\": true})."
  type        = string
  default     = "sessionPipeline"
}

variable "available_memory" {
  description = "Memory per instance."
  type        = string
  default     = "2Gi"
}

variable "available_cpu" {
  description = "vCPU per instance."
  type        = string
  default     = "1"
}

variable "timeout_seconds" {
  description = "Request timeout. Kept at or below the subscription's ack deadline (600 s)."
  type        = number
  default     = 300

  validation {
    condition     = var.timeout_seconds >= 30 && var.timeout_seconds <= 600
    error_message = "timeout_seconds must be 30-600 (the push ack deadline caps it)."
  }
}

variable "max_instance_count" {
  description = "Concurrency cap (the AWS module's max_concurrency)."
  type        = number
  default     = 4
}

variable "max_instance_request_concurrency" {
  description = "Concurrent requests per instance."
  type        = number
  default     = 1
}

variable "environment" {
  description = "Extra non-secret environment variables, merged over the module's defaults."
  type        = map(string)
  default     = {}
}

variable "search_index_enabled" {
  description = "SEARCH_INDEX_ENABLED (off: pointers only, Postgres pg_trgm search)."
  type        = bool
  default     = false
}

variable "vpc_connector" {
  description = "Existing Serverless VPC Access connector (projects/<p>/locations/<r>/connectors/<c>) for reaching a private Cloud SQL. null: no VPC egress."
  type        = string
  default     = null
}

variable "vpc_connector_egress_settings" {
  description = "PRIVATE_RANGES_ONLY or ALL_TRAFFIC."
  type        = string
  default     = "PRIVATE_RANGES_ONLY"
}

variable "kms_key_name" {
  description = "CMEK for the function (and its image). Needs docker_repository encrypted with the same key, and the Cloud Functions, Artifact Registry and Cloud Run service agents granted on the key."
  type        = string
  default     = null
}

variable "docker_repository" {
  description = "Artifact Registry repository for the built image (projects/<p>/locations/<r>/repositories/<repo>). null uses gcf-artifacts."
  type        = string
  default     = null
}

variable "build_service_account" {
  description = "Service account Cloud Build uses for the function build (projects/<p>/serviceAccounts/<email>). null uses the project default."
  type        = string
  default     = null
}

# --- Messaging --------------------------------------------------------------

variable "topic_kms_key_name" {
  description = "CMEK for both topics (the Pub/Sub service agent needs encrypter/decrypter on it)."
  type        = string
  default     = null
}

variable "ack_deadline_seconds" {
  description = "Push subscription ack deadline (10-600). Must be at least timeout_seconds."
  type        = number
  default     = 600

  validation {
    condition     = var.ack_deadline_seconds >= 10 && var.ack_deadline_seconds <= 600
    error_message = "ack_deadline_seconds must be 10-600."
  }
}

variable "max_delivery_attempts" {
  description = "Deliveries before a message moves to the dead-letter topic (5-100)."
  type        = number
  default     = 8
}

variable "dead_letter_retention" {
  description = "Retention of the dead-letter topic and of its hold subscription (up to 31 days for both)."
  type        = string
  default     = "1209600s"

  validation {
    condition     = can(regex("^[0-9]+s$", var.dead_letter_retention)) && try(tonumber(trimsuffix(var.dead_letter_retention, "s")) >= 600 && tonumber(trimsuffix(var.dead_letter_retention, "s")) <= 2678400, false)
    error_message = "dead_letter_retention must be <seconds>s between 600s and 2678400s (31 days)."
  }
}

variable "reconcile_minutes" {
  description = "Reconcile schedule (15, 20, 30, 60 or 120). The lookback is twice this."
  type        = number
  default     = 30

  validation {
    condition     = contains([15, 20, 30, 60, 120], var.reconcile_minutes)
    error_message = "reconcile_minutes must be 15, 20, 30, 60 or 120 (cron-expressible)."
  }
}

variable "briefs_enabled" {
  description = "Session briefs: unpauses the brief job and sets SESSION_BRIEF_ENABLED."
  type        = bool
  default     = false
}

variable "brief_schedule" {
  description = "Brief tick cron."
  type        = string
  default     = "* * * * *"
}

variable "scheduler_region" {
  description = "Cloud Scheduler region (null: region)."
  type        = string
  default     = null
}

variable "time_zone" {
  description = "Cloud Scheduler time zone."
  type        = string
  default     = "Etc/UTC"
}

# --- Secret, alerts, labels -------------------------------------------------

variable "create_secret" {
  description = "Create an empty Secret Manager secret (a container; add its JSON value out of band). Its resource name is passed as SESSION_PIPELINE_SECRET_ID."
  type        = bool
  default     = true
}

variable "secret_id" {
  description = "Existing secret resource name (projects/<p>/secrets/<id>) when create_secret is false."
  type        = string
  default     = null
}

variable "secret_kms_key_name" {
  description = "CMEK for the created secret (automatic replication)."
  type        = string
  default     = null
}

variable "create_alerts" {
  description = "Create Cloud Monitoring alert policies (dead letters, backlog age, function errors)."
  type        = bool
  default     = true
}

variable "notification_channels" {
  description = "Cloud Monitoring notification channel IDs for the alerts."
  type        = list(string)
  default     = []
}

variable "labels" {
  description = "Labels applied where supported."
  type        = map(string)
  default     = {}
}
