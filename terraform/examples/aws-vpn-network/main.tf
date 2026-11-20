provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]
}

module "vpn_network" {
  source = "../../modules/aws/vpn-network"

  enabled                = var.enabled
  name                   = var.name
  connector_cidr         = var.connector_cidr
  existing_network_cidrs = var.existing_network_cidrs
  outbound_rules         = var.outbound_rules
  account_id             = var.account_id
  vpc_id                 = var.vpc_id
  availability_zone      = var.availability_zone
  nat_public_subnet_id   = var.nat_public_subnet_id
  tags                   = var.tags
}
