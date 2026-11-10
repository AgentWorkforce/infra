# Local Kind code loop

After the one-time target/source setup below, start the complete **existing**
local core with:

```sh
make dev
```

Every normal launch derives and validates a fresh private plan automatically;
there is no daily remove/replan step. For a safe subset, for example while
another component is paused, use `make dev DEV_COMPONENTS=webapp`. The default
is all discovered roles. Nonselected Deployments remain hash/UID-protected and
their sources/readiness are not required. Comma-separated role/group selections
are supported (`control` includes its collector; `pipeline` includes all four
native pipeline roles).

This attaches to the admitted Kind dependency/data stack and starts development
versions of all eight application roles. It does not provision a replacement
cluster. PostgreSQL, MinIO, PVCs, tenant identity, Secrets, ingress, HTTPS and
the normal cookie/device-login flow stay in place. There is no Helm replay,
migration, role bootstrap, seed, upload, provider probe or test session.

Development builds are labelled `agent-relay-dev/*`; they are **not qualified
release artifacts**. Existing scrubber/unsafe-source containment must be cleared
by the coordinating operator for this exact dev target and source set first.
Discovery and readiness do not supply that clearance. In particular, a paused
or contained pipeline is not automatically resumed: preparation requires one
available replica per selected application Deployment.

## One-time setup

Use the existing Docker, Python 3.9+, kubectl and Kind binaries. No host
Node/Bun/Go/Rust, Tilt, Skaffold or filesystem watcher is needed. Builds run
inside the repositories' existing Dockerfiles and dependency caches.

Create source checkouts on the same machine that runs `make dev`. The loop
never fetches or switches a source checkout. The required repositories are
`AgentWorkforce/relay-webapp`, `relay-control`, `sessions-pipeline` and `relaycast`.
The current analytics collector CLI is built from **relay-control**, so Control
and collector share one build. Use the accepted revisions for your target; do not
select a new pipeline/scrubber revision to work around containment. Additional
existing Relayfile/Flows checkouts can be supplied when those services are
enabled. A public checkout alone is not admission.

Put existing paths in a private `.kind/dev/sources.json` (group names are
stable; deployment names and UIDs are discovered):

```json
{
  "webapp": "/work/relay-webapp",
  "control": "/work/relay-control",
  "pipeline": "/work/sessions-pipeline",
  "cast": "/work/relaycast"
}
```

For a non-root official Dockerfile use `{"path":"/work/repo",
"dockerfile":"docker/official.Dockerfile"}`. Actual source roots, exact Git
heads, protected-file hashes, deployment/container names, UIDs, images and init
container hashes are discovered. Ambiguous or missing core roles refuse.
The configured `baselineRevision` records setup provenance. Ordinary source-only
commits do not require reconfiguration: each fresh plan records the current Git
HEAD, while protected-file hashes remain unchanged. An explicitly frozen plan
still refuses a later HEAD change before any effects.
Missing source groups are explicitly reported. The default all-component plan
refuses them before effects; an explicit subset leaves them protected and
unwatched. They are never silently claimed to have hot reload. Gitlinks are
excluded without fetching submodules; a Dockerfile explicitly copying a
submodule path refuses with an unsupported-context diagnostic. The pipeline's
official services Dockerfile uses workspace packages, not its vendor gitlink.

```sh
python3 ci/agent-relay/dev/configure.py \
  --kubeconfig /existing/private/kubeconfig \
  --context kind-your-local-cluster --namespace your-namespace \
  --docker-context desktop-linux --workspace /work \
  --sources .kind/dev/sources.json \
  --kind /existing/bin/kind --kubectl /existing/bin/kubectl
```

Configuration is read-only against the target and creates a private file
without overwriting one. Use a new output path for a successor. `DEV_CONFIG`
selects that file, including paths containing spaces.

`make dev-plan` is an optional review/dry run. It writes `.kind/dev/plan.json`
create-only and prints its canonical JSON digest. `DEV_PLAN=PATH` supplies an
explicit reviewed plan to either target, with a 30-minute activation window.
For normal `make dev`, leave `DEV_PLAN` unset: the fresh in-memory plan is
saved only as a private per-session receipt before execution.

Review the discovered config/plan, including existing init commands, actual
source status, resource capacity and HTTPS/WebSocket routing. Normal local
development uses those explicit target/source bindings directly. For a target
already under an operational hold, `configure.py --admission-file PATH` can
require a separate existing-operator clearance record:

```json
{
  "result": "APPROVED_LOCAL_KIND_DEV_SESSION",
  "configSha256": "canonical JSON digest emitted by configure.py",
  "planSha256": "canonical JSON digest emitted by make dev-plan",
  "approvedAt": 0,
  "containmentCleared": true
}
```

When this optional record is selected, use the explicit `DEV_PLAN` path.
`approvedAt` is the actual epoch second with a 12-hour limit. That plan has a
30-minute activation window and is freshly
compared to engine, node, namespace, Deployment and source identities before any
build. The optional record is local coordination, not a release attestation or
authority to clear another operator's quarantine. Never copy it from another
target/source.

