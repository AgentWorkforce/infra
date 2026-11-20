provider "azurerm" {
  features {}
  subscription_id                 = var.subscription_id
  resource_provider_registrations = "none"
}

module "vpn_network" {
  source = "../../modules/azure/vpn-network"

  enabled                = var.enabled
  name                   = var.name
  connector_cidr         = var.connector_cidr
  existing_network_cidrs = var.existing_network_cidrs
  outbound_rules         = var.outbound_rules
  subscription_id        = var.subscription_id
  resource_group_name    = var.resource_group_name
  virtual_network_name   = var.virtual_network_name
  tags                   = var.tags
}
