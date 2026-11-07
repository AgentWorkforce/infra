# Local kind evidence — 2026-11-07

Status: **blocked before full stack readiness; neither profile has an E2E pass**.
These are local development results, not the customer release or managed-cloud
infrastructure proof. Worktree: `/Volumes/Paris Drive/infra-worktrees/kind-stack`,
based on infra PR #76 at `73f9a0eb8ab52e390856e5bd5ca3812e19f5fe7a`.
No cloud account, registry publication, deployment outside kind, or image/volume
pruning was performed.

## Core bootstrap and the blocking contract

```sh
make kind-up PROFILE=core PYTHON=/opt/homebrew/bin/python3
```

The pinned native ARM images pulled. The local kind node, Calico, Postgres,
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
entries. Selected captured entries:

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
supported composition**. Its byte-exact ACL guard is a trust boundary and must
remain intact. The supported design requires History-owned objects in a
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
and need to provide the supported implementation and image before kind can
complete its proof.

The orchestrator stops before installing the rest of the umbrella and before
issuing a readiness receipt. A subsequent `make kind-proof-core` captures:

```text
FAIL proof.runtime: kind-up has not completed successfully for this profile
```

## Live network preflight (separate from full E2E)

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
Ran 9 tests
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
