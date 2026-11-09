# Local kind evidence — 2026-11-08 (Europe/Oslo)

Status: **core setup READY; core proof PENDING (57 PASS, 0 FAIL, 3 PENDING); add-on E2E not run**.
These are local development results, not the customer release or managed-cloud
infrastructure proof. Reproduction uses the current repository checkout;
source identities are pinned below.
The first negative run used PR #76 at `73f9a0eb8ab52e390856e5bd5ca3812e19f5fe7a`; the current receipts below pin the successful setup and latest proof separately.
No cloud account, registry publication, deployment outside kind, or image/volume
pruning was performed.

## Fresh ar-lap setup and protocol proof

At source `1c203f59fd22c4355fe309244593eef24e40d1ea`, a subagent performed
a fresh install on ar-lap, a native ARM Mac, following Khaliq's explicit setup
request. `make kind-up PROFILE=core` exited 0; all ten suite deployments and
Traefik were ready. A single real `make kind-proof PROFILE=core` run recorded
**57 PASS, 0 FAIL, 3 PENDING**, exit 2. The byte-identical, credential-checked
[proof](ar-lap-proof.json), [readiness](ar-lap-ready.json),
[image/generation](ar-lap-images.json) and
[control artifact transport](ar-lap-control-transport.json) receipts are separate
from the earlier Finn reuse receipts below.

The native control image was reused from the verified Finn build at `1f08cb6`,
not built on ar-lap. The archive SHA-256, native platform, source revision,
manifest digest and config digest were checked before import. No registry
publication or credential transfer was needed. Three portability fixes were
exercised on the actual Mac: anonymous public Docker pulls without keychain
access; Docker exports without optional descriptor platform metadata, while
mandatory native image-config and digest checks remain; and LibreSSL signing
keys converted to PKCS#8 with the same public identity and a private backup.
The final source also passes 58 Python and 9 Node checks locally; the three auth
key tests additionally passed against macOS LibreSSL. GitHub Actions completion
is a separate requirement and is not implied by these local results.

The new courier session `7b847789-498a-4e30-8188-cd5cb504407e` was uploaded,
indexed and verified through Locker/referee with real owner attribution, trace
and processing events. The Default workspace application API returned HTTP 200
without that session, so `pipeline.app_visibility` is still pending. Launch/
release and fixture workspace deletion are the other two pending checks. Cast
uses SQLite in this baseline; this does not qualify the final shared-Postgres
target, a custom Desktop artifact, component analytics adapters or add-ons.

On ar-lap, the running fixture is in
`~/Projects/AgentWorkforce/infra-worktrees/kind-core`. Source its private scoped
`.kind/ar-lap-env.sh` for local tools and kubeconfig. Its login endpoint is
`https://relay.kind.agentrelay.com:8443/login`; a verified-CA request returned
200. The public CA and hosts entries are `.kind/core/ca.crt` and
`.kind/core/hosts`. No system trust or DNS changes were made. The local operator
login helper verifies this installation's own organization, workspace and real
owner before approving a human's own pending device code; no human code was
approved during setup. The machine-local `.kind/ar-lap-setup.md` contains the
complete access instructions. The cluster remains running for the cofounder.

## Earlier Finn ownership and live reuse validation

Explicit recovery at `1c7838b` required the native UID already captured in the
original readiness receipt, matched it against the live cluster and node labels,
backed up the legacy record and wrote versioned local ownership. It did not
recreate the cluster or replace the kubeconfig. Normal reuse refuses legacy
receipts and does not infer ownership from live labels or a live UID alone.

At source `c6184d6`, `make kind-up PROFILE=core` completed with exit 0,
using the already selected native control image built from `1f08cb6`. The
harness emits private `.kind/core/ready.json`; its manually copied, byte-identical
[snapshot](core-ready.json) records source revision, ownership version, native
identity, recipe/render hashes and fresh exact-ACL Job
`kind-combined-acl-009152af5378a8aa`. The full proof at `fd8565c` records
57 PASS, 0 FAIL, 3 PENDING, exit 2. This is live recovery/reuse validation,
not a fresh cluster creation/deletion cycle. Setup and proof source revisions
are recorded separately because the later change corrects the verifier's
handling of the explicitly disabled optional transform, without changing setup.

