variable "name" {
  description = "Prefix for the roles and policies, e.g. agentrelay-prod-data. One instance per Terraform state."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,40}$", var.name))
    error_message = "name: 3-41 lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "github_oidc_provider_arn" {
  description = "The account's token.actions.githubusercontent.com OIDC provider (an account has at most one; ci-deploy creates it)."
  type        = string
}

variable "oidc_subject_prefix" {
  description = "Prefix of the caller repository's GitHub OIDC sub claim, e.g. repo:owner@<id>/name@<id> for immutable subjects."
  type        = string
}

variable "repository_id" {
  description = "Numeric GitHub repository ID of the caller (the repository_id claim)."
  type        = string
  validation {
    condition     = can(regex("^[0-9]+$", var.repository_id))
    error_message = "repository_id: the numeric GitHub repository ID."
  }
}

variable "workflow" {
  description = "Caller workflow file, owner/repo/.github/workflows/<file>.yml. Both roles trust only jobs of this workflow on branch (the job_workflow_ref claim)."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/\\.github/workflows/[A-Za-z0-9_.-]+\\.ya?ml$", var.workflow))
    error_message = "workflow: owner/repo/.github/workflows/<file>.yml."
  }
}

variable "branch" {
  description = "The only branch whose runs may plan or apply."
  type        = string
  default     = "main"
}

variable "apply_environment" {
  description = "GitHub environment the apply job runs in. The apply role trusts only that environment, on branch, in workflow."
  type        = string
}

variable "state" {
  description = "S3 backend of the Terraform state this CI plans and applies: bucket, key and the KMS key that encrypts it."
  type = object({
    bucket      = string
    key         = string
    kms_key_arn = string
  })
  validation {
    condition     = endswith(var.state.key, ".tfstate") && !startswith(var.state.key, "/") && !contains(split("/", var.state.key), "..")
    error_message = "state.key: a relative object key ending in .tfstate."
  }
}

variable "plan_store_prefix" {
  description = "Prefix in the state bucket for saved plans (<prefix>/<run>/run.tgz, manifest.json, apply-attempt.json). No trailing slash."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$", var.plan_store_prefix))
    error_message = "plan_store_prefix: slash-separated segments, no leading or trailing slash."
  }
}

variable "tfvars_parameter_name" {
  description = "SSM SecureString parameter holding the stack's .tfvars.json (non-secret, kept out of git). Both roles read it; neither writes it."
  type        = string
  validation {
    condition     = can(regex("^/[A-Za-z0-9_./-]+$", var.tfvars_parameter_name))
    error_message = "tfvars_parameter_name: an absolute SSM parameter name."
  }
}

variable "tfvars_kms_key_arn" {
  description = "KMS key of the SecureString. null: state.kms_key_arn."
  type        = string
  default     = null
}

variable "stack" {
  description = <<-EOT
    What the applied Terraform (examples/aws-environments) manages. name is its name_prefix-environment: every
    resource the apply role may create or change is named <name>-*. kms_key_arn is the environment key the stack
    encrypts RDS, OpenSearch and the RDS-managed secret with.
  EOT
  type = object({
    name             = string
    environment      = string
    eks_cluster_name = string
    kms_key_arn      = string
  })
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.stack.name))
    error_message = "stack.name: the stack's name_prefix-environment."
  }
}

variable "lambda_pipeline" {
  description = "Also allow the Lambda/SQS/EventBridge pipeline (aws-environments pipeline_runtime = lambda)."
  type        = bool
  default     = false
}

variable "chief_execution_node" {
  description = "Also allow the chief execution node (EC2 instance, security group, instance profile, its secrets)."
  type        = bool
  default     = false
}

variable "max_session_duration" {
  description = "Seconds a GitHub job may hold either role."
  type        = number
  default     = 3600
}

variable "tags" {
  description = "Tags for the roles and policies."
  type        = map(string)
  default     = {}
}
