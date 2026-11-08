# ar-lap delivery checklist

Updated 2026-11-08, 02:35 UTC. Dates below are executed evidence or explicit
owner commitments, never inferred from an open PR or an estimated hosted rollout.
**NOT COMMITTED** means that the owner has not supplied that date. Requests for
code, artifact and proof dates have been sent to the existing component owners.

The first cofounder handoff prioritizes Relaycast, relayhistory-pipeline and
relaycontrol, following Khaliq's setup request. A partial core fixture is running
now; that is distinct from the complete product acceptance requested originally.
Add-ons remain in the overall two-profile scope, after this core handoff.

| Milestone and owner | Code complete | Artifact available | Actual proof PASS | Remaining dependency / disposition |
| --- | --- | --- | --- | --- |
| Core fixture — infra-kind-stack | 2026-11-08: tested source `1c203f59`; three fresh-Mac portability fixes included | 2026-11-08: pinned baseline images loaded on ar-lap; native control reused from the verified Finn build, not built anew | 2026-11-08: setup exit 0; protocol **57 PASS / 0 FAIL / 3 PENDING**, exit 2; complete acceptance remains pending | [Fresh receipts](ar-lap-proof.json), [readiness](ar-lap-ready.json), [images](ar-lap-images.json), [transport](ar-lap-control-transport.json). All ten deployments and edge ready. PR #79 publication `96fc3b7` is mergeable; all six Actions checks were still queued at this update. Merge approval is separate. |
| Pipeline-to-app session reads — pipeline-lead coordinates layered-sessions-pipeline; infra-kind-stack owns operator wiring | **NOT COMMITTED** for the complete writer/read/canonical/TLS/auth assembly | **NOT COMMITTED** for a compatible, source-pinned OCI assembly | **NOT COMMITTED**; `pipeline.app_visibility` remains pending | #317/#318/#330 are drafts. #330 supplies a PG reader composition, but needs a real projection writer, approved schema/grants and verified TLS; canonical catalog binding and compatible control auth/upload/cost contracts remain. Operator wiring must follow a matching image/ACL generation. |
| Control completion — layered-control | **NOT COMMITTED** for launch/release, workspace delete and compatible auth/read assembly | **NOT COMMITTED** | **NOT COMMITTED**; `agent_launch_release` and `cleanup.control_plane_workspaces` remain pending | Native `1f08cb6` MCP discovery/auth passes. #20/#27 are draft successors, not enabled. A reader-only route must not silently replace working upload/cost routes. |
| Custom Desktop — layered-relay-desktop | **NOT COMMITTED** | **NOT COMMITTED** for a site build and ar-lap install/trust instructions | **NOT COMMITTED** for installed Desktop login, upload and visible readback | Site URL `https://relay.kind.agentrelay.com:8443`, scheme `agentrelay-kind`; local public CA available. Browser/device protocol tests are not a custom Desktop artifact proof. Depends on the pipeline/control assembly and the approved local analytics path. |
| Shared-Postgres Relaycast target — runtime owner to be named; owner/date request sent to codex-helm-charts-check-codex | **NOT COMMITTED** | **NOT COMMITTED** | **NOT COMMITTED** | Running Cast is SQLite. Its real DM proof is useful baseline evidence, not final Postgres acceptance. Prerequisite source tests such as #633 do not establish a deployed PG backend. |
| One application database / isolated service schemas — component migrator owners, coordinated by infragrok | **NOT COMMITTED** for SQL/bootstrap and application compatibility | **NOT COMMITTED** for a compatible service image set | **NOT COMMITTED** | Infra #80 merged the [binding contract](../../../docs/shared-postgres-storage-contract.md), not runtime SQL. Control, pipeline, History and optional services must implement their own namespace/role contracts together; do not run the dedicated-database HoopDB bootstrap unchanged in the shared database. |
| Component analytics adapters — each producer owner; owner map coordinated with infragrok | **NOT COMMITTED** for complete producer coverage | **NOT COMMITTED** for the local collector/adapter assembly | **NOT COMMITTED** for local event capture from every component with hosted egress denied | Self-host routes to local/in-cluster file collection; hosted uses the approved PostHog endpoint. Telemetry disabled is not analytics coverage. A pipeline OTLP file exporter alone does not cover product analytics or Desktop/browser intake. |
| Add-ons — infra-kind-stack (profiles/proof), layered-control (signed license), layered-relayfile (filesystem authority), Flows runtime owner to be named | **NOT COMMITTED** for complete gated runtime | Native Flows/file build preparation exists; signed-license/scoped-authority artifact dates **NOT COMMITTED** | **NOT COMMITTED** for installed Flow run, controller-scheduled CronJob firing and authenticated file read/write | Deferred from the first cofounder core handoff, not removed from the overall goal. No dev issuer, fake license or manually instantiated CronJob counts as acceptance. |

## Exact current pending trace

The new ar-lap courier session `7b847789-498a-4e30-8188-cd5cb504407e` passed
upload, owner attribution, indexer, referee, Locker, trace/event and scrub checks.
The real Default workspace application API returned 200 without that session.
That is **one** pipeline visibility gap. The other two protocol pending checks
belong to control: missing launch/release and workspace deletion returning 404.
Pipeline completion alone cannot turn all three into PASS.

The existing runtime's approved database composition is one Postgres instance
with separate service databases/roles. The exact pipeline ACL guard is unchanged.
No second migrator, manifest union, shared runtime role, fake completeness row
or privileged application login may substitute for the supported composition.
The running fixture's separate service databases do not qualify the final single
application-database target. Infra #80's bindings keep `application_sql_ready`
false. A reviewed owner-specific bootstrap and application migration path is
required; changing only database URLs or `search_path` cannot establish it.

The merged [collector interface](../../../docs/analytics-collector-interface.md)
is likewise an implementation contract, not a running collector or producer
coverage proof. The local app/desktop gateway must derive tenant authority and
keep collector producer credentials away from clients.

## Date and ETA rule

Each owner must provide UTC dates or conditional ranges for code complete,
artifact available and actual proof PASS, together with prerequisites and any
required approval. A build may be local or a verified transferred artifact;
registry publication is not inherently required for kind. Record provenance
honestly. Missing implementation cannot be solved by publishing an older image.

The delivery range is determined by the last complete dependency path, including
pipeline reads, Desktop, control, Cast and required analytics. While a critical
line is **NOT COMMITTED**, there is no supportable single full-E2E ETA. Flag that
line to Khaliq for prioritization rather than assigning an invented date. The
hosted History estimate of December 11–16 is a separate Cloud chain and supplies
no ar-lap date.

No date request authorizes merge, registry publication, cloud deployment or
enabling an unapproved runtime assembly. The already requested local ar-lap
fixture remains running. Its machine-local `.kind/ar-lap-setup.md` contains the
TLS, hostname and genuine own-code operator login handoff; no host trust or DNS
settings were changed by setup.
