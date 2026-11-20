mock_provider "google" {
  mock_data "google_project" { defaults = { number = "123456789012" } }
  mock_data "google_compute_network" { defaults = { id = "projects/proj/global/networks/vpc" } }
  mock_resource "google_compute_address" {
    defaults = { address = "203.0.113.10", self_link = "projects/proj/regions/us-central1/addresses/vpn" }
  }
}
variables {
  enabled                 = true
  project_id              = "proj"
  expected_project_number = "123456789012"
  region                  = "us-central1"
  network_name            = "vpc"
  connector_cidr          = "10.60.0.0/28"
  existing_network_cidrs  = ["10.10.0.0/24", "10.128.0.0/23"]
  outbound_rules          = { vpn = { cidr = "203.0.113.9/32", protocol = "udp", port = 1194 } }
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
