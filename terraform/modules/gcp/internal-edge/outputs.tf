output "static_ip_name" {
  description = "Chart value gkeIngress.staticIpName."
  value       = google_compute_address.this.name
}

output "address" {
  description = "The load balancer's private address. Point the DNS records of every install host at it, in a zone your VPN clients resolve."
  value       = google_compute_address.this.address
}

output "proxy_only_subnet_cidr" {
  description = "Chart value gkeIngress.internal.proxyOnlySubnetCidr, and the range to add to every backend's networkPolicy (values-gcp-internal.yaml)."
  value       = var.proxy_only_subnet.cidr
}

output "chart_values" {
  description = "The gkeIngress keys for internal mode. Add the certificate (gkeIngress.tlsSecretName or internal.preSharedCerts) and the NetworkPolicy lists from values-gcp-internal.yaml."
  value = { gkeIngress = {
    mode         = "internal"
    staticIpName = google_compute_address.this.name
    internal     = { proxyOnlySubnetCidr = var.proxy_only_subnet.cidr }
  } }
}
