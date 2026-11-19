mock_provider "google" {}

variables {
  project_id = "proj"
  name       = "relay"
  # Most runs pin 5 subexpressions per rule so that small lists exercise the
  # splitting into several rules; the module's default (10) has its own runs.
  max_subexpressions = 5
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
    condition     = keys(google_compute_security_policy_rule.rate_limit) == ["sign-in-0"] && google_compute_security_policy_rule.rate_limit["sign-in-0"].action == "throttle" && google_compute_security_policy_rule.rate_limit["sign-in-0"].match[0].expr[0].expression == "request.path.matches('^/(?:login|(?:cloud/)?api/v1/auth/)')"
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
        unthrottled   = true
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
    condition     = google_compute_security_policy_rule.rate_limit["sign-in-0"].match[0].expr[0].expression == "request.path.matches('^/(?:login|(?:cloud/)?api/v1/auth/)') && (inIpRange(origin.ip, '173.245.48.0/20') || inIpRange(origin.ip, '103.21.244.0/22') || inIpRange(origin.ip, '103.22.200.0/22') || inIpRange(origin.ip, '103.31.4.0/22'))"
    error_message = "Five subexpressions at most: the path and four ranges."
  }
  assert {
    condition     = keys(google_compute_security_policy_rule.client_ip) == ["uploads-allow-0", "uploads-allow-1", "uploads-deny"]
    error_message = "Five client ranges: two allow rules and the path deny."
  }
  assert {
    condition     = google_compute_security_policy_rule.client_ip["uploads-allow-1"].match[0].expr[0].expression == "request.path.matches('^(?:/v1/delivery|/v1/turns)') && (inIpRange(origin.user_ip, '198.18.0.0/15'))" && google_compute_security_policy_rule.client_ip["uploads-deny"].action == "deny(403)" && google_compute_security_policy_rule.client_ip["uploads-deny"].match[0].expr[0].expression == "request.path.matches('^(?:/v1/delivery|/v1/turns)')"
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
      create      = true
      cloudflare  = { enabled = true }
      rate_limits = []
      client_ip_rules = [
        {
          name          = "vendors"
          hosts         = ["history.relay.example.com"]
          path_prefixes = ["/v1/delivery", "/v1/turns", "/v1/auth/token/refresh"]
          cidrs         = ["192.0.2.0/24", "198.51.100.0/24"]
          rate_limit    = { count = 600, interval_sec = 60 }
        },
        {
          name          = "sign-in"
          path_prefixes = ["/login", "/api/v1/auth", "/cloud/api/v1/auth"]
          cidrs         = ["203.0.113.0/24"]
          rate_limit    = { count = 60, interval_sec = 60 }
        },
        {
          name          = "staff"
          path_prefixes = ["/"]
          cidrs         = ["203.0.113.0/24", "192.0.2.128/25", "198.18.0.0/15", "198.51.100.128/25", "203.0.113.128/25"]
          unthrottled   = true
        },
      ]
    }
    origin_secret_header = { name = "x-origin-auth", values = ["0123456789abcdef0123456789abcdef"] }
  }

  assert {
    condition     = keys(google_compute_security_policy_rule.client_ip) == ["sign-in-allow-0", "sign-in-deny", "staff-allow-0", "staff-allow-1", "staff-deny", "vendors-allow-0", "vendors-deny"]
    error_message = "Every rule admits its clients (four ranges per rule, three with hosts) and then denies its paths."
  }
  assert {
    condition     = google_compute_security_policy_rule.client_ip["vendors-allow-0"].match[0].expr[0].expression == "request.headers['host'].lower().matches('^(?:history\\\\.relay\\\\.example\\\\.com)(?::[0-9]+)?$') && request.path.matches('^(?:/v1/delivery|/v1/turns|/v1/auth/token/refresh)') && (inIpRange(origin.user_ip, '192.0.2.0/24') || inIpRange(origin.user_ip, '198.51.100.0/24'))"
    error_message = "Host, path and the client ranges, within five subexpressions."
  }
  # A short vendor list ahead of a staff-only "/" rule: the vendor is admitted
  # by its own rule, which ends evaluation, so the later staff rule cannot
  # deny it.
  assert {
    condition     = google_compute_security_policy_rule.client_ip["vendors-allow-0"].action == "throttle" && google_compute_security_policy_rule.client_ip["vendors-allow-0"].priority < google_compute_security_policy_rule.client_ip["vendors-deny"].priority && google_compute_security_policy_rule.client_ip["vendors-deny"].priority < google_compute_security_policy_rule.client_ip["sign-in-allow-0"].priority && google_compute_security_policy_rule.client_ip["sign-in-deny"].priority < google_compute_security_policy_rule.client_ip["staff-allow-0"].priority
    error_message = "Rules apply in list order: the first rule that matches the path decides."
  }
  # A rule's own limit applies whatever the length of its list.
  assert {
    condition     = google_compute_security_policy_rule.client_ip["vendors-allow-0"].rate_limit_options[0].rate_limit_threshold[0].count == 600 && google_compute_security_policy_rule.client_ip["sign-in-allow-0"].action == "throttle" && google_compute_security_policy_rule.client_ip["sign-in-allow-0"].rate_limit_options[0].rate_limit_threshold[0].count == 60 && google_compute_security_policy_rule.client_ip["sign-in-allow-0"].rate_limit_options[0].enforce_on_key == "USER_IP" && google_compute_security_policy_rule.client_ip["sign-in-allow-0"].rate_limit_options[0].exceed_action == "deny(429)"
    error_message = "A one-range rule with a rate_limit throttles per client address."
  }
  assert {
    condition     = google_compute_security_policy_rule.client_ip["staff-allow-0"].action == "allow" && length(google_compute_security_policy_rule.client_ip["staff-allow-0"].rate_limit_options) == 0 && google_compute_security_policy_rule.client_ip["staff-deny"].action == "deny(403)" && google_compute_security_policy_rule.client_ip["staff-deny"].match[0].expr[0].expression == "request.path.matches('^(?:/)')"
    error_message = "An unthrottled rule admits with allow; the closing rule denies every remaining path."
  }
  assert {
    condition     = alltrue([for r in google_compute_security_policy_rule.client_ip : r.priority > google_compute_security_policy_rule.origin_secret[0].priority]) && length(google_compute_security_policy_rule.rate_limit) == 0
    error_message = "The secret-header rule runs before any client rule."
  }
}

