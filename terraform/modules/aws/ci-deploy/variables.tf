variable "name" {
  description = "Prefix for every resource, e.g. agentrelay-dev-deploy. One module instance per environment (one EKS cluster)."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,40}$", var.name))
    error_message = "name: 3-41 lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "cluster_name" {
  description = "EKS cluster the deploy jobs reach through its private endpoint."
  type        = string
}

variable "cluster_security_group_id" {
  description = "The cluster security group (aws_eks_cluster vpc_config cluster_security_group_id). The module allows HTTPS to it from the CodeBuild jobs."
  type        = string
}

variable "vpc_id" {
  description = "VPC of the cluster."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets (with NAT egress) the CodeBuild jobs run in."
  type        = list(string)
  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "At least one private subnet."
  }
}

variable "kms_key_arn" {
  description = "Customer managed KMS key for the artifact bucket and the builds (IAM grants the roles its use)."
  type        = string
}

variable "log_kms_key_arn" {
  description = "KMS key for the build log group. Its key policy must allow logs.<region>.amazonaws.com for /codebuild/<name>. null: CloudWatch Logs' default encryption."
  type        = string
  default     = null
}

variable "github_repository" {
  description = "owner/name of the repository whose workflows deploy (it holds the environment's values)."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository: owner/name."
  }
}

variable "oidc_subject_prefix" {
  description = "Prefix of the GitHub OIDC sub claim. null: repo:<github_repository>. Set it when the repository's OIDC subject template differs (for example one that includes owner and repository IDs)."
  type        = string
  default     = null
}

variable "plan_subjects" {
  description = <<-EOT
    GitHub OIDC subjects allowed to start a plan. A plan reads the live release, whose storage holds Secrets, so
    keep it to protected refs: null means the default branch main only. Never add pull_request: a pull request
    would run its own bundle with this read access.
  EOT
  type        = list(string)
  default     = null
}

variable "apply_environment" {
  description = "GitHub environment that gates apply and rollback. Only a job in this environment can start the apply project; set its required reviewers and branch policy in GitHub."
  type        = string
}

variable "create_github_oidc_provider" {
  description = "Create the account's token.actions.githubusercontent.com OIDC provider. false: pass github_oidc_provider_arn (an account has at most one)."
  type        = bool
  default     = true
}

variable "github_oidc_provider_arn" {
  description = "Existing GitHub OIDC provider, when create_github_oidc_provider is false."
  type        = string
  default     = null
}

variable "namespaces" {
  description = "Namespaces holding the releases this environment deploys. The plan job may read them (helm release state); apply is cluster-wide."
  type        = list(string)
  validation {
    condition     = length(var.namespaces) > 0
    error_message = "At least one namespace."
  }
}

variable "rds_instance_identifiers" {
  description = "RDS instances the apply job snapshots before an upgrade. Empty: no RDS snapshot permission."
  type        = list(string)
  default     = []
}

variable "secrets_manager_prefix" {
  description = "Secrets Manager name prefix (e.g. agentrelay-dev/) whose secrets the apply job may read, create and copy into Kubernetes Secrets (deploy.json \"secrets\"). null: no Secrets Manager access."
  type        = string
  default     = null
  validation {
    condition     = var.secrets_manager_prefix == null || can(regex("^[A-Za-z0-9_+=.@-]+/$", coalesce(var.secrets_manager_prefix, "x/")))
    error_message = "secrets_manager_prefix: a name prefix ending in /, e.g. agentrelay-dev/."
  }
}

variable "build_image" {
  description = "CodeBuild image. The build installs pinned helm, kubectl and a PostgreSQL client itself."
  type        = string
  default     = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
}

variable "compute_type" {
  description = "CodeBuild compute type."
  type        = string
  default     = "BUILD_GENERAL1_SMALL"
}

variable "build_timeout_minutes" {
  description = "Upper bound for one plan or apply (helm --wait, snapshot)."
  type        = number
  default     = 60
}

variable "artifact_retention_days" {
  description = "Days bundles and run reports are kept."
  type        = number
  default     = 90
}

variable "snapshot_retention_days" {
  description = "Days pg_dump snapshots written by apply are kept (RDS snapshots are managed in RDS)."
  type        = number
  default     = 35
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}
