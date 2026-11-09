# Offline test fixture only: every provider below is mocked by composition.tftest.
terraform {
  required_version = ">= 1.11, < 2.0"
  required_providers {
    google = { source = "hashicorp/google", version = ">= 7.46.2, < 8.0" }
    random = { source = "hashicorp/random", version = ">= 3.7, < 4.0" }
  }
}
module "foundation" {
  source                  = "../.."
  project_id              = "example-project"
  expected_project_number = "123456789012"
  environment             = "development"
  expected_environment    = "development"
  name                    = "example"
  region                  = "us-central1"
  node_locations          = ["us-central1-a"]
  gke_version             = "1.34.1-gke.1000000"
  release_channel         = "STABLE"
  operator_cidrs          = { approved-vpn = "10.100.0.0/24" }
  maintenance_window = {
    start_time = "2030-01-05T00:00:00Z"
    end_time   = "2030-01-06T00:00:00Z"
    recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
  }
  network_ranges = {
    nodes            = "10.10.0.0/20"
    pods             = "10.20.0.0/16"
    services         = "10.30.0.0/20"
    control_plane    = "10.40.0.0/28"
    private_services = "10.50.0.0/16"
    connector        = "10.60.0.0/28"
  }
}
module "postgres" {
  source             = "../../../postgres"
  project_id         = module.foundation.identity.project_id
  region             = module.foundation.identity.region
  name               = "example-development-pg"
  network_self_link  = module.foundation.network.self_link
  allocated_ip_range = module.foundation.network.allocated_ip_range
  databases          = ["relaycontrol", "relayhistory", "hoopdb"]
  admin_user         = { create = false }
}
module "objects" {
  source      = "../../../object-storage"
  project_id  = module.foundation.identity.project_id
  location    = module.foundation.identity.region
  bucket_name = "example-development-sessions-offline-fixture"
  workload_identity = {
    workload_pool = module.foundation.workload_identity.workload_pool
    direct_kubernetes_service_accounts = [
      { namespace = "example", name = "worker" },
      { namespace = "example", name = "alleyoop" }
    ]
  }
}
module "functions" {
  source         = "../../../functions"
  project_id     = module.foundation.identity.project_id
  region         = module.foundation.identity.region
  name           = "example-development"
  bucket_name    = module.objects.bucket_name
  key_prefix     = "example"
  source_archive = { bucket = "example-offline-artifacts", object = "reviewed-function.zip" }
  vpc_connector  = module.foundation.network.functions_vpc_connector
  create_secret  = false
  secret_id      = "projects/example-project/secrets/existing-pipeline-reference"
  create_alerts  = false
}
output "contract" {
  description = "Only test fixture output references; no installer or live state composition."
  value = {
    foundation = module.foundation
    postgres   = module.postgres
    objects    = module.objects
    functions  = module.functions
  }
}
