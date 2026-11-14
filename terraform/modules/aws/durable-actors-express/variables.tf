variable "name" {
  description = "Name prefix for the Express directory bucket (<name>--<az id>--x-s3) and the actor storage role."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,40}[a-z0-9]$", var.name)) && !strcontains(var.name, "--")
    error_message = "name must be 3-42 lowercase letters, digits and single hyphens."
  }
}

variable "express_az_id" {
  description = <<-EOT
    Availability Zone ID (not name) of the S3 Express One Zone directory bucket, e.g. usw2-az1. AZ names map to
    different IDs in each account, so use the ID: in our account us-west-2a is usw2-az2, which has no S3 Express.
    Place the actor node group in the same zone.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z]+[0-9]+-az[0-9]+$", var.express_az_id))
    error_message = "express_az_id must be an Availability Zone ID such as usw2-az1, not a zone name such as us-west-2b."
  }
}

variable "express_supported_az_ids" {
  description = "Availability Zone IDs that offer S3 Express One Zone. Extend when AWS adds zones; usw2-az2 is deliberately absent."
  type        = list(string)
  default = [
    "use1-az4", "use1-az5", "use1-az6",
    "usw2-az1", "usw2-az3", "usw2-az4",
    "apne1-az1", "apne1-az4",
    "eun1-az1", "eun1-az2", "eun1-az3",
  ]
}

variable "checkpoint_bucket_name" {
  description = "Regional S3 Standard bucket that asynchronously checkpoints the Express bucket and holds compiled actor artifacts."
  type        = string

  validation {
    condition     = !endswith(var.checkpoint_bucket_name, "--x-s3")
    error_message = "checkpoint_bucket_name must be a regional bucket, not a directory bucket: it is the copy that survives losing the Express zone."
  }
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key for the checkpoint bucket (null: the AWS-managed aws/s3 key). The roles get Decrypt/GenerateDataKey on it."
  type        = string
  default     = null
}

variable "checkpoint_noncurrent_version_expiration_days" {
  description = "Days the checkpoint bucket keeps overwritten owner records, for point-in-time recovery from a bad write."
  type        = number
  default     = 7
}

variable "control_plane_role_name" {
  description = "Existing IAM role of the durable-actors control plane (EKS Pod Identity or IRSA). Gets an inline policy; the role itself is not managed here."
  type        = string
}

variable "deployer_role_names" {
  description = "Existing IAM roles of the relaycast/relayfile actor deployers. Each gets create-only artifact upload on the checkpoint bucket and nothing on Express."
  type        = list(string)
  default     = []
}

variable "express_operator_principal_arns" {
  description = "Extra role ARNs allowed to open Express sessions (break-glass, `durable-actors checkpoint-restore`). The directory bucket policy denies every other principal."
  type        = list(string)
  default     = []
}

variable "actor_role_permissions_boundary_arn" {
  description = "Optional permissions boundary for the actor storage role."
  type        = string
  default     = null
}

variable "storage_prefix" {
  description = "durable-actors object root."
  type        = string
  default     = "durable-actors/v3/"

  validation {
    condition     = endswith(var.storage_prefix, "/")
    error_message = "storage_prefix must end with /."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
