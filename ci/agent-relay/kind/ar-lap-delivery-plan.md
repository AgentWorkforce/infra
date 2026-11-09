# ar-lap delivery checklist

Updated 2026-11-08. Dates in the milestone table are executed evidence or explicit
owner commitments, never inferred from an open PR. Uncommitted planning estimates
are kept in their own section below the table.
**NOT COMMITTED** means that the owner has not supplied that date. Requests for
code, artifact and proof dates have been sent to the existing component owners.

The first cofounder handoff prioritizes Relaycast, relayhistory-pipeline and
relaycontrol, following Khaliq's setup request. A partial core fixture was
installed and proved; that is distinct from the complete product acceptance
requested originally. Static receipts do not monitor current host availability.
Add-ons remain in the overall two-profile scope, after this core handoff.

The historical 57/0/3 receipt predates the explicit `core.flows_disabled` proof
gate. New core proofs also report that requirement pending until the UI, API
and workload checks below are supported and executed; this source change has
not rerun or reattributed the historical fixture evidence.

| Milestone and owner | Code complete | Artifact available | Actual proof PASS | Remaining dependency / disposition |
| --- | --- | --- | --- | --- |
| Core fixture — infra-kind-stack | 2026-11-08: tested source `1c203f59`; three fresh-Mac portability fixes included | 2026-11-08: pinned baseline images loaded on ar-lap; native control reused from the verified Finn build, not built anew | 2026-11-08: setup exit 0; protocol **57 PASS / 0 FAIL / 3 PENDING**, exit 2; complete acceptance remains pending | [Fresh receipts](ar-lap-proof.json), [readiness](ar-lap-ready.json), [images](ar-lap-images.json), [transport](ar-lap-control-transport.json). All ten deployments and edge were ready at that run. PR #79 subsequently merged as `2a64b173`; that merge does not requalify the historical runtime receipt. |
| Pipeline-to-app session reads — pipeline-lead coordinates Muse (writer author) and layered-sessions-pipeline (review/schema boundary); infra-kind-stack owns operator wiring | **NOT COMMITTED** for the complete writer/read/canonical/TLS/auth assembly | **NOT COMMITTED** for a compatible, source-pinned OCI assembly | **NOT COMMITTED**; `pipeline.app_visibility` remains pending | #317/#318 merged as `d33bfdaa`/`a1e1473b`. PG reader #330 is open/non-draft at `0f2e8663`. Writer #336 is open/draft at `518ed0fa`, not yet re-reviewed here; the last reviewed `4bec3158` needs fixes for an invoker-trigger privilege and function grants outside the exact manifest. Native PG17/dogpatch/CI and full-bootstrap failure proof remain gates. Operator wiring requires a matching approved image/ACL migration generation and a final exact-manifest receipt. TLS, canonical catalog and compatible control auth/upload/cost contracts are still needed. |
| Control completion — layered-control | **NOT COMMITTED** for launch/release, workspace delete and compatible auth/read assembly | **NOT COMMITTED** for the complete installed assembly; merged-main `bae78a5` local candidate qualified separately in draft infra #91 | **NOT COMMITTED**; `agent_launch_release` and `cleanup.control_plane_workspaces` remain pending | Native `1f08cb6` MCP discovery/auth passes. #20 introspection merged as `bae78a5`, but is not installed in this fixture; #27 read integration remains separate. A reader-only route must not silently replace working upload/cost routes. |
| Custom Desktop — layered-relay-desktop | **NOT COMMITTED** | **NOT COMMITTED** for a site build and ar-lap install/trust instructions | **NOT COMMITTED** for installed Desktop login, upload and visible readback | Site URL `https://relay.kind.agentrelay.com:8443`, scheme `agentrelay-kind`; local public CA available. Browser/device protocol tests are not a custom Desktop artifact proof. Depends on the pipeline/control assembly and the approved local analytics path. |
| Shared-Postgres Relaycast target — layered-relaycast; ownership and estimate relayed by codex-helm-charts-check-codex | **NOT COMMITTED** | **NOT COMMITTED** | **NOT COMMITTED** | Running Cast is SQLite. Its real DM proof is useful baseline evidence, not final Postgres acceptance. Accepted task `relay-244997589034848256`, branch `agent/pg-backend`; no pushed runtime or image reported. No pushed SHA or artifact is supplied. Planning estimates are recorded separately below; no code/artifact/proof date is committed. Owner-reported #633 merge `2599154` is search-port preparation, not the PG backend. |
| One application database / isolated service schemas — component migrator owners, coordinated by infragrok | **NOT COMMITTED** for SQL/bootstrap and application compatibility | **NOT COMMITTED** for a compatible service image set | **NOT COMMITTED** | Infra #80 merged the [binding contract](../../../docs/shared-postgres-storage-contract.md), not runtime SQL. Control, pipeline, History and optional services must implement their own namespace/role contracts together; do not run the dedicated-database HoopDB bootstrap unchanged in the shared database. |
| Component analytics adapters — each producer owner; owner map coordinated with infragrok | **NOT COMMITTED** for complete producer coverage | **NOT COMMITTED** for the local collector/adapter assembly | **NOT COMMITTED** for local event capture from every component with hosted egress denied | Self-host routes to local/in-cluster file collection; hosted uses the approved PostHog endpoint. Telemetry disabled is not analytics coverage. A pipeline OTLP file exporter alone does not cover product analytics or Desktop/browser intake. |
| Add-ons — infra-kind-stack (profiles/proof), layered-control (signed license), layered-relayfile (filesystem authority), Flows runtime owner to be named | **NOT COMMITTED** for complete gated runtime | Native Flows/file build preparation exists; signed-license/scoped-authority artifact dates **NOT COMMITTED** | **NOT COMMITTED** for installed Flow run, controller-scheduled CronJob firing and authenticated file read/write | Deferred from the first cofounder core handoff, not removed from the overall goal. No dev issuer, fake license or manually instantiated CronJob counts as acceptance. |

