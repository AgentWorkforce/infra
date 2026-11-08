variable "account_id" {
  description = "Exact target AWS account. The provider refuses any other account. Use the allocated account from Pippen in sandbox mode."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the exact 12-digit AWS account ID."
  }
}

variable "region" {
  description = "AWS region for this environment."
  type        = string
  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.region))
    error_message = "region must be an explicit AWS region."
  }
}

variable "environment" {
  description = "Unique environment slug, e.g. dev, staging, production or team-a. It scopes resource names, tags, the namespace and the verification prefix."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9]*(-[a-z0-9]+)*$", var.environment)) && length(var.environment) <= 16
    error_message = "environment must be a lowercase slug of at most 16 characters."
  }
}

variable "environment_class" {
  description = "Sizing/protection tier; environment names remain independent of this classification."
  type        = string
  default     = "development"
  validation {
    condition     = contains(["development", "staging", "production"], var.environment_class)
    error_message = "environment_class must be development, staging or production."
  }
}

variable "name_prefix" {
  description = "Product prefix. prefix-environment must be at most 21 characters. For Pippen use e.g. pippen-sbx-ar."
  type        = string
  default     = "agent-relay"
  validation {
    condition     = can(regex("^[a-z][a-z0-9]*(-[a-z0-9]+)*$", var.name_prefix))
    error_message = "name_prefix must be a lowercase slug."
  }
}

variable "private_subnet_ids" {
  description = "Existing private database subnets in at least two AZs. The foundation stack owns VPC/subnets/routes."
  type        = list(string)
  validation {
    condition     = length(distinct(var.private_subnet_ids)) >= 2
    error_message = "Supply at least two distinct private database subnet IDs."
  }
}

variable "database_security_group_ids" {
  description = "Database security groups allowing PostgreSQL only from the approved application/proof runner."
  type        = list(string)
}

variable "search_subnet_ids" {
  description = "Existing private OpenSearch subnets, one per AZ. Production requires three."
  type        = list(string)
  validation {
    condition     = length(var.search_subnet_ids) >= 1 && length(var.search_subnet_ids) <= 3 && length(distinct(var.search_subnet_ids)) == length(var.search_subnet_ids)
    error_message = "Supply one to three distinct OpenSearch subnet IDs, one per AZ."
  }
}

variable "search_security_group_ids" {
  description = "Search security groups allowing HTTPS only from approved application/proof runner identities."
  type        = list(string)
}

variable "search_master_user_arn" {
  description = "Existing environment-specific IAM administrator for OpenSearch role bootstrap. Never a runtime role."
  type        = string
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", var.search_master_user_arn))
    error_message = "search_master_user_arn must be an explicit AWS IAM administrator role ARN."
  }
}

variable "eks_cluster_name" {
  description = "Existing EKS cluster for Pod Identity; the foundation root owns the cluster."
  type        = string
}

variable "namespace" {
  description = "Environment namespace; null uses agent-relay-<environment>."
  type        = string
  default     = null
}

variable "release_name" {
  description = "Helm release name used in generated ServiceAccount names."
  type        = string
  default     = "agent-relay"
}

variable "kms_key_arn" {
  description = "Existing customer-managed key; null uses AWS-managed encryption keys."
  type        = string
  default     = null
}

variable "postgres_engine_mode" {
  description = "rds or aurora. Aurora requires an explicit full engine version and separate live validation."
  type        = string
  default     = "rds"
  validation {
    condition     = contains(["rds", "aurora"], var.postgres_engine_mode)
    error_message = "postgres_engine_mode must be rds or aurora."
  }
}

variable "aurora_engine_version" {
  description = "Explicit region-supported Aurora PostgreSQL 17 minor version when Aurora is selected."
  type        = string
  default     = null
}

variable "database_instance_class" {
  description = "Override the environment tier's instance class. Aurora needs an Aurora-supported class."
  type        = string
  default     = null
}

variable "search_instance_type" {
  description = "Override the environment tier's OpenSearch data node type."
  type        = string
  default     = null
}

variable "search_engine_version" {
  description = "Region-supported OpenSearch engine version."
  type        = string
  default     = "OpenSearch_2.19"
}

variable "deletion_protection" {
  description = "Database API deletion protection. Production refuses false. Final snapshots and S3 versioning remain enabled."
  type        = bool
  default     = true
}

variable "pipeline_runtime" {
  description = "workers or lambda. Lambda requires its own compatible immutable handler artifact; application deployment must disable overlapping worker stages."
  type        = string
  default     = "workers"
  validation {
    condition     = contains(["workers", "lambda"], var.pipeline_runtime)
    error_message = "pipeline_runtime must be workers or lambda."
  }
}

