# Azure live proof: opt-in corporate connector network (infra PR 497, Azure half)

Source: PR head 399c24352aae5a7403fe2bb913e7bd725dc9d09b (checkout verified equal). Example root `terraform/examples/azure-vpn-network`, module `terraform/modules/azure/vpn-network`, run in place with external state and data dir.
Provider lock sha256 prefix 4cc1facc603d. Saved-plan sha256 prefixes: L1 64528c31bca8, L8 add 5a9d95c9e5f1, L8 remove 6933c3c0cfac, L11 destroy 84ccad1d1789. Every saved plan was inspected before apply: no replace, no delete (except the L11 destroy, exactly the module's 13 resources), nothing outside the proof resource group.
Environment: one resource group, eastus, five B1s VMs (hub, observer, client, connector, workload probe; the probe VM was added to the plan for the inbound-deny test), OpenVPN Community 2.6.x with a throwaway EC P-256 PKI (TLS 1.3 negotiated, AES-256-GCM, no compression, distinct cert per client). Hub and observer have different public addresses. The observer serves HTTPS on a throwaway-CA certificate for edge.vpn-proof.test; clients use `--cacert`, never `-k`. Private keys were generated in the guests; certificates signed on the build host.

## Verdict
The Azure module works as documented for the proxy path. Connector HTTPS reached the observer from the module's NAT egress address, a VPN client reached it through the tunnel and connector SNAT with the same observed address, and the deny rules held. Plans were stable and the destroy removed exactly the module's resources. No defect that breaks the module was found; four documentation/usability findings are listed below.

## Results
| Test | Result | Evidence summary |
| --- | --- | --- |
| terraform test (module and example) | PASS | 2 passed / 0 failed in the example; module tests pass; validate OK |
| G1 enabled=false | PASS | plan creates nothing |
| G2 wrong subscription | PASS (see finding 1) | plan fails; the module precondition cannot be the thing that fires through the example root |
| G3 overlap incl. nested both directions | PASS | precondition failure for every case |
| G4 CIDR outside VNet; non-RFC1918 /28 | PASS | precondition failure |
| G5 non-/28, duplicate priority, priority 4096, port 0, protocol icmp | PASS | each rejected by variable validation |
| L1 plan/apply, existing network unchanged | PASS | 13 adds, 0 change, 0 destroy; pre-existing VNet/subnet identical before/after |
| L2 connector facts | PASS | subnet with NSG and NAT, no default outbound access, NIC forwarding, effective NSG shows module rules plus both 4096 denies |
| L3 connector HTTPS; observed address equals egress_cidr | PASS | observed peer == module egress: true |
| L4 client via tunnel | PASS | observed peer == egress: true; != client public: false-equal; != hub: false-equal; only the observer host route pushed |
| L5 off-tunnel denial | PASS | negative control (route removed) fails; observer counters: client-direct 0, hub-direct 0, module-egress >0; hub's own address also refused; recovery restored |
| L6 deny tests | PASS | connector to a port with no rule: timeout, though the observer NSG allows it; unrelated HTTPS: no connection; inbound to connector from the workload subnet on 8080 and 22: blocked, with an in-subnet control open; untrusted-CA client cert rejected by hub |
| L7 DNS | PASS (see finding 2) | name resolved over the tunnel from the hub; platform resolver answered |
| L8 stable priorities | PASS | adding an earlier-sorting key at a fresh priority: 1 add, existing rules keep 100/200/300; removing: 1 destroy |
| L9 long stream | PASS | 210 s stream, 210 of 210 ticks from the egress address, no gap over 2 s |
| L10 zero drift (twice) | PASS | `plan -detailed-exitcode` exit 0 both times |
| L11 retirement | PASS | edge references removed, connector VM/NIC/disk deleted, destroy of exactly 13 module resources |

## Pre-existing network control (before, after apply, and after final destroy)
Unchanged: **true**. Compared properties, VNet: address space, DDoS setting, location, name, tags, peerings, provisioning state. Workload subnet: address prefix, default-outbound setting, delegations, name, private endpoint and private link policies, provisioning state, NSG association, route table, NAT gateway, service endpoints, IP configurations. After the destroy the VNet holds only the workload subnet.

## Findings
1. Subscription guard unreachable through the example root: the provider's `subscription_id` and the module's `subscription_id` are the same variable (examples/azure-vpn-network/main.tf:3 and :15), so a wrong value fails in the provider (subscription not found) before the module precondition (modules/azure/vpn-network/main.tf:37-39) can compare. The check can only fire if a caller wires two different values.
2. Platform DNS bypass is real: with no `dns` rule, the Azure platform resolver address on :53 still answers while a public resolver on :53 does not. It is disclosed (docs/vpn-networking.md:93, variables.tf:33); a `dns` rule for that address is therefore not needed for it to work, and does not restrict it.
3. The single generic message at modules/azure/vpn-network/main.tf:43 covers three distinct failures (not RFC1918, overlap, outside the VNet); operators cannot tell which.
4. Bootstrap gap (docs/vpn-networking.md:73-74, :96-107): with no outbound allow, the connector cannot install VPN software. This proof used one temporary rule named `bootstrap` (tcp/8000 to the hub, priority 150) with packages served from the hub, removed (1 destroy) before any traffic test. A documented bootstrap path would help.

## Disclosures
- The observer's first private key was placed in cloud-init custom data (not run-command) and was then replaced with an in-guest key. No run-command script, argument or output carried private keys.
- Provider lock file written into the example dir (gitignored); no tracked file changed.

## Not covered
IPv6, Desktop uploads and MCP, private-load-balancer routing (documented as out of scope), a vendor VPN product.

## Receipt appendix (sanitized; raw records kept privately by the operator)

Run label: vpn-proof-pr497-azure-1. Window: 2026-11-19, about 14:10Z to 14:53Z. Operator: layered-infra-ops on its own host, one proof resource group in eastus.

### Source, lock and plan hashes (full sha256 unless noted)
| Item | Value |
| --- | --- |
| Commit applied | 399c24352aae5a7403fe2bb913e7bd725dc9d09b |
| PR head at report time | e04fb616f4ce29d54086df78c58899c2ebbef92c (docs-only on top; 0 changed lines in terraform/modules and the VPN example roots) |
| git tree, terraform/modules/azure/vpn-network | f3662527c133dd7a3ebfe5d61da9d79e60227c4f (same at both commits) |
| git tree, terraform/examples/azure-vpn-network | 2712fcbadc45e31178c55e5da1d2170748b57083 (same at both commits) |
| Provider lock file | 4cc1facc603d068341246432f531ddaab8e2c7fa973af1f97867b192f199a2c7 |
| Plan L1 (create) | 64528c31bca818f424bcb791985b84a3dd8ead18539705a029c8a372f0de608f |
| Plan bootstrap rule add | 16c338faae5d4ff0a1d15e73b4b087d20d4459da31b44d2b4fb12b9678aa86d4 |
| Plan bootstrap rule remove | 97f3feabce24a3fb6a449cabb4bb7585cfa702379822e2e4de592ce61c17b582 |
| Plan L8 add | 5a9d95c9e5f165a21d2c6b0a044798f0f47d86404a7cc1edb5bd54fd3e1432e1 |
| Plan L8 remove | 6933c3c0cfac9dcde58ccfb6c0f321a8df0aba713c552c1a86d799c6c992949d |
| Plan L11 destroy | 84ccad1d178988544b124b7a047467be00ab8f35668b1817fabd4c3a5270a08c |
Terraform 1.16.7. Plan files are binary and environment-bound; the hashes identify the files I keep.

### Plan and apply summaries (from the saved logs)
| Step | Summary line |
| --- | --- |
| L1 plan / apply | Plan: 13 to add, 0 to change, 0 to destroy. / Apply complete! Resources: 13 added, 0 changed, 0 destroyed. |
| Bootstrap rule add / remove | Plan: 1 to add, 0 to change, 0 to destroy. / Plan: 0 to add, 0 to change, 1 to destroy. |
| L8 add / remove | Plan: 1 to add, 0 to change, 0 to destroy. / Plan: 0 to add, 0 to change, 1 to destroy. |
| L10 (twice) | No changes. `plan -detailed-exitcode` exit 0 both times |
| L11 plan / apply | Plan: 0 to add, 0 to change, 13 to destroy. / Apply complete! Resources: 0 added, 0 changed, 13 destroyed. |

### Zero state and native inventory
- Module state after L11: 0 resources (state serial 43).
- Native inventory of the proof resource group after L11, read with the cloud CLI, not from state: 21 resources, all proof fixtures and none from the module: 4 VMs, 4 OS disks, 4 NICs, 3 NSGs, 3 public addresses, 3 VNets. The connector VM, its NIC and disk were deleted before the destroy. No NAT gateway, no connector subnet, no connector NSG, no egress address remained.
- Pre-existing VNet and workload subnet: property comparison before apply, after apply and after destroy, every compared property equal (list in the section above).
- Address equality was recorded as booleans only. No address, subscription, tenant or resource id is in this receipt.

### Deviations from the test plan
1. Bootstrap: one temporary outbound rule (`bootstrap`, tcp/8000 to the hub, priority 150) so the connector could fetch VPN packages served from the hub. Added with a saved 1-add plan and removed with a saved 1-destroy plan before any traffic test. L3 to L9 ran without it.
2. Key handling: private keys were generated inside the guests and only certificate requests left them, with one exception: the observer's first private key was passed in cloud-init custom data at VM creation. It was replaced by an in-guest key before any test, and the first key was never used for a test. No run-command script, argument or output carried a private key.
3. A fifth VM (workload probe) was added for the inbound-deny test from the workload subnet.
4. The provider lock file was written into the example directory (gitignored). No tracked file changed.

### Cleanup
Order: fixtures referencing the connector, then module state (L11), then the proof resource group. Proof resource group deletion: issued 2026-11-19 15:06Z after an inventory showing only the 21 fixtures and no locks; the group was gone at 15:09Z and a group listing at 15:11Z shows only the two pre-existing groups, both unchanged. Shared groups, signing resources and the network-watcher group were not touched. Local test private keys: the throwaway CA keys, the VM login key and the cloud-init file that held the observer's first key were deleted from the operator host at 15:15Z; a scan of the proof state directory finds no private key file. CSRs, certificates, logs, plans and state stay with the operator, private.
