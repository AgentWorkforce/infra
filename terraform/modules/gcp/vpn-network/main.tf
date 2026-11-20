locals {
  # Compare whole intervals, not just network addresses, including nested ranges.
  ranges = { for key, cidr in merge({ connector = var.connector_cidr }, {
    for i, cidr in var.existing_network_cidrs : "existing-${i}" => cidr
    }) : key => {
    first = sum([for i, octet in split(".", cidrhost(cidr, 0)) : tonumber(octet) * pow(256, 3 - i)])
    last  = sum([for i, octet in split(".", cidrhost(cidr, -1)) : tonumber(octet) * pow(256, 3 - i)])
  } }
  private_ranges = [
    { first = 167772160, last = 184549375 },
    { first = 2886729728, last = 2887778303 },
    { first = 3232235520, last = 3232301055 }
  ]
  private_connector = anytrue([for r in local.private_ranges : local.ranges.connector.first >= r.first && local.ranges.connector.last <= r.last])
  no_overlap = alltrue([for key, r in local.ranges : key == "connector" ||
    local.ranges.connector.last < r.first || local.ranges.connector.first > r.last
  ])
}

data "google_project" "this" {
  count      = var.enabled ? 1 : 0
  project_id = var.project_id
}
data "google_compute_network" "this" {
  count   = var.enabled ? 1 : 0
  project = var.project_id
  name    = var.network_name
}
resource "terraform_data" "guard" {
  count = var.enabled ? 1 : 0
  input = var.connector_cidr
  lifecycle {
    precondition {
      condition     = tostring(data.google_project.this[0].number) == var.expected_project_number
      error_message = "Project ID does not match the independently approved project number."
    }
    precondition {
      condition     = !var.enforce_deny_rules || length(var.outbound_rules) > 0
      error_message = "Explicit deny rules require a non-empty reviewed outbound_rules map; hosted VPN FQDNs may need operator-owned egress policy instead."
    }
    precondition {
      condition     = local.private_connector && local.no_overlap
      error_message = "The connector must use unused RFC1918 space, disjoint from every supplied routed range."
    }
  }
}
resource "google_compute_subnetwork" "connector" {
  count                    = var.enabled ? 1 : 0
  project                  = var.project_id
  name                     = "${var.name}-vpn-connector"
  region                   = var.region
  network                  = data.google_compute_network.this[0].id
  ip_cidr_range            = var.connector_cidr
  private_ip_google_access = true
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "EXCLUDE_ALL_METADATA"
  }
  depends_on = [terraform_data.guard]
}
resource "google_compute_address" "egress" {
  count        = var.enabled ? 1 : 0
  project      = var.project_id
  name         = "${var.name}-vpn-egress"
  region       = var.region
  address_type = "EXTERNAL"
  labels       = merge(var.labels, { managed-by = "terraform" })
  depends_on   = [terraform_data.guard]
}
resource "google_compute_router" "this" {
  count      = var.enabled ? 1 : 0
  project    = var.project_id
  name       = "${var.name}-vpn"
  region     = var.region
  network    = data.google_compute_network.this[0].id
  depends_on = [terraform_data.guard]
}
resource "google_compute_router_nat" "this" {
  count                              = var.enabled ? 1 : 0
  project                            = var.project_id
  name                               = "${var.name}-vpn-egress"
  region                             = var.region
  router                             = google_compute_router.this[0].name
  nat_ip_allocate_option             = "MANUAL_ONLY"
  nat_ips                            = [google_compute_address.egress[0].self_link]
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.connector[0].id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
resource "google_compute_global_address" "ingress" {
  count      = var.enabled && var.create_ingress_ip ? 1 : 0
  project    = var.project_id
  name       = "${var.name}-ingress"
  labels     = merge(var.labels, { managed-by = "terraform" })
  depends_on = [terraform_data.guard]
}
resource "google_compute_firewall" "outbound" {
  for_each           = var.enabled ? var.outbound_rules : {}
  project            = var.project_id
  name               = "${var.name}-vpn-out-${each.key}"
  network            = data.google_compute_network.this[0].id
  direction          = "EGRESS"
  priority           = 100
  target_tags        = ["${var.name}-vpn-connector"]
  destination_ranges = [each.value.cidr]
  allow {
    protocol = each.value.protocol
    ports    = [tostring(each.value.port)]
  }
  log_config { metadata = "EXCLUDE_ALL_METADATA" }
  depends_on = [terraform_data.guard]
}
resource "google_compute_firewall" "deny" {
  for_each           = var.enabled && var.enforce_deny_rules ? toset(["INGRESS", "EGRESS"]) : toset([])
  project            = var.project_id
  name               = "${var.name}-vpn-deny-${lower(each.key)}"
  network            = data.google_compute_network.this[0].id
  direction          = each.key
  priority           = 200
  target_tags        = ["${var.name}-vpn-connector"]
  source_ranges      = each.key == "INGRESS" ? ["0.0.0.0/0"] : null
  destination_ranges = each.key == "EGRESS" ? ["0.0.0.0/0"] : null
  deny { protocol = "all" }
  log_config { metadata = "EXCLUDE_ALL_METADATA" }
  depends_on = [terraform_data.guard]
}
resource "google_compute_firewall" "iap" {
  count         = var.enabled && var.allow_iap_ssh ? 1 : 0
  project       = var.project_id
  name          = "${var.name}-vpn-iap-ssh"
  network       = data.google_compute_network.this[0].id
  direction     = "INGRESS"
  priority      = 100
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["${var.name}-vpn-connector"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  log_config { metadata = "EXCLUDE_ALL_METADATA" }
  depends_on = [terraform_data.guard]
}
