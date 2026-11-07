# AgentWorkforce Infrastructure

Terraform modules and Helm charts for customer-owned Agent Relay installations on AWS and GCP. Terraform provisions cloud foundations and managed services; Helm installs the application workloads.

- [Terraform modules and examples](terraform/README.md): network, Kubernetes, PostgreSQL, object storage, optional search and functions.
- [Helm charts](#charts): application configuration, deployment and versioned dependencies under `charts/<service-name>/`.
- [Full application proof](docs/terraform-helm-application-proof.md): required lifecycle evidence and current gaps.

This repository was renamed from `AgentWorkforce/helm-charts` to `AgentWorkforce/infra`.
Update existing clones with `git remote set-url origin git@github.com:AgentWorkforce/infra.git`;
local directory names may stay unchanged. Existing Helm clients should run
`helm repo add agentworkforce https://agentworkforce.github.io/infra --force-update`
and `helm repo update`. Chart names, release-tag format and the
`ghcr.io/agentworkforce/charts` OCI coordinates stay the same. Historical evidence
and the release gate’s `helm-charts` license-decision ID retain their original identifiers.

## Charts

| Chart | Description |
|-------|-------------|
| [agent-relay](charts/agent-relay) | Self-hosted Agent Relay suite umbrella — relaycast, relayauth, sessions-pipeline, relayhistory, control-plane API, dashboard (one GKE Ingress, no HA claim) |
| [relay-cloud-api](charts/relay-cloud-api) | Self-host control-plane API — organizations, workspaces, device auth; existing-Secret file mounts only, separate migration Job |
| [relay-dashboard](charts/relay-dashboard) | Static self-host dashboard — nginx SPA calling same-origin `/cloud/api` |
| [relayhistory](charts/relayhistory) | Relay History data plane — session delivery, search, replay on its own Postgres database (digest-pinned proof image) |
| [relaycast](charts/relaycast) | Portable self-hosted Relaycast core — realtime agent communication with single-writer SQLite persistence |
| [relayfile](charts/relayfile) | Relayfile server — single Go binary, HTTP on :8080, Postgres-backed in production |
| [relayflows](charts/relayflows) | Durable workflows running locally in Kubernetes, with optional Cloud assignment mode |
| [sessions-pipeline-worker](charts/sessions-pipeline-worker) | Sessions Pipeline workers: HoopDb migrations, Locker bucket init, and the indexer/referee/bob-costas stage workers |
| [sessions-pipeline](charts/sessions-pipeline) | The whole Sessions Pipeline in one release: sessions-pipeline-worker + alleyoop, with optional HoopDb (CloudNativePG), Locker (MinIO) and an OTel collector |
| [alleyoop](charts/alleyoop) | Sessions Pipeline ingest: receives session manifests and chunks and lands them in the Locker (S3) |
| [relayauth](charts/relayauth) | Self-hosted RelayAuth issuer: immutable image, externally managed keys, single-writer SQLite, and optional JWKS ingress |

## Self-hosted requirements registry

[`self-hosted/requirements.yaml`](self-hosted/requirements.yaml) is the single
source of truth for what a self-hosted install needs: every **requirement**
(Secrets with exact names and keys, database roles and extensions, DNS/TLS,
workload identity, cluster capabilities) and every **option** (HoopDb backend,
`databaseMode`, function boundary, search backend, ingress scheme, add-ons),
per install profile, with the chart values, env vars and Secret keys each maps
to, who provides it, how to verify it, and file:line sources. It also holds the
compatibility matrix: chart versions, services image digests, the
sessions-pipeline commit and migration generation, and the supported
`databaseMode` + boundary combinations. The readable form,
[docs/self-hosted-requirements.md](docs/self-hosted-requirements.md), is
generated from it.

To add or change an entry, edit the YAML (the field reference is at the top of
the file), then:

```bash
node ci/self-hosted-requirements/registry.mjs render   # regenerate the doc
node ci/self-hosted-requirements/registry.mjs check    # what CI runs
```

CI (`lint.yml`, static job) fails when the registry and the charts disagree:
a template env var, Secret key or Secret values path that is not registered; a
shipped entry whose values path, env var or Secret name/key the charts do not
have; a template that references a `planned` entry; a matrix digest, commit,
generation, chart version or release tag that differs from the pins; or a stale
generated doc. A new chart version needs a `current` row in
`compatibility.releases` (`status: unreleased` until its tag exists).

## Quick start

```bash
helm repo add agentworkforce https://agentworkforce.github.io/infra --force-update
helm repo update
```

### Install the Relaycast core

Relaycast is the minimal self-hosted core. Relayflows and the Sessions Pipeline are optional
add-ons and are not installed with it:

```bash
kubectl create namespace relaycast
kubectl -n relaycast create secret generic relaycast-secrets \
  --from-literal=internal-secret="$(openssl rand -hex 32)" \
  --from-literal=workspace-bootstrap-secret="$(openssl rand -hex 32)"
helm install relaycast agentworkforce/relaycast -n relaycast \
  --set baseUrl=https://relay.example.com \
  --set existingSecret=relaycast-secrets
```

Anonymous workspace creation is off; see
[charts/relaycast/README.md](charts/relaycast/README.md) for the first-run
workspace bootstrap, ingress, backups and restore, and upgrading from 0.1.0. The staged AWS-first/GCP-second adapter
plan and its proof gates are in
[docs/self-hosted-reference-architecture.md](docs/self-hosted-reference-architecture.md).
That document also records the transcript search decision: PostgreSQL 17 with
`pg_trgm` is the default backend (`postgres`). ClickHouse OSS is an optional
scale profile and is not charted yet.
What each install profile must provide and can choose is in
[docs/self-hosted-requirements.md](docs/self-hosted-requirements.md).

### Install relayfile

Provision `relayfile-secrets` through your approved secret-delivery system with
`RELAYFILE_PRODUCTION_DSN`, `RELAYFILE_INTERNAL_HMAC_SECRET` and
`RELAYFILE_JWT_SECRET`. Keep credential values out of Helm arguments and files.
Create a non-secret `relayfile-values.yaml`:

```yaml
secrets:
  existingSecret: relayfile-secrets
auth:
  jwksUrl: https://auth.relay.example.com/.well-known/jwks.json
```

```bash
helm install relayfile agentworkforce/relayfile -f relayfile-values.yaml
```

See [charts/relayfile/README.md](charts/relayfile/README.md) for the full parameter reference.

### Run Relayflows locally

Bundle a flow, the Relayflows runtime CLI, and its harness CLIs into an image,
then run it as a Kubernetes Job. This default mode does not use Agent Relay
Cloud:

```bash
helm install relayflows agentworkforce/relayflows \
  --namespace relayflows --create-namespace \
  --set image.repository=registry.example.com/acme/my-flow \
  --set image.tag=sha-0123456789abcdef \
  --set runtimeInstaller.enabled=false \
  --set standalone.flow.path=/app/flows/customer.flow.ts
```

See [charts/relayflows/README.md](charts/relayflows/README.md) for ConfigMap
flows, model credentials, resuming runs, and optional Cloud worker mode.

### Install the Sessions Pipeline (umbrella)

One release runs everything. Prerequisite: the CloudNativePG operator (see
[`deps/PINS.md`](deps/PINS.md)). Then create one Secret and install:

```bash
kubectl create namespace sessions-pipeline
read -rsp 'SUMMARY_MASTER_KEYS (<key-id>:<64-hex>): ' SUMMARY_MASTER_KEYS; printf '\n'
printf %s "$SUMMARY_MASTER_KEYS" | kubectl -n sessions-pipeline create secret generic sessions-pipeline-locker \
  --from-literal=rootUser=<user> \
  --from-literal=rootPassword=<password> \
  --from-file=SUMMARY_MASTER_KEYS=/dev/stdin
unset SUMMARY_MASTER_KEYS
helm install sessions-pipeline agentworkforce/sessions-pipeline -n sessions-pipeline \
  --set global.tenant.orgId=<org> \
  --set alleyoop.auth.jwksUrl=https://<relayauth>/.well-known/jwks.json
```

#### Upgrading a release of the former `96bulls` chart

The umbrella was renamed from `96bulls` (last released as 0.5.4) to
`sessions-pipeline` (0.6.0). An existing release upgrades in place:
`helm upgrade <release> agentworkforce/sessions-pipeline -f <your values>`.
Resource names and selectors are unchanged, because the worker subchart alias
is still `worker`. Only the `helm.sh/chart` and `app.kubernetes.io/part-of`
labels change. Two renamed defaults need a value if you relied on them. Set
`worker.existingSecret`, `alleyoop.existingSecret` and
`locker.existingSecret` to your current Secret name (the old default was
`96bulls-locker`). Set
`worker.migrations.runtimeRole` to the role your database already has. A
standalone `96bulls-worker` release keeps its selectors only with
`nameOverride: 96bulls-worker`; otherwise, install it fresh. Under the
`agent-relay` umbrella (0.3.0), move your `96bulls:` overrides to
`sessions-pipeline:`.

The charts default to `ghcr.io/agentworkforce/96bulls-services`, pinned by
digest. That hosted-service package is private. For direct installs, create a
docker-registry Secret and add `--set worker.imagePullSecrets[0].name=<secret>
--set alleyoop.imagePullSecrets[0].name=<secret>`. When overriding either app's
image repository or tag, also clear its shipped digest with
`--set worker.image.digest= --set alleyoop.image.digest=` (or supply matching
digests). Hosted EKS installs instead set both `worker.image.repository` and
`alleyoop.image.repository` to the fully qualified ECR repository plus its
matching digest; EKS nodes authenticate through their node role, so that path
does not need an image pull Secret. The OpenTelemetry collector is off by default; set
`global.otel.endpoint` to your backend, or set both `otel.enabled=true` and
`global.otel.endpoint=http://otel-collector:4318` to use the bundled collector.
Its safe default exporter drops telemetry; replace `otel.config.exporters` and
the pipeline exporters with your backend configuration outside local testing.

Bob Costas reads `SUMMARY_MASTER_KEYS` from a Secret and stores only encrypted
summary objects in the Locker; no key value belongs in Helm values. The worker
chart projects that Secret key as a read-only file into Bob Costas only. Set
`worker.summaryEncryption.existingSecret` when the key is not in the shared
Secret (required for pod-identity installs with no `worker.existingSecret`).

HoopDb credentials come from the Secret CloudNativePG generates
(`hoopdb-app`). Bring your own Postgres or S3 by disabling `hoopdb` or
`locker` and pointing `worker.*` / `alleyoop.*` at your infrastructure. On EKS,
set both app charts' `locker.credentials.mode=podIdentity` to omit
`LOCKER_ACCESS_KEY_ID` and `LOCKER_SECRET_ACCESS_KEY`; the AWS SDK then uses its
workload identity credential chain. Leave `locker.endpoint` empty to use the
native AWS S3 endpoint for `locker.region`. Unless the cluster uses EKS Auto
Mode, first install the
[EKS Pod Identity Agent](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html).
Create the IAM associations for the rendered worker and alleyoop
ServiceAccounts before deploying the workloads, because EKS injects the Pod
Identity configuration when each Pod starts. If associations are added later,
restart the app Pods and recreate any failed locker-init Job. If the S3 bucket
is already created and versioned, also set `worker.lockerInit.enabled=false`;
otherwise the worker role needs permission to create the bucket and enable
versioning.
`ci/sessions-pipeline-umbrella/smoke.sh` runs the umbrella on kind.

#### Profiles and the HoopDb migration contract

`worker.migrations` carries the migrator's database profile: sessions-pipeline
`src/hoopdb/migrate.ts` `migrationProfile()` at main
`7d7229bb31c121ecb98cd4e35c248fc2cf5669ad` (#124 session list RPC, #125 the
Supabase event-trigger function boundary, #139 its manifest sync, #137 the exact sessions function ACL check in every
non-local boundary mode). Each value is rendered at most
once, as an env var in the migrate container only. The render refuses these
names in `worker.extraEnv` and component `env`, along with
`HOOPDB_ROLE_BOOTSTRAP` and the old `HOOPDB_FUNCTION_BOUNDARY_APPROVED` name.
Where the migrator has no default, neither does the chart:

| value | env | rule |
| --- | --- | --- |
| `databaseMode` | `HOOPDB_DB_MODE` | Required: `local`, `selfhosted`, `cloudsql` (Google Cloud SQL) or `supabase`. |
| `supabaseShim` | `HOOPDB_SUPABASE_SHIM` | Required in local, selfhosted and cloudsql. In supabase mode it must be unset or false, and it is rendered `false`. |
| `roleBootstrap` | `HOOPDB_ROLE_BOOTSTRAP` | Optional (the migrator defaults it to the shim choice). Refused as true in supabase. Cloud SQL sets false. |
| `runtimeRole` | `HOOPDB_RUNTIME_ROLE` | Required. Outside local mode it must be a dedicated role, never the migration owner or the search Worker. |
| `runtimeRoleLogin` | `HOOPDB_RUNTIME_ROLE_LOGIN` | Required outside local mode; rendered only when set. |
| `runtimeWorkloadRole` | `HOOPDB_RUNTIME_WORKLOAD_ROLE` | Optional. |
| `functionBoundaryMode` | `HOOPDB_FUNCTION_BOUNDARY_MODE` | `global-default-revoke`, or `event-trigger` in supabase mode only (refused in local, selfhosted and cloudsql, as the migrator refuses it). Required in selfhosted and cloudsql. Optional in supabase; unset, migrate fails closed. |

`charts/sessions-pipeline/profiles/` ships four render shapes:

- `selfhost-postgres.yaml`: a new install on the in-cluster CNPG HoopDb, in
  selfhosted mode. initdb creates the search Worker role. Before migrate, two
  privileged Jobs run as `postgres` on every deploy:
  - `runtimeRole.bootstrapJob` runs `hoopdb_runtime_role.sql`. It creates or
    verifies the runtime role, revokes TEMPORARY from PUBLIC on the database
    (a database-wide change) and grants the role CONNECT.
  - `functionDefaultRevoke.bootstrapJob` runs
    `hoopdb_function_default_revoke.sql`. It sets the global function default
    of the owner and every superuser to `{<self>:EXECUTE}` and refuses a
    poisoned default (55000).

  migrate's `wait-for-role` waits for both roles and for the owner's exact
  function default.
- `migration.yaml`: an existing in-cluster CNPG HoopDb from before the search
  Worker role existed. It is `selfhost-postgres.yaml` plus
  `searchWorkerRole.bootstrapJob`.
- `external-selfhosted.yaml`: an external operator-controlled plain-Postgres
  HoopDb (RDS, your own Postgres) in selfhosted mode. There are no in-cluster
  SQL Jobs, and migrate waits for the roles. The operator runs the three
  bootstrap files as a superuser. Google Cloud SQL uses `cloudsql` mode instead:
  see `charts/sessions-pipeline/ci/gcp-cloudsql-values.yaml`. There the shim is off,
  `roleBootstrap` is false, the migration-owner URL is separate, and the
  operator runs the Cloud SQL bootstrap files.
- `external-supabase.yaml`: an external Supabase project in supabase mode. It
  has no shim, no wait-for-role and no in-cluster SQL Jobs, and the chart
  refuses each of those in supabase mode. Never run
  `hoopdb_function_default_revoke.sql` on Supabase. The runtime role is
  `sessions_pipeline_runtime` with LOGIN and no workload role (a database
  bootstrapped before the rename keeps its role: set
  `worker.migrations.runtimeRole` to that name, for example `bulls96_runtime`).
  Do not use the drifted
  legacy `relayhistory_runtime`. The Worker role is
  `session_directory_search_worker`.

  The profile pins the 7d7229b GHCR image and selects
  `functionBoundaryMode: event-trigger` (sessions-pipeline #125). It is still
  **fail-closed**: `supabaseActivation.hold` stops it from rendering, and even
  rendered, migrate refuses (`function_boundary_unproven`) until the operator
  has installed `hoopdb_sessions_function_boundary_supabase.sql` and
  `--activation-check` reports `event_trigger.verified: true`. Lift the hold
  only once that image is confirmed as the production-Supabase pin and the live
  Supabase steps are approved. The operator prerequisites are listed in the
  profile, including the Supabase-only bootstrap wrappers.

Every profile, every CI values file, and the worker and alleyoop chart
defaults pin the services image built from sessions-pipeline main `7d7229b`, GHCR
`ghcr.io/agentworkforce/96bulls-services@sha256:6f22ea17dff336e1431664542759fd27958649388b90a0b2f0881883caa7c6b2`
(publish-image run 41375745173). Its migration generation is
`eff8b3be46565b57ad8fa5e4a066dbb6d1fe608313d9c1680bfbcd484add259b`. The AWS
proof values (`charts/sessions-pipeline/ci/aws-cnpg-values.yaml`) pin the immutable ECR
digest from the same source,
`500268966557.dkr.ecr.us-west-2.amazonaws.com/96bulls-services@sha256:5bb6075240afa02a1b1797a81c07bffa029954eac7803d702ecba20db35d4db9`
(publish-image-ecr run 41375747474). Every profile
also needs `global.tenant.orgId` and `alleyoop.auth.jwksUrl`.

`ci/sessions-pipeline-profiles/matrix.sh` renders every profile and every
`charts/sessions-pipeline/ci/*-values.yaml`. Those include the AWS CNPG proof, AWS
external Supabase (`pod-identity`) and GCP Cloud SQL. For each one it asserts:
- the workloads and migrate, with phase 2 verify;
- the exact profile env, in migrate only;
- HoopDb and Locker;
- which privileged Jobs render, with their psql variables and files;
- what migrate waits for;
- the image pins: every row renders only the final images, and the ECR image only on the AWS path.

It also checks every mode combination the chart must refuse. CI runs it
offline (`static`) and as a server-side dry run on kind (`dryrun`).
`ci/sessions-pipeline-search-worker-role/kind.sh` builds the services image from
`services-commit` (7d7229b) and fails unless the image's generation equals
`services-generation`.

#### Session directory search Worker role

HoopDb's session directory migration only *verifies* the role
`session_directory_search_worker` (`NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER
NOCREATEDB NOCREATEROLE NOREPLICATION`, exactly `statement_timeout=2s`, no
memberships). Creating it needs a superuser on PostgreSQL 16+, so the chart
provisions it (sessions-pipeline `runbooks/session-directory-search-worker-bootstrap.md`):

- **New clusters:** two `hoopdb.cluster.initdb.postInitApplicationSQL` statements,
  run once by CNPG as `postgres`. Remove them to opt out.
- **Existing clusters:** `searchWorkerRole.bootstrapJob.enabled=true` with
  `sqlImage` set to the services image by digest. A separate Job (its own
  ServiceAccount; a Role limited to `pods` get/list and `pods/exec`) runs the
  image's `supabase/bootstrap/session_directory_search_worker.sql` as `postgres`
  by `kubectl exec` into the primary. `enableSuperuserAccess` stays false. It is
  idempotent and never alters a role that differs from the spec (it fails with
  `55000`). The sql init container, which runs the services image, gets no API
  token: the pod has `automountServiceAccountToken: false` and only the kubectl
  container mounts a projected token. Pull auth is `worker.imagePullSecrets`
  (the umbrella's shared `imagePullSecrets`), the same Secret as the workloads.
- **Order** (no Helm hooks): the migrate Job's `wait-for-role` init container
  (`worker.migrations.waitForRole`, on by default in the umbrella, on the pinned
  HoopDb image) polls HoopDb until the role exists, so bootstrap and migrate are
  applied together. migrate then verifies the role (phase 1), migrates, and
  checks its grants (phase 2) and records PASS for the image's migration
  generation in `sessions.__96bulls_role_validation`. Workloads are ready only
  while that PASS is current, so a phase 2 failure after the ledger is
  complete leaves everything unready. migrate always sets
  `HOOPDB_ROLE_VERIFY=true`, and `worker.extraEnv` may not override it: with
  verify off, readiness would need a separate mark_pass step, which this chart
  does not run. A drifted role fails both Jobs with `55000` and nothing
  becomes ready.
- **Disabling** the Job removes the Job and its RBAC; the role is never dropped
  (see the runbook's "Rollback and removal").

`ci/sessions-pipeline-search-worker-role/render.sh` asserts the rendered objects;
`ci/sessions-pipeline-search-worker-role/kind.sh` (required in CI) runs on the real
services image, which CI builds from the sessions-pipeline commit in
`ci/sessions-pipeline-search-worker-role/services-commit` (the published image is
private; locally, pass `SERVICES_IMAGE`). It proves:
- a fresh and an existing CNPG cluster converge to the same role;
- a drifted role is refused with `55000` (exit 3);
- in the whole release, migrate waits while the bootstrap is held back and no
  workload is ready; after the bootstrap, migrate passes both role checks and
  the workloads become ready;
- a phase-2-only failure after the ledger is complete (a direct grant) sets the
  role validation marker to pending, and running and restarted workloads go
  unready;
- with a drifted role, both Jobs fail with `55000` and nothing becomes ready.

#### Transcript search profiles

Shared transcript search has two profiles. The default is `postgres`:
PostgreSQL 17 and `pg_trgm` on the HoopDb this chart already installs. The
search Worker role above is the privilege boundary for that path.
Self-managed ClickHouse OSS is an optional derived index for high-volume
installs. No chart reads a `search.*` value, and core availability does not
depend on ClickHouse. `neon` is a hosted-provider name, not the self-hosted
search backend. `HOOPDB_DB_MODE=selfhosted` is unchanged. The decision and
the planned Secret boundary are in
[Transcript search profiles](docs/self-hosted-reference-architecture.md#transcript-search-profiles). The registry tracks it as the planned option
[`opt.sessions-pipeline.search-backend`](docs/self-hosted-requirements.md#opt-sessions-pipeline-search-backend).

### Install the Sessions Pipeline app charts individually

Both charts are hook-free, so `helm install` and Alchemy's
`helm template --no-hooks` + server-side apply behave the same. Create a
Secret with `HOOPDB_URL`, `LOCKER_ACCESS_KEY_ID`,
`LOCKER_SECRET_ACCESS_KEY` and `SUMMARY_MASTER_KEYS` first (or enable
`externalSecrets`). `SUMMARY_MASTER_KEYS` is referenced only by Bob Costas.

For workload identity, set `locker.credentials.mode=podIdentity` and provide
`hoopdb.existingSecret`; `existingSecret` may then be empty. This suppresses
both static Locker credential environment variables in every workload and in
the worker's locker-init Job. `locker.endpoint` may also be empty to select the
native AWS S3 endpoint.

> The default image `ghcr.io/agentworkforce/96bulls-services` (pinned by
> digest) is private: add `--set imagePullSecrets[0].name=<secret>` to both
> commands. If you override `image.repository` or
> `image.tag`, also set `image.digest=` or supply the matching digest.


```bash
helm install sessions-pipeline-worker agentworkforce/sessions-pipeline-worker -n sessions-pipeline --create-namespace \
  --set existingSecret=sessions-pipeline \
  --set locker.endpoint=http://locker:9000 \
  --set tenant.orgId=<org>
helm install alleyoop agentworkforce/alleyoop -n sessions-pipeline \
  --set existingSecret=sessions-pipeline \
  --set locker.endpoint=http://locker:9000 \
  --set tenant.orgId=<org> \
  --set auth.jwksUrl=https://<relayauth>/.well-known/jwks.json
```

`ci/sessions-pipeline/smoke.sh` runs the whole pipeline on kind, with CloudNativePG
(Postgres 17), MinIO and an OpenTelemetry collector. Third-party charts and
images are pinned once, in [`deps/`](deps/PINS.md).

## Releases

Charts are packaged and published to GitHub Pages via [helm/chart-releaser-action](https://github.com/helm/chart-releaser-action) on every merge to `main`, after the same lint checks that run on pull requests pass. chart-releaser detects changed chart versions automatically — each service chart is released independently.

Each released chart is also pushed to GHCR as an OCI artifact:

```bash
helm install <release> oci://ghcr.io/agentworkforce/charts/<chart> --version <version>
```

## Contributing

Add new service charts under `charts/<service-name>/`. Open a PR against `main`. Merges are gated by Khaliq.

Every chart must install correctly through `helm template --no-hooks` plus server-side apply, which is how Alchemy's `Kubernetes.HelmChart` installs it. Pull requests run `.github/workflows/lint.yml`:

- `helm lint --strict`, once per `charts/<chart>/ci/*-values.yaml` (or with defaults when there are none).
- **No Helm hooks.** Hooks never run under `--no-hooks`; use a plain Job instead (see `sessions-pipeline-worker`).
- **Deterministic renders.** No `randAlphaNum`, `lookup` or `now`, or every render looks like drift.
- `kubeconform`, plus a server-side dry-run apply on kind.
- **A version bump** for any chart change outside `ci/`.

Run the same checks locally with `scripts/ci/charts.sh static` and `scripts/ci/charts.sh dryrun` (the dry run needs a cluster in the current kube context).

## Local kind profiles

The local stack uses the existing `agent-relay` umbrella. Product names are
**relaycontrol** (`relay-cloud-api` chart, `selfhost-api` image) and
**relay-app** (`relay-dashboard` chart/image). The deprecated Cloud repository
is not a dependency. These profiles are development/proof fixtures, separate
from the customer release and AWS/GCP managed-infrastructure proofs.

| Profile | Components |
| --- | --- |
| `core` | relaycontrol, relay-app, Relaycast, RelayHistory, sessions-pipeline ingest/workers, Postgres + pgvector with per-service databases, MinIO Locker |
| `addons` | core + relayfile Go server with Postgres state, standalone Flows with Kubernetes CronJobs |

Both currently include **real, internal-only temporary RelayAuth**. The
`localKind.temporaryRelayauth` flag must match `components.relayauth`; this is
an explicit compatibility component pending the owners' introspection work.
There is no RelayAuth ingress, relaycron, hosted Flow worker, OpenSearch
dependency, or durable-actors platform in either profile. Postgres search is
selected explicitly. Locker stores session objects and is still needed.

Prerequisites: Docker Engine 28+ (including native-platform image export),
kind 0.31+, kubectl, Helm 3.10+, OpenSSL, Git, Python 3.9+, and PyYAML. Allocate
enough Docker memory for the suite and CNI; budget 20 GiB free disk for a cold
setup. Warm setup checks cached native image sizes plus unpacking headroom.
Setup fetches public image/chart/source
artifacts. Runtime suite pods receive no external egress. Run the checkout
and its worktree on a writable volume; all generated state and `TMPDIR` live
under its ignored `.kind/` directory.

```sh
python3 -m pip install -r ci/agent-relay/kind/requirements.txt
make kind-render PROFILE=core
make kind-up PROFILE=core
make kind-proof-core
make kind-down PROFILE=core

# Add-ons need an owner-supplied license. Run one profile at a time (same ports).
make kind-build-addons  # optional: prepare native images without starting a cluster
KIND_LICENSE_FILE=/absolute/path/to/signed-license make kind-up PROFILE=addons
KIND_RELAYFILE_TOKEN_FILE=/absolute/path/to/real-scoped-token make kind-proof-addons
make kind-down PROFILE=addons
```

`kind-up` creates a named cluster (`agent-relay-core` or
`agent-relay-addons`) and a private kubeconfig, installs checksum-verified
Calico and a pinned Traefik chart, provisions local Postgres/Locker and
generated Secrets, loads native-platform images, runs the chart's schema
Jobs in order, bootstraps the installation and first workspace, installs the
umbrella, and waits for readiness. PostgreSQL roles come from the exact
services image's bootstrap SQL; no invented grant list or privileged runtime
database connection is substituted. Its image/generation receipt is
`.kind/<profile>/images.json`. Current catalog images are pinned by digest;
their compatibility with current source remains subject to runtime proof.
History uses its own `relayhistory` database and migration owner; the pipeline
is the sole migrator of `sessions` in `hoopdb`. This matches the existing EKS
installer. Co-locating both migrators in HoopDB is unsupported and is rejected
by the unchanged final ACL check.
Relayfile and the pinned Flows runtime are built locally for the add-on profile.
The Flows Rust kernel is compiled natively from release `v2.0.50`, commit
`9a9086be16fd33eea15af2adf3ce0a7cf1239aa9`, with its locked dependencies.
The SDK selects it through the supported `RELAYFLOWD_BIN` setting; neither
emulation nor a replacement engine is used. Cargo caches and build outputs
stay on the checkout volume. This path still needs the runtime proof below.

Commands explicitly target their own kubeconfig and kind context. An existing
cluster without this worktree's ownership record is refused. `kind-down`
deletes only the named local cluster, including its node-backed data, and
retains the private local state for inspection. It does not prune Docker or
change a cloud account, registry, system trust store, or the caller's kubeconfig.

### Local TLS and Desktop

The local edge binds loopback HTTP `8080` and HTTPS `8443`. The generated
`.kind/<profile>/hosts` file lists the host entries to add for Desktop:

```text
127.0.0.1 relay.kind.agentrelay.com cast.kind.agentrelay.com history.kind.agentrelay.com files.kind.agentrelay.com
```

Trust `.kind/<profile>/ca.crt` in the test machine's trust store. The CA private
key stays on the host; Kubernetes receives only the separate server leaf key.
The leaf certificate covers these hostnames for 30 days. Desktop builds can
target `AGENT_RELAY_SITE_URL=https://relay.kind.agentrelay.com:8443` and
`AGENT_RELAY_URL_SCHEME=agentrelay-kind`. The dashboard carries the matching
Desktop link settings. The proof routes to loopback with verified TLS/SNI,
so it requires neither editing `/etc/hosts` nor disabling certificate checks.
Setup reissues old or expiring fixture certificates with strict-verifier key
identifiers. If you trusted an earlier fixture CA manually, use the current
`ca.crt`. The edge has its own egress-deny policy allowing only cluster DNS,
the local Kubernetes API and stack backends; version checks and usage export
are disabled.

There is no public self-signup endpoint. First boot creates the configured
organization, owner (`owner@kind.example`), and Default workspace. The proof
then exercises real device start/approval/token exchange as a CLI/Desktop
client. OIDC/email login providers are optional and are not enabled in the
offline profile.

### Evidence and current gaps

`kind-proof-core` and `kind-proof-addons` share
[`ci/agent-relay/kind/proof.py`](ci/agent-relay/kind/proof.py). They reuse the
existing real protocol drivers for device login, Relaycast DMs, History
durable delivery/read-back, session API filters and isolation, and the real
sessions courier/indexer path. The new wrapper checks the live namespace
policy, compares an external connectivity baseline with a denied suite probe
and a successful in-cluster probe, and reads the delivered session through
relay-app's TLS origin. The add-on proof runs a manual Flow Job and observes
a **new controller-scheduled** CronJob firing, then attempts authenticated
relayfile write/read with a real temporary RelayAuth token. A manually
instantiated CronJob Job cannot satisfy the scheduled-firing check.

Proof exit codes: `0` all required checks passed, `1` failed, `2` pending.
Driver skips become `PENDING`; neither readiness nor missing upstream work
can produce an overall pass. Curated results go to `.kind/<profile>/proof.json`;
credentials and protocol state remain in separate mode-0600 files. Never
commit or attach those private state files. Test session data stays in the
disposable kind cluster until `kind-down`.

The captured [core report](ci/agent-relay/kind/core-proof.json) is **PENDING**:
54 checks passed, none failed, and four remain pending. History delivery is
visible through relay-app, and reported usage/cost is attributed to the real
user/workspace. Courier upload, owner attribution, indexing and Locker readback
also pass. The courier-uploaded session is **not yet returned by the application
read API**; the proof checks that separately and does not infer visibility from
a database row. See [captured evidence](ci/agent-relay/kind/evidence.md).

| Gap | Owner / current evidence |
| --- | --- |
| Courier → RelayHistory → application read path | Pipeline and RelayHistory owners, coordinated by pipeline-lead: the real-owner courier session is indexed and stored, but RelayHistory does not return it through the authenticated Default workspace application API. Relaycontrol already proxies to `RELAYHISTORY_URL`; it needs no pipeline URL or separate read API. The pipeline-to-History workspace session visibility contract is a required pending check. |
| Shared-schema ownership | The local recipe now isolates History and HoopDB, matching the existing EKS installer; both migrators and the exact final ACL check pass. The earlier 160 violations remain as negative evidence for unsupported co-location. A future shared-schema design requires the schema and History application owners; the pipeline owner does not own the separate `relayhistory-cloud` application repo. |
| Add-on E2E | infra-kind-stack + license/file owners: native images and offline engine/storage preflights pass; the installed add-on profile, actual CronJob firing and authenticated file roundtrip remain unproved pending a signed license fixture and genuine filesystem-scoped authority. |
| Current image/source compatibility | Component owners: record exact source SHA and migrator generation; a tag named `main` is insufficient. This run used services source `f1c2672581b6f88d26d0549b4d1cb78fce0d5f16`, generation `0dcd0e89bebbdad789a40fa61311c601b4c0e49e389e3b2b0167b6fd5fdf542e`. |
| RelayAuth removal | layered-control + layered-sessions-pipeline: default-off introspection branch, `sh_at_`, `rth:read/rth:sync`; keep the temporary internal component until compatible images ship. |
| Cost attribution data | History's client-reported fixture usage/cost passes authenticated ingest and TLS readback, including owner and workspace isolation. This does not claim live model billing or courier-session application visibility. |
| Control image and MCP endpoint | layered-control: MCP PR #19 is merged in main `1f08cb624be66016eb0c135363553dd44e58f691`, but the catalog control image is release 0.3.0 / source `9b80b04` and lacks MCP. GHCR has no image tag for `1f08cb6` or `main`. A compatible build must be pinned and `/api/v1/mcp/shared-sessions` exercised before this can pass. No image publication is performed by the kind workflow. |
| Agent launch/release | layered-control: API unimplemented; fleet node claim/release is not this proof. |
| Signed offline license enforcement | layered-control: design only. `relay-cloud-api.license.existingSecret/key` reserves the `SELFHOST_LICENSE_FILE` mount; the file slot does not verify signatures or gate add-ons. |
| relayfile control-token filesystem scopes | layered-relayfile + layered-control: current introspection lacks `fs:*`; use real temporary RelayAuth for now. Dev issuer tokens do not count as acceptance evidence. |
| Native add-on runtime proof | infra-kind-stack + Flows owner: source build supports native runtime selection; full Job/CronJob and relayfile roundtrip remain unverified until the shared core and signed-license dependencies are resolved. |

Track the local work in [issue #77](https://github.com/AgentWorkforce/infra/issues/77).
For render/trust/schema checks without Docker (Helm and kubeconform required), run
`python3 ci/agent-relay/kind/test_stack.py -v` after building chart dependencies.
