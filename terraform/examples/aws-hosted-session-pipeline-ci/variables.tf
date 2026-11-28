# Private values (account, names, ARNs) come from a tfvars file the administrator keeps out of the repository.

variable "account_id" {
  description = "The hosted sessions account."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be 12 digits."
  }
}

variable "region" {
  description = "The hosted sessions region."
  type        = string
}

variable "name" {
  description = "Prefix for the CI resources (roles, state bucket, key alias, parameter)."
  type        = string
  default     = "hosted-session-pipeline-ci"
}

variable "github_repository" {
  description = "owner/repo whose workflow assumes the roles."
  type        = string
  default     = "AgentWorkforce/infra"
}

variable "plan_environment" {
  description = "GitHub environment of the plan job (its OIDC subject)."
  type        = string
  default     = "hosted-session-pipeline-plan"
}

variable "apply_environment" {
  description = "GitHub environment of the apply job (protected: required reviewers, main only)."
  type        = string
  default     = "hosted-session-pipeline"
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider. false when the account already has one."
  type        = bool
  default     = true
}

variable "state_key" {
  description = "Object key of the hosted root's state."
  type        = string
  default     = "hosted/session-pipeline.tfstate"
}

variable "pipeline" {
  description = "What the hosted root manages, so both roles are scoped to it and nothing else."
  type = object({
    name_prefix     = string # 96bulls-<stage>
    function_name   = string
    role_name       = string
    bucket_name     = string
    kms_key_arn     = string
    secret_name     = string # 96bulls/<stage>/session-pipeline
    log_group_names = optional(list(string), [])
  })
}

variable "tags" {
  description = "Tags on the CI resources."
  type        = map(string)
  default     = {}
}

variable "apply_scope" {
  description = "adoption (default): the apply role may write state and update the pipeline's event source mapping only, which is all the zero-diff import plus the approved ESM change needs. full: changes to every resource the hosted root manages (for later reviewed changes)."
  type        = string
  default     = "adoption"
  validation {
    condition     = contains(["adoption", "full"], var.apply_scope)
    error_message = "apply_scope: adoption or full."
  }
}
