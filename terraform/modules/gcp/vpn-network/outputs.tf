output "connector_subnet_id" {
  description = "New connector subnet ID, or null while disabled."
  value       = try(google_compute_subnetwork.connector[0].id, null)
}
output "connector_network_tag" {
  description = "Required network tag on the customer-owned connector VM (no external IP)."
  value       = var.enabled ? "${var.name}-vpn-connector" : null
}
output "egress_cidr" {
  description = "Stable outbound /32 for the edge's staff allowlist; null while disabled."
  value       = var.enabled ? "${google_compute_address.egress[0].address}/32" : null
}
output "ingress" {
  description = "Optional external GKE address; gkeIngress.staticIpName is name. Null unless explicitly created."
  value       = var.enabled && var.create_ingress_ip ? { name = google_compute_global_address.ingress[0].name, address = google_compute_global_address.ingress[0].address } : null
}