## What reloads

| Component | Source edit behavior | Preserved boundary |
| --- | --- | --- |
| Webapp | Vite HMR after bounded source sync into a pod emptyDir | Same HTTPS origin, `/cloud/api`, `/login`, cookie auth and official runtime-config generator |
| Control | Cached official image rebuild and guarded rolling restart | Current credentials/env, schema and init containers |
| Native ingest / reader / consumer / brief | One cached pipeline image build per save, then serial per-service restart | Exact selected Deployments, existing runtime roles, init images, data and schema |
| Relaycast | Official image build and restart | Existing storage, keys, networking and backend choice |
| Telemetry collector | Official image build and restart | Existing producer/exporter configuration and credentials |
| Relayfile / Flows | Same rebuild/restart when deployed and source supplied | No bootstrap, enrollment or optional-feature enablement |
| PostgreSQL / vector / MinIO / ingress and other dependencies | Kept stable; no source watch or reprovisioning | Existing volumes, service addresses, data and trust |
| Native Desktop | Separate native repository workflow; not a Linux Kind container | No Desktop install, profile, collection or account changes |
| Chief | Remains off when disabled | No capability changes |

Backend iteration is **code watch plus rebuild/restart**, not in-process HMR.
Initial dependency/Rust builds may be slow; warm Docker layers are reused.
There is one build at a time. A failed completed edit build keeps the last
working image and emits bounded compiler file/line/error-code metadata; source
snippets, environment values and arbitrary tool messages are not echoed.
Fix/save again to build again. A command timeout, cluster drift, image import
failure or readiness failure ends the session and runs guarded restoration.
If the frontend container restarts or its pod is replaced, the loop detects the
new running identity and replays the current source snapshot and deletions;
it does not require an additional source edit to replace the image's old code.
Recovery sends only differences from the known image seed, in bounded batches;
unchanged large assets are not resent. A single changed frontend file larger
than 24 MiB minus JSON/base64 headroom refuses; use an explicit image rebuild
for assets beyond that live-sync bound.

SQL, scrubber authority, dependency manifests/locks, Dockerfiles and runtime
entrypoints are protected. Changing them stops the session instead of
automatically upgrading schemas, dependencies or scrubber policy. Review a new
source/config/plan for those changes. This tool is not a migration operator.

Git-ignored local credentials/build output are excluded from image contexts;
new untracked source files are supported. Standalone credential files refuse.
Byte-identical committed test credentials/templates remain usable as public
regression fixtures; source code mentioning a PEM header is not treated as a
private-key file. This is a context boundary, not a general secret scanner:
do not put real secrets into source code or commit them to the repository.

## Frontend contract

The dev image uses the dashboard's immutable Node build base and existing
locked Vite dependency. Source lives in a 256 MiB emptyDir, dependencies remain
read-only in the image and Vite caches use the existing `/tmp`. The exact
`docker/40-runtime-config.sh` from the dashboard repo writes the existing HTML
volume; no synthetic runtime config or alternate auth client is introduced.
The frontend overlay requires the chart's uid/fsGroup 101, HTML volume and
`/tmp` emptyDir. It raises frontend memory to a 256 MiB request / 1 GiB limit
for Vite, restoring the exact original resources on stop.

Only the approved public hostname is allowed. HMR uses WSS on that same public
port, not an exposed localhost dev port. The existing ingress must forward
WebSockets on the dashboard route; the operator must prove that during actual
activation. API/login routes remain on Control. A merged Vite proxy refuses
before listen. No CORS wildcard, TLS bypass, new trust installation, cookie
injection or public debug port is added. See the official [Vite server
options](https://vite.dev/config/server-options) and [config loader
documentation](https://vite.dev/config/) for the reverse-proxy/runner behavior.

## Stop and recovery

Ctrl-C or SIGTERM stops scheduling new imports/rollouts and independently
attempts restoration of **every changed** Deployment. Each restoration requires
the same UID and an exact confirmed or in-flight owned dev spec before a
compare-and-swap patch; a failed update preserves the previous confirmed spec.
Unrelated drift is not
overwritten. Original specs stay in process memory, so environment/Secret data
is not written into a recovery file. The private journal contains only target
UID/spec hashes and dev image references.

SIGKILL, host failure or loss of operator connectivity can leave dev pods in
place. There is no blind reset/Helm rollback: preserve the journal and have the
coordinator recover the exact owned fields from the approved target record.
Cached dev images are retained to avoid deleting another session's cache.
Do not run a second dev session or another rollout operator on the same target.

## Validation and honest limits

```sh
make dev-test
```

Tests cover actual Git context filtering, snapshot/UID/resource-version guards,
independent compensation, Kubernetes empty-args omission, same-origin frontend
contracts, source-sync bounds, role discovery, and drift/refusal paths. They
do not establish live ar-lap HMR, image builds, WebSocket ingress, provider
behavior, database compatibility or a complete end-to-end stack. Actual
activation needs the coordinating lead's concrete target handoff and a smoke
showing one frontend edit plus each backend's new code/readiness while data,
auth, schema and protected resources remain unchanged.
