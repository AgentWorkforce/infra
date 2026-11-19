# Edge controls for the chart's GKE Ingress (modules/gcp/edge-security).
#
# The SSL policy (MODERN, TLS 1.2 minimum) is created by default and reaches
# the chart through chart_values (gkeIngress.sslPolicy): without one, the load
# balancer uses Google's default policy, which still accepts TLS 1.0 and 1.1.
# It is a free global resource and changes nothing until a Helm upgrade
# applies the regenerated managed-values.json; edge_ssl_policy.create = false
# opts out.
#
# The Cloud Armor policy is off by default (edge_security_policy.create).

module "edge_security" {
  source = "../../modules/gcp/edge-security"

  project_id           = var.project_id
  name                 = var.name
  labels               = var.labels
  ssl_policy           = var.edge_ssl_policy
  security_policy      = var.edge_security_policy
  origin_secret_header = var.edge_origin_secret_header
  max_subexpressions   = var.edge_max_subexpressions
  max_advanced_rules   = var.edge_max_advanced_rules
}
