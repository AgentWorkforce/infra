# Separate foundation state. Configure an approved durable backend out of band.
# Uses ambient ADC / workload identity, never provider tokens in variables.
provider "google" {
  project = var.project_id
  region  = var.region
}
module "foundation" {
  source                       = "../../modules/gcp/foundation"
  project_id                   = var.project_id
  expected_project_number      = var.expected_project_number
  environment                  = var.environment
  expected_environment         = var.expected_environment
  name                         = var.name
  region                       = var.region
  node_locations               = var.node_locations
  network_ranges               = var.network_ranges
  operator_cidrs               = var.operator_cidrs
  public_api_enabled           = var.public_api_enabled
  gke_version                  = var.gke_version
  release_channel              = var.release_channel
  maintenance_window           = var.maintenance_window
  enable_nat                   = var.enable_nat
  create_connector             = var.create_connector
  node_capacity                = var.node_capacity
  actor_hosts                  = var.actor_hosts
  node_image_registry_projects = var.node_image_registry_projects
  pipeline                     = var.pipeline
  redis                        = var.redis
  deletion_protection          = var.deletion_protection
  labels                       = var.labels
}
