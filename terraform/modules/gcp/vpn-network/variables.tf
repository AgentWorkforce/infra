variable "enabled" {
  description = "Explicit opt-in. False creates no resources or cloud data reads."
  type        = bool
  default     = false
}
variable "name" {
  description = "Unique resource prefix in the existing network."
  type        = string
  default     = "agent-relay"
  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,28}[a-z0-9])?$", var.name))
    error_message = "name must be a lowercase resource prefix of at most 30 characters."
  }
}
variable "connector_cidr" {
  description = "Unused RFC1918 IPv4 /28 for a customer-managed, outbound-initiated VPN connector."
  type        = string
  validation {
    condition     = can(cidrnetmask(var.connector_cidr)) && endswith(var.connector_cidr, "/28")
    error_message = "connector_cidr must be an IPv4 /28."
  }
}
variable "existing_network_cidrs" {
  description = "Existing node, pod, service, connector, peered and corporate ranges to check for overlap. Include every routed range, not the enclosing VPC/VNet address space."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for c in var.existing_network_cidrs : can(cidrnetmask(c))])
    error_message = "existing_network_cidrs must contain IPv4 CIDRs."
  }
}
variable "outbound_rules" {
  description = "Optional IPv4/port allow rules for the connector. Existing VPC policy controls egress unless enforce_deny_rules is explicitly enabled; provider-reserved metadata/DNS may bypass filters."
  type        = map(object({ cidr = string, protocol = string, port = number }))
  default     = {}
  validation {
    condition = length(var.outbound_rules) <= 100 && alltrue([
      for key in keys(var.outbound_rules) : can(regex("^[a-z]([a-z0-9-]{0,18}[a-z0-9])?$", key))
    ])
    error_message = "Use at most 100 outbound rules, with lowercase resource keys of at most 20 characters."
  }
  validation {
    condition = alltrue([for r in values(var.outbound_rules) :
      can(cidrnetmask(r.cidr)) && contains(["tcp", "udp"], r.protocol) && r.port >= 1 && r.port <= 65535 && floor(r.port) == r.port
    ])
    error_message = "Each outbound rule needs an IPv4 CIDR, tcp/udp and an integer port from 1 to 65535."
  }
}

variable "project_id" {
  description = "Existing approved GCP project ID."
  type        = string
}
variable "expected_project_number" {
  description = "Independently approved immutable project number."
  type        = string
}
variable "region" {
  description = "Region of the connector subnet and Cloud NAT."
  type        = string
}
variable "network_name" {
  description = "Existing VPC name; never creates or adopts a VPC."
  type        = string
}
variable "create_ingress_ip" {
  description = "Also reserve the external GKE Ingress IP; skip the guide's manual address creation or import it first."
  type        = bool
  default     = false
}
variable "allow_iap_ssh" {
  description = "Allow IAP TCP forwarding to port 22 on connector-tagged VMs; IAM and the VM remain operator-owned."
  type        = bool
  default     = false
}
variable "labels" {
  description = "Labels on supported resources. Subnets, routers, NAT and firewall rules do not support labels."
  type        = map(string)
  default     = {}
}

variable "enforce_deny_rules" {
  description = "Opt in to explicit 0.0.0.0/0 ingress/egress deny rules for connector-tagged VMs. Requires outbound_rules; false preserves the existing VPC/hierarchical policy for hosted VPN control planes."
  type        = bool
  default     = false
}
