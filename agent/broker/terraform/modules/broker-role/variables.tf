variable "name" {
  description = "Name of the broker role: the only long-lived identity that mints agent credentials."
  type        = string
  default     = "agent-cred-broker"
}

variable "account_id" {
  description = "Account the broker role lives in (the layered-infra-ops host's account)."
  type        = string
  validation {
    condition     = can(regex("^\\d{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account id."
  }
}

variable "trusted_principal_arns" {
  description = "Exact ARNs that may assume the broker role: the layered-infra-ops host role. No wildcards."
  type        = list(string)
  validation {
    condition     = length(var.trusted_principal_arns) > 0 && alltrue([for a in var.trusted_principal_arns : can(regex("^arn:aws:iam::\\d{12}:role/[\\w+=,.@/-]+$", a)) && !strcontains(a, "*")])
    error_message = "trusted_principal_arns must be exact IAM role ARNs, without wildcards."
  }
}

variable "target_role_arns" {
  description = "Exact ARNs of the roles the broker may assume to vend sessions (one per account and tier)."
  type        = list(string)
  validation {
    condition     = length(var.target_role_arns) > 0 && alltrue([for a in var.target_role_arns : can(regex("^arn:aws:iam::\\d{12}:role/[\\w+=,.@/-]+$", a)) && !strcontains(a, "*")])
    error_message = "target_role_arns must be exact IAM role ARNs, without wildcards."
  }
}

variable "audit_log_group_arn" {
  description = "ARN of the broker's CloudWatch audit log group (modules/audit-log), without :*. Null: no audit shipping."
  type        = string
  default     = null
  validation {
    condition     = var.audit_log_group_arn == null || can(regex("^arn:aws:logs:[a-z0-9-]+:\\d{12}:log-group:/aws-cred-broker/[\\w/.#-]+$", var.audit_log_group_arn))
    error_message = "audit_log_group_arn must be the exact ARN of a log group under /aws-cred-broker/, without wildcards."
  }
}

variable "tags" {
  description = "Tags on the role."
  type        = map(string)
  default     = {}
}
