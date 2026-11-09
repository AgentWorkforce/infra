locals {
  prefix = "${var.name}-${var.environment}"
  # Serverless VPC Access counts each hyphen twice and requires length <21.
  # Fixed 64-bit digest suffix keeps the full accepted prefix/environment in
  # the identity instead of truncating either into a colliding readable name.
  # "ar-" + 16 hex characters has 19 literal / 20 effective characters.
  connector_name = "ar-${substr(sha256(jsonencode([var.name, var.environment])), 0, 16)}"
  labels         = merge(var.labels, { environment = var.environment, managed-by = "terraform" })
  # IPv4 intervals allow offline overlap and RFC1918 checks without provider calls.
  ranges = { for k, c in var.network_ranges : k => {
    start = try(sum([for i, n in split(".", cidrhost(c, 0)) : tonumber(n) * pow(256, 3 - i)]), -1)
    end   = try(sum([for i, n in split(".", cidrhost(c, -1)) : tonumber(n) * pow(256, 3 - i)]), -1)
    bits  = try(tonumber(split("/", c)[1]), -1)
  } }
  rfc1918 = [
    { start = 167772160, end = 184549375 },
    { start = 2886729728, end = 2887778303 },
    { start = 3232235520, end = 3232301055 }
  ]
  wi_pool   = "${var.project_id}.svc.id.goog"
  wi_prefix = "principal://iam.googleapis.com/projects/${var.expected_project_number}/locations/global/workloadIdentityPools/${local.wi_pool}/subject"
}

data "google_project" "existing" {
  project_id = var.project_id
}

resource "terraform_data" "fence" {
  input = { project = var.project_id, number = var.expected_project_number, environment = var.environment }
  lifecycle {
    precondition {
      condition     = tostring(data.google_project.existing.number) == var.expected_project_number
      error_message = "STOP: project ID does not match the approved immutable project number."
    }
    precondition {
      condition     = var.environment == var.expected_environment
      error_message = "STOP: environment does not match the independently approved environment."
    }
    precondition {
      condition = alltrue([for r in values(local.ranges) : r.start >= 0 && r.bits >= 8 && r.bits <= 28 && anytrue([
        for private in local.rfc1918 : r.start >= private.start && r.end <= private.end
        ])]) && local.ranges.private_services.bits <= 24 && local.ranges.control_plane.bits == 28 && local.ranges.connector.bits == 28 && alltrue(flatten([
        for a, x in local.ranges : [for b, y in local.ranges : a == b || x.end < y.start || y.end < x.start]
      ]))
      error_message = "All six IPv4 ranges must be disjoint RFC1918 /8-/28 networks, with /28 control_plane and connector, and /24 or larger PSA. Also review external/peered range conflicts."
    }
  }
}

resource "google_compute_network" "this" {
  project                 = var.project_id
  name                    = local.prefix
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  depends_on              = [terraform_data.fence]
}

# Make the custom VPC ingress baseline explicit rather than relying only on
# Google's implied deny. GKE/connector generated allows use higher priorities
# (lower numbers); no application or operator allow rule is added here.
resource "google_compute_firewall" "deny_ingress" {
  project       = var.project_id
  name          = "${local.prefix}-deny-ingress"
  network       = google_compute_network.this.id
  description   = "Logged default-deny IPv4 ingress for the owned foundation VPC"
  direction     = "INGRESS"
  priority      = 65534
  source_ranges = ["0.0.0.0/0"]
  deny {
    protocol = "all"
  }
  log_config {
    metadata = "EXCLUDE_ALL_METADATA"
  }
}

resource "google_compute_subnetwork" "nodes" {
  project                  = var.project_id
  name                     = "${local.prefix}-nodes"
  region                   = var.region
  network                  = google_compute_network.this.id
  ip_cidr_range            = var.network_ranges.nodes
  private_ip_google_access = true
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.network_ranges.pods
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.network_ranges.services
  }
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "EXCLUDE_ALL_METADATA"
  }
}

resource "google_compute_global_address" "private_services" {
  project       = var.project_id
  name          = "${local.prefix}-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  address       = cidrhost(var.network_ranges.private_services, 0)
  prefix_length = tonumber(split("/", var.network_ranges.private_services)[1])
  network       = google_compute_network.this.id
}

resource "google_service_networking_connection" "private_services" {
  network                 = google_compute_network.this.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_services.name]
  # A foundation destroy must not disconnect still-owned Cloud SQL/Redis data.
  # Retirement must explicitly reconcile retained peering after all data is gone.
  deletion_policy = "ABANDON"
}

resource "google_compute_subnetwork" "connector" {
  count                    = var.create_connector ? 1 : 0
  project                  = var.project_id
  name                     = "${local.prefix}-connector"
  region                   = var.region
  network                  = google_compute_network.this.id
  ip_cidr_range            = var.network_ranges.connector
  private_ip_google_access = true
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "EXCLUDE_ALL_METADATA"
  }
}

resource "google_vpc_access_connector" "this" {
  count         = var.create_connector ? 1 : 0
  project       = var.project_id
  name          = local.connector_name
  region        = var.region
  machine_type  = "e2-micro"
  min_instances = 2
  max_instances = 3
  subnet {
    name       = google_compute_subnetwork.connector[0].name
    project_id = var.project_id
  }
}

