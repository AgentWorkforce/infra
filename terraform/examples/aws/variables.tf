variable "region" {
  description = "AWS region."
  type        = string
}

variable "name" {
  description = "Name prefix for every resource (lowercase; at most 21 characters, so <name>-search fits OpenSearch's 28)."
  type        = string
  default     = "agent-relay"

  validation {
    condition     = length(var.name) <= 21 && can(regex("^[a-z]([a-z0-9]|-[a-z0-9])*$", var.name))
    error_message = "name must be 1-21 lowercase letters, digits and single hyphens, starting with a letter and not ending with a hyphen (RDS identifier rules)."
  }
}

variable "tags" {
  description = "Tags for every resource (provider default_tags)."
  type        = map(string)
  default     = {}
}

variable "kms_key_arn" {
  description = "Customer managed KMS key for Postgres, the sessions bucket and OpenSearch (null: AWS managed keys). The optional pipeline keeps its module defaults (SQS-managed SSE, AWS managed keys); pass the functions module's *_kms_key_arn inputs to change that."
  type        = string
  default     = null
}

# --- Bring your own network ---------------------------------------------------

variable "private_subnet_ids" {
  description = "Existing private subnets (two or more AZs) for the database and the function."
  type        = list(string)
}

variable "database_security_group_ids" {
  description = "Existing security groups for Postgres (5432 from the EKS nodes/pods)."
  type        = list(string)
}

variable "search_subnet_ids" {
  description = "Existing private subnets for OpenSearch (one per AZ, 2 or 3)."
  type        = list(string)
  default     = []
}

variable "search_security_group_ids" {
  description = "Existing security groups for OpenSearch. Allow TCP 443 from the indexer and read API pods and, with enable_functions, from function_security_group_ids."
  type        = list(string)
  default     = []
}

variable "function_security_group_ids" {
  description = "Existing security groups for the pipeline function ENIs (egress to Postgres and, with enable_search, to the OpenSearch security groups on 443)."
  type        = list(string)
  default     = []
}

# --- Cluster and release ------------------------------------------------------

variable "eks_cluster_name" {
  description = "Existing EKS cluster that runs agent-relay (Pod Identity associations)."
  type        = string
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

variable "postgres_engine_mode" {
  description = "rds or aurora."
  type        = string
  default     = "rds"
}

variable "aurora_engine_version" {
  description = "Aurora PostgreSQL version when postgres_engine_mode is aurora."
  type        = string
  default     = "17.9"
}

variable "sessions_bucket_name" {
  description = "Globally unique S3 bucket name for session objects."
  type        = string
}

variable "enable_search" {
  description = "Create the optional OpenSearch domain."
  type        = bool
  default     = false
}

variable "indexer_service_account" {
  description = "ServiceAccount (in namespace) of the search indexer (the hoopdb-indexer worker), bound to the write role. Must differ from reader_service_account and the sessions worker/alleyoop ServiceAccounts. null creates the role without an association."
  type        = string
  default     = null
}

variable "reader_service_account" {
  description = "ServiceAccount (in namespace) of the session read API, bound to the read-only role. null creates the role without an association."
  type        = string
  default     = null
}

variable "search_master_user_arn" {
  description = "IAM role that administers OpenSearch fine-grained access control."
  type        = string
  default     = null
}

variable "enable_functions" {
  description = "Create the optional event-driven pipeline (Lambda)."
  type        = bool
  default     = false
}

variable "pipeline_package" {
  description = "Pipeline Lambda package (see modules/aws/functions)."
  type = object({
    image_uri         = optional(string)
    s3_bucket         = optional(string)
    s3_key            = optional(string)
    s3_object_version = optional(string)
    filename          = optional(string)
    source_code_hash  = optional(string)
  })
  # Empty: with enable_functions the module refuses it until one source is set.
  default = {}
}

variable "alarm_actions" {
  description = "SNS topics for the pipeline alarms."
  type        = list(string)
  default     = []
}

variable "application_database_name" {
  description = "Single shared application database for control, HoopDb, Relaycast and other service schemas. Default preserves the existing RDS initial database identity; do not change it on an existing instance without reviewing replacement/data migration."
  type        = string
  default     = "relaycontrol"
  nullable    = false
  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.application_database_name)) && !contains(["postgres", "template0", "template1"], var.application_database_name)
    error_message = "application_database_name must be a lowercase application identifier, not a PostgreSQL maintenance database."
  }
}
