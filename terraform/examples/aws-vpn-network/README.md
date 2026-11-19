# Optional AWS corporate VPN connector network

Standalone root for [`aws/vpn-network`](../../modules/aws/vpn-network).
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
All three clouds have static/mock validation only, not live tunnel qualification.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.7 |
| aws | >= 6.72, < 7.0 |

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| vpn\_network | ../../modules/aws/vpn-network | n/a |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | Independently approved target AWS account ID. | `string` | n/a | yes |
| availability\_zone | Connector and NAT subnet AZ; the existing public subnet must have an Internet Gateway route. | `string` | n/a | yes |
| connector\_cidr | Unused RFC1918 IPv4 /28 for a customer-managed, outbound-initiated VPN connector. | `string` | n/a | yes |
| nat\_public\_subnet\_id | Existing public subnet for a dedicated NAT Gateway, in this VPC and AZ. | `string` | n/a | yes |
| region | AWS region containing the existing VPC and public NAT subnet. | `string` | n/a | yes |
| vpc\_id | Existing VPC that will contain the connector subnet. | `string` | n/a | yes |
| enabled | Explicit opt-in. False creates no resources or cloud data reads. | `bool` | `false` | no |
| existing\_network\_cidrs | Existing node, pod, service, connector, peered and corporate ranges to check for overlap. Include every routed range, not the enclosing VPC/VNet address space. | `list(string)` | `[]` | no |
| name | Unique resource prefix in the existing network. | `string` | `"agent-relay"` | no |
| outbound\_rules | Explicit IPv4 destinations and single TCP/UDP ports for the connector (VPN server, DNS, HTTPS edge, management). The module creates no outbound allow without a rule; provider-reserved metadata and DNS may bypass network filters. | `map(object({ cidr = string, protocol = string, port = number }))` | `{}` | no |
| tags | Tags applied to resources. | `map(string)` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| vpn\_network | Non-secret connector placement and fixed egress references. Nulls when disabled. |
<!-- END_TF_DOCS -->
