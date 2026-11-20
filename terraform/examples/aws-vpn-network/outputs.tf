output "vpn_network" {
  description = "Non-secret connector placement and fixed egress references. Nulls when disabled."
  value       = module.vpn_network
}
