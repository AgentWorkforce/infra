output "ssl_policy_name" {
  description = "Chart value gkeIngress.sslPolicy. Null when ssl_policy.create is false."
  value       = try(google_compute_ssl_policy.this[0].name, null)
}

output "security_policy_name" {
  description = "Chart value gkeIngress.securityPolicy. Null when security_policy.create is false."
  value       = try(google_compute_security_policy.this[0].name, null)
}

output "chart_values" {
  description = "The gkeIngress keys to merge into the agent-relay values. With securityPolicy, also set the backend-config annotation the chart names on the relay-webapp (and relayfile) Service."
  value = { gkeIngress = merge(
    var.ssl_policy.create ? { sslPolicy = google_compute_ssl_policy.this[0].name } : {},
    local.armor ? { securityPolicy = google_compute_security_policy.this[0].name } : {},
  ) }
}

output "client_ip_header" {
  description = "Header Cloud Armor reads the client address from (null: the connecting address). When set there is one more proxy in front of the load balancer: raise relay-control.auth.trustedProxies by one."
  value       = local.armor ? local.client_ip_header : null
}
