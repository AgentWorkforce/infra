# gcp/vpn-network

Opt-in network prerequisites for a customer-managed corporate VPN connector:
a new private connector subnet, a dedicated fixed egress address/NAT, and
explicit connector firewall rules. `enabled = false` by default creates no
resources and performs no cloud data reads. Existing install roots are unchanged.

An optional global external ingress IP is available separately from the VPN egress IP. It does not create a load balancer or a certificate.

Read [the VPN networking guide](../../../../docs/vpn-networking.md) for the
supported proxy-egress topology, private-ingress distinctions, NAT/address
ownership, forwarding/SNAT, required inputs and live acceptance checks.
The [standalone example](../../../examples/gcp-vpn-network) supplies the
provider configuration. The customer supplies the VM, VPN software and credentials.

Provider-schema validated and covered by mock-provider tests only; no live
VPN or application qualification is implied. No HA claim.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.7 |
| google | >= 7.0, < 8.0 |

### Providers

| Name | Version |
| ---- | ------- |
| google | >= 7.0, < 8.0 |
| terraform | n/a |

### Resources

| Name | Type |
| ---- | ---- |
| [google_compute_address.egress](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_address) | resource |
| [google_compute_firewall.deny](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_firewall.iap](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_firewall.outbound](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_global_address.ingress](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_global_address) | resource |
| [google_compute_router.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_router) | resource |
| [google_compute_router_nat.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_router_nat) | resource |
| [google_compute_subnetwork.connector](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_subnetwork) | resource |
| [terraform_data.guard](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [google_compute_network.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/compute_network) | data source |
| [google_project.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/project) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| connector\_cidr | Unused RFC1918 IPv4 /28 for a customer-managed, outbound-initiated VPN connector. | `string` | n/a | yes |
| expected\_project\_number | Independently approved immutable project number. | `string` | n/a | yes |
| network\_name | Existing VPC name; never creates or adopts a VPC. | `string` | n/a | yes |
| project\_id | Existing approved GCP project ID. | `string` | n/a | yes |
| region | Region of the connector subnet and Cloud NAT. | `string` | n/a | yes |
| allow\_iap\_ssh | Allow IAP TCP forwarding to port 22 on connector-tagged VMs; IAM and the VM remain operator-owned. | `bool` | `false` | no |
| create\_ingress\_ip | Also reserve the external GKE Ingress IP; skip the guide's manual address creation or import it first. | `bool` | `false` | no |
| enabled | Explicit opt-in. False creates no resources or cloud data reads. | `bool` | `false` | no |
| existing\_network\_cidrs | Existing node, pod, service, connector, peered and corporate ranges to check for overlap. Include every routed range, not the enclosing VPC/VNet address space. | `list(string)` | `[]` | no |
| labels | Labels on supported resources. Subnets, routers, NAT and firewall rules do not support labels. | `map(string)` | `{}` | no |
| name | Unique resource prefix in the existing network. | `string` | `"agent-relay"` | no |
| outbound\_rules | Explicit IPv4 destinations and single TCP/UDP ports for the connector (VPN server, DNS, HTTPS edge, management). The module creates no outbound allow without a rule; provider-reserved metadata and DNS may bypass network filters. | `map(object({ cidr = string, protocol = string, port = number }))` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| connector\_network\_tag | Required network tag on the customer-owned connector VM (no external IP). |
| connector\_subnet\_id | New connector subnet ID, or null while disabled. |
| egress\_cidr | Stable outbound /32 for the edge's staff allowlist; null while disabled. |
| ingress | Optional external GKE address; gkeIngress.staticIpName is name. Null unless explicitly created. |
<!-- END_TF_DOCS -->
