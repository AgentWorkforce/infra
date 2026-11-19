# Optional corporate VPN connector networks

Use this profile when a customer already runs a corporate VPN and wants a
customer-managed connector VM in the Agent Relay network. The same opt-in
shape is available on GCP, AWS and Azure. It creates network prerequisites,
not VPN software, identities, certificates, enrollment tokens or managed VPN
services. The operator deploys and configures an outbound-initiated connector
using their VPN vendor's supported image and secret delivery.

All three modules default to `enabled = false`. Existing installation roots
are unchanged. The separate examples require an explicit opt-in and an approved
plan before any apply. They use existing cloud accounts/projects, VPCs/VNets and
(on AWS) an existing public subnet; they do not create or adopt a cluster.

| Cloud | Module | Standalone example | Resources when enabled |
| --- | --- | --- | --- |
| GCP | [gcp/vpn-network](../terraform/modules/gcp/vpn-network) | [gcp-vpn-network](../terraform/examples/gcp-vpn-network) | Connector subnet, dedicated Cloud Router/NAT and regional static IP, connector-tagged firewall rules; optional external GKE ingress IP and IAP SSH |
| AWS | [aws/vpn-network](../terraform/modules/aws/vpn-network) | [aws-vpn-network](../terraform/examples/aws-vpn-network) | Private connector subnet, dedicated route table, NAT Gateway/EIP in an existing public subnet, connector security group with no inbound rules |
| Azure | [azure/vpn-network](../terraform/modules/azure/vpn-network) | [azure-vpn-network](../terraform/examples/azure-vpn-network) | Connector subnet, Standard static public IP/NAT Gateway, subnet associations and an NSG with explicit inbound/outbound denies |

Azure support here is network-only. The [AKS guide](azure-install/README.md)
retains its existing qualification limits; these modules do not qualify an
Azure managed database, object store, private AKS installation or full suite.

## Choose the traffic path

### VPN users reaching an edge through a proxy

```text
VPN laptop -> encrypted vendor tunnel -> customer connector VM (SNAT)
           -> connector subnet NAT (fixed egress IP)
           -> Cloudflare/proxy -> application load balancer -> Agent Relay
```

Configure the VPN to send the intended site traffic through this connector.
The connector must SNAT forwarded client traffic to its own private address;
subnet NAT then translates it to the module's `egress_cidr`. A subnet and NAT
alone do not establish a VPN or change a laptop's routes.

Add `egress_cidr` to the edge's approved staff-source rules. When Cloudflare is
in front, the origin sees a Cloudflare address: customer-source rules must
use the authenticated original client address, after the origin-lockdown and
secret-header checks. See [GKE edge hardening](gcp-install/3-EDGE-HARDENING.md).
Keep vendor upload/MCP access scoped separately. Do not grant a VPN user the
same access as an AI provider just because they use the same hostname.

### VPN users reaching a private load balancer

This requires a private application edge, forward and return routes for VPN
clients, private DNS and an approved tunnel/connector configuration. The fixed
public egress IP is not the private client's source address. These modules do
not create those routes or private DNS, and are not proof of private reachability.
On GCP, compose with [internal-edge](../terraform/modules/gcp/internal-edge);
on AWS use the private ingress shape in the [enterprise guide](enterprise-aws-install.md).
The Azure guide has not qualified an internal ingress. Do not send a private
VPN route to an external edge configured to admit Cloudflare connections only.

## Inputs and ownership

Supply an independently approved cloud identity, an unused RFC1918 connector
`/28`, and **every existing subnet, pod, service, peered and corporate range**
in `existing_network_cidrs`. The overlap check compares full intervals,
including ranges nested inside one another. It can check only the inventory
supplied; verify the inventory against the actual cloud network before apply.
AWS also checks its NAT subnet, VPC ownership, AZ and primary address range;
Azure checks the authenticated subscription and VNet address spaces; GCP checks
the immutable project number.

No existing workload subnet or route table is adopted or edited. New resources
have a separate `vpn-connector` / `vpn-egress` name. GCP's existing foundation
`connector` is a Serverless VPC Access connector, not a VPN connector.

