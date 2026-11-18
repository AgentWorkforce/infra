mock_provider "google" {}

variables {
  project_id = "proj"
  name       = "relay"
}

run "defaults_create_only_the_tls_policy" {
  command = apply

  assert {
    condition     = google_compute_ssl_policy.this[0].name == "relay-tls" && google_compute_ssl_policy.this[0].profile == "MODERN" && google_compute_ssl_policy.this[0].min_tls_version == "TLS_1_2"
    error_message = "The default SSL policy is MODERN with a TLS 1.2 minimum."
  }
  assert {
    condition     = length(google_compute_security_policy.this) == 0 && length(google_compute_security_policy_rule.default) == 0 && length(google_compute_security_policy_rule.waf) == 0
    error_message = "Cloud Armor is off by default."
  }
  assert {
    condition     = length(output.chart_values.gkeIngress) == 1 && output.chart_values.gkeIngress.sslPolicy == "relay-tls" && output.security_policy_name == null && output.client_ip_header == null
    error_message = "chart_values carries only the SSL policy by default."
  }
}

run "tls_1_0_is_refused" {
  command = plan
  variables {
    ssl_policy = { profile = "COMPATIBLE", min_tls_version = "TLS_1_0" }
  }
  expect_failures = [var.ssl_policy]
}

run "tls_1_3_needs_restricted" {
  command = plan
  variables {
    ssl_policy = { min_tls_version = "TLS_1_3" }
  }
  expect_failures = [var.ssl_policy]
}

run "waf_and_rate_limit_defaults" {
  command = apply
  variables {
    labels          = { team = "platform", managed-by = "someone-else" }
    security_policy = { create = true }
  }

  assert {
    condition     = google_compute_security_policy.this[0].name == "relay-edge" && google_compute_security_policy.this[0].type == "CLOUD_ARMOR"
    error_message = "The policy is the backend policy <name>-edge."
  }
  assert {
    condition     = google_compute_security_policy.this[0].labels == tomap({ team = "platform", managed-by = "terraform" })
    error_message = "Labels reach the policy and managed-by is reserved."
  }
  assert {
    condition     = google_compute_security_policy_rule.default[0].action == "allow" && google_compute_security_policy_rule.default[0].priority == 2147483647
    error_message = "Without an allowlist the default rule allows."
  }
  assert {
    condition     = length(google_compute_security_policy_rule.waf) == 2 && alltrue([for r in google_compute_security_policy_rule.waf : r.action == "deny(403)" && r.preview])
    error_message = "Nine OWASP rules in two deny rules, in preview by default."
  }
  assert {
    condition     = google_compute_security_policy_rule.waf["0"].match[0].expr[0].expression == "evaluatePreconfiguredWaf('sqli-v33-stable', {'sensitivity': 1}) || evaluatePreconfiguredWaf('xss-v33-stable', {'sensitivity': 1}) || evaluatePreconfiguredWaf('lfi-v33-stable', {'sensitivity': 1}) || evaluatePreconfiguredWaf('rfi-v33-stable', {'sensitivity': 1}) || evaluatePreconfiguredWaf('rce-v33-stable', {'sensitivity': 1})"
    error_message = "WAF expression: five preconfigured rules at sensitivity 1."
  }
  assert {
    condition     = strcontains(google_compute_security_policy_rule.waf["1"].match[0].expr[0].expression, "evaluatePreconfiguredWaf('cve-canary', {'sensitivity': 1})")
    error_message = "The default rules include cve-canary (Log4Shell)."
  }
  assert {
    condition     = keys(google_compute_security_policy_rule.rate_limit) == ["sign-in-0"] && google_compute_security_policy_rule.rate_limit["sign-in-0"].action == "throttle" && google_compute_security_policy_rule.rate_limit["sign-in-0"].match[0].expr[0].expression == "request.path.matches('^/(login|(cloud/)?api/v1/auth/)')"
    error_message = "One throttle rule on the sign-in paths."
  }
  assert {
    condition     = google_compute_security_policy_rule.rate_limit["sign-in-0"].rate_limit_options[0].enforce_on_key == "IP" && google_compute_security_policy_rule.rate_limit["sign-in-0"].rate_limit_options[0].exceed_action == "deny(429)" && google_compute_security_policy_rule.rate_limit["sign-in-0"].rate_limit_options[0].rate_limit_threshold[0].count == 60
    error_message = "Throttle per connecting address, 60 per minute, 429 beyond."
  }
  assert {
    condition     = length(google_compute_security_policy_rule.allowlist) == 0 && length(google_compute_security_policy_rule.origin_secret) == 0 && length(google_compute_security_policy_rule.client_ip) == 0
    error_message = "No allowlist, secret-header or client rules unless asked for."
  }
  assert {
    condition     = length(output.chart_values.gkeIngress) == 2 && output.chart_values.gkeIngress.sslPolicy == "relay-tls" && output.chart_values.gkeIngress.securityPolicy == "relay-edge"
    error_message = "chart_values names both policies."
  }
}