## Current core setup and protocol proof

```sh
# Existing fixture with the native control selection already present:
make kind-up PROFILE=core PYTHON=python3
make kind-proof-core PYTHON=python3
# Historical reproduction builds the recorded 1f08cb6 source first:
# KIND_CONTROL_SOURCE=historical make kind-up-local-control PROFILE=core PYTHON=python3
```

Setup completed with exit 0 and a readiness receipt, including the application
returning HTTP 200 over verified TLS. The protocol proof exits 2 (**PENDING**),
not 0. Its [complete credential-checked report](core-proof.json) records proof
source `fd8565c`, 57 passing checks, no failed checks, and three pending checks.
The [image/generation receipt](core-images.json) records the rendered suite chart images and services generation.
The node image is in `core-ready.json`; support Postgres/probe image pins are
in `stack.py`. This captured snapshot is not automatically refreshed by a
subsequent setup invocation. The same manual copy applies to `core-proof.json`,
`core-images.json` and `control-build.json`; their embedded revisions identify
the recorded setup/proof/build runs; they are not automatically rewritten by later edits.
Selected literal proof output:

```text
PASS core.egress: external baseline connects; suite and edge external TCP denied; internal DNS/backend/API connects
PASS app.tls_session_read: trusted local TLS, relay-app HTML, and delivered session through /cloud/api
PASS app.cast_tls_dm: both agents send/receive through verified public Cast TLS origin; internal route denied at edge
PASS cost_attribution: reported fixture usage/cost preserved through public History TLS ingest and application TLS read API; owner user/workspace match; other workspace denied
PASS pipeline.owner_attribution: ingest and derived index match the real signed-in owner
PENDING pipeline.app_visibility: courier upload/index/Locker verified, but authenticated Default workspace application API returned 200 without that session; read-path integration contract required
PASS mcp: both trusted public TLS paths initialize, list19 tools and report the real workspace; missing auth401 and foreign origin403
PENDING agent_launch_release: layered-control: launch/release API not implemented
```

The third pending check is fixture workspace retention: the control API has
no workspace deletion endpoint. Generated device sessions were revoked and
their access/refresh failures verified; test workspaces remain in this
worktree's disposable cluster until `kind-down`.

Database isolation resolved the original setup failure. The existing
`docs/self-hosted-eks.md:36` and `scripts/selfhost/eks-proof-install.sh` already
use a distinct History database. Kind now uses one local Postgres instance with
separate `relaycontrol`, `relayhistory` and `hoopdb` databases and distinct
runtime/migration-owner roles. Both migration Jobs and the unchanged final
`runtimeRoleViolations` / `sessionsFunctionAclPreview` check pass. No manifest
union, grant widening or privileged runtime connection was substituted.

The proof exercises two data paths separately:

- History delivery → its database → relay-app/read API passes, including a
  client-reported fixture of 320 input tokens, 52 output tokens and 125000 USD
  micros, attributed to the real owner/workspace and denied to another workspace.
  No external model call or vendor billing calculation is involved.
- Courier → ingest → HoopDB/indexer/referee/Locker passes. Both index rows match
  the real signed-in owner. A real device session for the Default workspace then
  reads the application API: HTTP 200, but the courier session is absent. This
  remains a **required pending application read-path integration**, not a pass
  inferred from storage. Relaycontrol already proxies these reads to
  `RELAYHISTORY_URL`; it has no separate pipeline read path and needs no new
  pipeline URL. The pending boundary is courier/pipeline → RelayHistory workspace
  session visibility. Pipeline and RelayHistory owners, coordinated by
  pipeline-lead, have the concrete request and source/image identities.

