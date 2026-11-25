variable "sessions_account_id" {
  description = "The sessions account the role lives in (broker/allowlist.json accounts, label sessions-prod)."
  type        = string
  validation {
    condition     = can(regex("^\\d{12}$", var.sessions_account_id))
    error_message = "sessions_account_id must be a 12-digit AWS account id."
  }
}

variable "broker_role_arn" {
  description = "Exact ARN of the broker role (../sandbox output broker_role_arn): the only principal the new role trusts."
  type        = string
  validation {
    condition     = can(regex("^arn:aws:iam::\\d{12}:role/[\\w+=,.@/-]+$", var.broker_role_arn)) && !strcontains(var.broker_role_arn, "*")
    error_message = "broker_role_arn must be an exact IAM role ARN."
  }
}

variable "function_name" {
  description = "The session pipeline's indexing Lambda: the one function agents may read the configuration of."
  type        = string
  default     = "96bulls-aws-sessions-prod-session-pipeline"
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", var.function_name))
    error_message = "function_name must be one literal function name."
  }
}

variable "log_group_name" {
  description = "The function's log group. Null: the standard /aws/lambda/<function_name>."
  type        = string
  default     = null
  validation {
    condition     = var.log_group_name == null || can(regex("^/[A-Za-z0-9_/.#-]{1,511}$", var.log_group_name))
    error_message = "log_group_name must be one literal log group name starting with /."
  }
}

variable "region" {
  description = "The function's region. Must match the allowlist account's one region."
  type        = string
  default     = "us-east-1"
}

variable "role_name" {
  description = "Name of the role the broker assumes in this account (the allowlist's roles.elevated for the sessions account)."
  type        = string
  default     = "agent-broker-sessions-read"
}

variable "tag_key" {
  description = "Run tag key (the broker allowlist's tagKey)."
  type        = string
  default     = "agent-run"
}

variable "profile" {
  description = "AWS CLI profile with IAM rights and Lambda and Logs read in the sessions account. Null: the default credentials."
  type        = string
  default     = null
}

variable "assume_role_arn" {
  description = "Role in the sessions account that the provider assumes. Null: use the profile as is."
  type        = string
  default     = null
  validation {
    condition     = var.assume_role_arn == null || can(regex("^arn:aws:iam::\\d{12}:role/[\\w+=,.@/-]+$", var.assume_role_arn))
    error_message = "assume_role_arn must be an exact IAM role ARN."
  }
}

variable "tags" {
  description = "Tags on the role."
  type        = map(string)
  default     = {}
}
