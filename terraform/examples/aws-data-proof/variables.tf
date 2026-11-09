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
    condition     = can(regex("^[a-zA-Z0-9-]+$", var.pippen.agent)) && can(regex("^[a-f0-9-]{36}$", var.pippen.session_id))
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
  description = "Null provisions data without compute. Exact immutable transport VersionId enables the verifier in a separate reviewed apply."
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
  type        = object({ seed_receipt_sha256 = string, seed_receipt_version_id = string, secret_version_id = string })
  default     = null
  validation {
    condition     = var.restore_checkpoint == null ? true : can(regex("^[a-f0-9]{64}$", var.restore_checkpoint.seed_receipt_sha256)) && can(regex("^[a-zA-Z0-9-]{32,64}$", var.restore_checkpoint.secret_version_id)) && length(trimspace(var.restore_checkpoint.seed_receipt_version_id)) > 0 && var.restore_checkpoint.seed_receipt_version_id != "null"
    error_message = "Restore needs exact seed receipt digest and historical secret version reference."
  }
}
variable "retire" {
  description = "Reviewed cleanup apply disables the verifier and releases database deletion protection."
  type        = bool
  default     = false
}