## Attributed planning estimates, not commitments

On 2026-11-08, codex-helm-charts-check-codex relayed layered-relaycast's
estimate for the first runnable PG source head: about two working days, with
calendar estimate **2026-11-10**. No UTC delivery time or timezone was supplied.
Full conformance was estimated about a week after that first slice. These are
uncommitted source-effort estimates, not artifact, proof or full-stack delivery
dates. The milestone table deliberately keeps those dates NOT COMMITTED.

## Core profile hides and disables Flows

The [customer controls proposal in infra #90](https://github.com/AgentWorkforce/infra/pull/90)
requires UI, server and workload evidence, not only
`components.relayflows: false`. Effective capability must combine installation
selection and entitlement on the server. Core must hide Flows navigation,
worker/run/schedule links and settings/onboarding; direct URLs must show a
disabled state without fetching or running Flows. Authenticated creation, run,
schedule, worker and other Flows APIs must refuse under an owner-reviewed
status contract. Query parameters or local storage cannot enable the feature.
Selected add-on installations need their own positive tests.

This is an unresolved control/app contract, not an implemented chart input.
At control source `bae78a5`, `src/server.ts` constructs `FlowsStore`
unconditionally and passes it into `createApp`; `src/app.ts` then mounts its
handler, including authenticated `GET /api/v1/flows`. The chart's Flows storage
settings do not disable that API. The dashboard chart exposes runtime URLs and
branding, but no effective Flows capability setting. Product owners must supply
the reviewed capability/status behavior before infra wires it and replaces the
explicit pending proof gate. No runtime flag, reverse-proxy workaround or
client-only hiding is used here.

The control owner confirmed those source facts and supplied a design-only
proposal: member-readable `GET /api/v1/license`, capabilities for Flows/Chief/
Relayfile, `403 {"error":"feature_not_licensed"}` across disabled feature routes
(including worker enrollment/heartbeat), and 503 only for enabled-but-unavailable
backends. The proposed `/readyz` would echo effective features. None of these
feature/license endpoints or statuses is implemented on the reviewed main.
Implementation and app-owner assignment remain pending; the existing Chief
503 response is not a disabled-feature proof.

The control owner adopted `effective[f] = selected[f] AND entitled[f]`, replacing
the earlier precedence wording. Its proposed read would expose selected,
entitled and effective capabilities separately, with license status
`absent|valid|invalid`. No API can change selection, and an absent selection
cannot be enabled by a license. These remain design-only contracts.

Classification still needs alignment with this task's already-decided profiles:
core excludes Flows/Relayfile; the add-on profile adds both under signed offline
license enforcement. A proposed classification of Flows as entitled by definition
does not satisfy that add-on contract. For kind acceptance, both Flows and
Relayfile require explicit selection and verified signed entitlement. Infra sent
that distinction back to the control owner rather than changing the existing
decision or enabling unsigned features. There is no `SELFHOST_FEATURES` values
slot or implemented capability proof yet. No unsigned development exception is
assumed.

## Relaycast Postgres acceptance contract

The [runtime task contract](https://github.com/AgentWorkforce/relaycast/pull/602#issuecomment-6715685515)
requires a PostgreSQL-only, single-replica path in the same application database
as the other services. Platform provisioning supplies schema `relaycast`, owner
`relaycast_owner` and runtime `relaycast_runtime`; the service must not create or
adopt schemas or roles, or silently fall back to SQLite.

Infra wiring must wait for a qualified runtime head. It then needs an ordinary
template-hashed migration Job with a separate owner credential and ServiceAccount,
not a Helm hook. The server receives runtime credentials only and verifies its
binding without migrations or DDL. Expected identities are supplied independently
of the database URL, with schema-scoped migration ledger and advisory locking.
Explicit CA-file TLS must verify the server hostname and certificate chain.

Chart/operator orchestration owns the migration-Job/Deployment barrier. The
runtime owner reports verification before listen, not continuous detection of a
raised compatibility floor. An already-running server's old readiness result
cannot qualify it against a newly raised floor. The rollout plan must drain/stop
that single replica before any incompatible floor change, wait for the matching
migration Job and ledger/floor result, then restart and verify before restoring
traffic. The current chart already uses one replica and `Recreate`; that alone
does not serialize a separately created Job with the old server's shutdown.
The exact migration/verification entrypoints and barrier implementation await the
qualified PG head and reviewed compatibility contract. No barrier is claimed
implemented by this plan.

Qualification must exercise a blocked/failed migration, an existing old server
during a floor raise, fresh startup after migration, and refusal of an older
incompatible image after restart. Do not present a hot-readiness check or a
successful Job as evidence that the old running process revalidated itself.

Required qualification includes real runtime LOGIN access, tenant isolation,
restart/readback, transaction/concurrency behavior, migration replay, and denial
against seeded Control/pipeline schemas. Role membership, SET ROLE, effective
DDL/TEMP privileges, ownership and cross-schema access must fail closed when
misbound. Search ordering/public response behavior and existing SQLite/D1/actor
checks remain part of the runtime owner's gate.

An early slice must name its missing features. It is not full conformance,
multi-replica safety or managed-RDS restore/rollback evidence, and supplies no
authorization to switch a chart backend or publish/deploy an image. File/object
storage stays behind its existing port, with later S3/import/export and
ledger/image rollback compatibility explicitly tracked.

## Desktop owner build and trust contract

Layered-relay-desktop supplied readiness information against source
`6a5216749e6389c5c468db72c7ef2e4356b71e76`. **No qualified Desktop binary exists
for this target. Code, artifact and real installed-app proof dates remain NOT
COMMITTED.** A site Desktop Release dispatch is a separate release action gated
by Khaliq; infra has not dispatched, published, created environment settings or
installed System trust.

The site is fixed at build time. A default-profile app cannot be retargeted with
runtime environment variables. The site build must compile the exact origin
`https://relay.kind.agentrelay.com:8443` and scheme `agentrelay-kind`; the port is
part of the origin match. Its opaque profile id selects `desktop-<id>` in GitHub
Environments. The release owner needs the following key names, not values in
logs or handoff reports:

| Input | Required contract |
| --- | --- |
| Site identity | `AGENT_RELAY_SITE_URL`, `AGENT_RELAY_URL_SCHEME`, `DESKTOP_PRODUCT_NAME`, `DESKTOP_BUNDLE_ID`; site-profile values must differ from the default profile. |
| GitHub feed, reported working option | `RELEASE_FEED=github:<owner>/<name>`, `RELEASES_REPOSITORY`, and publisher credential references `DESKTOP_RELEASES_APP_ID` / `DESKTOP_RELEASES_PRIVATE_KEY`, or `RELEASES_TOKEN`. Feed/repository and release approval remain owner decisions. |
| Cloud feed alternative | Owner reports the signing-cap fix remains unlanded; this is not an available substitute for the first ar-lap artifact. No cloud-feed action is requested. |
| Platform and signing | macOS ARM64 DMG/pkg; existing repository Apple signing/notarization identity, not a new per-profile identity. |
| Trust and hostname resolution | Only on an operator-designated disposable fixture host, the fixture CA may be trusted in the **System** keychain for Desktop/LaunchAgent calls; remove its trust and exact certificate after testing. Do not install this unconstrained fixture CA on a general workstation. Login-keychain trust is insufficient. Use a properly trusted site certificate for a non-disposable host; no bypass is provided. |

On the reported main, a telemetry key without a host still selects the public
PostHog default. The current safe partial-fixture configuration has **no telemetry
key**; disabling telemetry does not satisfy full analytics coverage. The reviewed
fail-closed changes are not assumed landed. Full acceptance needs the actual
site adapter/gateway and local collector. The owner-reported proposed Desktop
intake `/api/v1/telemetry/desktop` remains design work, distinct from the internal
collector `POST /v1/events`. Native Desktop egress also needs its own proof;
the kind pod NetworkPolicy test does not constrain the host application.

The browser/device operator flow is compatible with this site build and requires
no public OIDC/SMTP. The [candidate request](ar-lap-desktop-request.md) records
proposed non-secret build inputs and the missing distinct public release-repository
choice. Source confirms conditional read admission for a control-named kind
History origin, including local addresses beside a genuine site build. Pushed
History still rejects this host/port and requires a scoped Desktop code change
and tests. An untrusted-origin opt-in is not an acceptance substitute, and a
profile build alone does not resolve the pipeline-to-dashboard read gap.

## Relayfile owner dates and gates

Layered-relayfile supplied the following UTC milestones. Code completion covers
the introspection/scoped-authority slice, not an installed add-on or a license.

| Milestone | Owner date / evidence |
| --- | --- |
| Auth code complete | Owner-reported **2026-11-07T19:52Z**, frozen [relayfile #568](https://github.com/AgentWorkforce/relayfile/pull/568) at `859a52a1cb62791f1ba1af9b3b597de5a9f73ea4`, based on `731ea459`. Source check confirmed the draft is open at that head with ten successful CI checks and CodeRabbit skipped. Required external review and merge dates remain **NOT COMMITTED**. |
| Compatible server artifact | **NOT COMMITTED**. No published server image is supplied by the actors/npm publishing paths. Kind can use a local source build after the approved code lands; registry publication is a separate release decision. The older native `731ea459` build does not prove the new authority contract. |
| Authenticated file write/read proof | **NOT COMMITTED**. Needs the real relaycontrol relayfile-agent token class and introspection pair, approved #568 code, chart endpoint/audience/mode and Secret inputs, the separate false-readiness fix, and an actual add-on roundtrip with genuine filesystem scopes. |

The control token-class dependency [#22](https://github.com/AgentWorkforce/relay-control/pull/22)
is open/non-draft at `e202195fecafb8c51ee7cdd39e13263cc5cccd8b`.
Control introspection #20 merged as `bae78a5`, but is not installed in this
fixture; its source merge alone does not qualify the relayfile authority pair. The backend-load/readiness issue is relayfile #569, a separate
follow-up after #568. A static `/health` 200 must not count as storage readiness.
Signed offline license enforcement remains with the control owner. No dev issuer
or token minting is authorized by these dates.

The old kind Postgres TLS-off DSN blocker is already mitigated: `Stack.credentials`
sets `RELAYFILE_PRODUCTION_DSN` with `?sslmode=disable`, and the earlier evidence
records the separate false-health finding. That operator mitigation does not
claim #569 is fixed or that authenticated persistence/readback has passed.
Future relaycontrol introspection chart slots are still pending; they are not
present merely because the old Go server boots.

## Captured pending trace

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
