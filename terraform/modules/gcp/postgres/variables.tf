variable "project_id" {
  description = "Project that owns the instance."
  type        = string
}

variable "region" {
  description = "Instance region."
  type        = string
}

variable "name" {
  description = "Instance name (lowercase letters, digits, hyphens; not reusable for about a week after deletion)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,78}[a-z0-9]$", var.name))
    error_message = "name must start with a letter and use lowercase letters, digits and hyphens."
  }
}

variable "database_version" {
  description = "Cloud SQL database version. The agent-relay services are tested on PostgreSQL 17."
  type        = string
  default     = "POSTGRES_17"

  validation {
    condition     = can(regex("^POSTGRES_[0-9]+$", var.database_version))
    error_message = "database_version must be a PostgreSQL version (POSTGRES_<major>)."
  }
}

variable "edition" {
  description = "ENTERPRISE or ENTERPRISE_PLUS."
  type        = string
  default     = "ENTERPRISE"

  validation {
    condition     = contains(["ENTERPRISE", "ENTERPRISE_PLUS"], var.edition)
    error_message = "edition must be ENTERPRISE or ENTERPRISE_PLUS."
  }
}

variable "tier" {
  description = "Machine tier (db-custom-<vCPU>-<MiB> for ENTERPRISE, db-perf-optimized-N-<vCPU> for ENTERPRISE_PLUS)."
  type        = string
  default     = "db-custom-2-7680"
}

variable "availability_type" {
  description = "REGIONAL (HA standby in a second zone) or ZONAL."
  type        = string
  default     = "REGIONAL"

  validation {
    condition     = contains(["REGIONAL", "ZONAL"], var.availability_type)
    error_message = "availability_type must be REGIONAL or ZONAL."
  }
}

variable "network_self_link" {
  description = "VPC network (self link or projects/<p>/global/networks/<n>) with Private Services Access already configured (an allocated range and the servicenetworking connection). The module creates neither."
  type        = string
}

variable "allocated_ip_range" {
  description = "Name of a specific PSA allocated range to place the instance in. null lets Cloud SQL pick from the connection's ranges."
  type        = string
  default     = null
}

variable "ssl_mode" {
  description = "ENCRYPTED_ONLY (TLS required) or TRUSTED_CLIENT_CERTIFICATE_REQUIRED (TLS plus client certificates). Unencrypted modes are refused."
  type        = string
  default     = "ENCRYPTED_ONLY"

  validation {
    condition     = contains(["ENCRYPTED_ONLY", "TRUSTED_CLIENT_CERTIFICATE_REQUIRED"], var.ssl_mode)
    error_message = "ssl_mode must be ENCRYPTED_ONLY or TRUSTED_CLIENT_CERTIFICATE_REQUIRED."
  }
}

variable "kms_key_name" {
  description = "CMEK key (projects/.../cryptoKeys/...). The Cloud SQL service agent needs roles/cloudkms.cryptoKeyEncrypterDecrypter on it first. null uses Google-managed encryption."
  type        = string
  default     = null
}

variable "disk_type" {
  description = "PD_SSD or PD_HDD."
  type        = string
  default     = "PD_SSD"

  validation {
    condition     = contains(["PD_SSD", "PD_HDD"], var.disk_type)
    error_message = "disk_type must be PD_SSD or PD_HDD."
  }
}

variable "disk_size_gb" {
  description = "Initial disk size in GB."
  type        = number
  default     = 100
}

variable "disk_autoresize_limit_gb" {
  description = "Autoresize ceiling in GB (0: no limit)."
  type        = number
  default     = 1000
}

variable "backup_start_time" {
  description = "Daily backup start (UTC HH:MM)."
  type        = string
  default     = "03:00"
}

variable "backup_location" {
  description = "Backup location (null: the multi-region nearest the instance)."
  type        = string
  default     = null
}

variable "retained_backups" {
  description = "Automated backups kept."
  type        = number
  default     = 14
}

variable "transaction_log_retention_days" {
  description = "Point-in-time recovery window in days (1-7 ENTERPRISE, up to 35 ENTERPRISE_PLUS)."
  type        = number
  default     = 7
}

variable "maintenance_window" {
  description = "Weekly maintenance window (day 1-7 Monday-Sunday, hour 0-23 UTC) and update_track (stable, canary, week5)."
  type = object({
    day          = number
    hour         = number
    update_track = optional(string, "stable")
  })
  default = {
    day  = 7
    hour = 4
  }

  validation {
    condition     = var.maintenance_window.day >= 1 && var.maintenance_window.day <= 7 && var.maintenance_window.hour >= 0 && var.maintenance_window.hour <= 23 && contains(["stable", "canary", "week5"], var.maintenance_window.update_track)
    error_message = "maintenance_window: day 1-7, hour 0-23, update_track stable, canary or week5."
  }
}

variable "deletion_protection" {
  description = "Both Terraform-side and API-side (deletion_protection_enabled) deletion protection."
  type        = bool
  default     = true
}

variable "database_flags" {
  description = "Database flags. cloudsql.iam_authentication is managed by iam_authentication. Overriding the map replaces these logging defaults."
  type        = map(string)
  default = {
    log_checkpoints    = "on"
    log_connections    = "on"
    log_disconnections = "on"
    log_lock_waits     = "on"
  }
}

variable "iam_authentication" {
  description = "Enable Cloud SQL IAM database authentication (cloudsql.iam_authentication=on)."
  type        = bool
  default     = true
}

variable "query_insights_enabled" {
  description = "Enable Query Insights."
  type        = bool
  default     = true
}

variable "databases" {
  description = "Databases to create (for example [\"relaycontrol\", \"relayhistory\", \"hoopdb\"]). Roles, ownership and extensions are created by the bootstrap SQL in the README."
  type        = list(string)
  default     = []
}

variable "admin_user" {
  description = <<-EOT
    The built-in administrator (cloudsqlsuperuser) used only to run the bootstrap SQL. The password is generated by
    an ephemeral random_password and written with write-only attributes to the user and to a Secret Manager version,
    so it is never stored in state or plan. Bump password_version to rotate. Set create = false to manage it yourself.
  EOT
  type = object({
    create           = optional(bool, true)
    name             = optional(string, "relay_admin")
    password_version = optional(number, 1)
    secret_id        = optional(string)
    secret_kms_key   = optional(string)
    secret_locations = optional(list(string), [])
  })
  default = {}
}

variable "labels" {
  description = "Labels applied to the instance and secret."
  type        = map(string)
  default     = {}
}
