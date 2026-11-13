# GKE end-to-end evidence: control plane, sessions, admin, flows, dashboard

(The standalone RelayHistory component referenced here was removed in
agent-relay 0.7.0; History is now the native read API and ingest edge.)

Summary of the internal end-to-end run on the Agent Relay GKE reference
deployment, 2026-11-03. Internal identifiers (project, cluster, workspace and
pod IDs, addresses, keys) are removed. The harness is
`scripts/selfhost/e2e-gcp-proof.sh` (with `e2e-gcp-proof-driver.mjs` and
`e2e-gcp-proof-sessions-pipeline.ts`) in this archive. It requires the
install's kube context (`--context`; it execs into the control-plane and
Sessions pods), the release Secret that holds the Relaycast internal secret
(`--secret`), and the install's public origins (derived from the control-plane
API's public URL, or `--base-domain`).

## Topology under test
- GKE (regional), Cloud SQL for PostgreSQL 17 (private IP), GCS, Memorystore,
  Pub/Sub, a global external Application Load Balancer with Google-managed
  certificates on four hosts (dashboard, api, cast, history).
- Components: relaycontrol (self-host control-plane API), Relay Dashboard,
  Relaycast, RelayAuth, RelayHistory, Sessions Pipeline, plus an in-namespace
  relayflows worker for the flows case.
- This is the live proof stack, not the 0.3.1 customer profile: it ran the
  experimental RelayHistory proof image (`sha256:72a057c2…`, relayhistory-cloud
  `74a6e526`, which carries the 0074 erasure fix), and on the final run
  Relaycast ran on durable actors (the actors gateway) instead of the SQLite
  server. The customer profile's RelayHistory and Sessions images are not
  published yet.

## Result
The final run used `--require-public` and no allowed gaps. All 15 cases passed
(`E2E_RESULT=PASS`). Runs on two other harness revisions (`a32d7fb`, `15ea0c1`) also passed.

| # | Case (as named by the harness) | Result |
|---|---|---|
| 1 | Bootstrap: the single organization is reused, two workspaces are created, a second org is refused with 409, device auth, the membership gate returns `not_member`, and a token for workspace A cannot approve for workspace B (404) | PASS |
| 2 | Messaging (in-cluster Relaycast URL): two agents register, roster, A to B, B replies in the same conversation, both see the history | PASS |
| 3 | Session delivery: a durable receipt, an identical retry returns the same receipt, one projection | PASS |
| 4 | Reads: dashboard list, replay and search, and RelayHistory read directly | PASS |
| 5 | Isolation: 28 workspace-scoped control-plane routes (sessions, flows, env vars, settings, runtime, audit, API tokens, enrollment) return 404 for workspace B on A's resources, plus RelayHistory and Relaycast tenant isolation | PASS |
| 6 | Durability: RelayHistory and Relaycast are restarted, then the session reads, the roster, the message history and pre-restart agent tokens still work | PASS |
| 7 | Auth: RelayAuth JWKS; RelayHistory token issued, and tampered, anonymous and forged-assertion requests refused; control-plane token and Relaycast key verified (invalid ones refused) | PASS |
| 8 | Sessions Pipeline: courier push, indexer, referee, summaries, bucket objects, no dead letters | PASS |
| 9 | Session erasure: list, search, replay and conversation turns are all purged (`erasure.turns_purged`) | PASS (proof-only RelayHistory image `74a6e526`; not tested against a 0.3.1 customer RelayHistory image, which is unpublished) |
| 10 | Public edge: `verify-public.sh`; API `whoami` and workspace resolve; dashboard sessions through `/cloud/api` (cross-tenant 404); Relaycast roster and agent reads; RelayHistory session list; anonymous requests refused (401); Relaycast workspace create and `/internal` denied at the edge | PASS |
| 11 | Sessions API through the public `/cloud/api`: list, filters, transcript and turns, search, activity | PASS |
| 12 | Admin: env var set, list masked, never returned in plaintext, delete; audit entries are written; `/internal` is denied at the edge | PASS |
| 13 | Flows: an in-namespace worker (`agent-relay@12.4.1`) enrolls and registers, runs one flow to COMPLETED, steps and logs are readable, and the worker is removed | PASS |
| 14 | Dashboard SPA served at `/` with `/runtime-config.js` (`apiBasePath` `/cloud/api`) and deep-link fallback | PASS |
| 15 | Cleanup (on by default): Relaycast workspaces deleted, device tokens revoked | PASS |

## Known gaps (not failures)
- relaycontrol has no workspace or user delete API, so each run leaves two
  workspaces and one user with no membership.
- The v1 worker runtime uploads no runner log, so run logs show
  `available=false`.
