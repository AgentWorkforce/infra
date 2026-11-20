variable "name" {
  description = "Log group name. Must match BROKER_AUDIT_LOG_GROUP in agent/setup-lane.sh and stay under the /aws-cred-broker/ prefix the elevated role's ceiling protects."
  type        = string
  default     = "/aws-cred-broker/audit"
  validation {
    condition     = startswith(var.name, "/aws-cred-broker/") && can(regex("^[\\w/.#-]+$", var.name))
    error_message = "name must be a literal log group name under /aws-cred-broker/."
  }
}

variable "retention_in_days" {
  description = "How long CloudWatch keeps audit lines. Two years by default."
  type        = number
  default     = 731
  validation {
    condition     = var.retention_in_days >= 365
    error_message = "keep the audit log at least a year."
  }
}

variable "tags" {
  description = "Tags on the log group."
  type        = map(string)
  default     = {}
}
