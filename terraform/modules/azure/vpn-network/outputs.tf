output "connector_subnet_id" {
  description = "New connector subnet; attach the separately managed VPN VM without a public IP."
  value       = try(azurerm_subnet.connector[0].id, null)
}
output "connector_network_security_group_id" {
  description = "NSG allowing only configured outbound destinations, with explicit inbound/outbound denies."
  value       = try(azurerm_network_security_group.connector[0].id, null)
}
output "egress_cidr" {
  description = "Stable outbound /32 for the edge's staff allowlist; null while disabled."
  value       = var.enabled ? "${azurerm_public_ip.egress[0].ip_address}/32" : null
}