resource "google_compute_router" "this" {
  count   = var.enable_nat ? 1 : 0
  project = var.project_id
  name    = "${local.prefix}-egress"
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  count                              = var.enable_nat ? 1 : 0
  project                            = var.project_id
  name                               = "${local.prefix}-egress"
  region                             = var.region
  router                             = google_compute_router.this[0].name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.nodes.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
  dynamic "subnetwork" {
    for_each = google_compute_subnetwork.connector
    content {
      name                    = subnetwork.value.id
      source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
    }
  }
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_service_account" "nodes" {
  project      = var.project_id
  account_id   = "${local.prefix}-nodes"
  display_name = "${local.prefix} GKE node identity (no workload data access)"
  depends_on   = [terraform_data.fence]
}

resource "google_project_iam_member" "nodes" {
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_project_iam_member" "registry" {
  for_each = var.node_image_registry_projects
  project  = each.value
  role     = "roles/artifactregistry.reader"
  member   = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_container_cluster" "this" {
  #checkov:skip=CKV_GCP_21:The pinned scanner cannot resolve the nested optional labels merge. Reserved environment/managed-by labels always override customer labels; mock plans assert the final map including override attempts.

  #checkov:skip=CKV_GCP_12:Dataplane V2 (ADVANCED_DATAPATH) enforces NetworkPolicy natively; the legacy Calico network_policy toggle is incompatible.
  #checkov:skip=CKV_GCP_65:Customer Google Group/Workspace authority is external; operator IAM and Kubernetes RBAC must be approved in application state.
  #checkov:skip=CKV_GCP_66:Binary Authorization attestors and project policy are external prerequisites, not invented by this foundation. Enable through a reviewed policy integration.

  project                     = var.project_id
  name                        = local.prefix
  location                    = var.region
  node_locations              = var.node_locations
  network                     = google_compute_network.this.id
  subnetwork                  = google_compute_subnetwork.nodes.id
  networking_mode             = "VPC_NATIVE"
  datapath_provider           = "ADVANCED_DATAPATH"
  min_master_version          = var.gke_version
  remove_default_node_pool    = true
  initial_node_count          = 1
  deletion_protection         = var.deletion_protection
  enable_shielded_nodes       = true
  enable_intranode_visibility = true
  enable_legacy_abac          = false
  resource_labels             = local.labels
  logging_service             = "logging.googleapis.com/kubernetes"
  monitoring_service          = "monitoring.googleapis.com/kubernetes"
  release_channel { channel = var.release_channel }
  workload_identity_config { workload_pool = local.wi_pool }
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = !var.public_api_enabled
    master_ipv4_cidr_block  = var.network_ranges.control_plane
    master_global_access_config { enabled = false }
  }
  master_authorized_networks_config {
    gcp_public_cidrs_access_enabled      = false
    private_endpoint_enforcement_enabled = true
    dynamic "cidr_blocks" {
      for_each = var.operator_cidrs
      content {
        display_name = cidr_blocks.key
        cidr_block   = cidr_blocks.value
      }
    }
  }
  master_auth {
    client_certificate_config { issue_client_certificate = false }
  }
  addons_config {
    gce_persistent_disk_csi_driver_config { enabled = true }
  }
  maintenance_policy {
    recurring_window {
      start_time = var.maintenance_window.start_time
      end_time   = var.maintenance_window.end_time
      recurrence = var.maintenance_window.recurrence
    }
  }
  # Even the temporary default pool must never use the Compute default identity.
  node_config {
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    image_type      = "COS_CONTAINERD"
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
    workload_metadata_config { mode = "GKE_METADATA" }
    metadata = { disable-legacy-endpoints = "true" }
  }
  depends_on = [google_project_iam_member.nodes, google_project_iam_member.registry, google_compute_firewall.deny_ingress]
}

locals {
  pools = merge({ system = {
    machine_type = var.node_capacity.machine_type
    total_min    = var.node_capacity.total_min
    total_max    = var.node_capacity.total_max
    locations    = var.node_locations
    sandbox      = false
    } }, var.actor_hosts.enabled ? { actors = {
    machine_type = var.actor_hosts.machine_type
    total_min    = var.actor_hosts.total_min
    total_max    = var.actor_hosts.total_max
    locations    = [var.actor_hosts.zone]
    sandbox      = true
  } } : {})
}

resource "google_container_node_pool" "this" {
  for_each           = local.pools
  project            = var.project_id
  name               = each.key
  cluster            = google_container_cluster.this.id
  location           = var.region
  node_locations     = each.value.locations
  initial_node_count = 1
  autoscaling {
    total_min_node_count = each.value.total_min
    total_max_node_count = each.value.total_max
  }
  management {
    auto_repair  = true
    auto_upgrade = true
  }
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }
  node_config {
    machine_type    = each.value.machine_type
    disk_size_gb    = 100
    disk_type       = "pd-balanced"
    image_type      = "COS_CONTAINERD"
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    metadata        = { disable-legacy-endpoints = "true" }
    labels          = { pool = each.key }
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
    workload_metadata_config { mode = "GKE_METADATA" }
    dynamic "sandbox_config" {
      for_each = each.value.sandbox ? [1] : []
      content { type = "GVISOR" }
    }
  }
}
