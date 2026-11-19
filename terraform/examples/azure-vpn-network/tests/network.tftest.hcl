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
run "disabled_example" {
  command = plan
  variables { enabled = false }
  assert {
    condition     = output.vpn_network.egress_cidr == null && output.vpn_network.connector_subnet_id == null
    error_message = "The standalone root must preserve the module's disabled outputs."
  }
}
run "enabled_example" {
  command = apply
  assert {
    condition     = output.vpn_network.egress_cidr == "203.0.113.10/32" && output.vpn_network.connector_subnet_id != null
    error_message = "Opt-in must propagate through the standalone root and expose connector placement and static egress."
  }
}
