# VPN connector-network live runs, 2026-11-19: review addendum

This is the review record for the two live runs of the optional VPN
connector-network modules (`docs/vpn-networking.md` in the infra repository).
It is separate from the receipts on purpose. The receipts are the operator's own text, stored byte for
byte and never edited. Corrections, timeline and the disposition go here.

Nothing was re-run or redeployed to write this file. It is built from the saved
run records.

## Stored receipts

| Cloud | File | Bytes | sha256 |
| --- | --- | --- | --- |
| GCP | [vpn-network-gcp-20261119.md](vpn-network-gcp-20261119.md) | 11994 | `31feff640b37780d5b56f51f6c8d88aa07507dbc346204887611f5e21180e8b4` |
| Azure | [vpn-network-azure-20261119.md](vpn-network-azure-20261119.md) | 10549 | `97d122ba291d53af6f4d523eaba82225698e62ffc52ddf72ba9d8012449ae3fd` |

Check them with `sha256sum docs/handoff/evidence/vpn-network-*-20261119.md`.
Both hashes equal the copies the packet owner retained. A change to either
file, including whitespace, breaks that match: put corrections in this
addendum instead.

Raw evidence (addresses, cloud identities, Terraform state, saved plans, guest
scripts, per-assertion logs) stays in the operator's private store and is not
in this repository.

## GCP: disposition

Decided by the packet owner after reviewing the receipt, the supplemental
hashes and the timeline below.

- **First pass: FAIL, retained.** Assertion 9 failed on its first pass. From
  the VPN client, tcp 22 and tcp 8081 on the hub's tunnel address and tcp 22 on
  the connector's tunnel address were open. The proof packet
  (`terraform/examples/vpn-network-proof/README.md`) says a failure keeps a
  run unqualified. That first-pass result is not withdrawn or
  replaced by the second pass.
- **After the guest-only correction: functional PASS of the connector module,
  with disclosed deviations.** The correction changed the test guests' own
  firewall (hub, connector and client). No module input, cloud firewall rule or
  project setting changed. The deviations are those listed in the receipt plus
  the gap recorded below.
- **Not granted:** a clean first-pass qualification, and qualification of a
  full customer profile.

## GCP: strict cycle against the guest fix

All times are UTC on 2026-11-19. A6 is the strict-mode cycle (steps S1 to S4);
A4, A5, A8 and A9 are the receipt's assertions of the same number.

| Time | Event |
| --- | --- |
| before 22:24:17 | A9 first pass: FAIL (three rows open) |
| 22:24:17 | Guest fix applied on hub, connector and client: an input chain on the tunnel interface. The applied rules of all three guests were dumped into the first-pass A9 evidence file |
| 22:27:10 | A6 started |
| 22:27:23 | S1 applied |
| 22:28:14 | S2 plan gated |
| 22:28:25 | A later tightening was written to the hub guest script: tunnel DNS limited to the VPN source range. This is the file's write time, not the time it was applied on the hub |
| about 22:31 | A6 finished (S4 done) |
| 22:31:04 | Second passes of A4, A5 and A8 began, in default mode after S4 |
| 22:36:35 | A9 second pass began. Its header names the DNS source limit |

What the record shows:

- Every strict step, S1 to S4, ran after the fix that closed the management
  ports.
- S1 ran without the hub DNS source limit.

What the record does not show:

- **The time the hub DNS source limit was applied was not recorded.** It lies
  between 22:28:25 and 22:36:35. For S2, S3 and S4, and for the second passes
  of A4, A5 and A8, the evidence cannot show whether they ran before or after
  it.
- **No rule dump of the final hub chain was captured.** The only saved dump of
  the hub's rules is the 22:24:17 state, in which DNS on the tunnel interface
  was open to any tunnel source. The final state is shown only by the script
  (hash below) and by the A9 second pass passing.
- **Only the A9 second pass is shown to have run on the final DNS
  configuration.**

Operator's assessment, which is an assessment and not evidence: the strict
cycle uses tunnel DNS only from the client, which is inside the VPN range and
was allowed both before and after the limit, so no effect on A6 is expected.

