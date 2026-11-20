# GCP live proof receipt: vpn-network module (sanitized)

## Verdict
All required GCP assertions (1-6 and 8-10) passed, assertion 9 only on its second pass. Its first pass FAILED: the test hub and connector guests (fixtures, not the module under test) answered management ports on their tunnel addresses. After a guest-only fix it passed, and assertions 4, 5 and 8 were repeated and passed again. Both passes are recorded below. The packet says a failure keeps a run unqualified; whether a first-pass failure of the fixture does so is the packet owner's call. Everything the run created was deleted and the project's pre-existing resources are unchanged.

## Identity of what was tested
- Packet: PR 508, head f10aa952, merged commit 163422f8. Packet README sha256 df96b60cc9dca31251cdfa6e44f1aab2d1037d7bd7f8628fe6aebd57d8f78961 (identical at head and at the merged commit).
- Module source: infra PR 497 at commit f92de10c4c2e6592539fc5ed17cb8e5c32b1b934 (worktree clean at apply time).
- Provider lock sha256: 3c533985c20f82c8394be1a3f1b650f6c3ef9770e63a13456410dc47fcd74135 (terraform 1.16.7, provider hashicorp/google 7.46.2).
- Environment: one shared GCP project, region us-central1, all run resources named with the run prefix and labelled with the run label. Local state files, no remote backend.
- Operator key public fingerprint: SHA256:3IWg1YFpqyliLVMhvYQHsspiH6WhJnG7LvbmaVyU35E (ED25519).
- Time window: 2026-11-19 21:37Z (baseline before) to 22:52Z (residual check and baseline after). Phase 3 assertions 22:08Z to 22:42Z. Teardown applies 22:48Z to 22:51Z.

## Plans and gates (all saved, hashed, gated by plancheck.py)
| Label | Mode | Expected | sha256 | Gate |
|---|---|---|---|---|
| stage1 (fixture-net) | create | 9 | 5a90357b437a5a9aacb924f8fbfa1302ce9097cc373054b345a30d0d8110c031 | PASS |
| module default | create | 8 (as briefed) | 627fa09e2618d88ee1af2781dada8193e36caad816ee104010b1591b1b3d9999 | REJECT on expected count (plan has 7 creates) |
| module default re-gate | create | 7 (lead-confirmed count) | same plan, same hash | PASS, then applied |
| module second plan | noop | none | 2797852a22c7f3a9b6f7c3d4bb5ba34a182e3fb195b3d68d44859173e9ed3254 | PASS |
| stage2 (fixture-vms) | create | 19 | 589a3dcfb2555f91e773c511abca38ccd60dc17496d9f118ea2183c81925c619 | PASS |
| S1 | module-rules | 4 creates | e599778f5e1779678c862c81cfb8b5d751423dcfaab1932045ab7769a7e66624 | PASS |
| S2 | module-rules | 1 delete | 90a0d4ed5bb95f75d88e0da5a655a9c71a5cb99941dc1e71e1d087d118b80d8d | PASS |
| S3 | module-rules | 1 create | 5a0b83b058f93e6e191796f225aa6dfa200bb26332ceb3c61cae79faf5a8a66f | PASS |
| S4 | module-rules | 4 deletes | 44475897a216c125463efb38292f31bf6b1cb11d563ad563c24ba477b10f016f | PASS |
| A10 module | noop | none | 61376d900735fbe0d39c980e5e942cb84ec4e723ce30c7e1a71d626f4ec21663 | PASS |
| A10 fixture-net | noop | none | 98d68a6859255d7f5b4af2a9c7e269b46922d7cadeae11cd9f98f1b842b26e4b | PASS |
| A10 fixture-vms | noop | none | a8d272e4129554f9436cde00936d8d48db1b7532cd658b1370d12fb9ecd7c058 | PASS |
| destroy fixture-vms | destroy | 19 | 149bbf32d1383fcc0a10e75afa078f295403aa9bbdfedf203ae245bf1c4a53de | PASS |
| destroy module | destroy | 7 | 22b93b009b6cd0a507232912270024e95614895546769edb0c3e16f5fb04deea | PASS |
| destroy fixture-net | destroy | 9 | eb911b019489719276f75f8f34f69f6e5e5a80287edbf1bad976d47abf83d3bc | PASS |

