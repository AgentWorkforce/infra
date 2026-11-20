variable "account_id" {
  description = "The account that gets the operator role. The provider refuses any other."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account id."
  }
}

variable "region" {
  description = "Provider region. IAM is global; this only picks the STS/IAM endpoint."
  type        = string
  default     = "us-west-2"
}

variable "trusted_role_arns" {
  description = "The operator's own admin role(s), by exact role ARN, in its home account. Only these may assume the role: no account root, no wildcard, no user."
  type        = list(string)
  validation {
    condition     = length(var.trusted_role_arns) > 0 && alltrue([for a in var.trusted_role_arns : can(regex("^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$", a)) && !strcontains(a, "*")])
    error_message = "trusted_role_arns must name at least one IAM role ARN (arn:aws:iam::<account>:role/<name>), with no wildcard."
  }
}

variable "role_name" {
  description = "Name of the operator role in this account."
  type        = string
  default     = "layered-infra-ops"
  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", var.role_name))
    error_message = "role_name must be an IAM role name (1-64 characters of A-Z a-z 0-9 + = , . @ _ -)."
  }
}

variable "role_path" {
  description = "IAM path for the role."
  type        = string
  default     = "/"
}

variable "max_session_duration" {
  description = "Longest session the operator may request, in seconds (1 to 12 hours)."
  type        = number
  default     = 3600
  validation {
    condition     = var.max_session_duration >= 3600 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be 3600..43200 seconds."
  }
}

variable "external_id" {
  description = "Optional sts:ExternalId the operator must present. Not a secret; a guard against a mis-targeted assume-role."
  type        = string
  default     = null
  validation {
    condition     = var.external_id == null ? true : (can(regex("^[A-Za-z0-9+=,.@:/_-]{2,}$", var.external_id)) && length(var.external_id) <= 1224)
    error_message = "external_id must be null or 2-1224 characters of A-Z a-z 0-9 + = , . @ : / _ -."
  }
}

variable "policy_arns" {
  description = "Managed policies attached to the role. The default is the same grant the operator has in its home account."
  type        = list(string)
  default     = ["arn:aws:iam::aws:policy/AdministratorAccess"]
  validation {
    condition     = length(var.policy_arns) > 0 && alltrue([for p in var.policy_arns : can(regex("^arn:aws:iam::(aws|[0-9]{12}):policy/.+$", p))])
    error_message = "policy_arns must be managed policy ARNs."
  }
}

variable "permissions_boundary_arn" {
  description = "Optional permissions boundary for the role."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags for the role."
  type        = map(string)
  default     = {}
}
