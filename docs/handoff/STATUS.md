# Release status: what is proven and what is preview

Current release: `agent-relay` chart 0.3.12, published from the
`agent-relay-0.3.12` tag by `release-agent-relay.yml`
([release run](https://github.com/AgentWorkforce/infra/actions/runs/41985579885)).
It is pullable anonymously from `oci://ghcr.io/agentworkforce/charts/agent-relay`.
0.3.12 adds durable actors on AWS EKS (`values-eks-actors.yaml`, off by
default) on top of 0.3.11. Every image
`values-gcp.yaml` renders is now a public GHCR release digest: the
control-plane API (selfhost-api 0.3.0), the redesigned dashboard,
RelayHistory and the Sessions services image join Relaycast, RelayAuth and
PostgreSQL, so there is no REQUIRED OVERRIDE image left. 0.3.11 includes the
never-tagged 0.3.7 (Desktop deep-link settings), 0.3.8 (integration OAuth
apps), 0.3.9 (first-boot bootstrap, OIDC / email sign-in and invites) and
0.3.10 (the AWS EKS profile `values-eks.yaml`, proven on EKS Auto Mode).
Upgrading from 0.3.6 or earlier needs the HoopDb role bootstraps described in
RELEASE_NOTES.md.

Published versions of the umbrella chart:

| Version | Tag | Notes |
|---|---|---|
| 0.3.1 | `agent-relay-0.3.1` | First published version. Relaycast `a05732ad…` (no SBOM, min-mode provenance). |
| 0.3.3 | `agent-relay-0.3.3` | Pins the attested Relaycast image `81274dca…` (engine 12.7.0) and the GKE proof-overlay refresh. 0.3.2 was never tagged. |
| 0.3.4 | `agent-relay-0.3.4` | Documentation patch of 0.3.3 (Relaycast `ar_` credentials guidance). Published by [run 41754926487](https://github.com/AgentWorkforce/infra/actions/runs/41754926487). |
| 0.3.6 | `agent-relay-0.3.6` | Opt-in single-host mode and optional dashboard `customerProfile` branding (relay-dashboard 0.1.2); 0.3.5 was never tagged. Published by [run 41769269329](https://github.com/AgentWorkforce/infra/actions/runs/41769269329). |
| 0.3.11 | `agent-relay-0.3.11` | Public release digests for every customer image (selfhost-api 0.3.0, dashboard redesign, RelayHistory, Sessions services with origin-bound ingest auth). Includes the never-tagged 0.3.7 (Desktop deep links), 0.3.8 (integration OAuth apps), 0.3.9 (bootstrap, OIDC / email sign-in, invites) and 0.3.10 (AWS EKS profile). Published by [run 41812609280](https://github.com/AgentWorkforce/infra/actions/runs/41812609280). |
| 0.3.12 | `agent-relay-0.3.12` | Durable actors on AWS EKS: S3 actor storage, per-actor STS by default, `values-eks-actors.yaml` with six public GHCR actor images, `scripts/selfhost/eks-actors-install.sh`. Actor components stay off by default; customer images and `values-gcp.yaml` are unchanged from 0.3.11. |

This release is for **review by a company evaluating a self-hosted Agent Relay
on GCP**. It is a reviewable `portable-single` release that pins every
image by a public digest. It is not
a production-readiness or high-availability claim. The fail-closed customer
release gate (`scripts/release/validate-customer-release.py`) does **not** pass
yet. The items it still reports, and the blockers it does not check, are listed
under "Not yet done; planned" below.
This archive is therefore labelled a development preview.

## Proven

| Area | Evidence (what was checked, including its limits) |
|---|---|
| Licensing | Apache-2.0 at `main` for relaycast, relayauth, relaycontrol (control-plane API), relay-dashboard and this chart repository. Sessions Pipeline is Apache-2.0 by owner decision; its LICENSE landed on `main` in sessions-pipeline #172 (merge `51b38ff`), after the image revision recorded in the manifest (`7d7229b`). RelayHistory is Apache-2.0 by owner decision; its LICENSE PR (relayhistory-cloud #279) is open and held, so no RelayHistory revision carries it yet. The third-party PostgreSQL image (CloudNativePG) is Apache-2.0 packaging. See `self-hosted/customer-release-evidence.json` (`licenses.firstParty`). |
| Image supply chain | Per image in `self-hosted/customer-images.yaml`; every row is approved and public on GHCR with linux/amd64 and linux/arm64 verified anonymously. The control-plane API (`selfhost-api` 0.3.0, relaycontrol `9b80b04`), dashboard, RelayHistory (relayhistory-cloud `53c3333`) and Sessions services (sessions-pipeline `f1c2672`) images were built by their reviewed release workflows from `main` commits with an SBOM and max-mode provenance; the dashboard and Relaycast also carry a GitHub build-provenance attestation (the RelayHistory and Sessions attestation steps failed on their private source repositories after the push). The RelayAuth image has an SBOM and provenance. The CloudNativePG PostgreSQL digest is verified against upstream revision `4c2710a` (keyless cosign signature verified). |
| End-to-end function on GKE | The live proof deployment (not the 0.3.1 or later customer profile: it ran the experimental RelayHistory proof image, and Relaycast on durable actors in the final run) passed all 15 end-to-end cases: single-org bootstrap, Relaycast messaging, session delivery and reads, workspace isolation on 28 routes, restart durability, RelayAuth verification, the Sessions Pipeline, session erasure, public-edge checks, the sessions API, admin env vars and audit, flows on an in-namespace worker, the dashboard and cleanup. See `docs/handoff/evidence/gke-e2e.md`. The harness is in `scripts/selfhost/`. |
| Upgrade and restore drills | An isolated GKE drill of agent-relay 0.1.1 ran a quiesced backup (writers stopped for 314 s) and a restore into a separate Cloud SQL instance, bucket, PVCs and namespace. All seven recorded verification gates passed (Cloud SQL, Relaycast and RelayAuth integrity, GCS integrity, isolated messaging, cross-workspace denial, no production references). No data was lost between the quiesce point and the capture. RTO was 387 s to pods Ready and 578 s to the gates passing; a cold restore adds about 189 s of instance creation (about 767 s, about 12.8 min). The pre-upgrade gate passed (OK), and an upgrade from 0.1.1 to the release candidate passed 17/17 checks (run before the Sessions chart rename that the final 0.3.1 also contains). Neither ran the full release image set: the restore ran the 0.1.1 drill images, and the upgrade ran previous or live-proof images for `selfhost-api`, RelayHistory and Sessions. See `docs/handoff/evidence/gke-upgrade-restore-drills.md`. |

## Preview (optional, off by default, not in the customer image matrix)

- **Relaycast on durable actors** (gateway plus durable-actors control plane):
  the chart (since 0.3.1) includes the optional `durable-actors` dependency
  (`components.durableActors`, off by default) and
  `relaycast.runtime.backend=durable-actors`. Its images and profile are not
  part of the gated customer image matrix (`self-hosted/customer-images.yaml`),
  and the invoke-only control-plane patch the proof used is not upstream. It
  was proven on GKE with 4 known Relaycast end-to-end suite failures
  (`docs/handoff/evidence/gke-durable-actors-preview.md`).
- **Durable actors on AWS EKS** (0.3.12, `values-eks-actors.yaml`, a
  standalone profile, off by default): Relaycast and Relayfile in actor mode
  on S3 with per-actor STS credentials. Proven in a Pippen sandbox on
  2026-11-04: activation, the Relaycast harness 18/18, the Relayfile mount
  e2e and a cross-actor negative check 15/15. The proof's Postgres (a
  single-replica, emptyDir, plaintext in-namespace database) and its
  generated Secrets are proof-only, so it does not cover a production install;
  use a managed Postgres with TLS. Its six images are public, but
  they are not in the gated matrix and have no customer approval yet. The
  two durable-actors images are linux/amd64 only.
- **Relayflows in-cluster** (`components.relayflows`, off by default): see
  `docs/self-hosted-relayflows.md`.
- **Integration OAuth apps** (relay-cloud-api 0.2.3,
  `integrations.<provider>.existingSecret`, none by default): the customer's
  own OAuth app per integration, for just-in-time connects from the CLI and
  flow pages. Not verified with a real provider app yet. The pinned
  selfhost-api 0.3.0 image includes it (relaycontrol #12).

## Not yet done; planned

These gate items are open. None of them is claimed.

- **Branch and environment controls**: the chart repository has no branch
  protection or protected release environment yet. The gate records
  `release.branchControls` / `environmentControls` as unprotected.
- **Operational readiness** (`supported-100`: 100 users, 50 concurrent agents,
  10,000 sessions/day): the 24-hour soak, burst, drain and fault phases in
  `docs/operations/capacity-and-load-test.md` have not run. Alerts, dashboards
  and runbooks evidence are not produced. No SLO or capacity claim is made.
- **Version compatibility** (server N and N-1 x Desktop current and previous): not
  run (server N is 0.3.12, N-1 is 0.3.11).
- **Desktop**: the custom-origin Desktop (self-hosted sign-in) passes CI on
  macOS arm64/x64, Linux x64/arm64 and Windows (relay-desktop CI run
  41606660810), but it is not merged or released yet.
- **High availability**: Relaycast and RelayAuth are single-writer SQLite
  workloads on RWO volumes.
- **Session ingest auth on GKE**: with the interim RelayAuth bearer off,
  couriers present origin-bound History assertions, which the 0.3.11 Sessions
  services image verifies. This passed end to end on the EKS proof (15/15);
  it has not been re-run on GKE with the 0.3.11 image set (0.3.12 keeps it).
- **Release evidence bound to this manifest**: the gate also rejects evidence
  that was recorded against other images. The upgrade and restore drills ran
  other image sets than `self-hosted/customer-images.yaml` (and the restore
  ran chart 0.1.1). The RelayHistory migration evidence is for the live-proof
  image (relayhistory-cloud `74a6e526`), not the manifest's revision
  (`53c3333`).
- **Dashboard API prefix**: the self-host dashboard only talks to the
  same-origin `/cloud/api` prefix (route `/cloud/api` and `/login` to the
  control-plane API).
- **Customer release gate**: `python3 scripts/release/validate-customer-release.py`
  fails closed on the gate items above; the archive includes the structured
  evidence in `self-hosted/customer-release-evidence.json`.
