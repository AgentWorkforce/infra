variable "account_id" {
  description = "The AWS account that owns the bucket and the distribution. The providers refuse any other."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account id."
  }
}

variable "region" {
  description = "The bucket's region."
  type        = string
}

variable "bucket_name" {
  description = "The private downloads bucket. An existing bucket is imported (see the README)."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name)) && !strcontains(var.bucket_name, "..")
    error_message = "bucket_name must be an S3 bucket name."
  }
}

variable "origin_prefix" {
  description = "The one key prefix CloudFront may read and serves as its root. Objects live at <origin_prefix>/<channel>/..., and the URL path starts at <channel>."
  type        = string
  default     = "desktop"
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,62}$", var.origin_prefix))
    error_message = "origin_prefix must be a plain path segment (lowercase letters, digits, hyphens)."
  }
}

variable "signing_public_keys" {
  description = "CloudFront public keys that verify signed URLs: key name => PEM of an RSA 2048 public key. The name is the CloudFront key's name (an existing key is imported under its own name). The private halves never go into Terraform, state or the repository. Add a second entry to rotate with an overlap."
  type        = map(string)
  validation {
    condition     = length(var.signing_public_keys) >= 1
    error_message = "signing_public_keys needs at least one key."
  }
  validation {
    condition     = alltrue([for k in keys(var.signing_public_keys) : can(regex("^[A-Za-z0-9_-]{1,128}$", k))])
    error_message = "Each signing_public_keys name must be 1..128 letters, digits, hyphens or underscores."
  }
  validation {
    condition     = alltrue([for v in values(var.signing_public_keys) : can(regex("^-----BEGIN PUBLIC KEY-----[^-]+-----END PUBLIC KEY-----$", trimspace(v)))])
    error_message = "Each signing_public_keys value must be a PEM public key (-----BEGIN PUBLIC KEY-----)."
  }
}

variable "key_group_name" {
  description = "Name of the key group. null: <bucket_name>-signers."
  type        = string
  default     = null
}

variable "origin_access_control_name" {
  description = "Name of the origin access control. null: <bucket_name>-oac."
  type        = string
  default     = null
}

variable "domain_name" {
  description = "A hostname for the downloads (its DNS is not managed here), or null for the CloudFront domain only. Set, it creates a certificate in us-east-1 and outputs its validation record."
  type        = string
  default     = null
  validation {
    condition     = var.domain_name == null || can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,}$", var.domain_name))
    error_message = "domain_name must be null or a lowercase hostname."
  }
}

variable "attach_domain" {
  description = "false: create the certificate but keep the default CloudFront domain. true: serve domain_name with that certificate. Set it only after the validation CNAME exists and the certificate is issued."
  type        = bool
  default     = false
}

variable "price_class" {
  description = "CloudFront price class."
  type        = string
  default     = "PriceClass_100"
  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "price_class must be PriceClass_100, PriceClass_200 or PriceClass_All."
  }
}

variable "noncurrent_version_days" {
  description = "Days a replaced or deleted object version is kept (versioning is on, for recovery)."
  type        = number
  default     = 180
  validation {
    condition     = var.noncurrent_version_days >= 1 && var.noncurrent_version_days <= 3650
    error_message = "noncurrent_version_days must be 1..3650."
  }
}

variable "tags" {
  description = "Tags for the bucket, the distribution and the certificate."
  type        = map(string)
  default     = {}
}
