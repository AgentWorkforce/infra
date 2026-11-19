# Disposable GCP and Azure VPN network proof

Execution packet for the default-off connector-network modules. **Unexecuted:
this packet is not a live qualification receipt.** The infra operator allocates
new targets through the approved workflow; never reuse a customer or shared
proof stack. Pin the module source at commit 399c2435, or a later reviewed
commit, and record the exact source and provider-lock hashes.

## Admission and resource plan

The operator supplies a new GCP project ID and immutable number in us-central1,
and a new Azure resource group in the approved subscription in eastus. Check
those identities before every operation. An existing local CLI default is not
admission. No credential transfer or new caller IAM binding is needed when the
infra owner executes on its operator host.

Proposed execution window: two hours per cloud, with an operator-reviewed cost
estimate and a proposed USD 10 ceiling per cloud before provisioning. This is
a proposal, not evidence that a budget was approved. Label/tag resources with
the run ID, purpose, owner and expiry. The operator proposes 48-hour expiry;
expiry is inventory metadata, not an automatic deletion mechanism.

Each cloud gets these exclusively owned fixtures:

| Fixture | Purpose |
| --- | --- |
| New connector VPC/VNet | Holds only the module's private connector subnet |
| New peer VPC/VNet and subnet | Holds the hub, observer and test-client fixtures |
| Four small Ubuntu Linux VMs and OS disks | Private connector, public OpenVPN hub, public HTTPS observer, separate VPN test client |
| Module NAT and static egress address | The exact resources under test |
| Three fixture public IPs | Hub, observer and test client; none on the connector |
| GCP optional global ingress reservation | Test that the module owns and labels the optional address; no GKE/LB is implied |
| Scoped fixture firewall/NSG rules | Management and explicit hub/observer traffic only |
| Azure management-only VNet peering | Lets the hub administer the private connector over SSH; connector NSG permits only the hub's private /32 on port 22 |

Do not add GKE, AKS, databases, object storage, application identities, Cloudflare
resources or DNS-zone authority to this network proof. VM administration uses
the operator's approved transport: GCP IAP; Azure SSH through the hub, with
public SSH on the hub limited to the operator's exact source /32. No public
SSH or public IP on the connector. The target VM NIC and guest need IP forwarding.
No service-account JSON keys, role grants or long-lived credentials are required.

OpenVPN test PKI and SSH private keys are generated in a mode-0700 operator
directory or inside the owned guests. Deliver credentials over the approved
encrypted admin transport; never put private keys, client profiles containing
keys or enrollment tokens in Terraform inputs/state, argv, logs or receipts.
Use unique credentials for each cloud/run.

## Inputs and saved plans

The adjacent JSON examples are deliberately invalid and contain no secrets.
Copy the full GCP inputs into the standalone gcp-vpn-network example and the
Azure inputs into azure-vpn-network in a private execution directory. Fill every
placeholder from the newly admitted target and complete routed-range inventory.
Use a short lowercase name (at most 30 characters).

The GCP strict file is an overlay passed after the full GCP file. It enables
explicit deny rules only for that test phase. Azure priorities remain fixed:
edge 100, VPN 200, DNS 300. Add any approved lifecycle test rule at a new priority.

Before applying, save and inspect the native Terraform plan, hash it, and record
the exact expected creates. Reject replacements/deletions or references outside
the admitted project/group. Existing GCP NAT ownership must be absent or
explicitly disjoint. Azure effective routes must send observer traffic through
the connector NAT, not a learned gateway/NVA. Fixture creation has its own
reviewed inventory, separate from the module state.

Bootstrap the private connector without widening permanent egress: stage the
required Ubuntu/OpenVPN packages on the public hub using the same pinned image,
then copy the package bundle over encrypted administration and install offline.
Alternatively propose a separately reviewed temporary bootstrap rule and remove
it before testing. Do not silently add world egress to make installation pass.

## Real encrypted topology

The hub and observer must have **different public IPs**. Routing the hub's own
public address through the tunnel would also route the OpenVPN transport back
into itself and invalidate the test.

```text
test client -> OpenVPN hub -> encrypted connector tunnel -> private connector
            -> guest SNAT -> module static NAT -> HTTPS observer
```

Use OpenVPN Community with TLS certificates, TLS 1.2 or later, authenticated
AES-GCM data channels, no compression and unique client identities. The hub is
the corporate-VPN stand-in. It and the client live outside the connector's
VPC/VNet. Azure management peering must not provide an alternate application
path: the connector NSG allows only hub administration; observer rules allow
HTTPS only from the module NAT /32.