Pipeline owner clarification at main `d9c1cbad` / introspection merge `5cdc9d8f`:
`src/session-read-api` is a Hono API with a Lambda adapter, and
`packages/session-read-worker` is its Workers port. Neither is a supported
container SERVICE in `docker/entrypoint.sh`; the large-read worker is a scan
worker, not this API. A self-host deployment/interface decision is pending with
Khaliq and service owners. A container entry alone would not establish the
pipeline → RelayHistory workspace read contract required above. Kind does not
substitute an ad hoc server command or deploy a cloud adapter to hide this gap.

The edge class is explicitly `traefik`, matching the profile Ingress objects.
Traefik's version/usage checks are disabled. Its own namespace denies external
egress while allowing only stack backends, DNS and this cluster's API endpoint
addresses/ports. The proof checks both namespace policies and real denied edge
and app connections, with a successful unrestricted control and internal probes.
TLS uses CA/leaf key identifiers and strict chain verification; only the server
leaf key is mounted. Old fixture certificates are reissued by setup as needed.

## Draft read-service review and fixture diagnosis

[Read API contract review](read-api-contract.md) records draft #317/#318 inputs,
readiness requirements and upstream blockers. Read-only catalog queries find one
matching courier directory row and populated canonical identity columns in
HoopDB; missing directory data is not the explanation for this fixture. The
[diagnostic receipt](pipeline-directory.json) does not claim canonical RPC/object
reads or application visibility. No chart component or service was enabled.

## Local MCP-capable control build and public endpoint proof

The recorded historical `kind-up-local-control` run built the official Dockerfile at
`relay-control-internal@1f08cb624be66016eb0c135363553dd44e58f691`, with a pinned
native Node base. This historical commit remains available from the archived
private repository for explicit `KIND_CONTROL_SOURCE=historical` reproduction.
Current builds instead pin public `relay-control@df4b3901768809407c7c6e1e0d28031e2c2fa25d`
in a separate cache. Existing build and runtime receipts below are unchanged and
have not been rerun or attributed to the current source.
The [current native candidate receipt](control-df4b390-smoke.json) records the
official helper build at infra `30270e7` and an owned PostgreSQL 17 fixture.
Synthetic rows survive 17-to-23 migrations, the next migration run is a no-op,
and the runtime role reads application data while migration-ledger reads remain
denied. Native health, readiness and organization reads return 200. The actual
workspace DELETE route returns 204 for owner, bootstrap and allowed-origin cookie
requests, and refuses anonymous, member, foreign-org, Factory-bound and last
workspace requests. The Default workspace and foreign seeded rows remain;
deleted workspace sessions become invalid and delete audits remain org-scoped.
The fixture, its synthetic secrets and its internal Docker network were removed.
This is candidate behavior, not an installed-profile or external-object erasure
receipt. The initial fixture omitted multi-tenant bootstrap settings and refused
startup; the retained first-attempt receipt and corrected passing run are
separate, with the same image bytes.
The [previous readiness candidate receipt](control-e74413b-smoke.json) records an
actual arm64 build through this helper and a disposable PostgreSQL 17 upgrade
test: synthetic rows survive 17-to-23 migrations, a second run applies zero,
and health, readiness and an authenticated organization read return 200 with
the supported runtime role while migration-ledger SELECT remains denied.
The fixture uses private plaintext transport, not TLS, and qualifies neither
an installed profile nor MCP, Desktop, cloud or full pipeline readback.
The historical command
above requires `KIND_CONTROL_SOURCE=historical`; its default now selects the
`53252e3` candidate from open Control PR #23. That source is not represented here
as upstream main or as runtime-qualified. The earlier `df4b390` smoke receipt is
historical evidence for that source only, not runtime proof for `53252e3`.

The retired public pin `a659ac4` fails readiness with the supported runtime
database role: readiness reads the migration ledger, which the runtime grants
deliberately deny. The current pin includes the catalog-based readiness fix
merged in Control PR #10. Its source checks do not reattribute the historical
MCP, full-profile or installed-client proof to this new pin.
The [raw build receipt](control-build.json) records the native manifest
and config digests, source revision, tag, architecture and base image. It was
built and tested on linux/arm64. No registry publication occurred.

