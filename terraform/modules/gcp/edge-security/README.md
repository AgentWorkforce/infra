# gcp/edge-security

Edge controls for the GKE Ingress of the `agent-relay` chart. Both resources are global Compute resources that the chart refers to by name; GKE attaches them to the load balancer.

| Resource | Chart value | Default |
| --- | --- | --- |
| Compute SSL policy `<name>-tls` (`MODERN`, TLS 1.2 minimum) | `gkeIngress.sslPolicy` | created |
| Cloud Armor backend security policy `<name>-edge` | `gkeIngress.securityPolicy` | not created (`security_policy.create = true`) |

Without an SSL policy a Google load balancer uses its default policy, which still accepts TLS 1.0 and 1.1.

`labels` reach the Cloud Armor policy (plus `managed-by = terraform`). Compute SSL policies and security policy rules have no labels in the API.

## Cloud Armor policy

Rules are evaluated in priority order and the first match decides. Deny rules come first; every rule that admits a request comes after them.

| Priority | Rule | Action |
| --- | --- | --- |
| 100 | `origin_secret_header`: the shared-secret header is missing or wrong | deny 403 |
| 1000+ | `waf`: OWASP preconfigured rules (SQLi, XSS, LFI, RFI, RCE, scanner detection, protocol attack, session fixation, CVE canary) at sensitivity 1 | deny 403, **preview by default** |
| 2000+ | `client_ip_rules`: on the listed paths, admit the listed client addresses and deny everyone else | allow, then deny 403 |
| 3000+ | `rate_limits`: per-client throttle on path regexes (default: sign-in and password paths, 60 requests a minute) | 429 beyond the limit |
| 9000+ | the allowlist of connecting addresses (`source_ip_allowlist`, Cloudflare's ranges) | allow |
| last | default | allow, or **deny 403 when an allowlist is set** |

**The WAF rules start in preview.** Session transcripts, messages and flows carry code, SQL and shell text, which is what the OWASP signatures look for. Preview logs each match without blocking. Read the load balancer's request log (`jsonPayload.previewSecurityPolicy`) for a week of normal use, then set `waf.preview = false`, or remove the rule names that only match your own traffic from `waf.rules`.

A throttle rule admits the requests under its limit, so when an allowlist is set each throttle rule also requires an allowlisted connecting address. Cloud Armor expressions take five subexpressions, which is why an allowlist appears there in groups of four.

### Only some addresses may connect

```hcl
security_policy = {
  create              = true
  source_ip_allowlist = ["198.51.100.0/24"] # for example your VPN's egress range
}
```

Add `waf = { enabled = false }` and `rate_limits = []` for a policy that is the allowlist and nothing else.

### Behind Cloudflare

```hcl
security_policy = {
  create     = true
  cloudflare = { enabled = true }
}
origin_secret_header = { name = "x-origin-auth", values = [var.origin_secret] } # openssl rand -hex 32
```

- `cloudflare.enabled` admits only [Cloudflare's published ranges](https://www.cloudflare.com/ips/) as connecting addresses (the IPv4 list as read on 2026-11-18; `include_ipv6` adds the IPv6 list, which a load balancer with an IPv4 address never sees). Cloudflare announces changes to the list: override `cloudflare.ipv4_cidrs` when it changes.
- Cloudflare's ranges are shared by every Cloudflare customer, so the allowlist alone does not prove a request came through **your** zone. `origin_secret_header` does: add the header in a Cloudflare request header transform rule, and Cloud Armor denies any request without it. `values` takes up to three accepted values, so rotation has no outage: add the new value and apply, switch the Cloudflare rule to it, then remove the old one and apply. The values are kept in Terraform state and are readable in the policy by anyone with `compute.securityPolicies.get`.
- The client address is read from `CF-Connecting-IP` (Cloud Armor `origin.user_ip`), so rate limits count per client and not per Cloudflare address.
- `client_ip_rules` decide which clients may reach which paths, by the client address in `CF-Connecting-IP`. They trust that header, so they require `origin_secret_header`. See the next section.

- There is now one more proxy in front of the application, so `relay-control.auth.trustedProxies` goes up by one: 3 behind Cloudflare (2 was measured for the Google load balancer alone; 3 is expected and not yet measured). `docs/gcp-install/3-EDGE-HARDENING.md` shows how to check it. With the wrong number, sign-in rate limits and lockout are shared by every user.

### Which clients may reach which paths

`client_ip_rules` are allowlists of client addresses, each scoped to path prefixes and optionally to hosts. They are evaluated in list order. A request that matches a rule's paths (and hosts) is admitted when the client address is in `cidrs` and denied 403 otherwise; a request that matches no rule falls through to the rules below.

This example lets two vendors' published ranges reach only the session upload paths on the history host, lets the organisation's own ranges reach everything, and closes the rest:

```hcl
security_policy = {
  create     = true
  cloudflare = { enabled = true }
  client_ip_rules = [
    {
      name          = "vendors"
      hosts         = ["history.relay.example.com"]
      path_prefixes = ["/v1/delivery", "/v1/turns", "/v1/auth/token/refresh"]
      cidrs         = ["192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24"] # vendor ranges, then your own
    },
    {
      name          = "staff"
      path_prefixes = ["/"] # every remaining path, on every host
      cidrs         = ["203.0.113.0/24"]
    },
  ]
}
origin_secret_header = { name = "x-origin-auth", values = [var.origin_secret] }
```

- Put the narrower rule first. Repeat your own ranges in it if your users use those paths too.
- Without the closing `["/"]` rule, paths that no rule names stay open to every client that comes through the proxy.
- Each rule costs one advanced rule per four client ranges (three with `hosts`) plus one. A vendor that publishes hundreds of ranges will exceed the project's Cloud Armor quota for advanced rules; ask Google for a higher quota, or enforce that list at the proxy instead (Cloudflare WAF custom rules see the same client address and have no such limit). The limit per rule here is 294 ranges.
- No rule in this module can contain `0.0.0.0/0` or `::/0`: validation refuses them in every list. The only "all addresses" match is Cloud Armor's mandatory default rule, which is deny whenever an allowlist is set.

## Chart side

`gkeIngress.securityPolicy` puts the policy on the BackendConfig of every backend Service. The dashboard Service (and Relayfile with `gkeIngress.hosts.files`) needs its `cloud.google.com/backend-config` annotation; `helm template` fails with the exact value until it is set. See the chart README, "GKE edge hardening".

Advanced rules (`expr`) count against the project's Cloud Armor quotas: the defaults use three, and seven with `cloudflare.enabled`.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.6 |
| google | >= 7.0, < 8.0 |

### Providers

| Name | Version |
| ---- | ------- |
| google | >= 7.0, < 8.0 |

### Resources

| Name | Type |
| ---- | ---- |
| [google_compute_security_policy.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_security_policy) | resource |
| [google_compute_security_policy_rule.allowlist](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_security_policy_rule) | resource |
| [google_compute_security_policy_rule.client_ip](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_security_policy_rule) | resource |
| [google_compute_security_policy_rule.default](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_security_policy_rule) | resource |
| [google_compute_security_policy_rule.origin_secret](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_security_policy_rule) | resource |
| [google_compute_security_policy_rule.rate_limit](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_security_policy_rule) | resource |
| [google_compute_security_policy_rule.waf](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_security_policy_rule) | resource |
| [google_compute_ssl_policy.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_ssl_policy) | resource |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| name | Name prefix: the SSL policy is <name>-tls and the Cloud Armor policy <name>-edge. | `string` | n/a | yes |
| project\_id | Project of the GKE cluster. GKE Ingress resolves gkeIngress.sslPolicy and gkeIngress.securityPolicy by name in this project. | `string` | n/a | yes |
| labels | Labels for every resource here that takes labels (the Cloud Armor policy; Compute SSL policies have none in the API). managed-by=terraform is always added. | `map(string)` | `{}` | no |
| origin\_secret\_header | Optional shared-secret request header a fronting proxy adds on every request (for Cloudflare: a request header transform rule). Requests without the exact value are denied 403 before any other rule, which proves the request came through the proxy and makes its client-address header trustworthy. values lists every accepted value (1 to 3), so a rotation has no outage: add the new value here and apply, switch the proxy to it, then remove the old value and apply. The values are stored in Terraform state and readable in the Cloud Armor policy by anyone with compute.securityPolicies.get: treat both as secret stores. | ```object({ name = string values = list(string) })``` | `null` | no |
| security\_policy | Cloud Armor backend security policy (chart value gkeIngress.securityPolicy), off unless create = true.  - waf: preconfigured OWASP rules (deny 403) at the given sensitivity (1 = fewest false positives). preview = true (the default) only logs matches: session transcripts and messages carry code, SQL and shell text, so read the logs before enforcing. - rate\_limits: per-client throttle (429) on the listed path regexes; the default covers password sign-in, setup-key and login paths. - source\_ip\_allowlist: when non-empty (or cloudflare.enabled), the default rule becomes deny 403 and only these connecting addresses are admitted: a pure source-IP allowlist. - cloudflare: admit Cloudflare's published ranges as the connecting addresses (origin lockdown) and read the client address from CF-Connecting-IP. - client\_ip\_header: header an upstream proxy sets with the real client address (Cloud Armor origin.user\_ip). Only trustworthy when nothing but that proxy can reach the load balancer: combine with an allowlist of the proxy's ranges, or origin\_secret\_header. - client\_ip\_rules: per-client allowlists scoped to paths (and optionally hosts), evaluated in list order. A request whose path starts with one of a rule's path\_prefixes (on one of its hosts, when given) is admitted if the client address (origin.user\_ip) is in cidrs and denied 403 otherwise. A last rule with path\_prefixes = ["/"] therefore closes every other path to everyone but its cidrs. Requires origin\_secret\_header. - adaptive\_protection: Layer 7 DDoS detection (alerts; automatic deployment needs Cloud Armor Enterprise). | ```object({ create = optional(bool, false) waf = optional(object({ enabled = optional(bool, true) preview = optional(bool, true) sensitivity = optional(number, 1) rules = optional(list(string), [ "sqli-v33-stable", "xss-v33-stable", "lfi-v33-stable", "rfi-v33-stable", "rce-v33-stable", "scannerdetection-v33-stable", "protocolattack-v33-stable", "sessionfixation-v33-stable", "cve-canary", ]) }), {}) rate_limits = optional(list(object({ name = string path_regex = string count = number interval_sec = number ban_duration_sec = optional(number, 0) })), [{ name = "sign-in" path_regex = "^/(login|(cloud/)?api/v1/auth/)" count = 60 interval_sec = 60 }]) source_ip_allowlist = optional(list(string), []) cloudflare = optional(object({ enabled = optional(bool, false) include_ipv6 = optional(bool, false) # https://www.cloudflare.com/ips/ as read on 2026-11-18. Cloudflare # announces changes; compare the list with that page before each apply. ipv4_cidrs = optional(list(string), [ "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22", "141.101.64.0/18", "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20", "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13", "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22", ]) ipv6_cidrs = optional(list(string), [ "2400:cb00::/32", "2606:4700::/32", "2803:f800::/32", "2405:b500::/32", "2405:8100::/32", "2a06:98c0::/29", "2c0f:f248::/32", ]) }), {}) client_ip_header = optional(string) client_ip_rules = optional(list(object({ name = string path_prefixes = list(string) hosts = optional(list(string), []) cidrs = list(string) })), []) adaptive_protection = optional(bool, false) })``` | `{}` | no |
| ssl\_policy | Compute SSL policy for the load balancer's HTTPS listener (chart value gkeIngress.sslPolicy). MODERN with TLS 1.2 serves current browsers, the desktop app and CLIs; RESTRICTED narrows the cipher list further (TLS 1.2 minimum is required by it). | ```object({ create = optional(bool, true) profile = optional(string, "MODERN") min_tls_version = optional(string, "TLS_1_2") })``` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| chart\_values | The gkeIngress keys to merge into the agent-relay values. With securityPolicy, also set the backend-config annotation the chart names on the relay-webapp (and relayfile) Service. |
| client\_ip\_header | Header Cloud Armor reads the client address from (null: the connecting address). When set there is one more proxy in front of the load balancer: relay-control.auth.trustedProxies is one more than for the Google load balancer alone (2), so 3 (docs/gcp-install/3-EDGE-HARDENING.md). |
| security\_policy\_name | Chart value gkeIngress.securityPolicy. Null when security\_policy.create is false. |
| ssl\_policy\_name | Chart value gkeIngress.sslPolicy. Null when ssl\_policy.create is false. |
<!-- END_TF_DOCS -->
