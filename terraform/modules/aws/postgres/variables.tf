variable "name" {
  description = "Identifier for the instance or cluster and the prefix for its subnet and parameter groups. Lowercase letters, digits and hyphens."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,49}$", var.name)) && !can(regex("--|-$", var.name))
    error_message = "name must start with a letter, use lowercase letters, digits and single hyphens, not end with a hyphen, and be at most 50 characters."
  }
}

variable "engine_mode" {
  description = "\"rds\" for RDS for PostgreSQL (one instance, optionally Multi-AZ) or \"aurora\" for an Aurora PostgreSQL cluster."
  type        = string
  default     = "rds"

  validation {
    condition     = contains(["rds", "aurora"], var.engine_mode)
    error_message = "engine_mode must be \"rds\" or \"aurora\"."
  }
}

variable "engine_version" {
  description = "PostgreSQL engine version. RDS accepts a major version (\"17\") and picks the default minor; Aurora needs a full version (for example \"17.5\"). The agent-relay services are tested on PostgreSQL 17."
  type        = string
  default     = "17"
}

variable "subnet_ids" {
  description = "Private subnet IDs (at least two Availability Zones) for a new DB subnet group. Ignored when db_subnet_group_name is set."
  type        = list(string)
  default     = []
}

variable "db_subnet_group_name" {
  description = "Existing DB subnet group to use instead of creating one from subnet_ids."
  type        = string
  default     = null
}

variable "vpc_security_group_ids" {
  description = "Existing security groups for the database. Allow TCP 5432 only from the cluster nodes or pods that run agent-relay. The module never opens anything."
  type        = list(string)

  validation {
    condition     = length(var.vpc_security_group_ids) > 0
    error_message = "Pass at least one security group; the module creates none."
  }
}

variable "kms_key_arn" {
  description = "Customer managed KMS key for storage, Performance Insights and the managed master password secret. null uses the AWS managed keys."
  type        = string
  default     = null
}

variable "database_name" {
  description = "Initial database created with the instance. Create the others (relaycontrol, relayhistory, hoopdb, ...) with the bootstrap SQL in the README."
  type        = string
  default     = "relaycontrol"
}

variable "master_username" {
  description = "Master (rds_superuser) user name. Its password is generated and stored by RDS in Secrets Manager; it never enters Terraform state."
  type        = string
  default     = "relay_admin"
}

variable "port" {
  description = "Database port."
  type        = number
  default     = 5432
}

variable "instance_class" {
  description = "Instance class for RDS, or for each Aurora instance (\"db.serverless\" for Aurora Serverless v2)."
  type        = string
  default     = "db.r7g.large"
}

variable "aurora_instance_count" {
  description = "Aurora instances (one writer plus readers). Two or more gives a failover target in another AZ."
  type        = number
  default     = 2

  validation {
    condition     = var.aurora_instance_count >= 1 && var.aurora_instance_count <= 16
    error_message = "aurora_instance_count must be between 1 and 16."
  }
}

variable "serverlessv2_scaling" {
  description = "Aurora Serverless v2 capacity range in ACUs, used when instance_class is db.serverless."
  type = object({
    min_capacity = number
    max_capacity = number
  })
  default = {
    min_capacity = 0.5
    max_capacity = 8
  }
}

variable "multi_az" {
  description = "RDS only: a synchronous standby in a second AZ."
  type        = bool
  default     = true
}

variable "allocated_storage" {
  description = "RDS only: initial gp3 storage in GiB."
  type        = number
  default     = 100
}

variable "max_allocated_storage" {
  description = "RDS only: storage autoscaling ceiling in GiB (0 disables autoscaling)."
  type        = number
  default     = 1000
}

variable "storage_type" {
  description = "RDS only: storage type."
  type        = string
  default     = "gp3"
}

variable "iops" {
  description = "RDS only: provisioned IOPS (gp3 above 400 GiB, or io1/io2). null uses the storage type's baseline."
  type        = number
  default     = null
}

variable "backup_retention_days" {
  description = "Automated backup (and point-in-time recovery) retention in days."
  type        = number
  default     = 14

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be 1-35; 0 would disable backups and PITR."
  }
}

variable "preferred_backup_window" {
  description = "Daily backup window (UTC, hh24:mi-hh24:mi). null lets AWS choose."
  type        = string
  default     = null
}

variable "preferred_maintenance_window" {
  description = "Weekly maintenance window (ddd:hh24:mi-ddd:hh24:mi, UTC). null lets AWS choose."
  type        = string
  default     = null
}

variable "deletion_protection" {
  description = "Refuse deletion through the API until turned off."
  type        = bool
  default     = true
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. Keep false for anything holding real data."
  type        = bool
  default     = false
}

variable "auto_minor_version_upgrade" {
  description = "Apply minor engine upgrades in the maintenance window."
  type        = bool
  default     = true
}

variable "apply_immediately" {
  description = "Apply modifications now instead of in the next maintenance window."
  type        = bool
  default     = false
}

variable "iam_database_authentication_enabled" {
  description = "Allow IAM database authentication in addition to passwords (password roles keep working)."
  type        = bool
  default     = true
}

variable "performance_insights_enabled" {
  description = "Enable Performance Insights (encrypted with kms_key_arn when set)."
  type        = bool
  default     = true
}

variable "performance_insights_retention_period" {
  description = "Performance Insights retention in days (7, or 31-731 in multiples of 31)."
  type        = number
  default     = 7
}

variable "monitoring_interval" {
  description = "Enhanced Monitoring interval in seconds (0 disables it). Non-zero needs monitoring_role_arn."
  type        = number
  default     = 0
}

variable "monitoring_role_arn" {
  description = "Existing IAM role for Enhanced Monitoring (rds.amazonaws.com monitoring role)."
  type        = string
  default     = null
}

variable "enabled_cloudwatch_logs_exports" {
  description = "Log types exported to CloudWatch Logs."
  type        = list(string)
  default     = ["postgresql"]
}

variable "allowed_extensions" {
  description = "Value for the rds.allowed_extensions parameter. null leaves the RDS default (every supported extension). When set, pg_trgm and vector are always added, because RelayHistory needs them."
  type        = list(string)
  default     = null
}

variable "parameters" {
  description = "Extra parameters for the (cluster) parameter group. rds.force_ssl is managed by the module through force_ssl."
  type = list(object({
    name         = string
    value        = string
    apply_method = optional(string, "pending-reboot")
  }))
  default = []

  validation {
    condition     = length(setintersection(toset([for p in var.parameters : p.name]), toset(["rds.force_ssl", "rds.allowed_extensions"]))) == 0
    error_message = "rds.force_ssl and rds.allowed_extensions are managed by force_ssl and allowed_extensions; do not repeat them in parameters."
  }

  validation {
    condition     = length(var.parameters) <= 18
    error_message = "At most 18 extra parameters: with the module's own two, a parameter group request carries at most 20."
  }
}

variable "force_ssl" {
  description = "Set rds.force_ssl=1, so the server refuses unencrypted connections. Connect with sslmode=verify-full and the RDS CA bundle."
  type        = bool
  default     = true
}

variable "ca_cert_identifier" {
  description = "Server certificate authority. null uses the account default."
  type        = string
  default     = "rds-ca-rsa2048-g1"
}

variable "copy_tags_to_snapshot" {
  description = "Copy resource tags to snapshots."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
