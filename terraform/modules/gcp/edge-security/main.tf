# Edge controls for the GKE Ingress of the agent-relay chart: the TLS policy of
# the HTTPS listener and an optional Cloud Armor policy for every backend. Both
# are global Compute resources the chart refers to by name
# (gkeIngress.sslPolicy, gkeIngress.securityPolicy); GKE attaches them.

locals {
  labels = merge(var.labels, { managed-by = "terraform" })
  sp     = var.security_policy
  armor  = local.sp.create
  # Whether the header is configured is not secret; its value is.
  secret_header = nonsensitive(var.origin_secret_header != null)

  # Addresses allowed to connect to the load balancer. Any entry turns the
  # default rule into deny.
  cloudflare_cidrs = local.sp.cloudflare.enabled ? concat(local.sp.cloudflare.ipv4_cidrs, local.sp.cloudflare.include_ipv6 ? local.sp.cloudflare.ipv6_cidrs : []) : []
  allowlist        = distinct(concat(local.sp.source_ip_allowlist, local.cloudflare_cidrs))
  locked           = length(local.allowlist) > 0
  # Basic rules take 10 ranges each; expressions take five subexpressions, so
  # an allowlist conjoined with a path match is cut into groups of four.
  allow_rules  = chunklist(local.allowlist, 10)
  allow_groups = chunklist(local.allowlist, 4)

  client_ip_header = local.sp.client_ip_header != null ? local.sp.client_ip_header : (local.sp.cloudflare.enabled ? "CF-Connecting-IP" : null)

  waf_groups = local.sp.waf.enabled ? chunklist(local.sp.waf.rules, 5) : []

  # One throttle rule per rate limit, or one per allowlist group when the
  # edge is locked: a throttle rule admits conforming requests, so it must
  # itself require an allowed connecting address.
  rate_rules = merge([for i, r in local.sp.rate_limits : {
    for j, group in(local.locked ? local.allow_groups : [[]]) : "${r.name}-${j}" => {
      priority   = 3000 + i * 100 + j
      limit      = r
      expression = join(" && ", compact(["request.path.matches('${r.path_regex}')", length(group) > 0 ? "(${join(" || ", [for c in group : "inIpRange(origin.ip, '${c}')"])})" : ""]))
    }
  }]...)

  # client_ip_rules: admit the listed client addresses on the paths, then
  # deny everything else on those paths.
  client_rules = merge([for i, r in local.sp.client_ip_rules : merge({
    for j, group in chunklist(r.cidrs, 4) : "${r.name}-allow-${j}" => {
      priority    = 2000 + i * 100 + j
      action      = "allow"
      description = "${r.name}: listed client addresses on ${join(", ", r.path_prefixes)}"
      expression  = "${local.path_match[r.name]} && (${join(" || ", [for c in group : "inIpRange(origin.user_ip, '${c}')"])})"
    }
    }, { "${r.name}-deny" = {
      priority    = 2000 + i * 100 + 99
      action      = "deny(403)"
      description = "${r.name}: any other client on ${join(", ", r.path_prefixes)}"
      expression  = local.path_match[r.name]
  } })]...)
  path_match = { for r in local.sp.client_ip_rules : r.name => "request.path.matches('^(${join("|", [for p in r.path_prefixes : replace(p, ".", "\\\\.")])})')" }
}

resource "google_compute_ssl_policy" "this" {
  #checkov:skip=CKV_GCP_4:The scanner cannot resolve the profile and minimum version from variables. var.ssl_policy only validates MODERN or RESTRICTED with TLS 1.2 or 1.3, and the module tests assert the applied values.
  count           = var.ssl_policy.create ? 1 : 0
  project         = var.project_id
  name            = "${var.name}-tls"
  description     = "agent-relay GKE Ingress: ${var.ssl_policy.profile}, minimum ${var.ssl_policy.min_tls_version}"
  profile         = var.ssl_policy.profile
  min_tls_version = var.ssl_policy.min_tls_version
}