# Admitted requests skip rate_limits, so a rule must say how it is limited.
run "client_rule_must_choose_a_limit" {
  command = plan
  variables {
    security_policy = {
      create          = true
      cloudflare      = { enabled = true }
      client_ip_rules = [{ name = "uploads", path_prefixes = ["/v1/delivery"], cidrs = ["192.0.2.0/24"] }]
    }
    origin_secret_header = { name = "x-origin-auth", values = ["0123456789abcdef0123456789abcdef"] }
  }
  expect_failures = [google_compute_security_policy.this]
}

# A rule for every path decides every request, so path rate_limits would be dead.
run "catch_all_client_rule_refuses_dead_rate_limits" {
  command = plan
  variables {
    security_policy = {
      create          = true
      cloudflare      = { enabled = true }
      client_ip_rules = [{ name = "staff", path_prefixes = ["/"], cidrs = ["203.0.113.0/24"], unthrottled = true }]
    }
    origin_secret_header = { name = "x-origin-auth", values = ["0123456789abcdef0123456789abcdef"] }
  }
  expect_failures = [google_compute_security_policy.this]
}

# A regex escape in path_regex survives the expression's string literal.
run "rate_limit_regex_with_an_escape" {
  command = apply
  variables {
    security_policy = {
      create      = true
      waf         = { enabled = false }
      rate_limits = [{ name = "v1", path_regex = "^/v1\\.0/", count = 10, interval_sec = 60 }]
    }
  }

  assert {
    condition     = google_compute_security_policy_rule.rate_limit["v1-0"].match[0].expr[0].expression == "request.path.matches('^/v1\\\\.0/')"
    error_message = "The backslash is doubled inside the quoted expression string."
  }
}

# The policy reports what it costs against the project's rule quotas, and a
# higher max_subexpressions packs a long client list into fewer rules.
run "rule_counts_and_wider_expressions" {
  command = apply
  variables {
    security_policy = {
      create      = true
      cloudflare  = { enabled = true }
      rate_limits = []
      client_ip_rules = [{
        name          = "vendors"
        hosts         = ["history.relay.example.com"]
        path_prefixes = ["/v1/delivery"]
        cidrs         = [for i in range(24) : "198.51.${i}.0/24"]
        unthrottled   = true
      }]
    }
    origin_secret_header = { name = "x-origin-auth", values = ["0123456789abcdef0123456789abcdef"] }
  }

  # 24 ranges at 3 per rule = 8 admitting rules + 1 deny; + secret header + 2 WAF = 12 advanced; + 2 allowlist + default = 15.
  assert {
    condition     = length(google_compute_security_policy_rule.client_ip) == 9 && output.rule_counts.advanced == 12 && output.rule_counts.total == 15
    error_message = "rule_counts must equal the rules created."
  }
  assert {
    condition     = output.rule_counts.total == length(google_compute_security_policy_rule.client_ip) + length(google_compute_security_policy_rule.waf) + length(google_compute_security_policy_rule.origin_secret) + length(google_compute_security_policy_rule.rate_limit) + length(google_compute_security_policy_rule.allowlist) + length(google_compute_security_policy_rule.default)
    error_message = "total counts every rule resource."
  }
}