Add this to the receipt's deviation list when reading it: the hub DNS source
limit was applied during or after the strict cycle; its apply time and the
resulting rule dump were not captured.

## GCP: supplemental hashes

These identify private files in the operator's store, as they stood at the end
of the run. The guest scripts are in no repository.

| File | sha256 | Last write (UTC) |
| --- | --- | --- |
| guest/lib.sh | `66172a14e5da33ba1a788375a30e5420c3db87301f675689d483ac70dbdc3ba1` | 22:23:18 |
| guest/hub.sh | `1baded5f4720145abd0914511bf8d287e084d29a413db71195613265151af2dc` | 22:28:25 |
| guest/connector.sh | `4632ffde80cebd60f079c96a8b8619eaab7e153e1c48ecd4653ee64ea047d4c4` | 22:23:31 |
| guest/client.sh | `ca3ad9f45dae0b08988f118a9153121d7d5188fdd0c8bf56f71deaab9c4469f9` | 22:23:31 |
| guest/probe-client.sh | `0459d62b60c1c751d7148d14c253a8732ca1e9d86b102836006b27846cf8227f` | 22:22:54 |
| evidence, A9 first pass (with the 22:24:17 rule dump, re-probe and regression checks) | `613417808afa366ff46858a9c2c7d510df84ca94556a8bcee5f8f79c303ac3c9` | |
| evidence, A9 second pass | `dfe4419466f79e08087b3b2572486fc8122b1142a2d4e6215520962ab5584230` | |
| evidence, A6 strict cycle | `ce434e775b120417a404d009ee24b3e0258bf2447f921c5f08cbb6aa62c1f15f` | |
| unsanitized results | `33b630d3eb1c68c99eca8e642239cf9de1d6f5e777cbe2944032b4a44f7f97dc` | |

What the final guest rules do, per script: the hub accepts on the tunnel
interface only established traffic, DNS from the VPN range and ICMP echo. The
connector and client accept only established traffic and ICMP echo. The
connector forwards only the VPN range to the observer front on tcp 443, with
return traffic, and masquerades only that pair. Each is installed as a systemd
unit ordered before the VPN service, so it is applied again at boot.

The GCP receipt gives the packet README's sha256 as `df96b60c…`. That is the
file at merged commit `163422f8`. The packet is unchanged by the change that
added this addendum, so the hash still matches the file in this repository
until the packet is next edited.

## Azure

- The stored receipt equals the copy the packet owner retained (hash above).
  It is preserved, not regenerated.
- The run was made before the packet existed. It applied commit `399c2435`,
  the head of the module's pull request at the time, which does not contain
  the packet. It therefore uses its own test list (G1 to G5 and L1 to L11) and
  not the packet's ten assertions. No mapping between the two is made here.
- The module and example trees it tested are the ones that merged: the git
  tree ids in the receipt (`f3662527…` for the module, `2712fcba…` for the
  example root) are the same at merged commit `f92de10c`.
- The operator's verdict in the receipt is a pass for the proxy path, with four
  findings and four deviations. The deviations include a temporary bootstrap
  rule, and one private key that was first placed in cloud-init custom data and
  replaced before any test.
- No packet-owner disposition of the Azure run is recorded in this file. Until
  one is added, read the receipt as operator-reported evidence for the paths
  it tested, not as a qualification under the packet.

## Limits that still stand

- **AWS has no live run.** The AWS module has provider-schema validation and
  mock-provider tests only.
- **The application is not qualified.** Neither run deployed Agent Relay. No
  sign-in, Desktop upload, MCP or WebSocket path was tested through a
  connector.
- **IPv6 was not tested.** The profile is IPv4-only.
- **Private load-balancer routing was not tested.**
- **No vendor VPN product was tested.** Both runs used OpenVPN Community with a
  throwaway certificate authority, not a vendor-hosted VPN or its onboarding.
- Also outside both runs: customer DNS, a Cloudflare edge, high availability,
  production load, and any region other than the one used per cloud.
- Each cloud has one run. The GCP test guests' firewall is a fixture, not a
  hardening reference.
