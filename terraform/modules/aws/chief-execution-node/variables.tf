variable "name" {
  description = "Name of the host and its role, security group and secret. Keep it free of customer names."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,48}$", var.name))
    error_message = "name must be lowercase letters, digits and hyphens, up to 49 characters."
  }
}

variable "subnet_id" {
  description = "Private subnet for the host. It needs outbound HTTPS to AWS APIs, the Relay origin, GitHub and npm."
  type        = string
}

variable "kms_key_arn" {
  description = "Key for the root volume and the worker token secret. The key policy must delegate to IAM."
  type        = string
}

variable "ami_id" {
  description = "Exact x86_64 AMI id. Set exactly one of ami_id and ami_ssm_parameter."
  type        = string
  default     = null
}

variable "ami_ssm_parameter" {
  description = "SSM parameter naming an x86_64 Amazon Linux 2023 AMI. The image is read once: later releases do not replace the host."
  type        = string
  default     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

variable "instance_type" {
  description = "x86_64 instance type. The node, the bridge and each spawned harness share this host."
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size_gb" {
  description = "Root volume size in GiB. Holds the bridge ledger, the checkouts and the harness login."
  type        = number
  default     = 40

  validation {
    condition     = var.root_volume_size_gb >= 20
    error_message = "The bridge build and target checkouts need at least 20 GiB."
  }
}

variable "relay_base_url" {
  description = "Bare https origin of the Relay API. Set on the node so a workspace key can never go to the default public service."
  type        = string

  validation {
    condition     = can(regex("^https://[a-z0-9.-]+$", var.relay_base_url))
    error_message = "relay_base_url must be a bare https origin."
  }
}

variable "node_runtime" {
  description = "URL and SHA-256 of a Node.js 22.13+ linux-x64 tar.xz."
  type = object({
    url    = string
    sha256 = string
  })

  validation {
    condition     = startswith(var.node_runtime.url, "https://") && can(regex("^[a-f0-9]{64}$", var.node_runtime.sha256))
    error_message = "node_runtime needs an https URL and a lowercase SHA-256."
  }
}

variable "relay_node" {
  description = "URL and SHA-256 of the agent-relay-node linux-x64 release binary. Keep it in step with the bridge's core-bridge version."
  type = object({
    url    = string
    sha256 = string
  })

  validation {
    condition     = startswith(var.relay_node.url, "https://") && can(regex("^[a-f0-9]{64}$", var.relay_node.sha256))
    error_message = "relay_node needs an https URL and a lowercase SHA-256."
  }
}

variable "harness" {
  description = "npm package and exact version of the one harness this node runs."
  type = object({
    npm_package = string
    version     = string
  })

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.harness.version))
    error_message = "harness.version must be an exact release version."
  }
}

variable "bridge" {
  description = "Public git repository and full commit SHA the execution bridge is built from."
  type = object({
    repository = string
    commit     = string
  })

  validation {
    condition     = startswith(var.bridge.repository, "https://") && can(regex("^[a-f0-9]{40}$", var.bridge.commit))
    error_message = "bridge needs an https repository and a full 40-character commit SHA."
  }
}

variable "repositories" {
  description = "GitHub owner/name repositories checked out for spawned agents, under /var/lib/chief-node/repos/<name>. Public repositories only: the host holds no git credential."
  type        = list(string)

  validation {
    condition     = length(var.repositories) > 0 && alltrue([for r in var.repositories : can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", r))])
    error_message = "repositories must be a non-empty list of owner/name values."
  }
}

variable "egress_cidr_blocks" {
  description = "Destinations allowed for outbound HTTPS."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "iam_path" {
  description = "Path for the IAM role and instance profile."
  type        = string
  default     = "/"
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for the role, or null."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}
