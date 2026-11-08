variable "account_id" {
  description = "Exact existing sandbox account; never an account creation request."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Require a 12-digit account."
  }
}
variable "region" {
  description = "Explicit approved existing region."
  type        = string
}
variable "run_id" {
  description = "Lease-unique bounded slug; do not reuse while old resources or sessions exist."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,15}$", var.run_id))
    error_message = "Use 3-16 lowercase alphanumeric characters, beginning with a letter."
  }
}
variable "pippen" {
  description = "Expected allocated non-secret lease identity."
  type        = object({ agent = string, session_id = string })
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,40}$", var.pippen.agent)) && can(regex("^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$", var.pippen.session_id))
    error_message = "Require the expected agent and lease UUID."
  }
}
variable "vpc_id" {
  description = "Reviewed existing VPC; unchanged by this proof."
  type        = string
}
variable "private_subnet_ids" {
  description = "Exactly two reviewed existing private subnets in distinct AZs; null when create_private_subnets is selected."
  type        = set(string)
  default     = null
  validation {
    condition     = var.private_subnet_ids == null ? true : length(var.private_subnet_ids) == 2
    error_message = "Require exactly two private AZ subnets for this bounded proof."
  }
}
variable "create_private_subnets" {
  description = "Optional two owned local-only private subnets in the existing default VPC. Explicit reviewed non-overlapping /24-/28 IPv4 CIDRs and distinct available AZs; mutually exclusive with private_subnet_ids."
  type        = object({ first = object({ cidr = string, az = string }), second = object({ cidr = string, az = string }) })
  default     = null
  validation {
    condition = var.create_private_subnets == null ? true : alltrue([for subnet in values(var.create_private_subnets) : try(
      can(regex("^[0-9.]+/(24|25|26|27|28)$", subnet.cidr)) && subnet.cidr == "${cidrhost(subnet.cidr, 0)}/${split("/", subnet.cidr)[1]}" && length(trimspace(subnet.az)) > 0, false
    )])
    error_message = "Require two canonical IPv4 /24-/28 network CIDRs and explicit AZs."
  }
}
variable "host_subnet_id" {
  description = "Reviewed existing public subnet with HTTPS egress through an IGW. No routing changes."
  type        = string
}
variable "ami_id" {
  description = "Exact reviewed Amazon AL2023 ARM64 HVM/EBS AMI, not latest."
  type        = string
}
variable "postgres_version" {
  description = "Exact region-supported PostgreSQL17 minor verified independently by the operator."
  type        = string
  validation {
    condition     = can(regex("^17\\.[0-9]+$", var.postgres_version))
    error_message = "Require an explicit PostgreSQL17 minor."
  }
}
variable "source_sha" {
  description = "Exact committed source of the reviewed transport payload."
  type        = string
  validation {
    condition     = can(regex("^[a-f0-9]{40}$", var.source_sha))
    error_message = "Require a full source SHA."
  }
}
variable "payload_sha256" {
  description = "Content digest of the secret-free transport archive, checked before extraction."
  type        = string
  validation {
    condition     = can(regex("^[a-f0-9]{64}$", var.payload_sha256))
    error_message = "Require a SHA256."
  }
}
variable "payload_version_id" {
  description = "Null provisions data without compute. A non-null immutable transport VersionId also requires a registered application activation; none is registered, so verifier execution stays refused."
  type        = string
  default     = null
  validation {
    condition     = var.payload_version_id == null ? true : length(trimspace(var.payload_version_id)) > 0 && var.payload_version_id != "null"
    error_message = "Require a real S3 object version to launch compute."
  }
}
variable "rds_ca_sha256" {
  description = "Reviewed SHA256 of the public regional RDS CA bundle; never a private certificate/key."
  type        = string
  validation {
    condition     = can(regex("^[a-f0-9]{64}$", var.rds_ca_sha256))
    error_message = "Require a public CA bundle SHA256."
  }
}
variable "restore_checkpoint" {
  description = "Null for seed. Supply only after a successful independently reviewed seed receipt; no secret values."
  type        = object({ seed_receipt_sha256 = string, seed_receipt_version_id = string, secret_version_id = string, runtime_secret_version_id = string, seed_evidence_sha256 = string })
  default     = null
  validation {
    condition     = var.restore_checkpoint == null ? true : can(regex("^[a-f0-9]{64}$", var.restore_checkpoint.seed_receipt_sha256)) && can(regex("^[a-zA-Z0-9-]{32,64}$", var.restore_checkpoint.secret_version_id)) && can(regex("^[a-zA-Z0-9-]{32,64}$", var.restore_checkpoint.runtime_secret_version_id)) && can(regex("^[a-f0-9]{64}$", var.restore_checkpoint.seed_evidence_sha256)) && length(trimspace(var.restore_checkpoint.seed_receipt_version_id)) > 0 && var.restore_checkpoint.seed_receipt_version_id != "null"
    error_message = "Restore needs exact seed receipt digest and historical secret version reference."
  }
}
variable "retire" {
  description = "Reviewed cleanup apply disables the verifier and releases database deletion protection."
  type        = bool
  default     = false
}

variable "guest_sources" {
  description = "Frozen unchanged source composition, actual manifest and generation. Public provenance only, no credentials."
  type        = object({ composition_commit = string, manifest_sha256 = string, generation = string })
  validation {
    condition     = var.guest_sources.composition_commit == "292359f0c68b1e4615704fd51d303b7f6b4db445" && can(regex("^[a-f0-9]{64}$", var.guest_sources.manifest_sha256)) && var.guest_sources.generation == "7d64ae1f74670530fd6443fad7d6cc9ac11776055941821ef79f8501fb2d7879"
    error_message = "Require the exact reviewed original guest composition/manifest/generation; never repin implicitly."
  }
}

variable "deadline" {
  description = "Explicit immutable UTC workload deadline; fresh parent review must budget creation/guest/restore/cleanup. Never extend it to retry a failed fixture."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$", var.deadline)) && can(formatdate("YYYY", var.deadline))
    error_message = "Require a canonical UTC millisecond deadline."
  }
}

variable "application_activation" {
  description = "Reviewed schema-aware Sessions activation artifact for the shared-database application path (source commit, artifact sha256, generation, contract id). Null keeps application execution refused. Must name an entry of local.approved_activations, which is empty until a reviewed artifact exists."
  type = object({
    sessions_commit = string
    artifact_sha256 = string
    generation      = string
    contract        = string
  })
  default = null
  validation {
    condition     = var.application_activation == null ? true : can(regex("^[a-f0-9]{40}$", var.application_activation.sessions_commit)) && can(regex("^[a-f0-9]{64}$", var.application_activation.artifact_sha256)) && can(regex("^[a-f0-9]{64}$", var.application_activation.generation)) && can(regex("^[a-z0-9][a-z0-9._-]{0,63}$", var.application_activation.contract))
    error_message = "application_activation needs a 40-hex Sessions commit, 64-hex artifact and generation digests and a bounded contract id."
  }
}
