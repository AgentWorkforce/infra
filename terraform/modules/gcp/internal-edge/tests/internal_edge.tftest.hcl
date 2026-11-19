mock_provider "google" {
  mock_resource "google_compute_address" {
    defaults = { address = "10.10.0.50" }
  }
}

variables {
  project_id           = "proj"
  region               = "us-central1"
  name                 = "relay"
  network              = "projects/proj/global/networks/vpc"
  subnetwork           = "projects/proj/regions/us-central1/subnetworks/nodes"
  node_service_account = "relay-nodes@proj.iam.gserviceaccount.com"
  proxy_only_subnet    = { cidr = "10.129.0.0/23" }
}

run "internal_edge_prerequisites" {
  command = apply

  assert {
    condition     = google_compute_subnetwork.proxy_only[0].purpose == "REGIONAL_MANAGED_PROXY" && google_compute_subnetwork.proxy_only[0].role == "ACTIVE" && google_compute_subnetwork.proxy_only[0].ip_cidr_range == "10.129.0.0/23" && google_compute_subnetwork.proxy_only[0].region == "us-central1"
    error_message = "The proxy-only subnet is a regional managed proxy subnet in the cluster's region."
  }
  assert {
    condition     = google_compute_address.this.address_type == "INTERNAL" && google_compute_address.this.purpose == "SHARED_LOADBALANCER_VIP" && google_compute_address.this.region == "us-central1" && google_compute_address.this.subnetwork == "projects/proj/regions/us-central1/subnetworks/nodes"
    error_message = "The address is regional and internal: never a global or external address."
  }
  assert {
    condition     = google_compute_address.this.labels["managed-by"] == "terraform"
    error_message = "The address carries the labels."
  }
  # The only allow rule: from the proxy-only subnet, to the nodes' identity, on the backend ports.
  assert {
    condition     = google_compute_firewall.proxy_only.direction == "INGRESS" && google_compute_firewall.proxy_only.source_ranges == toset(["10.129.0.0/23"]) && google_compute_firewall.proxy_only.target_service_accounts == toset(["relay-nodes@proj.iam.gserviceaccount.com"])
    error_message = "The firewall rule admits only the proxy-only subnet, only to instances running as the node service account."
  }
  assert {
    condition     = one(google_compute_firewall.proxy_only.allow).protocol == "tcp" && toset(one(google_compute_firewall.proxy_only.allow).ports) == toset(["3000", "7100", "8080", "8081", "8787"])
    error_message = "Only the backend TCP ports are opened."
  }
  assert {
    condition     = output.chart_values.gkeIngress.mode == "internal" && output.chart_values.gkeIngress.staticIpName == "relay-internal" && output.chart_values.gkeIngress.internal.proxyOnlySubnetCidr == "10.129.0.0/23" && output.address == "10.10.0.50"
    error_message = "Outputs feed the chart's internal mode."
  }
}

run "existing_proxy_only_subnet" {
  command = apply
  variables {
    proxy_only_subnet = { create = false, cidr = "10.200.0.0/24" }
  }

  assert {
    condition     = length(google_compute_subnetwork.proxy_only) == 0 && google_compute_firewall.proxy_only.source_ranges == toset(["10.200.0.0/24"]) && output.proxy_only_subnet_cidr == "10.200.0.0/24"
    error_message = "An existing proxy-only subnet is used by its range, not created again."
  }
}

run "public_range_refused" {
  command = plan
  variables {
    proxy_only_subnet = { cidr = "203.0.113.0/24" }
  }
  expect_failures = [var.proxy_only_subnet]
}

run "too_small_range_refused" {
  command = plan
  variables {
    proxy_only_subnet = { cidr = "10.129.0.0/28" }
  }
  expect_failures = [var.proxy_only_subnet]
}
