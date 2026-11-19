# azure/vpn-network

Opt-in network prerequisites for a customer-managed corporate VPN connector:
a new private connector subnet, a dedicated fixed egress address/NAT, and
explicit connector firewall rules. `enabled = false` by default creates no
resources and performs no cloud data reads. Existing install roots are unchanged.

The VNet and resource group already exist. This is network-only support; it creates no AKS cluster, VPN Gateway, VM or identity.

Read [the VPN networking guide](../../../../docs/vpn-networking.md) for the
supported proxy-egress topology, private-ingress distinctions, NAT/address
ownership, forwarding/SNAT, required inputs and live acceptance checks.
The [standalone example](../../../examples/azure-vpn-network) supplies the
provider configuration. The customer supplies the VM, VPN software and credentials.

Provider-schema validated and covered by mock-provider tests only; no live
VPN or application qualification is implied. No HA claim.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.7 |
| azurerm | >= 4.0, < 5.0 |

### Providers

| Name | Version |
| ---- | ------- |
| azurerm | >= 4.0, < 5.0 |
| terraform | n/a |

### Resources

| Name | Type |
| ---- | ---- |
| [azurerm_nat_gateway.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/nat_gateway) | resource |
| [azurerm_nat_gateway_public_ip_association.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/nat_gateway_public_ip_association) | resource |
| [azurerm_network_security_group.connector](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_group) | resource |
| [azurerm_network_security_rule.deny](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_rule) | resource |
| [azurerm_network_security_rule.outbound](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_rule) | resource |
| [azurerm_public_ip.egress](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/public_ip) | resource |
| [azurerm_subnet.connector](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet_nat_gateway_association.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet_nat_gateway_association) | resource |
| [azurerm_subnet_network_security_group_association.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet_network_security_group_association) | resource |
| [terraform_data.guard](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [azurerm_client_config.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/client_config) | data source |
| [azurerm_virtual_network.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/virtual_network) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| connector\_cidr | Unused RFC1918 IPv4 /28 for a customer-managed, outbound-initiated VPN connector. | `string` | n/a | yes |
| resource\_group\_name | Existing VNet's resource group; this module does not create one. | `string` | n/a | yes |
| subscription\_id | Independently approved subscription; must match the authenticated provider. | `string` | n/a | yes |
| virtual\_network\_name | Existing VNet name; no AKS foundation or application is created. | `string` | n/a | yes |
| enabled | Explicit opt-in. False creates no resources or cloud data reads. | `bool` | `false` | no |
| existing\_network\_cidrs | Existing node, pod, service, connector, peered and corporate ranges to check for overlap. Include every routed range, not the enclosing VPC/VNet address space. | `list(string)` | `[]` | no |
| name | Unique resource prefix in the existing network. | `string` | `"agent-relay"` | no |
| outbound\_rules | Explicit IPv4 destinations and single TCP/UDP ports for the connector (VPN server, DNS, HTTPS edge, management). The module creates no outbound allow without a rule; provider-reserved metadata and DNS may bypass network filters. | `map(object({ cidr = string, protocol = string, port = number }))` | `{}` | no |
| tags | Tags applied to supported resources. | `map(string)` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| connector\_network\_security\_group\_id | NSG allowing only configured outbound destinations, with explicit inbound/outbound denies. |
| connector\_subnet\_id | New connector subnet; attach the separately managed VPN VM without a public IP. |
| egress\_cidr | Stable outbound /32 for the edge's staff allowlist; null while disabled. |
<!-- END_TF_DOCS -->