`outbound_rules` is empty by default. Add only the destinations and TCP/UDP
ports required by the VPN vendor, edge, resolver and approved management path.
The example uses documentation-only addresses: replace them with reviewed
values. Provider-reserved metadata/DNS traffic may bypass firewall or security
group rules; these rules do not establish a complete data-egress or PHI boundary.
On GCP, inspect higher-priority and hierarchical firewall policies too.

The VM remains operator-owned:

- Create it without a public IP, in `connector_subnet_id`.
- GCP: apply `connector_network_tag` and enable VM IP forwarding. IAP SSH is a
  separate opt-in; IAM and login policy remain operator-owned.
- AWS: attach `connector_security_group_id`, turn off source/destination checking
  for forwarded traffic, and use an approved SSM role/endpoints for management.
  No inbound SSH rule is created. Extra security groups can broaden access.
- Azure: enable NIC and guest IP forwarding; the module's subnet NSG applies.
  Use approved Azure management tooling; there is no inbound SSH allow.
- Configure guest forwarding, source NAT, VPN routes, DNS and vendor enrollment
  outside Terraform, with credentials held in the customer's secret system.

Do not attach unrelated workloads to the connector subnet or give them the
connector's security group/tag. The static address is an edge allowlist input,
not an authentication mechanism.

## Existing-network integration

**GCP NAT ownership.** A second Cloud NAT cannot claim a subnet already covered
by another NAT. If the existing router uses `ALL_SUBNETWORKS_ALL_IP_RANGES`
(the GKE guide's `--nat-all-subnet-ip-ranges`), first review a change to an
explicit list of its existing workload subnets, excluding the new VPN subnet.
Preserve every existing node and Serverless VPC Access subnet. The foundation
module already uses explicit subnet selection. This module translates only
its newly created VPN subnet; it never changes the existing NAT.

**GCP ingress IP ownership.** `create_ingress_ip` is false by default. When true,
skip the install guide's manual `agent-relay-ingress` reservation and use the
module's `ingress` output. If the address already exists, either keep it outside
this module or explicitly import it into the intended state before enabling
ownership. Never let the guide and Terraform both create the same address.
This address is external-only; do not compose it with the internal-edge address.

**AWS public subnet.** `nat_public_subnet_id` must already have a working default
route to the VPC's Internet Gateway. The NAT and connector subnets must be in
the same AZ. The module changes only the new connector route table and its
association. Existing VPC network ACLs still apply; review them for the vendor
transport and return traffic. Capture connection evidence with the VPC's
approved flow logging.

**Azure routing.** The new subnet disables default outbound access and uses its
own NAT Gateway. A more-specific route, or a learned/user-defined default to
an NVA, VPN Gateway or ExpressRoute, can bypass that NAT. Review effective
routes before using `egress_cidr` as an allowlist input. An existing inline
VNet `subnet` declaration must not compete with separately managed subnets.
The example disables automatic Azure resource-provider registration; required
Network provider registration stays in the operator's approved prerequisites.

## Verification and lifecycle

Terraform mock-provider tests cover disabled resources/data reads, identity
mismatches, overlap rejection, private connector placement, NAT scope and
explicit firewall rules. **No live tunnel has been qualified by those tests.**

Before handing over an enabled profile, record:

1. The reviewed plan and resource inventory: only the intended new connector
   network resources; no existing workload route or subnet changes.
2. A real tunnel connection, guest SNAT and the intended client route.
3. An HTTPS request from the connector and VPN laptop that reaches the edge;
   its observed original client address matches `egress_cidr` for the proxy path.
4. The same staff path fails off-VPN, and direct-origin access remains refused
   where proxy lockdown is enabled. Test IPv6 separately; this profile is IPv4-only.
5. DNS, Desktop uploads, MCP, WebSockets and long-lived connections through
   the selected path; required private return routes if using private ingress.
6. An unchanged second Terraform plan, and a documented retirement sequence:
   remove edge references, retire the connector through the approved vendor
   process, then destroy only this module's resources after separate approval.

NAT gateways/static addresses incur provider charges when enabled. This is a
single-connector network path; it makes no high-availability claim.

Provider references: [AWS appliance forwarding](https://docs.aws.amazon.com/vpc/latest/userguide/work-with-nat-instances.html),
[Azure NAT routing precedence](https://learn.microsoft.com/en-us/azure/nat-gateway/nat-gateway-design),
[Azure static NAT addresses](https://learn.microsoft.com/en-us/azure/nat-gateway/nat-gateway-snat).
