variable "project_id" {
  description = "Approved existing project ID. No project, billing or organization resources are created."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "Supply an existing GCP project ID."
  }
}
variable "expected_project_number" {
  description = "Approved immutable project number, checked against Resource Manager before mutations."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{6,20}$", var.expected_project_number))
    error_message = "Supply the immutable numeric project number as a string."
  }
}
variable "environment" {
  description = "Environment label and resource-name suffix."
  type        = string
  validation {
    condition     = contains(["development", "staging", "production"], var.environment)
    error_message = "environment must be development, staging or production."
  }
}
variable "expected_environment" {
  description = "Independent reviewed environment fence; must equal environment."
  type        = string
}
variable "name" {
  description = "Installation prefix; environment is appended automatically."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,11}$", var.name))
    error_message = "name must be 1-12 lowercase letters, digits or hyphens, beginning with a letter."
  }
}
variable "region" {
  description = "Explicit regional GKE and managed-service location."
  type        = string
}
variable "node_locations" {
  description = "Explicit node zones in region; regional control plane does not imply application HA."
  type        = list(string)
  validation {
    condition     = length(var.node_locations) > 0 && length(distinct(var.node_locations)) == length(var.node_locations) && alltrue([for z in var.node_locations : startswith(z, "${var.region}-")])
    error_message = "Choose distinct node zones belonging to region."
  }
}
variable "network_ranges" {
  description = "Reviewed disjoint RFC1918 IPv4 ranges: nodes, pods, services, /28 control plane, PSA, /28 serverless connector. Must also avoid connected networks."
  type = object({
    nodes            = string
    pods             = string
    services         = string
    control_plane    = string
    private_services = string
    connector        = string
  })
}
variable "operator_cidrs" {
  description = "Explicit approved operator source IPv4 CIDRs (VPN/bastion/CI); required even for private API. No /0. These do not create a network path or grant Kubernetes RBAC."
  type        = map(string)
  validation {
    condition     = length(var.operator_cidrs) > 0 && alltrue([for c in values(var.operator_cidrs) : can(cidrnetmask(c)) && try(tonumber(split("/", c)[1]) >= 8, false)])
    error_message = "Supply approved IPv4 operator networks with /8 or narrower prefixes; public-wide /0 is forbidden."
  }
}
variable "public_api_enabled" {
  description = "Explicit opt-in to operator-CIDR-scoped public GKE API; default is private endpoint only."
  type        = bool
  default     = false
}
variable "gke_version" {
  description = "Explicit reviewed initial/minimum GKE version (x.y.z-gke.build); managed channel upgrades can advance it. No latest lookup."
  type        = string
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+-gke\\.[0-9]+$", var.gke_version))
    error_message = "Provide an exact region/channel-supported GKE version x.y.z-gke.build."
  }
}
variable "release_channel" {
  description = "Explicit GKE managed upgrade channel. Control plane and nodes advance; a version is not a permanent pin."
  type        = string
  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE", "EXTENDED"], var.release_channel)
    error_message = "Choose RAPID, REGULAR, STABLE or EXTENDED deliberately."
  }
}
variable "maintenance_window" {
  description = "Reviewed recurring GKE maintenance window (RFC3339 start/end, RFC5545 recurrence); GKE minimum availability requirements apply."
  type        = object({ start_time = string, end_time = string, recurrence = string })
}
variable "enable_nat" {
  description = "Reviewed internet egress through Cloud NAT for private nodes/connector. False permits Google API access but not arbitrary internet pulls or actor HTTPS egress."
  type        = bool
  default     = false
}
variable "create_connector" {
  description = "Create dedicated Serverless VPC Access connector for modules/gcp/functions."
  type        = bool
  default     = true
}
variable "node_capacity" {
  description = "Ordinary node pool total min/max across the selected zones; initial count is per zone. Size for all selected application resources and PVC constraints."
  type        = object({ machine_type = string, total_min = number, total_max = number })
  default     = { machine_type = "e2-standard-4", total_min = 3, total_max = 6 }
  validation {
    condition     = var.node_capacity.total_min >= 1 && var.node_capacity.total_max >= var.node_capacity.total_min && floor(var.node_capacity.total_min) == var.node_capacity.total_min && floor(var.node_capacity.total_max) == var.node_capacity.total_max
    error_message = "Require integer total_max >= total_min >= 1."
  }
}
variable "actor_hosts" {
  description = "Opt-in GCP Terse/durable-actors GKE Sandbox pool, not the EKS actor-host profile. Zone must match chart placement.zone. No multi-tenant or HA guarantee."
  type        = object({ enabled = optional(bool, false), zone = optional(string), machine_type = optional(string, "e2-standard-4"), total_min = optional(number, 1), total_max = optional(number, 3) })
  default     = {}
  validation {
    condition     = !var.actor_hosts.enabled || (try(contains(var.node_locations, var.actor_hosts.zone), false) && var.actor_hosts.total_min >= 1 && var.actor_hosts.total_max >= var.actor_hosts.total_min && floor(var.actor_hosts.total_min) == var.actor_hosts.total_min && floor(var.actor_hosts.total_max) == var.actor_hosts.total_max)
    error_message = "Enabled actor hosts need an explicit selected zone and integer total_max >= total_min >= 1."
  }
}
variable "node_image_registry_projects" {
  description = "Approved existing projects granting nodes Artifact Registry reader; no wildcard project-wide data/secret roles. Registry projects are explicit external inputs."
  type        = set(string)
  default     = []
}
variable "pipeline" {
  description = "Optional native pod pipeline pull queue, distinct from functions module GCS event topic; IAM is limited to supplied KSAs. No subscription is auto-consumed by the chart."
  type        = object({ enabled = optional(bool, false), publishers = optional(set(string), []), subscribers = optional(set(string), []), retention = optional(string, "604800s"), kms_key_name = optional(string) })
  default     = {}
  validation {
    condition     = alltrue([for k in setunion(var.pipeline.publishers, var.pipeline.subscribers) : can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?/[a-z0-9]([-a-z0-9]*[a-z0-9])?$", k))]) && can(regex("^[0-9]+s$", var.pipeline.retention)) && try(tonumber(trimsuffix(var.pipeline.retention, "s")) >= 600 && tonumber(trimsuffix(var.pipeline.retention, "s")) <= 2678400, false)
    error_message = "Use namespace/ksa identity subjects and retention between 600s and 2678400s."
  }
}
variable "redis" {
  description = "Optional managed TLS+AUTH Memorystore. Enabling requires explicit acknowledgment that the Google provider stores generated AUTH in state, including refresh. Prefer externally managed Redis when foundation state must contain no secrets."
  type        = object({ enabled = optional(bool, false), acknowledge_auth_in_state = optional(bool, false), version = optional(string), memory_size_gb = optional(number, 5), deletion_protection = optional(bool, true) })
  default     = {}
  validation {
    condition     = !var.redis.enabled || (var.redis.acknowledge_auth_in_state && can(regex("^REDIS_[0-9]+_[0-9]+$", var.redis.version)) && var.redis.memory_size_gb >= 5 && floor(var.redis.memory_size_gb) == var.redis.memory_size_gb)
    error_message = "Managed Redis requires acknowledgment of AUTH in state, an explicit REDIS_major_minor version, and integer memory >=5 GiB for TLS."
  }
}
variable "deletion_protection" {
  description = "GKE deletion protection. Disabling must be a separately approved retirement change applied before destroy; does not authorize deleting durable data."
  type        = bool
  default     = true
}
variable "labels" {
  description = "Additional non-secret labels; environment/managed-by are reserved."
  type        = map(string)
  default     = {}
}
