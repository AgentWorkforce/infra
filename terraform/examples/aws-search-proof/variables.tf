variable "account_id" {
  description = "Exact existing sandbox account; no account vending."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Require an exact 12-digit account."
  }
}
variable "region" {
  description = "Explicit approved existing region."
  type        = string
  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.region))
    error_message = "Require an AWS region."
  }
}
variable "pippen" {
  description = "Expected existing lease identity; immutable for the entire proof."
  type        = object({ agent = string, session_id = string })
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,40}$", var.pippen.agent)) && can(regex("^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$", var.pippen.session_id))
    error_message = "Require the expected agent and lowercase UUIDv4 lease."
  }
}
variable "source_sha" {
  description = "Exact clean committed Helm source; also bound by the source runner."
  type        = string
  validation {
    condition     = can(regex("^[a-f0-9]{40}$", var.source_sha))
    error_message = "Require a full source commit."
  }
}
variable "approved_tag_keys" {
  description = "Exact profile-approved metadata keys, at most eight. No arbitrary tag values are accepted."
  type        = set(string)
  validation {
    condition     = length(var.approved_tag_keys) >= 7 && length(var.approved_tag_keys) <= 8 && alltrue([for key in var.approved_tag_keys : can(regex("^[A-Za-z0-9][A-Za-z0-9:_.@/+=-]{0,63}$", key)) && (!startswith(lower(key), "pippen:") || contains(["pippen:sandbox", "pippen:agent", "pippen:session"], key))])
    error_message = "Require 7-8 exact-case ASCII keys; reserved Pippen keys cannot be aliased."
  }
}
variable "vpc_id" {
  description = "Reviewed existing VPC; never modified by this root."
  type        = string
}
variable "subnet_ids" {
  description = "One or two existing private subnets, one per distinct AZ. Single-AZ is explicitly disposable and has no HA claim."
  type        = list(string)
  validation {
    condition     = length(var.subnet_ids) >= 1 && length(var.subnet_ids) <= 2 && length(distinct(var.subnet_ids)) == length(var.subnet_ids)
    error_message = "Require one or two distinct reviewed private subnets."
  }
}
variable "domain_security_group_id" {
  description = "Existing exclusive domain SG: only HTTPS ingress from the exact client groups; no world/prefix ranges."
  type        = string
}
variable "client_security_group_ids" {
  description = "Reviewed existing client SGs permitted by the domain SG; no network changes or workload installation."
  type        = set(string)
  validation {
    condition     = length(var.client_security_group_ids) > 0 && length(var.client_security_group_ids) <= 3
    error_message = "Require 1-3 explicit client security groups."
  }
}
variable "roles" {
  description = "Pre-existing distinct same-account admin, indexer and reader IAM role ARNs. This root never authors IAM/trust/grants."
  type        = object({ admin = string, indexer = string, reader = string })
}
variable "engine_version" {
  description = "Explicit region-supported OpenSearch engine version reviewed separately; never a guessed latest default."
  type        = string
  validation {
    condition     = can(regex("^OpenSearch_[0-9]+\\.[0-9]+$", var.engine_version))
    error_message = "Require an explicit OpenSearch_X.Y version."
  }
}
