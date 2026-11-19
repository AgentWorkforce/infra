# Corporate VPN + Cloudflare profile

Use this with the [three customer setup tasks](README.md). The intended access is:

```text
Staff on VPN -> private OpenVPN connector -> fixed NAT IP -> Cloudflare -> Google LB -> Agent Relay
Claude/ChatGPT -> Cloudflare -> allowed API MCP/OAuth and History ingest/read paths
```

The website and other staff paths are VPN-only. Vendor ranges do not grant
general website access. The origin admits Cloudflare only, with the origin
header; direct-to-LB requests must fail even when they carry that header.
Use a dedicated production project and production Desktop identity, separate
from the POC.

Use **chart 0.7.59 or newer**, with Terraform and scripts from the same reviewed
infra commit. The operator reference's older 0.7.54 chart ignores the TLS Secret
and security-policy keys needed here. Keep `name = "agent-relay"` in both
Terraform roots for the prepared resource names; verify `gkeIngress.staticIpName`
matches `vpn_network.ingress.name` or the manual reservation.

## Settings and ownership

| Requirement | Configuration and owner |
| --- | --- |
| Corporate VPN | Customer deploys the outbound OpenVPN connector into the Terraform-created subnet, without a public IP, using the output network tag and IP forwarding. Configure site routes, DNS and guest source NAT so forwarded traffic exits as `vpn_network.egress_cidr`. Terraform alone does not establish the VPN. |
| Fixed VPN access | Agent Relay prepares platform staff/sign-in rules using that egress CIDR. Customer reviews/applies them. Keep the GKE node NAT separate from the connector NAT. |
| Cloudflare and TLS | Customer picks four flat names under their zone, configures proxied DNS and Full (strict), and supplies Origin CA TLS and the secret header through their own secret path. Agent Relay attaches the TLS 1.2 policy and Cloud Armor to every application backend. |
| Claude/ChatGPT access | Customer-approved vendor ranges are limited to API MCP/OAuth and selected History ingest/read paths, including `/v1/turns/` reads; browser authorization remains VPN-only. The full list uses an existing Cloud Armor Enterprise address group created by the customer. Confirm enrollment/cost and validate the address-group rule live before acceptance. Keep MCP connector URLs on the API host. |
| Labels and firewall policy | Apply `app=agent-relay` and approved extra labels wherever supported. For a no-`0.0.0.0/0` rule requirement, leave GCP `enforce_deny_rules = false` and audit existing/generated firewall rules too. Review required VPN egress with the customer; that setting alone does not restrict it. |
| relaygate | Agent Relay retains the approved gate policy, enablement and Secret references. `gate_only = true` prepares matching History URLs; it does not enable or create the gate policy. |
| Desktop and signed updates | Agent Relay prepares production site/profile builds and enables feed storage with its signer together. Customer supplies final names; the operator provisions the private signer. Reuse no POC identity by accident. |

## Prepared configuration

Start from [the profile input template](edge-site-cloudflare-vpn.example.json).
It selects `mode: cloudflare`, `require_single_level_zone: true` and
`gate_only: true`; turn off the gate option if it is not part of the approved
deployment. Fill the remaining public inputs once. The operator runs the
[configuration preparer](EDGE-DESKTOP-CONFIG.md); VPN ranges and access rules
remain in the reviewed Terraform inputs. The JSON does not configure the VPN,
create the address group, change Cloudflare or provision credentials.

## Acceptance

Require staff sign-in, Desktop upload and a long connection through the VPN;
the same staff request must fail off-VPN. Verify direct-origin denial on all
four hosts, allowed vendor MCP/History paths and denied vendor staff paths.
Raise trusted proxies from 2 to 3 only after origin denial is proven. Verify
signed downloads and Desktop updates before handover. Record any remaining
unproven item explicitly; the network proof alone does not qualify this whole
application profile.

Operator details: [VPN routing and NAT](../vpn-networking.md),
[Cloudflare and origin lockdown](3-EDGE-HARDENING.md#3-cloudflare-in-front),
[Cloud Armor client rules/address groups](../../terraform/modules/gcp/edge-security/README.md).