Suggested VPN subnet: an operator-approved unused /24. Configure the hub with
subnet topology and client-config-dir. Give the connector a stable tunnel
address. Its client config needs an iroute for the observer's public /32; the
hub's corresponding kernel route and client-to-client routing send test-client
observer traffic through that connector. Push only the observer host route to
the test client, never a route for the hub's transport address.

The connector enables guest IPv4 forwarding and SNATs forwarded test traffic
to its private interface address before cloud NAT. Restrict that guest rule
to the test VPN subnet and observer /32. Record non-secret route and packet
counters, not VPN client private keys or packet payloads.

Serve a test DNS name such as edge.vpn-proof.test on the hub's tunnel interface.
It resolves to the observer's public IP. Configure the owned client guest to
resolve that suffix over the tunnel. The HTTPS observer uses a certificate
whose public CA is trusted by the test client. Do not use curl -k.
The observer returns the run marker and observed TCP peer address.

## Required assertions

Record an independent pass/fail and evidence locator for every item. A failure
keeps the run unqualified; do not infer success from a Terraform exit code.

1. **Fresh module apply:** admitted identity matches, connector has no public
   IP, and only owned fixture/module resources were created.
2. **Real VPN connection:** both test client and connector complete TLS
   handshakes with distinct identities; routes and live tunnel counters exist.
3. **Default GCP mode:** no explicit catch-all deny rule is created by this
   module, and the real connector can reach its VPN service using the approved
   existing VPC policy.
4. **NAT identity:** the client resolves the test name and requests HTTPS.
   The observer's marker matches and its observed source equals egress_cidr.
   A request originating on the connector has the same expected source.
5. **Off-VPN denial:** remove only the client's observer tunnel route (or stop
   its VPN), confirm the request is denied, restore the tunnel and confirm the
   identical request succeeds. The observer must remain healthy during this
   negative test. Log a firewall/NSG denial or another independent reachability
   control so a timeout alone is not treated as proof.
6. **GCP strict mode:** apply the reviewed strict overlay. VPN and observer
   traffic pass; an unlisted destination/port fails. Remove the observer allow,
   require that request to fail while the VPN stays connected, restore it and
   require success. Restore default mode and verify the explicit denies disappear.
7. **Azure rule lifecycle:** add an alphabetically earlier rule using a fresh
   stable priority (for example an extra DNS rule at 400), apply and inspect
   the native NSG. Existing edge/VPN/DNS priorities must remain 100/200/300.
   Remove the new rule, apply again and repeat traffic checks.
8. **Long connection:** an HTTPS stream lasting at least 120 seconds completes
   through the VPN and NAT with the expected marker and source. This does not
   qualify Cloudflare's separate timeout behavior.
9. **Identity/port denials:** an untrusted VPN client certificate is rejected;
   management and unrelated ports remain unreachable from the test client.
10. **Idempotence:** the second native module plan has zero changes. Export
    exact non-secret resource IDs and the plan hash.

This qualifies connector networking only. It does not qualify the Agent Relay
application, a private load balancer, vendor-hosted OpenVPN onboarding, customer
DNS, a Cloudflare edge or HA. Those need their own deployments and receipts.

## Receipts and cleanup

Keep credentials and sensitive state in the approved restricted execution
store, together with the exact cloud identities, addresses and owned inventory.
The public receipt contains source/lock/plan hashes, a redacted run label, time
window, per-test command/expected/observed/pass-fail results and resource counts.
Record address equality as a boolean; omit raw cloud IDs, addresses and keys.

Before teardown, show the exact cleanup plan and obtain the required operator
confirmation. Stop guests and remove test-client credentials; delete fixture
VMs/disks/NICs and temporary management rules/peering first. Then destroy the
owned module state, including NAT/static addresses and optional GCP ingress IP.
Finally delete only the newly allocated proof project/resource group through
the target owner's workflow. Never delete a shared project/group, default
signing resources or a NetworkWatcher resource group.

Verify zero owned residual VMs, disks, NICs, subnets, NAT gateways, public
addresses and firewall rules using native APIs as well as Terraform state.
Record the deletion result and any retained resource with owner, reason and
expiry. Destroy local test private keys and temporary client profiles after
the receipt is stored; retain only their public fingerprints.