The first module gate REJECT was on the expected count only (the briefed count differed from the 7 resources the module creates). Nothing was applied until the lead confirmed 7 and the same saved plan re-gated PASS.

## Assertions
| # | Command | Expected | Observed | Result |
|---|---|---|---|---|
| 1 | saved-plan apply of module; project and instance describe; native listing vs state | identity as designed, connector has no external address and no service account, inventory equals state | all identity booleans true, connector has no external address and no service account | PASS |
| 2 | real OpenVPN client to hub to connector to observer | two distinct certificate common names, TLS 1.3, routes as designed, counters rise | connector and client common names distinct, TLS 1.3 AES-256-GCM, routes correct, tun counters rose on client, hub and connector | PASS |
| 3 | default mode, restart connector for a fresh handshake, external HTTPS | no deny or out rules exist, handshake succeeds, internet reachable | no strict-mode rule present, fresh handshake, HTTPS to an external site returned 200 | PASS |
| 4 pass 1 | client and connector HTTPS to observer, read the source it saw; NAT counter | source equals the module egress address; masquerade counter rises | source_equals_module_NAT true for both, counter rose | PASS |
| 4 pass 2 | same, repeated after the guest firewall fix and strict cycle | same | same, counter rose again | PASS |
| 5 pass 1 | remove client's observer route, probe 3 times, connector request, restore | timeouts; independent denial signals; backend stays healthy | see signals below | PASS |
| 5 pass 2 | same | same | same signals (8 denied log entries, observer saw only the connector) | PASS |
| 6 | strict mode S1 to S4 | S1: client works, connector tcp 80 and external HTTPS blocked; S2: removing the out rule breaks the client; S3: re-adding restores; S4: all strict rules gone, internet back | exactly as expected at each step; sessions stayed connected through S2 | PASS |
| 7 | not applicable to GCP | | | N/A |
| 8 pass 1 | 130 s stream through the tunnel, no certificate bypass | exit 0, end marker, source equals module egress address, no session churn | exit 0, 130 s, 8531 bytes, marker and source correct, hub session count unchanged | PASS |
| 8 pass 2 | same | same | same | PASS |
| 9 pass 1 | rogue-CA client certificate; port table incl. hub and connector tunnel addresses | rogue rejected; all closed | rogue rejected (verify error, no address, no tunnel); table below shows 3 rows open | FAIL |
| 9 pass 2 | rogue-CA again; expanded table after guest-only fix | rogue rejected; all 9 rows timeout or refused; regression checks hold | rogue rejected, 9 of 9 timed out, regression checks all true | PASS |
| 10 | fresh plans of module, fixture-net, fixture-vms | noop | exit 0 and 0 managed changes for all three | PASS |

### A5 independent denial signals (both passes)
1. Client probes to the observer timed out 3 of 3 with the route removed.
2. GCP firewall log (read-only query) held DENIED entries for the peer deny rule with source equal to the peer NAT address and destination port 443 (9 in pass 1, 8 in pass 2).
3. Observer backend stayed HEALTHY, the observer journal showed requests only from the module egress address (none from the peer NAT), and the restored client request succeeded afterwards.

### A9 tables
| Target | Port | Path | First pass | Second pass |
|---|---|---|---|---|
| hub front | 22 | direct | timeout | timeout |
| hub front | 8081 | direct | timeout | timeout |
| observer front | 22 | tunnel | timeout | timeout |
| observer front | 8443 | tunnel | timeout | timeout |
| hub tunnel address | 22 | tunnel | OPEN | timeout |
| hub tunnel address | 8081 | tunnel | OPEN | timeout |
| connector tunnel address | 22 | tunnel | OPEN | timeout |
| observer front | 22 | route removed | timeout | timeout |
| observer front | 8443 | route removed | timeout | timeout |