The native manifest, rather than a config ID or multi-platform index ID, is used
as the chart digest. The loader verifies metadata bytes and source/architecture,
checks the node's imported manifest, registers the matching digest reference and
verifies CRI resolution. The workload uses pull policy Never. Tenant bootstrap
preserves the chosen image and overrides stale component org IDs with the
organization actually discovered from control. Setup refuses an image-set
change during bootstrap; the MCP proof compares the live API container with the
exact selected control image.

Both `/api/v1/mcp/shared-sessions` and `/cloud/api/v1/mcp/shared-sessions` pass
real-device-token initialization, nineteen-tool discovery and
`describe_capabilities`, including exact workspace and each alias's public URL.
Missing authentication returns 401 and a foreign Origin returns 403. This proves
the endpoint/discovery/authorization contract, not every tool's backend or agent
launch/release. The remaining required courier-read integration is unchanged.

The first native-image attempt exposed Helm 4 server-side field conflicts with
bootstrap's client-side apply. The local wrapper selects the supported
client-side reconciliation mode. A subsequent proof caught tenant bootstrap
resetting the image selection; preservation and exact-image guards were added.
The cloud alias advertises its own public path, which the proof now validates.
Repeated device-login runs reached the real 10-starts/5-minute limit; a full quiet
window was honored before this final complete run. Limits were not disabled or
reset, and diagnostic device sessions were revoked.

The catalog values remain on their audited published image. A clean catalog-only
fixture therefore still reports MCP pending. To reproduce the source selection
for the recorded MCP check, use the local-control command above with
`KIND_CONTROL_SOURCE=historical`. The default current-source command does not
reproduce this historical proof; rebuilt image bytes and a new run need their
own receipts.

## Historical unsupported database co-location (negative evidence)

```sh
make kind-up PROFILE=core PYTHON=python3
```

In the original incorrect co-located recipe, the pinned native ARM images pulled. The local kind node, Calico, Postgres,
MinIO, real internal RelayAuth, Relaycast, and relaycontrol became ready.
relaycontrol's real first-boot API returned its organization and Default
workspace. The control, pipeline, and History migration Jobs each completed.
After **both** database migrators, the read-only combined ACL check failed:

```text
Run chart Job relay-cloud-api/migration
Run chart Job worker/locker-init
Run chart Job worker/hoopdb-migrate
Run chart Job relayhistory/migration
FAIL: Job kind-combined-acl-134671fd failed; inspect its redacted application error before retrying
```

The check calls the deployed services image's `runtimeRoleViolations` and
`sessionsFunctionAclPreview`; it does not invent a replacement grant policy.
It found 160 function ACL violations, including 18 `history_runtime:EXECUTE`
entries. The [complete captured diagnostic](combined-acl-failure.json) contains
only function signatures and role/privilege identifiers: 142 owner entries and
18 History runtime entries. No credentials or tenant data are included.
Selected captured entries:

```text
sessions.accept_conversation_turns(text,text,text,text,text,jsonb): <owner>:EXECUTE
sessions.database_health_v1(): history_runtime:EXECUTE
sessions.session_brief_v3(text,text,text,text,text,text,boolean,text): history_runtime:EXECUTE
```

The History migrator creates additional `sessions` functions and grants outside
the pipeline manifest. The runtimes have separate login roles; migration owners
are not runtime connections. Running History first instead correctly triggers
the pipeline's unledgered-schema refusal. Sharing the runtime role instead
correctly triggers its excess-privilege refusal. Neither ordering nor elevated
runtime access is accepted as a workaround.

Exact services identity:

```text
image: ghcr.io/agentworkforce/96bulls-services@sha256:070fe6fd46ecd1e1f9db32ff22379f6df9b9e6c4d48ede5312c8fb986a95f3a9
source: f1c2672581b6f88d26d0549b4d1cb78fce0d5f16
generation: 0dcd0e89bebbdad789a40fa61311c601b4c0e49e389e3b2b0167b6fd5fdf542e
History: ghcr.io/agentworkforce/relayhistory@sha256:d3166bb14e1d6043426a4dd8cc05408b94574c8d79ad5fd6e789e0de00ab371b
```

