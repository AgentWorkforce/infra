variable "broker_account_id" {
  description = "Account of the layered-infra-ops host, where the broker role lives."
  type        = string
}

variable "broker_host_role_arn" {
  description = "Exact ARN of the layered-infra-ops host role (layered-agent-infra-ops-<stage>)."
  type        = string
}

variable "sandbox_account_id" {
  description = "Sandbox account the scoped role lives in."
  type        = string
  default     = "805532413586"
}

variable "region" {
  description = "Provider region (IAM is global)."
  type        = string
  default     = "us-east-1"
}

variable "broker_profile" {
  description = "AWS CLI profile with IAM rights in the broker account. Null: the default profile (infra-ops' admin role)."
  type        = string
  default     = null
}

variable "sandbox_profile" {
  description = "AWS CLI profile with IAM rights in the sandbox account. Null: the default profile, plus sandbox_assume_role_arn."
  type        = string
  default     = null
}

variable "sandbox_assume_role_arn" {
  description = "Role in the sandbox account, trusted by infra-ops' admin role, that the sandbox provider assumes. Null: use the profile as is."
  type        = string
  default     = null
  validation {
    condition     = var.sandbox_assume_role_arn == null || can(regex("^arn:aws:iam::\\d{12}:role/[\\w+=,.@/-]+$", var.sandbox_assume_role_arn))
    error_message = "sandbox_assume_role_arn must be an exact IAM role ARN."
  }
}

variable "allowed_regions" {
  description = "Regions sandbox sessions may use. Must match broker/allowlist.json."
  type        = list(string)
  default     = ["us-east-1", "us-west-2"]
}

variable "dev_read_role_arn" {
  description = "Read-only dev-cluster role the broker may vend (created by ../dev, applied by that account's owner). Must equal broker/allowlist.json accounts.<dev account>.roles.elevated."
  type        = string
  default     = "arn:aws:iam::154551280135:role/agent-broker-dev-read"
  validation {
    condition     = can(regex("^arn:aws:iam::\\d{12}:role/[\\w+=,.@/-]+$", var.dev_read_role_arn))
    error_message = "dev_read_role_arn must be an exact IAM role ARN."
  }
}