run "pure_source_ip_allowlist" {
  command = apply
  variables {
    security_policy = {
      create              = true
      waf                 = { enabled = false }
      rate_limits         = []
      source_ip_allowlist = ["198.51.100.0/24", "203.0.113.7/32"]
    }
  }

  assert {
    condition     = google_compute_security_policy_rule.default[0].action == "deny(403)"
    error_message = "An allowlist makes the default rule deny."
  }
  assert {
    condition     = length(google_compute_security_policy_rule.allowlist) == 1 && google_compute_security_policy_rule.allowlist["0"].action == "allow" && google_compute_security_policy_rule.allowlist["0"].match[0].config[0].src_ip_ranges == toset(["198.51.100.0/24", "203.0.113.7/32"]) || tolist(google_compute_security_policy_rule.allowlist["0"].match[0].config[0].src_ip_ranges) == tolist(["198.51.100.0/24", "203.0.113.7/32"])
    error_message = "The allowlist is one basic allow rule."
  }
  assert {
    condition     = length(google_compute_security_policy_rule.waf) + length(google_compute_security_policy_rule.rate_limit) == 0
    error_message = "WAF and rate limits can be switched off: a pure allowlist."
  }
}

run "cloudflare_origin_lockdown" {
  command = apply
  variables {
    security_policy = {
      create     = true
      cloudflare = { enabled = true }
      client_ip_rules = [{
        name          = "uploads"
        path_prefixes = ["/v1/delivery", "/v1/turns"]
        cidrs         = ["192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24", "192.0.2.128/25", "198.18.0.0/15"]
      }]
    }
    origin_secret_header = { name = "x-origin-auth", values = ["0123456789abcdef0123456789abcdef"] }
  }

  assert {
    condition     = google_compute_security_policy_rule.default[0].action == "deny(403)" && length(google_compute_security_policy_rule.allowlist) == 2 && length(flatten([for r in google_compute_security_policy_rule.allowlist : tolist(r.match[0].config[0].src_ip_ranges)])) == 15
    error_message = "Cloudflare's 15 IPv4 ranges in two basic allow rules, default deny."
  }
  assert {
    condition     = google_compute_security_policy.this[0].advanced_options_config[0].user_ip_request_headers == toset(["CF-Connecting-IP"]) && output.client_ip_header == "CF-Connecting-IP"
    error_message = "The client address comes from CF-Connecting-IP."
  }
  assert {
    condition     = google_compute_security_policy_rule.origin_secret[0].priority == 100 && google_compute_security_policy_rule.origin_secret[0].action == "deny(403)" && nonsensitive(google_compute_security_policy_rule.origin_secret[0].match[0].expr[0].expression) == "!has(request.headers['x-origin-auth']) || !(request.headers['x-origin-auth'] == '0123456789abcdef0123456789abcdef')"
    error_message = "The secret-header rule is the first rule and denies a missing or wrong value."
  }
  # Throttle admits conforming requests, so each throttle rule also requires a Cloudflare address.
  assert {
    condition     = length(google_compute_security_policy_rule.rate_limit) == 4 && alltrue([for r in google_compute_security_policy_rule.rate_limit : strcontains(r.match[0].expr[0].expression, "&& (inIpRange(origin.ip, '") && r.rate_limit_options[0].enforce_on_key == "USER_IP"])
    error_message = "Rate limits stay inside the allowlist and count per client address."
  }
  assert {
    condition     = google_compute_security_policy_rule.rate_limit["sign-in-0"].match[0].expr[0].expression == "request.path.matches('^/(login|(cloud/)?api/v1/auth/)') && (inIpRange(origin.ip, '173.245.48.0/20') || inIpRange(origin.ip, '103.21.244.0/22') || inIpRange(origin.ip, '103.22.200.0/22') || inIpRange(origin.ip, '103.31.4.0/22'))"
    error_message = "Five subexpressions at most: the path and four ranges."
  }
  assert {
    condition     = keys(google_compute_security_policy_rule.client_ip) == ["uploads-allow-0", "uploads-allow-1", "uploads-deny"]
    error_message = "Five client ranges: two allow rules and the path deny."
  }
  assert {
    condition     = google_compute_security_policy_rule.client_ip["uploads-allow-1"].match[0].expr[0].expression == "request.path.matches('^(/v1/delivery|/v1/turns)') && (inIpRange(origin.user_ip, '198.18.0.0/15'))" && google_compute_security_policy_rule.client_ip["uploads-deny"].action == "deny(403)" && google_compute_security_policy_rule.client_ip["uploads-deny"].match[0].expr[0].expression == "request.path.matches('^(/v1/delivery|/v1/turns)')"
    error_message = "Client rules match the path and origin.user_ip, then deny the path."
  }
  # Order: secret header, WAF, client rules, rate limits, allowlist, default.
  assert {
    condition     = max([for r in google_compute_security_policy_rule.waf : r.priority]...) < min([for r in google_compute_security_policy_rule.client_ip : r.priority]...) && max([for r in google_compute_security_policy_rule.client_ip : r.priority]...) < min([for r in google_compute_security_policy_rule.rate_limit : r.priority]...) && max([for r in google_compute_security_policy_rule.rate_limit : r.priority]...) < min([for r in google_compute_security_policy_rule.allowlist : r.priority]...)
    error_message = "Rule priorities keep deny rules ahead of every allow."
  }
}