First pass FAIL: hub tunnel tcp 22, hub tunnel tcp 8081 and connector tunnel tcp 22 were open from the VPN client. The fix was guest-only (fixture iptables units on hub, connector and client, DNS limited to the VPN source range, sshd untouched). No module input, cloud firewall rule or project setting was changed. Second pass PASS with regression checks true: IAP ssh to all four VMs, client DNS over the tunnel, HTTPS marker with source equal to the module egress address, hub to client and hub to connector tunnel pings, both backends HEALTHY.

## Deviations and unverified items
- The pass 2 tests of A4, A5, A8 and A9 ran in default mode after S4, not before S1 as asked (the request arrived after S1 was applied).
- A5 firewall-log line counts were cut by an --until bound in both passes and were recounted; both files record the correction.
- Two Result lines were first written wrongly by my own counting (A4 pass 1 and A9 pass 2, where an expected false value was counted as failure) and were corrected in the files.
- A4 pass 1: first connector request hit curl error 77 (key directory root-only); rerun with sudo.
- A6 S1: a quoting typo in one connector probe printed a shell error; rerun correctly.
- A1 native-inventory recount was not repeated after phase 3 (the baseline compare covers it).
- Rogue-CA test was run once in pass 2.
- The apply of the last destroy plan (fixture-net) printed no readable summary in my session because a helper library failed after the module outputs vanished; success is established by the state having 0 resources and the native listing.

## Resources
- Managed resources created: 9 (fixture-net) + 7 (module) + 19 (fixture-vms) = 35; strict-mode rules (4) were created and deleted within the run.
- Cloud resources exported to the private id list: 30.
- Destroyed: 19 (fixture-vms), 7 (module), 9 (fixture-net) per saved destroy plans; apply summaries for the first two read "0 added, 0 changed, 19 destroyed" and "0 added, 0 changed, 7 destroyed".

## Cleanup
- In-guest first: OpenVPN services stopped and disabled on hub, connector and client; client profile and PKI removed; no run credential files left (only distro sample keys remain, inside machines that were then deleted); no IAP tunnel left open.
- Residual native listing by name prefix and by run label: 0 for instances, disks, instance groups, forwarding rules, backend services, health checks, regional and global addresses, routers, subnets, networks, firewall rules, routes. All three terraform states have 0 resources.
- Baseline after versus baseline before: all categories equal; also byte-identical raw files with no ignore rule at all (0 files differ, no run-prefix mention in either), IAM etag equal, project metadata fingerprint equal.

## Independent verification by the operator (lead session)
- Recomputed the sha256 of all 14 saved plan files: every hash equals the table above. Re-ran the gate on the strict (S1-S4), zero-change (A10) and destroy plans from the saved files: same results and counts (4/1/1/4, 0/0/0, 19/7/9).
- 22:45Z, before teardown: native firewall listing showed the run's 7 default-mode rules and no strict rule; before/after inventory equal including IAM etag and project metadata fingerprint; module worktree clean and lock hash unchanged.
- 22:54Z, after teardown: native listing by run prefix returned 0 for instances, disks, instance groups, forwarding rules, backend services, health checks, addresses, routers, subnets, networks, firewall rules, routes, snapshots and custom images; 0 by run label and by purpose label; the three states hold 0 resources; counts of pre-existing networks, instances, firewall rules, forwarding rules and addresses equal the baseline; the 24 inventory files are byte-identical before and after.
- This covers the fixture-net destroy whose apply summary was not captured.

## What this qualifies
This proves, on a live GCP project with real OpenVPN traffic, that the module's default and strict modes behave as the packet claims for the tested paths: connector egress through the module NAT address, off-VPN denial, strict deny and allow rule cycles, long-lived connection, idempotent plans, and clean teardown without touching other resources. It does not qualify other regions, other VPN software, the packet's Azure or AWS paths, production load, or the fixture guest firewall as a hardening reference. A9 first pass failed on the fixture, not on the module.

Packet wording: this qualifies connector networking only. It does not qualify the Agent Relay application, a private load balancer, vendor-hosted OpenVPN onboarding, customer DNS, a Cloudflare edge or HA.