The pipeline owner confirmed that **two migrators writing `sessions` is not a
supported composition in one database**. Its byte-exact ACL guard is a trust boundary and must
remain intact. A co-located design would require History-owned objects in a
different schema, with pipeline data accessed through its published read/RPC
contracts. Alternatively, functions that must live in `sessions` need a
reviewed pipeline migration lane assigned by pipeline-lead and Khaliq, with
History no longer migrating those objects. Kind does not choose that lane.

The repositories must not be confused:

- `96bulls-services@070fe6fd…` comes from
  `AgentWorkforce/sessions-pipeline@f1c2672…`, now resolved by GitHub as
  `AgentWorkforce/relayhistory-pipeline`.
- `relayhistory@d3166bb…` comes from
  `AgentWorkforce/relayhistory-cloud@53c333349cb9210832013cd3a2423f5f19062d36`.
  At that pinned source, `packages/relayhistory/src/db/schema.ts:21` uses
  `pgSchema("sessions")`, and `src/lib/database-health.ts:75` calls
  `sessions.database_health_v1()`. The migrator requires runtime access to the
  migrated sessions schema. There is no chart switch to namespace these objects.

Namespacing the pinned History image requires application/migration work by
its owner. This is not evidence that such a change is impossible, nor a reason
to relax the pipeline guard. Owners have the exact repository/source identities
for any future unified-schema change. The existing EKS installer instead separates
History and HoopDB into different databases; the corrected kind recipe follows
that pattern and needs no application schema change to become ready. The
pipeline schema owner does not own the separate `relayhistory-cloud` application
repo; any work there needs its application owner. The remaining courier-to-app
read-path integration is tracked separately below.

That historical attempt stopped before installing the rest of the umbrella and
before issuing a readiness receipt. Its subsequent `make kind-proof-core` captured:

```text
FAIL proof.runtime: kind-up has not completed successfully for this profile
```

## Historical network preflight (the current proof also covers edge egress)

```sh
python3 - <<'PY'
import sys
sys.path.insert(0, 'ci/agent-relay/kind')
from stack import Stack
from proof import Proof
Proof(Stack('core')).egress()
PY
```

```text
PASS core.egress: external baseline connects; suite external TCP denied; in-cluster DNS/service connects
```

This exercised the live Calico policy with real pods. An unrestricted control
namespace reached `1.1.1.1:443`; the suite namespace could not. The suite could
resolve and connect to the internal relaycontrol service. Both canary pods and
the temporary control namespace were removed. No aggregate E2E pass was issued.

## Native add-on build preflight

```sh
make kind-build-addons PYTHON=python3
```

Completed with exit 0 on ARM. Built the actual Rust kernel from Flows release
`v2.0.50` / `9a9086be16fd33eea15af2adf3ce0a7cf1239aa9` with locked dependencies,
and the Go server from relayfile `731ea459d2e486892638b292ad218bbd04dd21a3`.
Images remained local. A deterministic one-step flow through that packaged CLI,
in a container with `--network none`, returned:

```json
{"ok":true,"command":"run","status":"completed","completionReason":"success","completedSteps":1}
```

The excerpt omits the generated run ID and warning diagnostic. It is a native
engine preflight only: Kubernetes Flow Job/CronJob scheduling, signed license
enforcement, and relayfile authenticated roundtrip are still unproved.

### Relayfile local PostgreSQL transport review

The relayfile owner identified lib/pq's default TLS requirement against the
local Postgres server (`SHOW ssl` returns `off`). The generated relayfile-only
DSN now explicitly uses `?sslmode=disable`, matching the pinned relayfile
repository's `docs/production-validation.md`. Other components' DSNs are
unchanged.

