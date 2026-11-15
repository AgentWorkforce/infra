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
  description = "AWS CLI profile with IAM rights in the broker account (a human's)."
  type        = string
  default     = null
}

variable "sandbox_profile" {
  description = "AWS CLI profile with IAM rights in the sandbox account (a human's)."
  type        = string
  default     = null
}

variable "allowed_regions" {
  description = "Regions sandbox sessions may use. Must match broker/allowlist.json."
  type        = list(string)
  default     = ["us-east-1", "us-west-2"]
}
