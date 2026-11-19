variable "name" {
  description = "Name of the scoped role the broker vends sessions on."
  type        = string
  default     = "agent-broker-sandbox-scoped"
}

variable "broker_role_arn" {
  description = "Exact ARN of the broker role: the only principal this role trusts."
  type        = string
  validation {
    condition     = can(regex("^arn:aws:iam::\\d{12}:role/[\\w+=,.@/-]+$", var.broker_role_arn)) && !strcontains(var.broker_role_arn, "*")
    error_message = "broker_role_arn must be an exact IAM role ARN."
  }
}

variable "tag_key" {
  description = "Run tag key: sessions carry it as a principal tag; resources carry it to be theirs. Must match the broker allowlist's tagKey."
  type        = string
  default     = "agent-run"
}

variable "allowed_regions" {
  description = "Regions a session may act in (global services excepted). Must match the allowlist's account regions."
  type        = list(string)
  default     = ["us-east-1", "us-west-2"]
}

variable "base_policy_arn" {
  description = "Managed policy the role's ceiling starts from; the ceiling's denies and each session policy narrow it."
  type        = string
  default     = "arn:aws:iam::aws:policy/PowerUserAccess"
}

variable "tags" {
  description = "Tags on the role."
  type        = map(string)
  default     = {}
}
