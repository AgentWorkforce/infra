# aws/vpn-network

Opt-in network prerequisites for a customer-managed corporate VPN connector:
a new private connector subnet, a dedicated fixed egress address/NAT, and
explicit connector firewall rules. `enabled = false` by default creates no
resources and performs no cloud data reads. Existing install roots are unchanged.

The NAT Gateway uses an existing public subnet in the same AZ. The module creates no Internet Gateway, VPN endpoint, IAM role or EC2 instance.

Read [the VPN networking guide](../../../../docs/vpn-networking.md) for the
supported proxy-egress topology, private-ingress distinctions, NAT/address
ownership, forwarding/SNAT, required inputs and live acceptance checks.
The [standalone example](../../../examples/aws-vpn-network) supplies the
provider configuration. The customer supplies the VM, VPN software and credentials.

Provider-schema validated and covered by mock-provider tests only; no live
VPN or application qualification is implied. No HA claim.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.7 |
| aws | >= 6.72, < 7.0 |

### Providers

| Name | Version |
| ---- | ------- |
| aws | >= 6.72, < 7.0 |
| terraform | n/a |

### Resources

| Name | Type |
| ---- | ---- |
| [aws_eip.egress](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eip) | resource |
| [aws_nat_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/nat_gateway) | resource |
| [aws_route.egress](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route_table.connector](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table_association.connector](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_security_group.connector](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_subnet.connector](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_vpc_security_group_egress_rule.connector](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [terraform_data.guard](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [aws_caller_identity.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_subnet.nat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |
| [aws_vpc.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | Independently approved target AWS account ID. | `string` | n/a | yes |
| availability\_zone | Connector and NAT subnet AZ; the existing public subnet must have an Internet Gateway route. | `string` | n/a | yes |
| connector\_cidr | Unused RFC1918 IPv4 /28 for a customer-managed, outbound-initiated VPN connector. | `string` | n/a | yes |
| nat\_public\_subnet\_id | Existing public subnet for a dedicated NAT Gateway, in this VPC and AZ. | `string` | n/a | yes |
| vpc\_id | Existing VPC that will contain the connector subnet. | `string` | n/a | yes |
| enabled | Explicit opt-in. False creates no resources or cloud data reads. | `bool` | `false` | no |
| existing\_network\_cidrs | Existing node, pod, service, connector, peered and corporate ranges to check for overlap. Include every routed range, not the enclosing VPC/VNet address space. | `list(string)` | `[]` | no |
| name | Unique resource prefix in the existing network. | `string` | `"agent-relay"` | no |
| outbound\_rules | Explicit IPv4 destinations and single TCP/UDP ports for the connector (VPN server, DNS, HTTPS edge, management). The module creates no outbound allow without a rule; provider-reserved metadata and DNS may bypass network filters. | `map(object({ cidr = string, protocol = string, port = number }))` | `{}` | no |
| tags | Tags applied to resources. | `map(string)` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| connector\_route\_table\_id | Dedicated connector route table; existing workload route tables are not modified. |
| connector\_security\_group\_id | Attach only this group to the customer-managed connector (no public IP, no inbound rules). |
| connector\_subnet\_id | Private connector subnet; null while disabled. |
| egress\_cidr | Stable outbound /32 for the edge's staff allowlist; null while disabled. |
<!-- END_TF_DOCS -->