A one-off live preflight loaded the native relayfile image through the local
archive path into the existing kind node. It ran separate temporary pods using
the same production backend, internal JWKS endpoint and dedicated database,
first without the parameter, then with it. It checked both HTTP health and the
Postgres table catalog. Captured output:

```text
NEGATIVE OBSERVATION relayfile.storage_before: /health HTTP 200 despite zero Postgres backing tables (load error ignored)
PASS relayfile.storage_fixed: /health HTTP 200; Postgres backing tables=relayfile_envelope_queue,relayfile_state,relayfile_writeback_queue
Scope: database initialization preflight only; no authenticated filesystem or full addon E2E pass
```

The unfixed image did **not** crashloop: the pinned `store.go:1035` ignores the
initial `loadFromDisk()` error. `/health` alone therefore does not prove storage
initialization. That source/runtime finding was sent to layered-relayfile;
application code was not changed here. The temporary probe pods and their
dedicated Secrets were removed; host images/volumes and the core cluster were
retained. No filesystem token was minted and no auth path was bypassed.

## Static verification

Captured commands and results (Helm 4.3.1, kubeconform 0.8.0):

```text
python3 ci/agent-relay/kind/test_stack.py -v
Ran 10 tests
OK

scripts/ci/charts.sh static
exit 0

ci/agent-relay/render.sh
subdomain renders match ci/agent-relay/subdomain-golden.sha256
agent-relay GCP proof render contract: ok

scripts/ci/deps.sh
exit 0 (four pinned dependencies)

node ci/self-hosted-requirements/registry.mjs check
self-hosted requirements registry: OK (105 entries, 20 profiles)

ci/self-hosted-requirements/test.sh
registry.mjs regression tests: OK
```

On this Mac, native GNU compatibility command adapters were used for the Linux
shell checks. kubeconform used the unchanged native validator and locally
cached official schemas fetched over verified HTTPS because its Go HTTPS
fetch stalled. Standard schemas were required; both new profiles reported zero
skipped schemas. Existing static fixtures retain their declared custom-CRD
schema skips. These local tool adapters are ignored and are not shipped.


## Review fixes and current-source runtime validation

The review fixes preserve the original recovery anchor before ownership refusal,
use version-checked Secret create/replace instead of plaintext last-applied
annotations, renew TLS leaves for missing hosts or mismatched keys, and share
one hosted/offline courier verifier. Offline verification still requires a
trace, processing events, owner identity and a stored marked transcript. Model
summaries are optional in offline mode.
The proof's Python/JavaScript/TypeScript verifier code comes from the proving
infra checkout; the service application, migrator and bootstrap SQL come from
the separately pinned services image. These are deliberately distinct inputs.
`infraRevision` is the proving checkout's HEAD, not a claim about the current PR
head or that verifier bytes were supplied by the application image. Captured
setup/proof revisions and image/generation receipts must be read together.
The MCP fallback checks both public aliases before recording an unavailable
catalog feature as pending; partial availability or a failing alias is a failure.
The pinned raw-pointer path also
explicitly disables its optional derived file-normalize transform; the proof
accepts only `file-normalize/skipped/not_enabled` with no error, and rejects
errors and unknown skips. This does not claim derived normalization. An initial
`c6184d6` proof rejected that documented non-error skip; its negative receipt was
preserved privately before the corrected `fd8565c` run above. Temporary cost sync sessions are revoked via
History's supported `/v1/auth/token/revoke` route, including ingest failure.

These changes have offline regression/render checks, server-side dry runs and
the current-source warm setup/protocol run above. The actual setup removed the
old plaintext last-applied annotation from all five inspected core Secrets;
subsequent reads confirmed its absence. The protocol run also exercised the
History sync-session revoke path after cost ingest. No auth/ACL guard, runtime
feature flag, image source, or external-egress restriction was bypassed.

Review validation: 61 offline checks pass (16 ownership, 20 harness, 13
profile/schema/TLS, 3 control admission/tenant, 4 bootstrap and 5 shared pipeline
verifier checks). The nine JavaScript checks also pass inside the pinned native
Node 22.23.3 image with networking disabled and read-only source mounts.
