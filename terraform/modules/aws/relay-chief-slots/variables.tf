variable "slot_ids" {
  description = "Opaque slot identifiers, one host per id: slot- plus 8 to 32 lowercase letters or digits. Never embed a customer or chief name; the id appears in tags and ARNs."
  type        = set(string)

  validation {
    condition     = alltrue([for id in var.slot_ids : can(regex("^slot-[a-z0-9]{8,32}$", id))])
    error_message = "Each slot id must be slot- followed by 8 to 32 lowercase letters or digits."
  }
}

variable "vpc_id" {
  description = "VPC of the slot security group."
  type        = string
}

variable "subnet_id" {
  description = "Private subnet for every slot host. It must have outbound HTTPS (NAT or VPC endpoints); hosts get no public IP."
  type        = string
}

variable "kms_key_arn" {
  description = "Customer managed KMS key that encrypts the EBS volumes and the slot secrets. Its key policy must allow the operator to attach encrypted volumes and must delegate to IAM (or name the slot roles)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN."
  }
}

variable "ami_id" {
  description = "arm64 AMI id. Set exactly one of ami_id and ami_ssm_parameter. The AMI must provide systemd, the SSM agent, AWS CLI v2, python3 with sqlite3 and util-linux."
  type        = string
  default     = null

  validation {
    condition     = var.ami_id == null || can(regex("^ami-[0-9a-f]{8,17}$", var.ami_id))
    error_message = "ami_id must look like ami-0123456789abcdef0."
  }
}

variable "ami_ssm_parameter" {
  description = "SSM parameter name holding an arm64 AMI id, instead of ami_id. No default: choose the image deliberately."
  type        = string
  default     = null
}

variable "node_runtime" {
  description = "Node.js 24+ linux-arm64 tarball and its SHA-256. Installed at /usr/bin/node. Bootstrap fails if the checksum, architecture or major version is wrong."
  type = object({
    url    = string
    sha256 = string
  })

  validation {
    condition     = can(regex("^https://[A-Za-z0-9._~:/?#@%+=,&-]+$", var.node_runtime.url)) && can(regex("^[a-f0-9]{64}$", var.node_runtime.sha256))
    error_message = "node_runtime needs an https:// url without quotes or spaces and a lowercase hex sha256."
  }
}

variable "relay_chief_artifact" {
  description = "Self-contained relay-chief release tarball (dist/, node_modules/, package.json at the root) and its SHA-256, extracted to /opt/relay-chief. null leaves /opt/relay-chief empty, and binding a slot is refused until a build is installed. User data is ignored after creation, so setting this later shows no diff: each existing slot needs -replace."
  type = object({
    url    = string
    sha256 = string
  })
  default = null

  validation {
    condition     = var.relay_chief_artifact == null || (can(regex("^https://[A-Za-z0-9._~:/?#@%+=,&-]+$", try(var.relay_chief_artifact.url, ""))) && can(regex("^[a-f0-9]{64}$", try(var.relay_chief_artifact.sha256, ""))))
    error_message = "relay_chief_artifact needs an https:// url without quotes or spaces and a lowercase hex sha256."
  }
}

variable "name_prefix" {
  description = "Prefix of IAM and security group names."
  type        = string
  default     = "relay-chief"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,19}$", var.name_prefix))
    error_message = "name_prefix must be 1-20 lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "secret_name_prefix" {
  description = "Secrets Manager path of the slot secrets. Each slot reads only <prefix>/<slot id>. This module never creates the secrets or their values."
  type        = string
  default     = "relay-chief/slots"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9/_.-]*[A-Za-z0-9]$", var.secret_name_prefix))
    error_message = "secret_name_prefix may contain letters, digits, slashes, underscores, dots and hyphens."
  }
}

variable "instance_type" {
  description = "arm64 instance type, one of those the relay-chief provisioning contract admits."
  type        = string
  default     = "t4g.small"

  validation {
    condition     = contains(["t4g.small", "t4g.medium", "t4g.large"], var.instance_type)
    error_message = "instance_type must be t4g.small, t4g.medium or t4g.large."
  }
}

variable "root_volume_size_gb" {
  description = "Root volume size."
  type        = number
  default     = 20
}

variable "data_volume_size_gb" {
  description = "Data volume size. It holds the chief ledger at /var/lib/relay-chief."
  type        = number
  default     = 20
}

variable "egress_cidr_blocks" {
  description = "Destinations allowed for outbound HTTPS. The only other traffic is to VPC-provided DNS and time services, which security groups do not filter."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.egress_cidr_blocks) > 0 && alltrue([for c in var.egress_cidr_blocks : can(cidrhost(c, 0))])
    error_message = "egress_cidr_blocks must be a non-empty list of CIDR blocks."
  }
}

variable "iam_path" {
  description = "Path of the slot IAM roles and instance profiles."
  type        = string
  default     = "/"
}

variable "permissions_boundary_arn" {
  description = "Optional permissions boundary for the slot roles."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource. A relay:chief-slot key here is ignored; the module sets it per slot."
  type        = map(string)
  default     = {}
}
