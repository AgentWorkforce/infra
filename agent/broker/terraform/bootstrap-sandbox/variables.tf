variable "sandbox_account_id" {
  description = "The sandbox account this bootstraps."
  type        = string
  default     = "805532413586"
}

variable "region" {
  description = "Region of the state bucket (IAM is global)."
  type        = string
  default     = "us-east-1"
}

variable "profile" {
  description = "AWS CLI profile of a human admin in the sandbox account (SSO). Null: the environment's credentials."
  type        = string
  default     = null
}

variable "infra_ops_admin_role_arn" {
  description = "Exact ARN of layered-infra-ops' admin role, the only principal that may assume the bootstrap role."
  type        = string
  default     = "arn:aws:iam::500268966557:role/layered-agent-admin-infra-ops-dev"
  validation {
    condition     = can(regex("^arn:aws:iam::\\d{12}:role/[\\w+=,.@/-]+$", var.infra_ops_admin_role_arn)) && !strcontains(var.infra_ops_admin_role_arn, "*")
    error_message = "infra_ops_admin_role_arn must be an exact IAM role ARN."
  }
}

variable "scoped_role_name" {
  description = "The one role the bootstrap role may manage: the broker's sandbox scoped role (../sandbox)."
  type        = string
  default     = "agent-broker-sandbox-scoped"
}

variable "state_key_prefix" {
  description = "Key prefix in the state bucket that the bootstrap role may read and write."
  type        = string
  default     = "aws-cred-broker/"
}
