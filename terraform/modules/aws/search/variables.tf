variable "disposable" {
  description = "Explicitly create a new disposable domain with Terraform destruction enabled. Defaults to protected. Stored-mode enrollment blocks later ordinary flips; unmarked existing states require independently reviewed unchanged-mode enrollment. Raw Terraform cannot prove first-enrollment history."
  type        = bool
  default     = false
  nullable    = false
}

variable "domain_name" {
  description = "OpenSearch domain name (3-28 characters, lowercase letter first)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,27}$", var.domain_name))
    error_message = "domain_name must be 3-28 lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "engine_version" {
  description = "Engine version (OpenSearch_X.Y)."
  type        = string
  default     = "OpenSearch_2.19"

  validation {
    condition     = can(regex("^OpenSearch_[0-9]+\\.[0-9]+$", var.engine_version))
    error_message = "engine_version must look like OpenSearch_2.19 (Elasticsearch_* engines are not supported)."
  }
}

variable "subnet_ids" {
  description = "Private subnets for the VPC domain, one per Availability Zone (2 or 3). The zone awareness count follows their number."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 1 && length(var.subnet_ids) <= 3
    error_message = "Pass 1-3 subnet_ids (one per AZ); 3 is recommended for production."
  }
}

variable "security_group_ids" {
  description = "Existing security groups for the domain ENIs. Allow TCP 443 only from the indexer and read API pods (or their nodes)."
  type        = list(string)

  validation {
    condition     = length(var.security_group_ids) > 0
    error_message = "Pass at least one security group; the module creates none."
  }
}

variable "kms_key_arn" {
  description = "Customer managed KMS key for encryption at rest. null uses the AWS managed aws/es key."
  type        = string
  default     = null
}

variable "instance_type" {
  description = "Data node type. Memory-optimized (r7g) fits a full-text index of transcript events; use or1/or2 (OpenSearch Optimized) for heavy ingest."
  type        = string
  default     = "r7g.large.search"
}

variable "instance_count" {
  description = "Data nodes, a multiple of the subnet (AZ) count. null picks the smallest multiple that is at least 3 (3 for one or three AZs, 4 for two)."
  type        = number
  default     = null
}

variable "dedicated_master_enabled" {
  description = "Dedicated cluster manager nodes (recommended for production)."
  type        = bool
  default     = true
}

variable "dedicated_master_type" {
  description = "Cluster manager node type."
  type        = string
  default     = "m7g.large.search"
}

variable "dedicated_master_count" {
  description = "Cluster manager nodes (3 or 5)."
  type        = number
  default     = 3

  validation {
    condition     = contains([3, 5], var.dedicated_master_count)
    error_message = "dedicated_master_count must be 3 or 5."
  }
}

variable "multi_az_with_standby_enabled" {
  description = "Multi-AZ with Standby (needs 3 AZs, dedicated masters and a multiple of 3 data nodes)."
  type        = bool
  default     = false
}

variable "ebs_volume_size" {
  description = "gp3 volume per data node in GiB. Size for the transcript text plus replicas plus ~25% headroom."
  type        = number
  default     = 200
}

variable "ebs_volume_type" {
  description = "EBS volume type."
  type        = string
  default     = "gp3"
}

variable "ebs_iops" {
  description = "Provisioned IOPS for gp3 (null uses the baseline)."
  type        = number
  default     = null
}

variable "ebs_throughput" {
  description = "Provisioned throughput (MiB/s) for gp3 (null uses the baseline)."
  type        = number
  default     = null
}

variable "tls_security_policy" {
  description = "Minimum TLS policy for the HTTPS endpoint."
  type        = string
  default     = "Policy-Min-TLS-1-2-PFS-2023-10"
}

variable "master_user_arn" {
  description = "IAM principal ARN that becomes the fine-grained access control master user (an admin role, not a workload role). It maps the indexer and reader roles to OpenSearch roles; see the README."
  type        = string

  validation {
    condition     = var.master_user_arn != null && can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:", var.master_user_arn))
    error_message = "master_user_arn must be an IAM role or user ARN."
  }
}

variable "workload_roles" {
  description = <<-EOT
    The two workload roles the module creates, trusted by EKS Pod Identity (and IRSA when oidc_provider_arn is set):
    indexer (the sessions-pipeline search stage: writes transcript events) and reader (the session read API: searches).
    Set create = false to skip them: attach indexer_policy_json / reader_policy_json to existing roles and list them in
    additional_principal_arns. EKS Pod Identity allows one association per ServiceAccount, so a ServiceAccount that
    already has a role (the sessions worker has the bucket role) needs a separate ServiceAccount for search.
  EOT
  type = object({
    create                   = optional(bool, true)
    name_prefix              = optional(string)
    path                     = optional(string, "/")
    permissions_boundary_arn = optional(string)
    oidc_provider_arn        = optional(string)
    indexer_service_accounts = optional(list(object({
      cluster_name    = optional(string)
      namespace       = string
      service_account = string
    })), [])
    reader_service_accounts = optional(list(object({
      cluster_name    = optional(string)
      namespace       = string
      service_account = string
    })), [])
  })
  default = {}
}

variable "additional_principal_arns" {
  description = "Extra IAM principals allowed to send HTTP requests to the domain (still subject to fine-grained access control)."
  type        = list(string)
  default     = []
}

variable "automated_snapshot_start_hour" {
  description = "Hour (UTC) of the daily automated snapshot. Ignored by OpenSearch 5.3+ domains, which take hourly snapshots."
  type        = number
  default     = 3
}

variable "off_peak_window_start" {
  description = "Off-peak window start (UTC) for service software updates and Auto-Tune."
  type = object({
    hours   = number
    minutes = number
  })
  default = {
    hours   = 7
    minutes = 0
  }
}

variable "auto_software_update_enabled" {
  description = "Apply service software updates in the off-peak window."
  type        = bool
  default     = true
}

variable "log_publishing" {
  description = "CloudWatch log types to publish (ES_APPLICATION_LOGS, SEARCH_SLOW_LOGS, INDEX_SLOW_LOGS, AUDIT_LOGS). Empty disables log publishing."
  type        = list(string)
  default     = ["ES_APPLICATION_LOGS", "SEARCH_SLOW_LOGS", "INDEX_SLOW_LOGS"]
}

variable "log_retention_days" {
  description = "Retention of the published log groups."
  type        = number
  default     = 30
}

variable "log_kms_key_arn" {
  description = "KMS key for the log groups (its key policy must allow CloudWatch Logs). null uses CloudWatch's default encryption."
  type        = string
  default     = null
}

variable "create_log_resource_policy" {
  description = "Create the CloudWatch Logs resource policy that lets OpenSearch write to the log groups. Disable when the account manages one centrally (the per-region limit is 10)."
  type        = bool
  default     = true
}

variable "advanced_options" {
  description = "Extra OpenSearch advanced options."
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
