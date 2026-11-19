provider "google" {
  project = var.project_id
  region  = var.region
}

module "vpn_network" {
  source = "../../modules/gcp/vpn-network"

  enabled                 = var.enabled
  name                    = var.name
  connector_cidr          = var.connector_cidr
  existing_network_cidrs  = var.existing_network_cidrs
  outbound_rules          = var.outbound_rules
  project_id              = var.project_id
  expected_project_number = var.expected_project_number
  region                  = var.region
  network_name            = var.network_name
  create_ingress_ip       = var.create_ingress_ip
  allow_iap_ssh           = var.allow_iap_ssh
  labels                  = var.labels
}
