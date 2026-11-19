# Network prerequisites for the agent-relay chart's internal-only GKE edge
# (gkeIngress.mode=internal): a regional internal Application Load Balancer
# that GKE creates from the Ingress. Nothing here is reachable from the
# internet, and nothing here opens a path from outside the VPC: reaching the
# address from an office or laptop needs your VPN or Interconnect routes.

locals {
  labels = merge(var.labels, { managed-by = "terraform" })
}

# Envoy proxies of regional load balancers take their addresses here. They
# are the source of every request the pods receive.
resource "google_compute_subnetwork" "proxy_only" {
  #checkov:skip=CKV_GCP_26:Flow logs are not supported on a proxy-only subnet (purpose REGIONAL_MANAGED_PROXY).
  #checkov:skip=CKV_GCP_74:Private Google Access does not apply to a proxy-only subnet; no workload runs in it.
  #checkov:skip=CKV_GCP_76:IPv4 only; no IPv6 access is configured on this subnet.
  count         = var.proxy_only_subnet.create ? 1 : 0
  project       = var.project_id
  region        = var.region
  name          = "${var.name}-proxy-only"
  network       = var.network
  ip_cidr_range = var.proxy_only_subnet.cidr
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

# The load balancer's private address (chart value gkeIngress.staticIpName).
resource "google_compute_address" "this" {
  project      = var.project_id
  region       = var.region
  name         = "${var.name}-internal"
  address_type = "INTERNAL"
  purpose      = "SHARED_LOADBALANCER_VIP"
  subnetwork   = var.subnetwork
  address      = var.address
  labels       = local.labels
}

# GKE opens the firewall for Google's health checks itself, but not for the
# proxy-only subnet. Without this rule every request times out at the proxy.
resource "google_compute_firewall" "proxy_only" {
  project                 = var.project_id
  name                    = "${var.name}-allow-proxy-only"
  network                 = var.network
  description             = "Internal load balancer proxies (proxy-only subnet) to the agent-relay pods"
  direction               = "INGRESS"
  priority                = 1000
  source_ranges           = [var.proxy_only_subnet.cidr]
  target_service_accounts = [var.node_service_account]
  allow {
    protocol = "tcp"
    ports    = var.backend_ports
  }
  log_config {
    metadata = "EXCLUDE_ALL_METADATA"
  }
  depends_on = [google_compute_subnetwork.proxy_only]
}
