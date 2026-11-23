variable "prod_account_id" {
  description = "The prod account the role and the EKS access entry live in (broker/allowlist.json accounts)."
  type        = string
  validation {
    condition     = can(regex("^\\d{12}$", var.prod_account_id))
    error_message = "prod_account_id must be a 12-digit AWS account id."
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

variable "cluster_name" {
  description = "The EKS cluster agents may read. Its authentication mode must include API (access entries)."
  type        = string
  default     = "agent-relay-prod"
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$", var.cluster_name))
    error_message = "cluster_name must be one literal cluster name."
  }
}

variable "region" {
  description = "The cluster's region. Must match the allowlist account's one region."
  type        = string
  default     = "us-west-2"
}

variable "role_name" {
  description = "Name of the role the broker assumes in this account (the allowlist's roles.elevated for the prod account)."
  type        = string
  default     = "agent-broker-prod-read"
}

variable "tag_key" {
  description = "Run tag key (the broker allowlist's tagKey)."
  type        = string
  default     = "agent-run"
}

variable "profile" {
  description = "AWS CLI profile with IAM and EKS rights in the prod account. Null: the default credentials."
  type        = string
  default     = null
}

variable "assume_role_arn" {
  description = "Role in the prod account that the provider assumes. Null: use the profile as is."
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
