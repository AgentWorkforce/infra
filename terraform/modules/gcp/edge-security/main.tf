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
  allow_groups = chunklist(local.allowlist, var.max_subexpressions - 1)

  client_ip_header = local.sp.client_ip_header != null ? local.sp.client_ip_header : (local.sp.cloudflare.enabled ? "CF-Connecting-IP" : null)

  waf_groups = local.sp.waf.enabled ? chunklist(local.sp.waf.rules, 5) : []

  # A backslash in path_regex is doubled: the pattern sits inside a quoted
  # string of the expression, whose own reader consumes one level of escaping.
  # One throttle rule per rate limit, or one per allowlist group when the
  # edge is locked: a throttle rule admits conforming requests, so it must
  # itself require an allowed connecting address.
  rate_rules = merge([for i, r in local.sp.rate_limits : {
    for j, group in(local.locked ? local.allow_groups : [[]]) : "${r.name}-${j}" => {
      priority   = 20000 + i * 1000 + j
      limit      = r
      expression = join(" && ", compact(["request.path.matches('${replace(r.path_regex, "\\", "\\\\")}')", length(group) > 0 ? "(${join(" || ", [for c in group : "inIpRange(origin.ip, '${c}')"])})" : ""]))
    }
  }]...)

  # client_ip_rules: the first rule whose paths (and hosts) match decides.
  # Its clients are admitted, by a throttle when the rule has a rate_limit,
  # and everyone else on those paths is denied. A Cloud Armor rule that admits
  # ends evaluation, so admitted requests meet no later rule: that is why each
  # rule states its own limit and why the secret header rule must come first.
  # A rule's clients are terms: one per address group (a single subexpression
  # for the whole list) and one per CIDR. Address groups are existing project
  # resources named here; the google provider below 8.0 cannot create one with
  # purpose CLOUD_ARMOR, so they are made with gcloud (README).
  client_terms = { for r in local.sp.client_ip_rules : r.name => concat(
    [for g in r.address_groups : "evaluateAddressGroup('${g}', origin.user_ip)"],
    [for c in r.cidrs : "inIpRange(origin.user_ip, '${c}')"],
  ) }
  client_groups = { for r in local.sp.client_ip_rules : r.name => chunklist(local.client_terms[r.name], var.max_subexpressions - (length(r.hosts) > 0 ? 2 : 1)) }
  client_rules = merge([for i, r in local.sp.client_ip_rules : merge({
    for j, group in local.client_groups[r.name] : "${r.name}-allow-${j}" => {
      priority    = 10000 + i * 1000 + j
      action      = r.rate_limit == null ? "allow" : "throttle"
      rate        = { count = try(r.rate_limit.count, 0), interval_sec = try(r.rate_limit.interval_sec, 0) }
      description = "${r.name}: listed client addresses on ${join(", ", concat(r.hosts, r.path_prefixes))}"
      expression  = "${local.path_match[r.name]} && (${join(" || ", group)})"
    }
    }, { "${r.name}-deny" = {
      priority    = 10000 + i * 1000 + 999
      action      = "deny(403)"
      rate        = { count = 0, interval_sec = 0 }
      description = "${r.name}: any other client on ${join(", ", concat(r.hosts, r.path_prefixes))}"
      expression  = local.path_match[r.name]
  } })]...)
  connecting_guard = length(local.sp.connecting_asns) + length(local.sp.connecting_address_groups) > 0

  # What the policy costs against the project's Cloud Armor quotas.
  rule_counts = {
    advanced = (local.secret_header ? 1 : 0) + (local.connecting_guard ? 1 : 0) + length(local.waf_groups) + length(local.client_rules) + length(local.rate_rules)
    basic    = length(local.allow_rules) + 1
  }
  # The path (one subexpression) and, with hosts, the Host header (a second);
  # the rest of max_subexpressions holds client ranges. Groups are
  # non-capturing: Cloud Armor rejects a regular expression with a capture
  # group ("Capture Groups are not allowed").
  path_match = { for r in local.sp.client_ip_rules : r.name => join(" && ", compact([
    length(r.hosts) > 0 ? "request.headers['host'].lower().matches('^(?:${join("|", [for h in r.hosts : replace(h, ".", "\\\\.")])})(?::[0-9]+)?$')" : "",
    # A prefix ends at a path segment: /mcp matches /mcp and /mcp/x, not
    # /mcpfoo. "/" is every path.
    contains(r.path_prefixes, "/") ? "request.path.matches('^/')" : "request.path.matches('^(?:${join("|", [for p in r.path_prefixes : replace(trimsuffix(p, "/"), ".", "\\\\.")])})(?:/|$)')",
  ])) }
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
      condition     = local.rule_counts.advanced <= var.max_advanced_rules
      error_message = "This policy needs ${local.rule_counts.advanced} rules with an expression, and one Cloud Armor policy holds at most ${var.max_advanced_rules} (quota SECURITY_POLICY_ADVANCED_RULES_PER_SECURITY_POLICY, which Google does not raise). Nothing has been created. Shorten client_ip_rules (each rule holds ${var.max_subexpressions - 1} ranges, ${var.max_subexpressions - 2} with hosts), merge adjacent ranges, or enforce the long list at the fronting proxy; see the module README, Quotas."
    }
    precondition {
      condition     = alltrue([for r in local.sp.client_ip_rules : length(local.client_groups[r.name]) <= 999]) && length(local.allow_groups) <= 999
      error_message = "A list needs more than 999 rules at this max_subexpressions. Shorten it, or enforce it at the fronting proxy."
    }
    precondition {
      condition     = length(local.sp.client_ip_rules) == 0 || local.connecting_guard || local.sp.secret_header_only
      error_message = "client_ip_rules admit requests before the allowlist of connecting addresses is checked, so a caller that holds the secret header could skip the proxy and choose its own client address. Set connecting_asns (Cloudflare: [13335]) or connecting_address_groups so connections from outside the proxy are denied first, or set secret_header_only = true to accept that the secret header is the only guard."
    }
    precondition {
      condition     = alltrue([for r in local.sp.client_ip_rules : r.rate_limit != null || r.unthrottled])
      error_message = "Each client_ip_rules entry admits its clients, and admitted requests skip rate_limits. Give the rule its own rate_limit, or set unthrottled = true to accept that it has none."
    }
    precondition {
      condition     = length(local.sp.rate_limits) == 0 || !anytrue([for r in local.sp.client_ip_rules : length(r.hosts) == 0 && contains(r.path_prefixes, "/")])
      error_message = "A client_ip_rules entry for every path (\"/\" without hosts) decides every request, so rate_limits would never apply. Set rate_limits = [] and put the limits you want in client_ip_rules, for example a sign-in rule ahead of the closing rule."
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

# Requests admitted by a client rule never reach the allowlist of connecting
# addresses further down, so without this rule the shared-secret header alone
# decides whether a caller that skipped the proxy gets in (and such a caller
# chooses its own client address). The proxy's ranges do not fit one negated
# expression, but its network number does, and so does an address group: deny
# every connection that comes from none of them.
resource "google_compute_security_policy_rule" "connecting" {
  count           = local.armor && local.connecting_guard ? 1 : 0
  project         = var.project_id
  security_policy = google_compute_security_policy.this[0].name
  priority        = 150
  action          = "deny(403)"
  description     = "Connections from outside the fronting proxy (${join(", ", concat([for a in local.sp.connecting_asns : "AS ${a}"], local.sp.connecting_address_groups))})"
  match {
    expr {
      expression = join(" && ", concat(
        [for a in local.sp.connecting_asns : "origin.asn != ${a}"],
        [for g in local.sp.connecting_address_groups : "!evaluateAddressGroup('${g}', origin.ip)"],
      ))
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
  dynamic "rate_limit_options" {
    for_each = each.value.rate.count > 0 ? [each.value.rate] : []
    content {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "USER_IP"
      rate_limit_threshold {
        count        = rate_limit_options.value.count
        interval_sec = rate_limit_options.value.interval_sec
      }
    }
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
  priority        = 30000 + tonumber(each.key)
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