resource "google_compute_security_policy" "this" {
  #checkov:skip=CKV_GCP_73:The check looks for an inline cve-canary rule. Rules here are google_compute_security_policy_rule resources, and the default waf.rules include cve-canary (asserted in the module tests).
  count       = local.armor ? 1 : 0
  project     = var.project_id
  name        = "${var.name}-edge"
  description = "agent-relay GKE Ingress backends"
  type        = "CLOUD_ARMOR"
  labels      = local.labels

  advanced_options_config {
    json_parsing            = "STANDARD"
    log_level               = "NORMAL"
    user_ip_request_headers = local.client_ip_header != null ? [local.client_ip_header] : []
  }
  dynamic "adaptive_protection_config" {
    for_each = local.sp.adaptive_protection ? [1] : []
    content {
      layer_7_ddos_defense_config { enable = true }
    }
  }

  lifecycle {
    precondition {
      condition     = length(local.sp.client_ip_rules) == 0 || (local.secret_header && local.client_ip_header != null)
      error_message = "client_ip_rules trust a client-address header, so they need origin_secret_header (proof the request came through the proxy) and client_ip_header or cloudflare.enabled."
    }
    precondition {
      condition     = local.client_ip_header == null || local.locked || local.secret_header
      error_message = "client_ip_header is only trustworthy when direct connections are refused: set cloudflare.enabled, source_ip_allowlist (the proxy's ranges) or origin_secret_header."
    }
  }
}

resource "google_compute_security_policy_rule" "origin_secret" {
  count           = local.armor && local.secret_header ? 1 : 0
  project         = var.project_id
  security_policy = google_compute_security_policy.this[0].name
  priority        = 100
  action          = "deny(403)"
  description     = "Requests without the fronting proxy's shared-secret header"
  match {
    expr {
      # One subexpression for the missing header and one per accepted value.
      expression = "!has(request.headers['${var.origin_secret_header.name}']) || !(${join(" || ", [for v in var.origin_secret_header.values : "request.headers['${var.origin_secret_header.name}'] == '${v}'"])})"
    }
  }
}

resource "google_compute_security_policy_rule" "waf" {
  for_each        = local.armor ? { for i, group in local.waf_groups : tostring(i) => group } : {}
  project         = var.project_id
  security_policy = google_compute_security_policy.this[0].name
  priority        = 1000 + tonumber(each.key)
  action          = "deny(403)"
  preview         = local.sp.waf.preview
  description     = "OWASP preconfigured rules, sensitivity ${local.sp.waf.sensitivity}: ${join(", ", each.value)}"
  match {
    expr {
      expression = join(" || ", [for r in each.value : "evaluatePreconfiguredWaf('${r}', {'sensitivity': ${local.sp.waf.sensitivity}})"])
    }
  }
}

resource "google_compute_security_policy_rule" "client_ip" {
  for_each        = local.armor ? local.client_rules : {}
  project         = var.project_id
  security_policy = google_compute_security_policy.this[0].name
  priority        = each.value.priority
  action          = each.value.action
  description     = each.value.description
  match {
    expr { expression = each.value.expression }
  }
  depends_on = [google_compute_security_policy_rule.origin_secret]
}

resource "google_compute_security_policy_rule" "rate_limit" {
  for_each        = local.armor ? local.rate_rules : {}
  project         = var.project_id
  security_policy = google_compute_security_policy.this[0].name
  priority        = each.value.priority
  action          = each.value.limit.ban_duration_sec > 0 ? "rate_based_ban" : "throttle"
  description     = "Per-client rate limit ${each.value.limit.name}: ${each.value.limit.count} requests per ${each.value.limit.interval_sec}s"
  match {
    expr { expression = each.value.expression }
  }
  rate_limit_options {
    conform_action   = "allow"
    exceed_action    = "deny(429)"
    enforce_on_key   = local.client_ip_header != null ? "USER_IP" : "IP"
    ban_duration_sec = each.value.limit.ban_duration_sec > 0 ? each.value.limit.ban_duration_sec : null
    rate_limit_threshold {
      count        = each.value.limit.count
      interval_sec = each.value.limit.interval_sec
    }
  }
}

resource "google_compute_security_policy_rule" "allowlist" {
  for_each        = local.armor ? { for i, group in local.allow_rules : tostring(i) => group } : {}
  project         = var.project_id
  security_policy = google_compute_security_policy.this[0].name
  priority        = 9000 + tonumber(each.key)
  action          = "allow"
  description     = "Allowed connecting addresses (${local.sp.cloudflare.enabled ? "Cloudflare and " : ""}source_ip_allowlist)"
  match {
    versioned_expr = "SRC_IPS_V1"
    config { src_ip_ranges = each.value }
  }
}

# The rule Cloud Armor evaluates last. Deny when an allowlist is in force.
resource "google_compute_security_policy_rule" "default" {
  count           = local.armor ? 1 : 0
  project         = var.project_id
  security_policy = google_compute_security_policy.this[0].name
  priority        = 2147483647
  action          = local.locked ? "deny(403)" : "allow"
  description     = local.locked ? "Default deny: only allowlisted connecting addresses are admitted" : "Default allow"
  match {
    versioned_expr = "SRC_IPS_V1"
    config { src_ip_ranges = ["*"] }
  }
}
