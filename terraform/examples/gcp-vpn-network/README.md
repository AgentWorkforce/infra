# Optional GCP corporate VPN connector network

Standalone root for [`gcp/vpn-network`](../../modules/gcp/vpn-network).
It is not called by the existing installation roots, and `enabled` defaults
to false. The example tfvars also starts disabled. Supply the approved cloud
identity and existing network inputs, replace the documentation-only CIDRs,
and review the plan before enabling it. This root creates no connector VM,
VPN software, credentials or managed VPN service.

Read [VPN networking](../../../docs/vpn-networking.md) before planning: it covers
forwarding/SNAT, existing NAT and address ownership, private versus proxied
access, and the checks that still need a live tunnel. Use a dedicated approved
backend/state for this root; no backend is selected for you.

```sh
cp terraform.tfvars.example terraform.tfvars
# Fill in approved inputs; keep enabled = false for the first review.
terraform init
terraform plan
# Set enabled = true only as part of the reviewed provisioning plan.
terraform plan -out=connector.tfplan
# Apply only the approved saved plan using your infrastructure workflow.
```

The VM goes in the output subnet without a public IP. Cloudflare/DNS and edge
allowlists stay separately owned; `egress_cidr` supplies the staff-source value.
GCP and Azure each have one dated live connector-network run; AWS has
static/mock validation only. None is an application, IPv6, private
load-balancer or vendor-VPN qualification: see the
[evidence and its limits](../../../docs/vpn-networking.md#verification-and-lifecycle).

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.7 |
| google | >= 7.0, < 8.0 |

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| vpn\_network | ../../modules/gcp/vpn-network | n/a |

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
| enforce\_deny\_rules | Opt in to explicit 0.0.0.0/0 ingress/egress deny rules for connector-tagged VMs. Requires outbound\_rules; false preserves the existing VPC/hierarchical policy for hosted VPN control planes. | `bool` | `false` | no |
| existing\_network\_cidrs | Existing node, pod, service, connector, peered and corporate ranges to check for overlap. Include every routed range, not the enclosing VPC/VNet address space. | `list(string)` | `[]` | no |
| labels | Labels on supported resources. Subnets, routers, NAT and firewall rules do not support labels. | `map(string)` | `{}` | no |
| name | Unique resource prefix in the existing network. | `string` | `"agent-relay"` | no |
| outbound\_rules | Optional IPv4/port allow rules for the connector. Existing VPC policy controls egress unless enforce\_deny\_rules is explicitly enabled; provider-reserved metadata/DNS may bypass filters. | `map(object({ cidr = string, protocol = string, port = number }))` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| vpn\_network | Non-secret connector placement and fixed egress references. Nulls when disabled. |
<!-- END_TF_DOCS -->
