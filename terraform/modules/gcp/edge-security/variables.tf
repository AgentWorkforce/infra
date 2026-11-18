variable "project_id" {
  description = "Project of the GKE cluster. GKE Ingress resolves gkeIngress.sslPolicy and gkeIngress.securityPolicy by name in this project."
  type        = string
}

variable "name" {
  description = "Name prefix: the SSL policy is <name>-tls and the Cloud Armor policy <name>-edge."
  type        = string
  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,56}[a-z0-9])?$", var.name))
    error_message = "name must be 1-58 lowercase letters, digits or hyphens, beginning with a letter."
  }
}

variable "labels" {
  description = "Labels for every resource here that takes labels (the Cloud Armor policy; Compute SSL policies have none in the API). managed-by=terraform is always added."
  type        = map(string)
  default     = {}
}

variable "ssl_policy" {
  description = "Compute SSL policy for the load balancer's HTTPS listener (chart value gkeIngress.sslPolicy). MODERN with TLS 1.2 serves current browsers, the desktop app and CLIs; RESTRICTED narrows the cipher list further (TLS 1.2 minimum is required by it)."
  type = object({
    create          = optional(bool, true)
    profile         = optional(string, "MODERN")
    min_tls_version = optional(string, "TLS_1_2")
  })
  default = {}
  validation {
    condition     = contains(["MODERN", "RESTRICTED"], var.ssl_policy.profile) && contains(["TLS_1_2", "TLS_1_3"], var.ssl_policy.min_tls_version)
    error_message = "ssl_policy.profile must be MODERN or RESTRICTED and min_tls_version TLS_1_2 or TLS_1_3 (COMPATIBLE and TLS 1.0/1.1 are what this policy exists to switch off)."
  }
  validation {
    condition     = var.ssl_policy.min_tls_version != "TLS_1_3" || var.ssl_policy.profile == "RESTRICTED"
    error_message = "min_tls_version TLS_1_3 requires profile RESTRICTED."
  }
}

