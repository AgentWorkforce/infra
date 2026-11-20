variable "region" {
  description = "Region of the runner. us-east-1 keeps it next to the Neon and Supabase projects."
  type        = string
  default     = "us-east-1"
}

variable "account_id" {
  description = "AWS account the runner lives in; the provider refuses any other."
  type        = string
}

variable "name" {
  description = "Name prefix for every resource."
  type        = string
  default     = "neon-exit-runner"
}

variable "vpc_id" {
  description = "VPC that gets the private subnet and the NAT gateway."
  type        = string
}

variable "public_subnet_id" {
  description = "Existing public subnet (route to an internet gateway) that hosts the NAT gateway."
  type        = string
}

variable "private_subnet_cidr" {
  description = "CIDR of the new private subnet; must be free inside the VPC."
  type        = string
  default     = "172.31.96.0/20"
}

variable "availability_zone" {
  description = "AZ of the private subnet; the instance type must be offered there."
  type        = string
  default     = "us-east-1a"
}

variable "instance_type" {
  description = "Instance type with local NVMe for the dump."
  type        = string
  default     = "m6id.4xlarge"
}

variable "ami_ssm_parameter" {
  description = "SSM public parameter that resolves to the AMI."
  type        = string
  default     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size. The dump goes to the NVMe instance store at /scratch, not here."
  type        = number
  default     = 50
}

variable "db_owner_secret_name" {
  description = "Secrets Manager name of the target database owner credential. Created empty; the value is written out of band by whoever holds it."
  type        = string
  default     = "neon-exit/relayhistory-legacy/postgres-owner"
}

variable "copy_urls_secret_name" {
  description = "Secrets Manager name of the Cloud copy connection URLs. Created empty; written out of band and read on the runner."
  type        = string
  default     = "neon-exit/cloud/copy-urls"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    project   = "neon-exit"
    managed   = "terraform"
    ephemeral = "true"
  }
}

# --- alerting (alerting.tf) -------------------------------------------------

variable "log_group_name" {
  description = "CloudWatch Logs group that receives the files listed in runner_log_files."
  type        = string
  default     = "/neon-exit/runner"
}

variable "log_retention_days" {
  description = "Days CloudWatch keeps the runner log."
  type        = number
  default     = 90
}

variable "runner_log_dir" {
  description = "Directory on the runner that holds the files listed in runner_log_files, which the CloudWatch agent ships. Write the erasure CLI's structured stdout there (for example `| tee -a /var/log/neon-exit/erasure.log`)."
  type        = string
  default     = "/var/log/neon-exit"
  validation {
    condition     = can(regex("^/[A-Za-z0-9_./-]+$", var.runner_log_dir)) && !endswith(var.runner_log_dir, "/")
    error_message = "runner_log_dir must be an absolute path without a trailing slash."
  }
}

variable "runner_log_files" {
  description = "File names under runner_log_dir that the CloudWatch agent ships. Each file gets its own collect entry (and log stream) because a wildcard would ship only the newest match. A new log file name must be added here before its lines reach the alarms."
  type        = list(string)
  default     = ["erasure.log", "canary.log"]
  validation {
    condition     = length(var.runner_log_files) > 0 && alltrue([for f in var.runner_log_files : can(regex("^[A-Za-z0-9_.-]+\\.log$", f))])
    error_message = "runner_log_files needs at least one entry, each a plain file name ending in .log (no slash, no wildcard)."
  }
  validation {
    condition     = length(distinct(var.runner_log_files)) == length(var.runner_log_files)
    error_message = "runner_log_files entries must be distinct."
  }
}

variable "metric_namespace" {
  description = "CloudWatch metric namespace for the signals extracted from the log."
  type        = string
  default     = "neon-exit"
}

variable "alert_signals" {
  description = "Signals that page: metric name => CloudWatch Logs filter pattern on the eraser's JSON lines (every pattern must also require $.service = \"neon-s3-erasure\"). One metric filter and one alarm (any match in a minute) per entry."
  type        = map(string)
  default = {
    # The @metric line carries legacyFenceFailed/value; the message lines are
    # what the eraser on main logs today when a fence sweep fails.
    legacy_fence_failed                        = "{ ($.service = \"neon-s3-erasure\") && ((($.legacyFenceFailed > 0) && ($.value > 0)) || ($.message = \"fence sweep failed\") || ($.message = \"live fence sweep failed\")) }"
    legacy_erasure_requires_supabase_authority = "{ ($.service = \"neon-s3-erasure\") && ($.error_code = \"legacy_erasure_requires_supabase_authority\") }"
  }
  validation {
    condition     = alltrue([for k, v in var.alert_signals : can(regex("^[A-Za-z0-9_]{1,100}$", k)) && length(trimspace(v)) > 0])
    error_message = "alert_signals keys are metric names ([A-Za-z0-9_]) and values are non-empty filter patterns."
  }
}

variable "alert_protocol" {
  description = "SNS subscription protocol for the ops topic: https (a PagerDuty Events v2 CloudWatch integration URL or Slack workflow URL), email, email-json or sms."
  type        = string
  default     = "https"
  validation {
    condition     = contains(["https", "email", "email-json", "sms"], var.alert_protocol)
    error_message = "alert_protocol must be one of https, email, email-json, sms."
  }
}

variable "alert_endpoint" {
  description = "Where the ops topic delivers (URL, address or number for alert_protocol). Unset: the topic exists, the alarms publish to it, and nobody is subscribed."
  type        = string
  default     = null
  sensitive   = true
}

variable "runner_log_owner" {
  description = "User that owns runner_log_dir (0750). The eraser runs as this user; the CloudWatch agent reads as root."
  type        = string
  default     = "ssm-user"
  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.runner_log_owner))
    error_message = "runner_log_owner must be a plain Unix user name."
  }
}

variable "heartbeat_enabled" {
  description = "Create the dead-man alarm on the eraser's per-sweep summary line. Missing data is breaching, so leave it false until the apply that starts the eraser on the runner; an alarm created earlier sits in ALARM and the first real outage after subscribing never transitions, so never pages."
  type        = bool
  default     = false
}

variable "heartbeat_pattern" {
  description = "Filter pattern for the eraser's per-sweep summary line."
  type        = string
  default     = "{ ($.service = \"neon-s3-erasure\") && ($.message = \"erasure sweep\") }"
}

variable "heartbeat_period_seconds" {
  description = "Expected sweep cadence in seconds (the eraser's default is 600). One alarm period."
  type        = number
  default     = 600
  validation {
    condition     = var.heartbeat_period_seconds >= 60 && var.heartbeat_period_seconds % 60 == 0
    error_message = "heartbeat_period_seconds must be a multiple of 60."
  }
}

variable "heartbeat_evaluation_periods" {
  description = "Periods the dead-man alarm looks back over. With the defaults (3 periods, 2 breaching) it pages after 20 to 30 minutes without a sweep line, and one slow sweep that straddles a bucket does not page."
  type        = number
  default     = 3
  validation {
    condition     = var.heartbeat_evaluation_periods >= 1
    error_message = "heartbeat_evaluation_periods must be at least 1."
  }
}

variable "heartbeat_datapoints_to_alarm" {
  description = "Periods without a sweep line, out of heartbeat_evaluation_periods, that put the dead-man alarm in ALARM."
  type        = number
  default     = 2
  validation {
    condition     = var.heartbeat_datapoints_to_alarm >= 1 && var.heartbeat_datapoints_to_alarm <= var.heartbeat_evaluation_periods
    error_message = "heartbeat_datapoints_to_alarm must be between 1 and heartbeat_evaluation_periods."
  }
}
