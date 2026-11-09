# AgentWorkforce Infrastructure

Public chart names and existing-release compatibility: [Control/Webapp rename](docs/control-webapp-chart-rename.md).

Terraform modules and Helm charts for customer-owned Agent Relay installations on AWS and GCP. Terraform provisions cloud foundations and managed services; Helm installs the application workloads.

- [Terraform modules and examples](terraform/README.md): network, Kubernetes, PostgreSQL, object storage, optional search and functions.
- [Helm charts](#charts): application configuration, deployment and versioned dependencies under `charts/<service-name>/`.
- [Full application proof](docs/terraform-helm-application-proof.md): required lifecycle evidence and current gaps.
- [Enterprise AWS installation and first-user guide](docs/enterprise-aws-install.md): customer roles, SSO, Desktop downloads, device approval and acceptance; release preparation with explicit remaining gates.
- [Enterprise operator controls](docs/enterprise-customer-controls.md): generic operator controls, profile-specific downloads and disabled-Flows acceptance.

This repository was renamed from `AgentWorkforce/helm-charts` to `AgentWorkforce/infra`.
Update existing clones with `git remote set-url origin git@github.com:AgentWorkforce/infra.git`;
local directory names may stay unchanged. Existing Helm clients should run
`helm repo add agentworkforce https://agentworkforce.github.io/infra --force-update`
and `helm repo update`. The chart namespace and release-tag format stay the
same; the two public chart names change from `relay-cloud-api` /
`relay-dashboard` to `relay-control` / `relay-webapp` as described in the
[rename guide](docs/control-webapp-chart-rename.md). Historical evidence
and the release gate’s `helm-charts` license-decision ID retain their original identifiers.

## Charts

| Chart | Description |
|-------|-------------|
| [agent-relay](charts/agent-relay) | Self-hosted Agent Relay suite umbrella — relaycast, relayauth, sessions-pipeline, relayhistory, control-plane API, dashboard (one GKE Ingress, no HA claim) |
| [relay-control](charts/relay-control) | Self-host control-plane API — organizations, workspaces, device auth; existing-Secret file mounts only, separate migration Job |
| [relay-webapp](charts/relay-webapp) | Static self-host dashboard — nginx SPA calling same-origin `/cloud/api` |
| [relayhistory](charts/relayhistory) | Relay History data plane — session delivery, search, replay on its own Postgres database (digest-pinned proof image) |
| [relaychief-control](charts/relaychief-control) | Optional Relay Chief registry and slot-binding add-on on PostgreSQL — one replica, loopback-only admin listener, Ingress limited to `/chief/v1` by default (not part of the umbrella) |
| [relayfile-control](charts/relayfile-control) | Optional Relayfile webhook ingest and Flows API add-on on PostgreSQL. One replica, digest-only image, existing Secrets only, Flows and Ingress off by default. |
| [relaycast](charts/relaycast) | Portable self-hosted Relaycast core — realtime agent communication with single-writer SQLite persistence |
| [relayfile](charts/relayfile) | Relayfile server — single Go binary, HTTP on :8080, Postgres-backed in production |
| [relayflows](charts/relayflows) | Durable workflows running locally in Kubernetes, with optional Cloud assignment mode |
| [sessions-pipeline-worker](charts/sessions-pipeline-worker) | Session summary, metadata indexing and status workers, plus migration and storage initialization Jobs |
| [sessions-pipeline](charts/sessions-pipeline) | Session workers and ingest API, with optional Postgres, session-object-storage (MinIO) and an OTel collector |
| [telemetry-collector](charts/telemetry-collector) | Default-off analytics intake for Control events, internal TLS and file storage; installed durability is unverified |
| [session-ingest-api](charts/session-ingest-api) | Receives session manifests and chunks and stores them in S3-compatible object storage |
| [relayauth](charts/relayauth) | Self-hosted RelayAuth issuer: immutable image, externally managed keys, single-writer SQLite, and optional JWKS ingress |

## Self-hosted requirements registry

The public session resource names are `session-object-storage`,
`session-ingest-api`, `session-summary-worker`, `session-metadata-indexer` and
`session-status-worker`. See the [actual chart and workload rename](docs/descriptive-session-names.md)
for internal stage mappings and existing-release compatibility values. The three
workers share the `sessions-pipeline-worker` chart; MinIO uses the descriptive
dependency alias rather than a new wrapper chart.

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

The current `sessions-pipeline` 0.7.0 / `agent-relay` 0.4.0 rename changes
resource defaults. Before upgrading, migrate values as described in the
[descriptive-name upgrade guide](docs/descriptive-session-names.md). Retain your
existing release name, Secret names, runtime role and storage claim. Set
`worker.legacyResourceNames: true`, `alleyoop.legacyResourceNames: true`, and
move the old MinIO `locker` values block to `session-object-storage` with the
recorded old `fullnameOverride` and `nameOverride`. Do not use `--reuse-values`.

A standalone former `96bulls-worker` release also needs
`legacyResourceNames: true` together with `nameOverride: 96bulls-worker` to retain
its old Deployment names and selectors. `nameOverride` alone is insufficient.
Under the `agent-relay` umbrella, move old `96bulls:` overrides to
`sessions-pipeline:`. A deliberate resource rename requires a separate drained,
seeded upgrade/rollback test; these source changes do not establish that proof.

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
| `databaseMode` | `HOOPDB_DB_MODE` | Required: `local`, `selfhosted`, `cloudsql` (Google Cloud SQL), `rds` (Amazon RDS for PostgreSQL 16+, not Aurora) or `supabase`. |
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
- `external-rds.yaml`: Amazon RDS for PostgreSQL 16+ in rds mode, in a database
  dedicated to HoopDb. The master runs the `rds_*.sql` bootstrap first.
- `external-selfhosted.yaml`: an external operator-controlled plain-Postgres
  HoopDb with a superuser, in selfhosted mode. There are no in-cluster
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
  --set locker.endpoint=http://session-object-storage:9000 \
  --set tenant.orgId=<org>
helm install session-ingest-api agentworkforce/session-ingest-api -n sessions-pipeline \
  --set existingSecret=sessions-pipeline \
  --set locker.endpoint=http://session-object-storage:9000 \
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
**relaycontrol** (`relay-control` chart, `selfhost-api` image) and
**relay-app** (`relay-webapp` chart/image). The deprecated Cloud repository
is not a dependency. These profiles are development/proof fixtures, separate
from the customer release and AWS/GCP managed-infrastructure proofs.

| Profile | Components |
| --- | --- |
| `core` | relaycontrol, relay-app, Relaycast, RelayHistory, sessions-pipeline ingest/workers, Postgres + pgvector with per-service databases, MinIO Locker |
| `addons` | core + relayfile Go server with Postgres state, standalone Flows with Kubernetes CronJobs |

Both currently include **real, internal-only temporary RelayAuth**. The
`localKind.allowLocalOnly=true` explicitly opts into the local policy/ingress;
child network policies must stay disabled because Kubernetes combines egress
allows. The `localKind.temporaryRelayauth` flag must match `components.relayauth`; this is
an explicit compatibility component pending the owners' introspection work.
There is no RelayAuth ingress, relaycron, hosted Flow worker, OpenSearch
dependency, or durable-actors platform in either profile. Postgres search is
selected explicitly. Locker stores session objects and is still needed.

Prerequisites: Docker Engine 28+ (including native-platform image export),
kind 0.31+, kubectl, Helm 3.10+, OpenSSL, Git, Python 3.9+, and PyYAML. Allocate
enough Docker memory for the suite and CNI; budget 20 GiB free disk for a cold
setup. Current optional native Control builds fetch public
`AgentWorkforce/relay-control` at the exact `e74413b` source pin. Explicit historical
reproduction (`KIND_CONTROL_SOURCE=historical`) uses `1f08cb6` from the archived
private `AgentWorkforce/relay-control-internal` repository and needs authenticated
Git read access. Current and historical source caches are separate. Existing
cached checkouts are checked against exact revision and clean-tree requirements;
the builder does not repoint their remotes. Warm setup checks cached native
image sizes plus unpacking headroom.
On Linux the disk preflight measures the admitted daemon’s DockerRootDir. For
a relocated Docker Desktop disk or another local VM, set
`KIND_DOCKER_DATA_PATH` to the existing host-side Docker backing file or directory.
An unavailable storage path refuses setup rather than skipping the check.
Setup fetches public image/chart/source artifacts. Only explicit historical
Control reproduction additionally fetches private source from the archived
repository. Runtime suite pods receive no external
egress.
Public image pulls use a private anonymous Docker configuration with explicit
registry entries, so SSH setup does not invoke a locked native keychain helper
or inherit `DOCKER_AUTH_CONFIG`. No Docker login or global configuration changes
are performed.
Run the checkout and its worktree on a writable volume; all generated state and `TMPDIR` live
under its ignored `.kind/` directory. Helm dependency preparation also writes
ignored archives under each chart’s `charts/` directory.

These commands prepare a development fixture. Current core acceptance is
**PENDING**, and add-on acceptance is not established; see
[the pinned evidence and open checks](ci/agent-relay/kind/evidence.md). A
successful `kind-up` means readiness, not full application acceptance.

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
umbrella, and waits for readiness. The fixture creates its own local database
owners and dedicated runtime logins. Pipeline compatibility and guarded runtime
roles then use the exact services image's bootstrap SQL. The local Postgres
superuser initializes those databases and roles; application runtime connections
use the separate runtime logins. Its image/generation receipt is
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

Ownership records bind the profile, cluster name, node image, local Docker
endpoint and native `kube-system` namespace UID. Reuse and teardown verify that
identity through a temporary private kubeconfig before replacing this
worktree's kubeconfig. Older name-only receipts are refused; they are never
silently upgraded into authority over an existing cluster. Interrupted creation
without a completed ownership record requires explicit operator recovery.
Name or generic node-label matches alone do not authorize adoption or deletion.

For a cluster created by this worktree before versioned ownership receipts,
explicit recovery is available only when its original `.kind/core/ready.json`
still records the independently captured native UID. Supply that original UID
(the live cluster UID alone is insufficient):

```sh
python3 ci/agent-relay/kind/stack.py recover --profile core --expected-cluster-uid '<original readiness clusterUid>'
make kind-up PROFILE=core
```

Recovery compares the prior receipt and live UID, checks node labels, backs up
the legacy receipt, and updates only the local ownership record. It preserves
the cluster and kubeconfig. Missing original identity or any mismatch fails;
normal `kind-up` and `kind-down` never recover a receipt implicitly.

To build and install the pinned MCP-capable control source without registry
publication, use the same profile and local fixture with:

```sh
make kind-up-local-control PROFILE=core
make kind-proof-core
```

This requires Docker BuildKit/buildx and GitHub access during preparation. It
builds the official public Control Dockerfile at `e74413b` using a pinned Node base,
selects the native manifest digest in this worktree's private values, loads it
into kind and uses `imagePullPolicy: Never`. The OCI manifest/config hashes,
architecture and source revision are verified before installation. The build
also selects the matching API and migration entrypoints: current public images
use `node_modules/relay-control`, while the historical image uses
`node_modules/@cloud/selfhost-api`. Custom command overrides require explicit
translation before preparation; unrelated server and migration settings stay
in place. Switching source selects both commands with the image.
The build
receipt is `.kind/core/control-build.json`. `make kind-build-control PROFILE=core`
performs just the build/selection; it does not install or publish an image.
For the previous source, use `KIND_CONTROL_SOURCE=historical make kind-build-control PROFILE=core`.
This selects the archived `1f08cb6` pin explicitly. Existing historical image
receipts remain admissible only with their exact source, native architecture,
tag and manifest reference. Each build deliberately replaces the single active
`.kind/<profile>/control-build.json` receipt and selected image override. A current
build therefore replaces the historical selection; rerun the historical build
to select that source again and capture its resulting digest. Source caches stay
separate, and checked-in historical evidence is unchanged.
The normal catalog profile remains unchanged. Each build captures its resulting
artifact digest; the official Dockerfile's runtime npm dependency ranges mean
that identical source does not guarantee identical rebuilt image bytes.
The historical `1f08cb6` proof covers both public MCP paths with real-token initialization, nineteen-tool discovery,
workspace/public-origin binding and negative auth/origin checks in the recorded
local-control proof. It has not been rerun for `e74413b`; no current-build runtime
acceptance is implied. Agent launch/release remains pending.
The local bootstrap applies release objects client-side before final Helm
reconciliation. On Helm 4 the wrapper explicitly selects its supported
[`--server-side=false`](https://docs.helm.sh/docs/helm/helm_upgrade/) mode to keep
that ownership model consistent; Helm 3 keeps its existing default.

### Local TLS and Desktop

The local edge binds loopback HTTP `8080` and HTTPS `8443`. The generated
`.kind/<profile>/hosts` file lists the host entries to add for Desktop:

```text
127.0.0.1 relay.kind.agentrelay.com cast.kind.agentrelay.com history.kind.agentrelay.com files.kind.agentrelay.com
```

Only on a disposable test machine, trust `.kind/<profile>/ca.crt` in its trust
store and remove that trust after testing. This fixture CA has no name
constraints: trusting it authorizes its key for other domains too. For CLI
probes, prefer the supplied per-request CA file without installing system trust.
The CA private
key stays on the host; Kubernetes receives only the separate server leaf key.
The leaf certificate covers these hostnames for 30 days. Desktop builds can
target `AGENT_RELAY_SITE_URL=https://relay.kind.agentrelay.com:8443` and
`AGENT_RELAY_URL_SCHEME=agentrelay-kind` as **compile-time site-build inputs**;
runtime environment variables cannot retarget a default-profile Desktop.
Only on an operator-designated disposable fixture host, Desktop/LaunchAgent
calls may use this fixture CA in the macOS **System** keychain; remove its trust
and exact certificate after testing, identified by its recorded fingerprint.
Do not install it on a general workstation; use a properly trusted site
certificate there. Login-keychain trust is insufficient. Desktop has
no custom-CA or trust-bypass setting. No trust-store change is made by this
installer. The [Desktop delivery contract](ci/agent-relay/kind/ar-lap-delivery-plan.md#desktop-owner-build-and-trust-contract)
tracks the separate release/artifact gate and analytics requirements.
The dashboard carries the matching
Desktop link settings. The proof routes to loopback with verified TLS/SNI,
so it requires neither editing `/etc/hosts` nor disabling certificate checks.
Add-on SDK dependencies are committed in `ci/agent-relay/kind/flows-sdk/package-lock.json`
and installed with `npm ci`; its version must match the pinned Flows source
and local image tag. Cargo runs with the invoking host UID/GID, uses private
checkout-volume caches, and removes only its allocated build container after
a timeout. Old root-owned build caches from earlier runs require explicit
operator recovery; setup does not change their ownership.

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
57 checks passed, none failed, and three remain pending in the refreshed local-control variant.
Both public MCP aliases pass real-device authentication, discovery and workspace
binding checks. History delivery is
visible through relay-app, and reported usage/cost is attributed to the real
user/workspace. Courier upload, owner attribution, indexing and Locker readback
also pass. The courier-uploaded session is **not yet returned by the application
read API**; the proof checks that separately and does not infer visibility from
a database row. See [captured evidence](ci/agent-relay/kind/evidence.md).

| Gap | Owner / current evidence |
| --- | --- |
| Courier → RelayHistory → application read path | Pipeline and RelayHistory owners, coordinated by pipeline-lead: the real-owner courier session is indexed and stored, but RelayHistory does not return it through the authenticated Default workspace application API. Relaycontrol already proxies to `RELAYHISTORY_URL`; it needs no new pipeline URL in control, while the compatible History read service remains unqualified. The pipeline-to-History workspace session visibility contract is a required pending check. Merged pipeline #317/#318 add a default-off container entry and login/catalog routes; [source review and read-only diagnosis](ci/agent-relay/kind/read-api-contract.md) track remaining Postgres-only composition, TLS, canonical source and auth-pair blockers. The courier fixture already has a matching directory row. Nothing is enabled. |
| Shared-schema ownership | The local recipe now isolates History and HoopDB, matching the existing EKS installer; both migrators and the exact final ACL check pass. The earlier 160 violations remain as negative evidence for unsupported co-location. A future shared-schema design requires the schema and History application owners; the pipeline owner does not own the separate `relayhistory-cloud` application repo. |
| Add-on E2E | infra-kind-stack + license/file owners: native images and offline engine/storage preflights pass; the installed add-on profile, actual CronJob firing and authenticated file roundtrip remain unproved pending a signed license fixture and genuine filesystem-scoped authority. |
| Current image/source compatibility | Component owners: record exact source SHA and migrator generation; a tag named `main` is insufficient. This run used services source `f1c2672581b6f88d26d0549b4d1cb78fce0d5f16`, generation `0dcd0e89bebbdad789a40fa61311c601b4c0e49e389e3b2b0167b6fd5fdf542e`. |
| RelayAuth removal | layered-control + layered-sessions-pipeline: default-off introspection branch, `sh_at_`, `rth:read/rth:sync`; keep the temporary internal component until compatible images ship. |
| Cost attribution data | History's client-reported fixture usage/cost passes authenticated ingest and TLS readback, including owner and workspace isolation. This does not claim live model billing or courier-session application visibility. |
| Control image and MCP endpoint | PASS for the recorded historical local-Control variant at pinned source `1f08cb6`: verified native manifest transport, both public MCP aliases, nineteen-tool discovery, real workspace binding and auth/origin rejection ([raw receipts](ci/agent-relay/kind/evidence.md)). Current public source `e74413b` has not received that runtime proof. The catalog default remains source `9b80b04` and reports MCP pending. This does not claim agent launch/release or every MCP tool backend. No image publication is performed. |
| Custom Desktop package for ar-lap | layered-relay-desktop: target build/artifact and real browser/Desktop handoff plus courier-to-app trace are not qualified by the infra proof. Device auth and site TLS endpoint checks do not substitute for that custom application run. |
| Agent launch/release | layered-control: API unimplemented; fleet node claim/release is not this proof. |
| Signed offline license enforcement | layered-control: design only. `relay-control.license.existingSecret/key` reserves the `SELFHOST_LICENSE_FILE` mount; the file slot does not verify signatures or gate add-ons. |
| relayfile control-token filesystem scopes | layered-relayfile + layered-control: current introspection lacks `fs:*`; use real temporary RelayAuth for now. Dev issuer tokens do not count as acceptance evidence. |
| Native add-on runtime proof | infra-kind-stack + Flows owner: source build supports native runtime selection; full Job/CronJob and relayfile roundtrip remain unverified until the shared core and signed-license dependencies are resolved. |

Track the local work in [issue #77](https://github.com/AgentWorkforce/infra/issues/77).
For render/trust/schema checks without Docker (Helm and kubeconform required), run
`python3 ci/agent-relay/kind/test_stack.py -v` after building chart dependencies.

The default-off [session read API chart preparation](docs/self-hosted-session-read-api.md)
is available as the `charts/session-read-api` chart, carried under `sessions-pipeline.sessionReadApi`. It remains disabled in both kind
profiles pending the approved runtime assembly and image; the running core
evidence does not prove this new component.

The local add-on Flow journal uses `ReadWriteOnce` because kind's local-path
provisioner does not support CSI `ReadWriteOncePod`. Its CronJob uses `Forbid`;
the proof suspends and drains scheduled Jobs before starting a manual run. Do
not start other writers against this development journal. Production keeps
the relayflows chart's `ReadWriteOncePod` default with a compatible CSI driver.