variable "security_policy" {
  description = <<-EOT
    Cloud Armor backend security policy (chart value gkeIngress.securityPolicy), off unless create = true.

    - waf: preconfigured OWASP rules (deny 403) at the given sensitivity (1 = fewest false positives). preview = true (the default) only logs matches: session transcripts and messages carry code, SQL and shell text, so read the logs before enforcing.
    - rate_limits: per-client throttle (429) on the listed path regexes; the default covers password sign-in, setup-key and login paths.
    - source_ip_allowlist: when non-empty (or cloudflare.enabled), the default rule becomes deny 403 and only these connecting addresses are admitted: a pure source-IP allowlist.
    - cloudflare: admit Cloudflare's published ranges as the connecting addresses (origin lockdown) and read the client address from CF-Connecting-IP.
    - client_ip_header: header an upstream proxy sets with the real client address (Cloud Armor origin.user_ip). Only trustworthy when nothing but that proxy can reach the load balancer: combine with an allowlist of the proxy's ranges, or origin_secret_header.
    - client_ip_rules: requests whose path starts with one of path_prefixes are denied unless the client address (origin.user_ip) is in cidrs. Requires origin_secret_header.
    - adaptive_protection: Layer 7 DDoS detection (alerts; automatic deployment needs Cloud Armor Enterprise).
  EOT
  type = object({
    create = optional(bool, false)
    waf = optional(object({
      enabled     = optional(bool, true)
      preview     = optional(bool, true)
      sensitivity = optional(number, 1)
      rules = optional(list(string), [
        "sqli-v33-stable", "xss-v33-stable", "lfi-v33-stable", "rfi-v33-stable", "rce-v33-stable",
        "scannerdetection-v33-stable", "protocolattack-v33-stable", "sessionfixation-v33-stable", "cve-canary",
      ])
    }), {})
    rate_limits = optional(list(object({
      name             = string
      path_regex       = string
      count            = number
      interval_sec     = number
      ban_duration_sec = optional(number, 0)
      })), [{
      name         = "sign-in"
      path_regex   = "^/(login|(cloud/)?api/v1/auth/)"
      count        = 60
      interval_sec = 60
    }])
    source_ip_allowlist = optional(list(string), [])
    cloudflare = optional(object({
      enabled      = optional(bool, false)
      include_ipv6 = optional(bool, false)
      # https://www.cloudflare.com/ips/ as read on 2026-11-18. Cloudflare
      # announces changes; review the list when it does.
      ipv4_cidrs = optional(list(string), [
        "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22", "141.101.64.0/18",
        "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20", "197.234.240.0/22", "198.41.128.0/17",
        "162.158.0.0/15", "104.16.0.0/13", "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
      ])
      ipv6_cidrs = optional(list(string), [
        "2400:cb00::/32", "2606:4700::/32", "2803:f800::/32", "2405:b500::/32", "2405:8100::/32",
        "2a06:98c0::/29", "2c0f:f248::/32",
      ])
    }), {})
    client_ip_header = optional(string)
    client_ip_rules = optional(list(object({
      name          = string
      path_prefixes = list(string)
      cidrs         = list(string)
    })), [])
    adaptive_protection = optional(bool, false)
  })
  default = {}

  validation {
    condition     = contains([0, 1, 2, 3, 4], var.security_policy.waf.sensitivity) && alltrue([for r in var.security_policy.waf.rules : can(regex("^[a-z0-9-]+$", r))])
    error_message = "waf.sensitivity is 0-4 and waf.rules are Cloud Armor preconfigured WAF rule names (for example sqli-v33-stable)."
  }
  validation {
    condition = alltrue([for c in concat(
      var.security_policy.source_ip_allowlist, var.security_policy.cloudflare.ipv4_cidrs, var.security_policy.cloudflare.ipv6_cidrs,
      flatten([for r in var.security_policy.client_ip_rules : r.cidrs])
    ) : can(cidrhost(c, 0)) && !contains(["0.0.0.0/0", "::/0"], c)])
    error_message = "Every allowlist entry must be a CIDR range, and never 0.0.0.0/0 or ::/0."
  }
  validation {
    condition = alltrue([for r in var.security_policy.rate_limits :
      can(regex("^[a-z0-9]([-a-z0-9]{0,30}[a-z0-9])?$", r.name)) && !strcontains(r.path_regex, "'") && length(r.path_regex) <= 512 &&
      r.count >= 1 && contains([10, 30, 60, 120, 180, 240, 300, 600, 900, 1200, 1800, 2700, 3600], r.interval_sec) && r.ban_duration_sec >= 0
    ]) && length(var.security_policy.rate_limits) <= 9 && length(distinct(var.security_policy.rate_limits[*].name)) == length(var.security_policy.rate_limits)
    error_message = "At most 9 rate_limits with unique lowercase names, a path_regex without single quotes, count >= 1 and an interval_sec Cloud Armor accepts (10, 30, 60, 120, 180, 240, 300, 600, 900, 1200, 1800, 2700 or 3600)."
  }
  validation {
    condition = alltrue([for r in var.security_policy.client_ip_rules :
      can(regex("^[a-z0-9]([-a-z0-9]{0,30}[a-z0-9])?$", r.name)) && length(r.cidrs) >= 1 && length(r.cidrs) <= 392 &&
      length(r.path_prefixes) >= 1 && alltrue([for p in r.path_prefixes : can(regex("^/[A-Za-z0-9/._~-]*$", p))])
    ]) && length(var.security_policy.client_ip_rules) <= 9 && length(distinct(var.security_policy.client_ip_rules[*].name)) == length(var.security_policy.client_ip_rules)
    error_message = "At most 9 client_ip_rules with unique lowercase names, 1-392 cidrs, and path_prefixes that start with / and hold only unreserved URL characters."
  }
  validation {
    condition     = var.security_policy.client_ip_header == null || can(regex("^[A-Za-z][A-Za-z0-9-]{0,63}$", var.security_policy.client_ip_header))
    error_message = "client_ip_header is an HTTP header name, for example CF-Connecting-IP or True-Client-IP."
  }
}

variable "origin_secret_header" {
  description = "Optional shared-secret request header a fronting proxy adds on every request (for Cloudflare: a request header transform rule). Requests without the exact value are denied 403 before any other rule, which proves the request came through the proxy and makes its client-address header trustworthy. The value is stored in Terraform state and readable in the Cloud Armor policy by anyone with compute.securityPolicies.get: treat both as secret stores, and rotate by adding the new value at the proxy after applying it here in a maintenance window."
  type = object({
    name  = string
    value = string
  })
  default   = null
  sensitive = true
  validation {
    condition     = var.origin_secret_header == null || (can(regex("^[a-z][a-z0-9-]{0,63}$", var.origin_secret_header.name)) && can(regex("^[A-Za-z0-9_-]{32,256}$", var.origin_secret_header.value)))
    error_message = "origin_secret_header.name is a lowercase header name and value 32-256 characters from A-Z a-z 0-9 _ - (for example: openssl rand -hex 32)."
  }
}
