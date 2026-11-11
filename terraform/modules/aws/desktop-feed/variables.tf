variable "name" {
  description = "Base name for the feed keys, aliases, role and policy, e.g. agent-relay-dev-desktop-feed."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,46}[a-z0-9]$", var.name))
    error_message = "name must be 2-48 lowercase letters, digits and hyphens."
  }
}

variable "profiles" {
  description = "Desktop profile IDs. Each gets its own Ed25519 SIGN_VERIFY key and alias alias/<name>-<profile>."
  type        = set(string)

  validation {
    condition     = length(var.profiles) > 0 && alltrue([for p in var.profiles : can(regex("^[A-Za-z0-9_-]{1,64}$", p))])
    error_message = "profiles must name at least one profile; each ID is 1-64 letters, digits, _ or -."
  }
}

variable "key_deletion_window_days" {
  description = "Waiting period before a removed profile key is deleted. Deleting a key invalidates every Desktop build that embeds its public key."
  type        = number
  default     = 30

  validation {
    condition     = var.key_deletion_window_days >= 7 && var.key_deletion_window_days <= 30
    error_message = "key_deletion_window_days must be 7-30."
  }
}

variable "bucket_name" {
  description = "Private feed bucket. Control signs its virtual-hosted host into download_hosts, so the name cannot contain dots."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3-63 lowercase letters, digits and hyphens (no dots)."
  }
}

variable "create_bucket" {
  description = "Create bucket_name as a private bucket through modules/aws/object-storage. false grants access to the prefix of an existing private bucket in this account."
  type        = bool
  default     = true
}

variable "prefix" {
  description = "Object key prefix (SELFHOST_DESKTOP_FEED_S3_PREFIX). Control's default is desktop-feed."
  type        = string
  default     = "desktop-feed"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$", var.prefix)) && !anytrue([for s in split("/", var.prefix) : contains([".", ".."], s)])
    error_message = "prefix must be [A-Za-z0-9._-] segments separated by /, without leading/trailing / or . and .. segments."
  }
}

variable "force_destroy" {
  description = "Allow destroy to delete every feed object in a created bucket. Keep false outside disposable fixtures."
  type        = bool
  default     = false
}

variable "access_log_bucket" {
  description = "Existing bucket for S3 server access logs of a created bucket. null disables access logging."
  type        = string
  default     = null
}

variable "role" {
  description = <<-EOT
    The Relay Control workload identity. create = true makes a role trusted by EKS Pod Identity with the feed policy
    and the listed Pod Identity associations (Pod Identity allows one role per ServiceAccount). create = false makes no
    IAM: attach the policy_json output to Control's existing role instead.
  EOT
  type = object({
    create                   = optional(bool, true)
    name                     = optional(string)
    path                     = optional(string, "/")
    permissions_boundary_arn = optional(string)
    pod_identity_associations = optional(list(object({
      cluster_name    = string
      namespace       = string
      service_account = string
    })), [])
  })
  default = {}
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
