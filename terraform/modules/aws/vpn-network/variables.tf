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
  description = "Explicit IPv4 destinations and single TCP/UDP ports for the connector (VPN server, DNS, HTTPS edge, management). The module creates no outbound allow without a rule; provider-reserved metadata and DNS may bypass network filters."
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

variable "account_id" {
  description = "Independently approved target AWS account ID."
  type        = string
}
variable "vpc_id" {
  description = "Existing VPC that will contain the connector subnet."
  type        = string
}
variable "availability_zone" {
  description = "Connector and NAT subnet AZ; the existing public subnet must have an Internet Gateway route."
  type        = string
}
variable "nat_public_subnet_id" {
  description = "Existing public subnet for a dedicated NAT Gateway, in this VPC and AZ."
  type        = string
}
variable "tags" {
  description = "Tags applied to resources."
  type        = map(string)
  default     = {}
}
