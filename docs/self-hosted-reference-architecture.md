# Self-hosted reference architecture

Status: implementation kickoff. This document distinguishes released behavior
from planned adapter work; it is not evidence that the HA profiles exist.

The per-profile list of what an operator must provide and can choose, and the
chart/image/migration compatibility matrix, are in the
[self-hosted requirements registry](self-hosted-requirements.md),
generated from [`self-hosted/requirements.yaml`](../self-hosted/requirements.yaml).

Links into the repository `README.md` point at the public source repository
because it is not part of the customer handoff archive. For the version
matching an archive, open the same path at the revision recorded in its
`RELEASE-MANIFEST.json`. The diagrams below ship in the archive under
`docs/diagrams/`.

## Current shared-store requirement

The 2026-11-07 user direction is one RDS instance and one application database,
with distinct service schemas and credentials, including Relaycast. See the
[shared PostgreSQL contract](https://github.com/AgentWorkforce/infra/blob/main/docs/shared-postgres-storage-contract.md).
The SQLite-backed `portable-single` profile is implemented; `aws-ha` and `gcp-ha`
are planned. None proves or satisfies the new shared-store target.

## Diagrams

- [Architecture overview](diagrams/agent-relay-architecture.png)
  ([SVG](diagrams/agent-relay-architecture.svg),
  [mermaid source](diagrams/agent-relay-architecture.mmd)): what
  `charts/agent-relay` deploys on GKE. It shows the ingress hosts and edge
  denies, the components in the release namespace, the Cloud SQL, GCS and
  Workload Identity data plane, the clients, and the optional telemetry
  egress. Preview and optional components (durable-actors, Relayfile,
  telemetry egress) have dashed borders; Relayflows is opt-in and labelled so.
- [Request flow](diagrams/agent-relay-request-flow.png)
  ([SVG](diagrams/agent-relay-request-flow.svg),
  [mermaid source](diagrams/agent-relay-request-flow.mmd)): Desktop sign-in
  with device approval, session upload to RelayHistory, the Dashboard read
  path, and agent messaging through Relaycast.
- [Detailed GKE shape](diagrams/self-hosted-architecture.md): ports, routes,
  Secrets and the Relayflows run modes.

![Agent Relay self-hosted architecture](diagrams/agent-relay-architecture.png)

## Product shape

The self-hosted product is composed rather than monolithic.

| Layer | Default | Responsibility |
|---|---:|---|
| Relaycast core | Required | Agent communication, REST/WebSocket API, messages, presence, actions, and files |
| Identity/control plane | Required for the complete product; naming and package boundary unresolved | Sign-in and tokens, organizations, workspaces, device enrollment, discovery, deployment bindings, and dashboard |
| Relayflows | Off | Durable, resumable, or scheduled multi-step workflow execution |
| Relayfile/providers | Off; inclusion in the self-host product is unresolved | GitHub, Slack, and other provider write-backs |
| Sessions Pipeline | Off | Session capture, durable storage, indexing, summaries, and evaluation |
| Observer/UI | Off | Human inspection and operations surfaces |

An add-on may consume core APIs, but the core availability path must never
depend on an add-on. In particular, Relaycast does not require Relayflows.

## Runtime profiles

Relaycast's options for these, including the planned `aws-ha` and `gcp-ha`
backends, are registry entry
[`opt.relaycast.runtime-backend`](self-hosted-requirements.md#opt-relaycast-runtime-backend).

### `portable-single` — implemented

`charts/relaycast` runs the released self-host image with its Node adapters,
one SQLite database, and local file storage on a retained persistent volume.
The chart enforces one replica and `Recreate` upgrades. This is a useful local,
edge, and small-team profile, not an HA cloud claim.

### `aws-ha` — next conformance target

The Relaycast engine must own the HA adapter implementation. The working
adapter boundary discussed with Barry and kjgrok is:

- relational state: PostgreSQL (Aurora/RDS on AWS);
- realtime fan-out and ephemeral coordination: Redis pub/sub (ElastiCache);
- durable asynchronous delivery: a queue adapter (SQS);
- files and signed object operations: an object-store adapter (S3);
- runtime selection: one explicit backend setting, consumed by the runtime;
- deployment binding: workspace-to-Relaycast target resolution in the control
  plane, without hard-coded hosted gateway URLs.

Helm may select a released backend and wire endpoints, identity, and Secrets.
It must not duplicate engine behavior or imply an adapter exists before the
runtime and conformance suite prove it.

### `gcp-ha` — after the AWS contract is frozen

GCP must implement the same committed adapter contract using Cloud SQL for
PostgreSQL, Memorystore for Redis, Pub/Sub for durable asynchronous delivery,
and Cloud Storage for objects. Provider differences belong behind adapters and
in deployment values, not in Relaycast API behavior.

If GCP requires a core API or semantic change after the AWS pattern is frozen,
that is evidence the boundary is incomplete and must be corrected explicitly,
not hidden in chart conditionals.

## Transcript search profiles

Operator decision (2026-11-01): self-hosted deployments support two transcript
search profiles. They select a backend; they do not fork RelayHistory
behavior, which already has a Postgres search path and a derived ClickHouse
path. A RelayHistory chart (`charts/relayhistory`, single-replica, digest-pinned
proof image) ships on this branch; no ClickHouse chart ships in this repository
today.

### Standard (default): PostgreSQL + `pg_trgm`

- PostgreSQL 17 is both the system of record and the search backend.
- `pg_trgm` is enabled and the existing RelayHistory GIN expression indexes
  are installed. The CNPG HoopDb image already ships the extension and its
  bootstrap creates it (`deps/cnpg-cluster-values.yaml`, `deps/PINS.md`).
- Exact `ILIKE` behavior and tenant filters are preserved.
- It adds no service beyond the Postgres already in the stack, so it is the
  default for small and standard installations.
- The backend is named `postgres`. `neon` is a hosted-provider name, not the
  self-hosted abstraction.

### Scale/HA (optional): self-managed ClickHouse OSS

- PostgreSQL remains the source of truth and the hydration/authorization
  store. Open-source ClickHouse, run in the customer's cluster, is only a
  derived candidate/search index, matching the Cloud architecture.
- Prefer the official ClickHouse Kubernetes Operator for HA. ClickHouse is
  either an external endpoint with credentials or an operator-managed cluster.
- It is optional for high-volume installs, never a required dependency. Core
  availability must not depend on it.
- The Postgres fallback, tail guard, isolation checks, backfill/parity gates,
  and single-switch rollback are retained.

### Not options

- SQLite FTS5: local/on-device private search only, not shared multi-user
  server search.
- ObsessionDB: not the self-hosted default at this maturity.

### Values and Secret boundary

**Planned — not implemented; no chart or conformance test ships this yet.**
The intended shape, to be confirmed when a chart and conformance tests exist:

- `search.backend: postgres | clickhouse`, default `postgres`;
- `search.clickhouse.mode: external | operator`: `external` points at a
  ClickHouse the customer already runs; `operator` expects a cluster managed
  by the official ClickHouse Kubernetes Operator;
- connection values: `search.clickhouse.endpoint` (HTTPS URL),
  `search.clickhouse.database`, `search.clickhouse.table` (the derived
  candidate index) and `search.clickhouse.user`;
- `search.clickhouse.existingSecret`, with `search.clickhouse.secretKeys`
  naming the password key. Credentials come only from an existing Kubernetes
  Secret, never inline values;
- Postgres connection and authorization values stay where they are today
  (HoopDb). The ClickHouse values add no second source of truth.

Selecting `clickhouse` keeps the Postgres path configured, so setting
`search.backend` back to `postgres` is the single-switch rollback.

Registry entries: the planned option
[`opt.sessions-pipeline.search-backend`](self-hosted-requirements.md#opt-sessions-pipeline-search-backend)
(CI fails if any template reads a `search.*` value while it is planned), and
the shipped requirement
[`req.db.postgres-17-extensions`](self-hosted-requirements.md#req-db-postgres-17-extensions)
(`pg_trgm`, `btree_gin`) that the standard profile relies on.

The Sessions Pipeline chart notes in the [README](https://github.com/AgentWorkforce/infra/blob/main/README.md#transcript-search-profiles)
point back to this section.

## Proof and commit gates

The sequence is deliberate:

1. Prove the released `portable-single` chart locally and on Kubernetes.
2. Implement adapter ports and the HA runtime in Relaycast, including its
   provider-neutral conformance suite.
3. Prove `aws-ha` end to end on EKS with the AgentWorkforce charts.
4. Review the evidence, then commit/freeze the adapter pattern and its
   conformance contract.
5. Implement and prove `gcp-ha` against that same contract.

AWS proof is complete only when evidence covers:

- fresh install and idempotent upgrade;
- workspace creation/claim, agent registration, REST, and WebSocket delivery;
- multi-replica fan-out without duplicate or lost visible events;
- file upload, download, expiry, and cleanup through object storage;
- queue retry, dead-letter behavior, replay, and recovery after worker loss;
- database, Redis, pod, and availability-zone failure/recovery exercises;
- backup and restore with an explicit recovery point and recovery time;
- metrics, logs, traces, alerts, and operator runbooks;
- a session flowing through the Sessions Pipeline: ingest, Locker, HoopDB, summaries, and
  verdicts when that add-on is enabled;
- add-ons independently disabled without breaking the Relaycast core;
- no AWS-specific branches in provider-neutral engine behavior.

## Release and migration safety

Initial installation and upgrade are different operations: use `helm install`
only for a confirmed absent release and `helm upgrade` only for a confirmed
existing release. Do not use `helm upgrade --install` or `--atomic` for this
suite. An atomic Helm failure can change Kubernetes resources, but it cannot
reverse PostgreSQL or SQLite migrations or restore PVC and object-store data.

Before an upgrade, require exact chart/image migration compatibility, a
current complete backup, a successful isolated restore drill, and an approved
database-aware recovery procedure. Helm rollback is not database rollback.
See the [backup and restore runbook](selfhost-backup-restore.md).

## Unresolved decisions

Do not encode these as defaults until the product owners resolve them:

- RelayAuth-to-RelayIdentity rename and repository/package timing;
- whether Relayfile/provider integrations ship in the self-host product;
- per-deployment billing;
- a managed tunnel for customers without inbound HTTPS;
- which hosted desktop/mobile/fleet route groups move into the engine for
  parity;
- final control-plane packaging and UI boundaries.