run "ten_subexpressions_need_a_third_of_the_rules" {
  command = apply
  variables {
    max_subexpressions = 10
    security_policy = {
      create      = true
      cloudflare  = { enabled = true }
      rate_limits = []
      client_ip_rules = [{
        name          = "vendors"
        hosts         = ["history.relay.example.com"]
        path_prefixes = ["/v1/delivery"]
        cidrs         = [for i in range(24) : "198.51.${i}.0/24"]
        unthrottled   = true
      }]
    }
    origin_secret_header = { name = "x-origin-auth", values = ["0123456789abcdef0123456789abcdef"] }
  }

  # 8 ranges per rule (10 - host - path): 3 admitting rules + 1 deny.
  assert {
    condition     = length(google_compute_security_policy_rule.client_ip) == 4 && output.rule_counts.advanced == 7 && length(regexall("inIpRange", google_compute_security_policy_rule.client_ip["vendors-allow-0"].match[0].expr[0].expression)) == 8
    error_message = "With 10 subexpressions a host-scoped rule carries 8 ranges."
  }
}

run "policy_off_reports_zero_rules" {
  command = apply
  assert {
    condition     = output.rule_counts.advanced == 0 && output.rule_counts.total == 0
    error_message = "No policy, no rules."
  }
}

# A capture group in a user regex is refused at plan: Cloud Armor rejects it at apply.
run "capture_group_in_path_regex_refused" {
  command = plan
  variables {
    security_policy = { create = true, rate_limits = [{ name = "auth", path_regex = "^/(login|setup)", count = 10, interval_sec = 60 }] }
  }
  expect_failures = [var.security_policy]
}

run "non_capturing_and_escaped_parentheses_accepted" {
  command = apply
  variables {
    security_policy = { create = true, waf = { enabled = false }, rate_limits = [{ name = "auth", path_regex = "^/(?:login|setup)\\(x\\)", count = 10, interval_sec = 60 }] }
  }
  assert {
    condition     = length(google_compute_security_policy_rule.rate_limit) == 1
    error_message = "(?:...) groups and escaped parentheses are allowed."
  }
}

# No expression the module builds contains a capture group.
run "generated_expressions_have_no_capture_groups" {
  command = apply
  variables {
    security_policy = {
      create     = true
      cloudflare = { enabled = true }
      client_ip_rules = [
        { name = "vendors", hosts = ["history.relay.example.com", "api.relay.example.com"], path_prefixes = ["/v1/delivery", "/.well-known"], cidrs = ["192.0.2.0/24"], unthrottled = true },
      ]
    }
    origin_secret_header = { name = "x-origin-auth", values = ["0123456789abcdef0123456789abcdef"] }
  }
  assert {
    condition = alltrue([for e in concat(
      [for r in google_compute_security_policy_rule.client_ip : r.match[0].expr[0].expression],
      [for r in google_compute_security_policy_rule.rate_limit : r.match[0].expr[0].expression],
    ) : length(regexall("matches\\('[^']*\\((?:[^?]|$)", e)) == 0])
    error_message = "Every group inside a matches() pattern must be non-capturing."
  }
  assert {
    condition     = google_compute_security_policy_rule.client_ip["vendors-deny"].match[0].expr[0].expression == "request.headers['host'].lower().matches('^(?:history\\\\.relay\\\\.example\\\\.com|api\\\\.relay\\\\.example\\\\.com)(?::[0-9]+)?$') && request.path.matches('^(?:/v1/delivery|/\\\\.well-known)')"
    error_message = "Host and path patterns in the form the API accepted."
  }
}

# The default: 10 subexpressions. Cloudflare's 15 ranges need two throttle rules, not four.
run "default_is_ten_subexpressions" {
  command = apply
  variables {
    max_subexpressions   = 10
    security_policy      = { create = true, cloudflare = { enabled = true } }
    origin_secret_header = { name = "x-origin-auth", values = ["0123456789abcdef0123456789abcdef"] }
  }
  assert {
    condition     = length(google_compute_security_policy_rule.rate_limit) == 2 && length(regexall("inIpRange", google_compute_security_policy_rule.rate_limit["sign-in-0"].match[0].expr[0].expression)) == 9 && output.rule_counts.advanced == 5
    error_message = "Path plus nine ranges per throttle rule."
  }
}
