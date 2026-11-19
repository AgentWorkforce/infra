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
run "default_off" {
  command = plan
  variables { enabled = false }
  assert {
    condition     = length(google_compute_subnetwork.connector) == 0 && length(google_compute_address.egress) == 0 && length(google_compute_router.this) == 0 && length(google_compute_router_nat.this) == 0 && length(google_compute_global_address.ingress) == 0 && length(google_compute_firewall.deny) == 0 && length(google_compute_firewall.outbound) == 0 && length(google_compute_firewall.iap) == 0 && length(data.google_project.this) == 0 && length(data.google_compute_network.this) == 0 && output.egress_cidr == null
    error_message = "Disabled must create nothing and perform no cloud data reads."
  }
}
run "dedicated_egress" {
  command = apply
  assert {
    condition     = google_compute_router_nat.this[0].nat_ip_allocate_option == "MANUAL_ONLY" && toset(google_compute_router_nat.this[0].nat_ips) == toset([google_compute_address.egress[0].self_link]) && google_compute_router_nat.this[0].source_subnetwork_ip_ranges_to_nat == "LIST_OF_SUBNETWORKS" && one(google_compute_router_nat.this[0].subnetwork).name == google_compute_subnetwork.connector[0].id
    error_message = "Only the new connector subnet can use the reserved NAT address."
  }
  assert {
    condition     = output.egress_cidr == "203.0.113.10/32" && length(google_compute_global_address.ingress) == 0 && length(google_compute_firewall.iap) == 0 && google_compute_firewall.deny["INGRESS"].priority > google_compute_firewall.outbound["vpn"].priority && toset(one(google_compute_firewall.outbound["vpn"].allow).ports) == toset(["1194"]) && toset(google_compute_firewall.outbound["vpn"].destination_ranges) == toset(["203.0.113.9/32"])
    error_message = "No ingress IP or SSH by default; only the approved VPN port/destination is allowed outbound."
  }
}
run "explicit_ingress_ip_and_iap" {
  command = apply
  variables {
    create_ingress_ip = true
    allow_iap_ssh     = true
  }
  assert {
    condition     = length(google_compute_global_address.ingress) == 1 && toset(google_compute_firewall.iap[0].source_ranges) == toset(["35.235.240.0/20"]) && toset(one(google_compute_firewall.iap[0].allow).ports) == toset(["22"]) && toset(google_compute_firewall.iap[0].target_tags) == toset([output.connector_network_tag])
    error_message = "Explicit IAP access targets only connector VMs, never public SSH."
  }
}
run "wrong_project_refused" {
  command = plan
  variables { expected_project_number = "999999999999" }
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
