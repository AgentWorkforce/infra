output "connector_subnet_id" {
  description = "Private connector subnet; null while disabled."
  value       = try(aws_subnet.connector[0].id, null)
}
output "connector_security_group_id" {
  description = "Attach only this group to the customer-managed connector (no public IP, no inbound rules)."
  value       = try(aws_security_group.connector[0].id, null)
}
output "connector_route_table_id" {
  description = "Dedicated connector route table; existing workload route tables are not modified."
  value       = try(aws_route_table.connector[0].id, null)
}
output "egress_cidr" {
  description = "Stable outbound /32 for the edge's staff allowlist; null while disabled."
  value       = var.enabled ? "${aws_eip.egress[0].public_ip}/32" : null
}