variable "activate_lambda" {
  description = "Reserved activation input. This shared-database profile currently refuses true until schema/bootstrap/runtime support is qualified by a reviewed implementation change; provision inactive infrastructure meanwhile."
  type        = bool
  default     = false
}

variable "lambda_package" {
  description = "Compatible pipeline artifact when pipeline_runtime=lambda: exactly one immutable image, versioned S3 zip, or local zip with hash. No credential values."
  type = object({
    image_uri         = optional(string)
    s3_bucket         = optional(string)
    s3_key            = optional(string)
    s3_object_version = optional(string)
    filename          = optional(string)
    source_code_hash  = optional(string)
  })
  default = null
}

variable "function_security_group_ids" {
  description = "Lambda security groups with private database/search access and egress to the required AWS services."
  type        = list(string)
  default     = []
}

variable "enable_relayfile" {
  description = "Include Relayfile in the full-suite application contract; its actor identities/Secrets must be configured by the application layer."
  type        = bool
  default     = false
}

variable "pippen" {
  description = "Pippen lease identity from sandbox status/exec. null for customer accounts. No credentials belong here."
  type = object({
    agent      = string
    session_id = string
  })
  default = null
}

variable "tags" {
  description = "Additional resource tags. Environment identity and Pippen conventions cannot be overridden."
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for k in keys(var.tags) : !startswith(k, "pippen:") && !contains(["Environment", "EnvironmentClass", "ManagedBy"], k)])
    error_message = "Environment, EnvironmentClass, ManagedBy and pippen:* tags are managed by this root."
  }
}

variable "existing_runtime_roles" {
  description = "Operator-owned runtime identities. Null manages search/pipeline roles here. Otherwise supply both search roles and, only in Lambda mode, the pipeline role. Trust, policies, guards and EKS associations must already be verified outside this state."
  type = object({
    indexer_role_arn  = string
    reader_role_arn   = string
    pipeline_role_arn = optional(string)
  })
  default = null

  validation {
    condition = var.existing_runtime_roles == null ? true : alltrue([
      for arn in values(var.existing_runtime_roles) : arn == null ? true : can(regex("^arn:aws:iam::[0-9]{12}:role/([A-Za-z0-9_+=,.@-]+/)*[A-Za-z0-9_+=,.@-]+$", arn))
    ]) && try(length(var.existing_runtime_roles.indexer_role_arn) > 0 && length(var.existing_runtime_roles.reader_role_arn) > 0, false)
    error_message = "Supply exact IAM role ARNs for both search identities (and optionally the pipeline), without empty values or wildcards."
  }
}

variable "lambda_runtime_bindings" {
  description = "Non-secret configuration for an independently verified private OpenSearch/Lambda artifact with its pinned public PostgreSQL CA at assets/postgres-ca.pem. Writer and reader must share these bindings. This is not artifact, bootstrap, FGAC or caller-transition proof."
  type = object({
    search_index       = string
    state_backend_id   = string
    complete_since     = string
    postgres_ca_sha256 = string
    projection_schema  = optional(string, "search_index")
  })
  default = null

  validation {
    condition = var.lambda_runtime_bindings == null ? true : (
      can(regex("^[a-z0-9][a-z0-9_-]{0,200}$", var.lambda_runtime_bindings.search_index)) &&
      can(regex("^[a-zA-Z0-9._-]{1,114}$", var.lambda_runtime_bindings.state_backend_id)) &&
      can(regex("^[a-z_][a-z0-9_]{0,62}$", var.lambda_runtime_bindings.projection_schema)) &&
      can(regex("^[0-9a-f]{64}$", var.lambda_runtime_bindings.postgres_ca_sha256)) &&
      (var.lambda_runtime_bindings.complete_since == "epoch" ? true : try(timecmp(var.lambda_runtime_bindings.complete_since, "1970-01-01T00:00:00Z") >= 0, false))
    )
    error_message = "Supply a lowercase OpenSearch index of at most 201 characters without dots, backend ID of at most 114 identifier characters (the artifact adds .js-literal-v2), PostgreSQL schema identifier, lowercase SHA256, and epoch or a nonnegative RFC3339 completeness timestamp."
  }
}

variable "application_database_name" {
  description = "Single shared application database for control, HoopDb, Relaycast and other service schemas. Default preserves the existing RDS initial database identity; do not change it on an existing instance without reviewing replacement/data migration."
  type        = string
  default     = "relaycontrol"
  nullable    = false
  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.application_database_name)) && !contains(["postgres", "template0", "template1", "rdsadmin"], var.application_database_name)
    error_message = "application_database_name must be a lowercase application identifier, not a PostgreSQL maintenance database."
  }
}
