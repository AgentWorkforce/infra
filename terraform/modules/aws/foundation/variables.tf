variable "account_id" {
  description = "Exact existing target account; independently checked against the caller."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Invalid account_id; see the input contract."
  }
}

variable "region" {
  description = "Explicit AWS commercial region."
  type        = string
  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.region))
    error_message = "Invalid region; see the input contract."
  }
}

variable "environment" {
  description = "Environment slug shared with the data root."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9]*(-[a-z0-9]+)*$", var.environment)) && length(var.environment) <= 16
    error_message = "Invalid environment; see the input contract."
  }
}

variable "name_prefix" {
  description = "Product prefix; combined name must fit the data-layer contract."
  type        = string
  default     = "agent-relay"
  validation {
    condition     = can(regex("^[a-z][a-z0-9]*(-[a-z0-9]+)*$", var.name_prefix))
    error_message = "Invalid name_prefix; see the input contract."
  }
}

variable "kubernetes_version" {
  description = "Required region-supported EKS minor version, verified by the execution plan. No latest default."
  type        = string
  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version))
    error_message = "Invalid kubernetes_version; see the input contract."
  }
}

variable "addon_versions" {
  description = "Explicit compatible versions for vpc-cni, kube-proxy, coredns, eks-pod-identity-agent and aws-ebs-csi-driver."
  type        = map(string)
  validation {
    condition     = toset(keys(var.addon_versions)) == toset(["vpc-cni", "kube-proxy", "coredns", "eks-pod-identity-agent", "aws-ebs-csi-driver"]) && alltrue([for v in values(var.addon_versions) : can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+-eksbuild\\.[0-9]+$", v))])
    error_message = "Invalid addon_versions; see the input contract."
  }
}

variable "vpc_cidr" {
  description = "Non-overlapping IPv4 VPC range approved by the operator."
  type        = string
  default     = "10.80.0.0/16"
  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && try(tonumber(split("/", var.vpc_cidr)[1]) >= 16 && tonumber(split("/", var.vpc_cidr)[1]) <= 28, false)
    error_message = "Invalid vpc_cidr; see the input contract."
  }
}

variable "subnets" {
  description = "Two or three unique AZ names mapped to non-overlapping public/private CIDRs within the VPC."
  type        = map(object({ public_cidr = string, private_cidr = string }))
  validation {
    condition     = length(var.subnets) >= 2 && length(var.subnets) <= 3 && alltrue([for s in values(var.subnets) : can(cidrnetmask(s.public_cidr)) && can(cidrnetmask(s.private_cidr))])
    error_message = "Invalid subnets; see the input contract."
  }
}

variable "search_az_count" {
  description = "Number of private AZs exported to OpenSearch: 1, 2 or 3."
  type        = number
  default     = 2
  validation {
    condition     = contains([1, 2, 3], var.search_az_count)
    error_message = "Invalid search_az_count; see the input contract."
  }
}

variable "actor_availability_zone" {
  description = "Single approved actor-host AZ, matching durable-actors placement.zone; no HA claim."
  type        = string
}

variable "public_api_enabled" {
  description = "Opt in to public EKS API only with explicit bounded operator CIDRs."
  type        = bool
  default     = false
}

variable "operator_cidrs" {
  description = "Approved IPv4 operator networks; private reachability is still required by default. Public API requires /8 or narrower."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for c in var.operator_cidrs : can(cidrnetmask(c)) && try(tonumber(split("/", c)[1]) >= 8, false)])
    error_message = "Invalid operator_cidrs; see the input contract."
  }
}

variable "operator_security_group_ids" {
  description = "Existing operator/proof-runner SGs in this VPC or connected networks; only API HTTPS ingress is granted."
  type        = set(string)
  default     = []
}

variable "operator_role_arns" {
  description = "Existing same-account IAM operator roles granted EKS cluster-admin access explicitly; no implicit creator admin."
  type        = set(string)
  validation {
    condition     = length(var.operator_role_arns) > 0 && alltrue([for a in var.operator_role_arns : can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", a))])
    error_message = "Invalid operator_role_arns; see the input contract."
  }
}

variable "kms_key_arn" {
  description = "Existing durable same-account/region symmetric KMS key for cluster secrets, logs and EBS; key policy/grants are external."
  type        = string
  validation {
    condition     = can(regex("^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", var.kms_key_arn))
    error_message = "Invalid kms_key_arn; see the input contract."
  }
}

variable "instance_type" {
  description = "Region-supported x86_64 AL2023 general node instance type."
  type        = string
  default     = "m6i.large"
}

variable "actor_instance_type" {
  description = "Region-supported x86_64 first-party actor-host node instance type."
  type        = string
  default     = "m6i.large"
}

variable "node_ami_release_version" {
  description = "Explicit compatible AL2023 x86_64 EKS AMI release, pinned by execution packet."
  type        = string
  validation {
    condition     = length(trimspace(var.node_ami_release_version)) > 0
    error_message = "Invalid node_ami_release_version; see the input contract."
  }
}

variable "capacity" {
  description = "General managed-node sizing; node count alone does not provide application HA."
  type        = object({ min = number, desired = number, max = number })
  default     = { min = 2, desired = 2, max = 4 }
  validation {
    condition     = var.capacity.min >= 1 && var.capacity.min <= var.capacity.desired && var.capacity.desired <= var.capacity.max && alltrue([for n in [var.capacity.min, var.capacity.desired, var.capacity.max] : floor(n) == n])
    error_message = "Invalid capacity; see the input contract."
  }
}

variable "actor_capacity" {
  description = "Dedicated first-party actor managed-node sizing; single AZ."
  type        = object({ min = number, desired = number, max = number })
  default     = { min = 1, desired = 1, max = 2 }
  validation {
    condition     = var.actor_capacity.min >= 1 && var.actor_capacity.min <= var.actor_capacity.desired && var.actor_capacity.desired <= var.actor_capacity.max && alltrue([for n in [var.actor_capacity.min, var.actor_capacity.desired, var.actor_capacity.max] : floor(n) == n])
    error_message = "Invalid actor_capacity; see the input contract."
  }
}

variable "namespace" {
  description = "Application namespace reference only; null exports agent-relay-environment."
  type        = string
  default     = null
  validation {
    condition     = var.namespace == null ? true : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.namespace))
    error_message = "Invalid namespace; see the input contract."
  }
}

variable "release_name" {
  description = "Helm release reference used for ServiceAccount names; creates no Kubernetes objects."
  type        = string
  default     = "agent-relay"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,39}$", var.release_name))
    error_message = "Invalid release_name; see the input contract."
  }
}

variable "pippen" {
  description = "Expected allocated lease agent/session from Pippen; exact STS session caller is enforced. No credentials."
  type        = object({ agent = string, session_id = string })
  default     = null
  validation {
    condition     = var.pippen == null ? true : (length(trimspace(var.pippen.agent)) > 0 && can(regex("^[a-zA-Z0-9-]+$", var.pippen.session_id)))
    error_message = "Invalid pippen; see the input contract."
  }
}

variable "tags" {
  description = "Additional tags; reserved environment/Pippen identity cannot be overridden."
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for k in keys(var.tags) : !startswith(k, "pippen:") && !contains(["Environment", "ManagedBy", "Name"], k)])
    error_message = "Invalid tags; see the input contract."
  }
}

variable "deletion_protection" {
  description = "EKS API deletion protection; disable only through a reviewed retirement change."
  type        = bool
  default     = true
}

variable "enable_load_balancer_controller" {
  description = "Create the AWS Load Balancer Controller IAM policy, role and Pod Identity association; the Helm release stays external."
  type        = bool
  default     = false
}
