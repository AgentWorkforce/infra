# Local kind evidence — 2026-11-07

Status: **core setup READY; core proof PENDING (54 PASS, 0 FAIL, 4 PENDING); add-on E2E not run**.
These are local development results, not the customer release or managed-cloud
infrastructure proof. Worktree: `/Volumes/Paris Drive/infra-worktrees/kind-stack`,
The first negative run used PR #76 at `73f9a0eb8ab52e390856e5bd5ca3812e19f5fe7a`; the current receipts below pin the successful setup and latest proof separately.
No cloud account, registry publication, deployment outside kind, or image/volume
pruning was performed.

## Lifecycle changes after the runtime receipt

The PR branch subsequently received ownership hardening (`d5a6bc4`, composed at
`a0b33f8`). Twenty offline tests pass on the composed tree: ten profile/schema/TLS
checks and ten mocked ownership refusal/reuse/creation checks. The ownership
suite contacts no Docker daemon or cluster; its deletion message refers only to
a mocked fixture. The real cluster and its older ownership receipt were not
changed or adopted. The new lifecycle refuses legacy name-only receipts.

The 54 PASS / 4 PENDING runtime receipt below remains evidence for its pinned
source revision, not a new acceptance run of the ownership-hardened lifecycle.
A fresh lifecycle/bootstrap proof has not been run on this latest head.

## Current core setup and protocol proof

```sh
make kind-up PROFILE=core PYTHON=/opt/homebrew/bin/python3
make kind-proof-core PYTHON=/opt/homebrew/bin/python3
```

Setup completed with exit 0 and a readiness receipt, including the application
returning HTTP 200 over verified TLS. The protocol proof exits 2 (**PENDING**),
not 0. Its [complete credential-checked report](core-proof.json) records proof
source `2efcca7`, 54 passing checks, no failed checks, and four pending checks.
The [image/generation receipt](core-images.json) records the exact setup inputs.
Selected literal proof output:

```text
PASS core.egress: external baseline connects; suite and edge external TCP denied; internal DNS/backend/API connects
PASS app.tls_session_read: trusted local TLS, relay-app HTML, and delivered session through /cloud/api
PASS app.cast_tls_dm: both agents send/receive through verified public Cast TLS origin; internal route denied at edge
PASS cost_attribution: reported fixture usage/cost preserved through public History TLS ingest and application TLS read API; owner user/workspace match; other workspace denied
PASS pipeline.owner_attribution: ingest and derived index match the real signed-in owner
PENDING pipeline.app_visibility: courier upload/index/Locker verified, but authenticated Default workspace application API returned 200 without that session; read-path integration contract required
PENDING mcp: layered-control: PR19 merged in source; catalog image9b80b04 lacks MCP; compatible build and endpoint proof pending
PENDING agent_launch_release: layered-control: launch/release API not implemented
```

The fourth pending check is fixture workspace retention: the control API has
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

## Local MCP-capable control build (not installed)

The official `relay-control` Dockerfile at source
`1f08cb624be66016eb0c135363553dd44e58f691` built successfully for native
linux/arm64 as `agent-relay-kind/selfhost-api:1f08cb6`, with its supported
`NODE_IMAGE` argument pinned to
`node:22.23.3-bookworm-slim@sha256:3ed98443660ff48413b5af19ecefce3b9d50845a901a43420d47cc63a9fddbe9`.
BuildKit is required for the official Dockerfile's cache mount; this host used
Docker Desktop's bundled `docker-buildx` binary with the existing private
public-image Docker configuration and local Unix socket. The source checkout,
TMPDIR and captured build log remain on Paris Drive. No image was published.

The [local build receipt](control-build.json) records the source, OCI index
identity, native architecture and literal offline smoke output. A runtime
container with `--network none` imports the compiled MCP handler and confirms
migration `0012_hosted_relay_participants.sql` is packaged. This is build/module
evidence, not endpoint or integration evidence. The source Dockerfile's own OCI
source label spells the repository `relaycontrol`; the checkout actually used
`AgentWorkforce/relay-control`, recorded separately in the receipt.

The running kind cluster remains on its audited catalog control image. Local
OCI transport/pinning, migration and authenticated public MCP endpoint checks
remain pending; the core proof result and its four pending checks are unchanged.

## Historical unsupported database co-location (negative evidence)

```sh
make kind-up PROFILE=core PYTHON=/opt/homebrew/bin/python3
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
make kind-build-addons PYTHON=/opt/homebrew/bin/python3
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
PASS relayfile.storage_before: /health HTTP 200 despite zero Postgres backing tables (load error ignored)
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