run "client_rules_need_the_secret_header" {
  command = plan
  variables {
    security_policy = {
      create          = true
      cloudflare      = { enabled = true }
      client_ip_rules = [{ name = "uploads", path_prefixes = ["/v1/delivery"], cidrs = ["192.0.2.0/24"] }]
    }
  }
  expect_failures = [google_compute_security_policy.this]
}

run "client_header_needs_a_locked_edge" {
  command = plan
  variables {
    security_policy = { create = true, client_ip_header = "True-Client-IP" }
  }
  expect_failures = [google_compute_security_policy.this]
}

run "open_ranges_are_refused" {
  command = plan
  variables {
    security_policy = { create = true, source_ip_allowlist = ["0.0.0.0/0"] }
  }
  expect_failures = [var.security_policy]
}

run "weak_secret_is_refused" {
  command = plan
  variables {
    security_policy      = { create = true }
    origin_secret_header = { name = "x-origin-auth", values = ["short"] }
  }
  expect_failures = [var.origin_secret_header]
}

# Rotation without an outage: the current and the next value are both accepted.
run "secret_rotation_accepts_two_values" {
  command = apply
  variables {
    security_policy      = { create = true }
    origin_secret_header = { name = "x-origin-auth", values = ["0123456789abcdef0123456789abcdef", "fedcba9876543210fedcba9876543210"] }
  }

  assert {
    condition     = nonsensitive(google_compute_security_policy_rule.origin_secret[0].match[0].expr[0].expression) == "!has(request.headers['x-origin-auth']) || !(request.headers['x-origin-auth'] == '0123456789abcdef0123456789abcdef' || request.headers['x-origin-auth'] == 'fedcba9876543210fedcba9876543210')"
    error_message = "A request carrying either value passes; anything else is denied."
  }
}

run "four_secret_values_are_refused" {
  command = plan
  variables {
    security_policy      = { create = true }
    origin_secret_header = { name = "x-origin-auth", values = ["0123456789abcdef0123456789abcde1", "0123456789abcdef0123456789abcde2", "0123456789abcdef0123456789abcde3", "0123456789abcdef0123456789abcde4"] }
  }
  expect_failures = [var.origin_secret_header]
}

# The documented shape behind a proxy: vendor ranges reach only the upload and
# MCP paths, the organisation's own ranges reach everything, nobody else
# reaches anything.
run "vendor_paths_and_a_closed_remainder" {
  command = apply
  variables {
    security_policy = {
      create     = true
      cloudflare = { enabled = true }
      client_ip_rules = [
        {
          name          = "vendors"
          hosts         = ["history.relay.example.com"]
          path_prefixes = ["/v1/delivery", "/v1/turns", "/v1/auth/token/refresh"]
          cidrs         = ["192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24", "198.18.0.0/15"]
        },
        {
          name          = "staff"
          path_prefixes = ["/"]
          cidrs         = ["203.0.113.0/24"]
        },
      ]
    }
    origin_secret_header = { name = "x-origin-auth", values = ["0123456789abcdef0123456789abcdef"] }
  }

  assert {
    condition     = keys(google_compute_security_policy_rule.client_ip) == ["staff-allow-0", "staff-deny", "vendors-allow-0", "vendors-allow-1", "vendors-deny"]
    error_message = "A host-scoped rule takes three ranges per allow rule; each rule ends with its deny."
  }
  assert {
    condition     = google_compute_security_policy_rule.client_ip["vendors-allow-0"].match[0].expr[0].expression == "request.headers['host'].lower().matches('^(history\\\\.relay\\\\.example\\\\.com)(:[0-9]+)?$') && request.path.matches('^(/v1/delivery|/v1/turns|/v1/auth/token/refresh)') && (inIpRange(origin.user_ip, '192.0.2.0/24') || inIpRange(origin.user_ip, '198.51.100.0/24') || inIpRange(origin.user_ip, '203.0.113.0/24'))"
    error_message = "Host, path and three client ranges: five subexpressions."
  }
  assert {
    condition     = google_compute_security_policy_rule.client_ip["vendors-deny"].priority < google_compute_security_policy_rule.client_ip["staff-allow-0"].priority && google_compute_security_policy_rule.client_ip["staff-deny"].match[0].expr[0].expression == "request.path.matches('^(/)')" && google_compute_security_policy_rule.client_ip["staff-deny"].action == "deny(403)"
    error_message = "Rules apply in list order, and the closing rule denies every remaining path."
  }
  assert {
    condition     = alltrue([for r in google_compute_security_policy_rule.client_ip : r.priority > google_compute_security_policy_rule.origin_secret[0].priority])
    error_message = "The secret-header rule runs before any client rule."
  }
}
