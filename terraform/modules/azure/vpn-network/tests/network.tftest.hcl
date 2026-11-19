mock_provider "azurerm" {
  mock_data "azurerm_client_config" { defaults = { subscription_id = "00000000-0000-0000-0000-000000000001" } }
  mock_data "azurerm_virtual_network" {
    defaults = { location = "eastus2", address_space = ["10.60.0.0/16"] }
  }
  mock_resource "azurerm_subnet" { defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/vpn" } }
  mock_resource "azurerm_public_ip" { defaults = { ip_address = "203.0.113.10", id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg/providers/Microsoft.Network/publicIPAddresses/vpn" } }
  mock_resource "azurerm_nat_gateway" { defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg/providers/Microsoft.Network/natGateways/vpn" } }
  mock_resource "azurerm_network_security_group" { defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg/providers/Microsoft.Network/networkSecurityGroups/vpn" } }
}
variables {
  enabled              = true
  subscription_id      = "00000000-0000-0000-0000-000000000001"
  resource_group_name  = "rg"
  virtual_network_name = "vnet"
  connector_cidr       = "10.60.0.0/28"
  outbound_rules       = { vpn = { cidr = "203.0.113.9/32", protocol = "udp", port = 1194 } }
}
run "default_off" {
  command = plan
  variables { enabled = false }
  assert {
    condition     = length(azurerm_subnet.connector) == 0 && length(azurerm_public_ip.egress) == 0 && length(azurerm_nat_gateway.this) == 0 && length(azurerm_nat_gateway_public_ip_association.this) == 0 && length(azurerm_subnet_nat_gateway_association.this) == 0 && length(azurerm_network_security_group.connector) == 0 && length(azurerm_network_security_rule.outbound) == 0 && length(azurerm_network_security_rule.deny) == 0 && length(azurerm_subnet_network_security_group_association.this) == 0 && length(data.azurerm_client_config.this) == 0 && length(data.azurerm_virtual_network.this) == 0 && output.egress_cidr == null
    error_message = "Disabled must create nothing and perform no cloud data reads."
  }
}
run "dedicated_nat_and_default_denies" {
  command = apply
  assert {
    condition     = !azurerm_subnet.connector[0].default_outbound_access_enabled && azurerm_public_ip.egress[0].allocation_method == "Static" && azurerm_public_ip.egress[0].sku == "Standard" && azurerm_subnet_nat_gateway_association.this[0].subnet_id == azurerm_subnet.connector[0].id && azurerm_nat_gateway_public_ip_association.this[0].public_ip_address_id == azurerm_public_ip.egress[0].id && output.egress_cidr == "203.0.113.10/32"
    error_message = "Only the new connector subnet uses the explicit static NAT; no implicit Azure outbound access."
  }
  assert {
    condition     = azurerm_network_security_rule.deny["Inbound"].access == "Deny" && azurerm_network_security_rule.deny["Outbound"].priority < 65000 && azurerm_network_security_rule.outbound["vpn"].destination_address_prefix == "203.0.113.9/32" && azurerm_network_security_rule.outbound["vpn"].destination_port_range == "1194" && azurerm_network_security_rule.outbound["vpn"].protocol == "Udp" && azurerm_subnet_network_security_group_association.this[0].network_security_group_id == azurerm_network_security_group.connector[0].id
    error_message = "Explicit denies override Azure default VNet allow rules; only approved outbound destinations pass."
  }
}
run "wrong_subscription_refused" {
  command = plan
  variables { subscription_id = "00000000-0000-0000-0000-000000000099" }
  expect_failures = [terraform_data.guard]
}
run "outside_vnet_refused" {
  command = plan
  variables { connector_cidr = "10.61.0.0/28" }
  expect_failures = [terraform_data.guard]
}

run "routed_range_overlap_refused" {
  command = plan
  variables { existing_network_cidrs = ["10.60.0.0/24"] }
  expect_failures = [terraform_data.guard]
}
run "public_connector_refused" {
  command = plan
  variables { connector_cidr = "198.51.100.0/28" }
  expect_failures = [terraform_data.guard]
}
run "invalid_vpn_port_refused" {
  command = plan
  variables { outbound_rules = { bad = { cidr = "203.0.113.9/32", protocol = "udp", port = 0 } } }
  expect_failures = [var.outbound_rules]
}
