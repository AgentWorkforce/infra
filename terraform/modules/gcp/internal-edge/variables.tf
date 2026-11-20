variable "project_id" {
  description = "Project of the GKE cluster and its VPC."
  type        = string
}

variable "region" {
  description = "Region of the GKE cluster. The internal load balancer, its address and the proxy-only subnet are regional."
  type        = string
}

variable "name" {
  description = "Name prefix: the address is <name>-internal, the proxy-only subnet <name>-proxy-only and the firewall rule <name>-allow-proxy-only."
  type        = string
  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,40}[a-z0-9])?$", var.name))
    error_message = "name must be 1-42 lowercase letters, digits or hyphens, beginning with a letter."
  }
}

variable "network" {
  description = "Self link or ID of the cluster's VPC network."
  type        = string
}

variable "subnetwork" {
  description = "Self link or ID of the subnet the load balancer's address is taken from, normally the cluster's node subnet."
  type        = string
}

variable "address" {
  description = "A specific unused address in subnetwork for the load balancer (null: Google picks one). DNS for every install host points at it."
  type        = string
  default     = null
}

variable "proxy_only_subnet" {
  description = "The VPC's proxy-only subnet for regional Envoy load balancers in this region. A VPC has one active proxy-only subnet per region: create = true makes it (cidr is a free RFC 1918 range, /26 or larger, /23 recommended); create = false uses one that already exists, and cidr is its range."
  type = object({
    create = optional(bool, true)
    cidr   = string
  })
  validation {
    condition     = can(cidrhost(var.proxy_only_subnet.cidr, 0)) && try(tonumber(split("/", var.proxy_only_subnet.cidr)[1]) <= 26, false) && can(regex("^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)", var.proxy_only_subnet.cidr))
    error_message = "proxy_only_subnet.cidr must be an RFC 1918 IPv4 range of /26 or larger."
  }
}

variable "node_service_account" {
  description = "Email of the service account the GKE nodes run as. The firewall rule lets the proxy-only subnet reach only instances running as it."
  type        = string
}

variable "backend_ports" {
  description = "TCP ports of the pods behind the Ingress, which the load balancer's proxies connect to: 3000 (control API), 8080 (dashboard, session read API, Relayfile, relaygate), 8081 (session ingest), 8787 (Relaycast) and 7100 (durable actors). Change it if you changed a server port in the values."
  type        = list(string)
  default     = ["3000", "7100", "8080", "8081", "8787"]
  validation {
    condition     = length(var.backend_ports) > 0 && alltrue([for p in var.backend_ports : can(regex("^[0-9]{1,5}(-[0-9]{1,5})?$", p))])
    error_message = "backend_ports are TCP ports or ranges, for example \"8080\" or \"8080-8081\"."
  }
}

variable "labels" {
  description = "Labels for the reserved address (the only resource here that takes labels). managed-by=terraform is always added."
  type        = map(string)
  default     = {}
}
