# Terraform modules for self-hosted Agent Relay

Terraform (and OpenTofu) modules for the infrastructure a self-hosted Agent Relay
install uses next to the `agent-relay` Helm chart. The four capability modules
consume an existing network and cluster identity. Separate foundation modules
can create the network and Kubernetes baseline in an approved existing AWS
account or GCP project. Foundation, data and application installation have
separate ownership and state; a successful source check is not live application
or teardown proof.

See [the complete Terraform + Helm application proof contract](../docs/terraform-helm-application-proof.md) for current evidence, outstanding live gates and the required provisioning, application, recovery and teardown lifecycle.

```
terraform/
  modules/aws/{foundation,postgres,object-storage,search,functions}
  modules/gcp/{foundation,postgres,object-storage,search,functions}
  examples/{aws,gcp}                 # thin roots: four capabilities together
  examples/{aws,gcp}-foundation      # network and Kubernetes foundation roots
  examples/aws-environments          # environment-scoped AWS data composition
  scripts/check.sh                   # fmt, validate, tflint, test, docs, checkov
```

Azure is on hold. A `modules/azure/<capability>` set with the same four
interfaces would slot in beside these.

## Current main-store direction — 2026-11-07

The required AWS application topology is **one RDS instance, one application
PostgreSQL database, separate service schemas**. Control and HoopDb share that
database; Relaycast must use it for authoritative relational state as well.
The AWS roots now expose `postgres_service_bindings` from the provider-free
[`postgres-layout`](modules/postgres-layout) contract. It rejects schema/role
collisions and keeps complete independent bindings for a later service split.
Read [the shared-store contract](../docs/shared-postgres-storage-contract.md)
for exact target namespaces, missing application work and required proof.

The default initial database name stays `relaycontrol` to preserve existing
resource identity; `application_database_name` chooses an explicit name for a
new installation. Changing it on an existing instance needs replacement/data
migration review. Binding outputs do not bootstrap SQL or make current images
schema-aware. `application_sql_ready` is false until that work is proved.
Older separate-database, dedicated-HoopDb and SQLite examples below describe
existing compatibility paths, not acceptance of this new target.

## Cloud mapping

| Capability | AWS module | GCP module | Required by the charts? |
|---|---|---|---|
| Postgres 17 | `aws/postgres`: RDS for PostgreSQL, or Aurora PostgreSQL (`engine_mode = "aurora"`) | `gcp/postgres`: Cloud SQL for PostgreSQL | **Yes, required** (relaycontrol, relayhistory, HoopDb, durable-actors) |
| Object storage | `aws/object-storage`: S3, with an optional EKS Pod Identity / IRSA role | `gcp/object-storage`: GCS, with optional Workload Identity | **Yes, required** (sessions Locker; durable-actors) |
| Search | `aws/search`: Amazon OpenSearch Service, VPC domain | `gcp/search`: OpenSearch on GKE through the OpenSearch Kubernetes operator | **No.** Optional add-on, see below |
| Functions | `aws/functions`: S3 notification -> SQS (+DLQ) -> Lambda, EventBridge schedules | `gcp/functions`: GCS notification -> Pub/Sub (+dead-letter topic) -> Cloud Run functions (2nd gen), Cloud Scheduler | **No.** Optional add-on, see below |

Every module stands alone. The examples compose them, but nothing forces you to
use all four, or to use them together.

For a new network and cluster, start with
[`aws/foundation`](modules/aws/foundation) and
[`examples/aws-foundation`](examples/aws-foundation), or
[`gcp/foundation`](modules/gcp/foundation) and
[`examples/gcp-foundation`](examples/gcp-foundation). AWS foundation covers the
owned VPC, private nodes, egress and EKS identities. GCP foundation covers the
owned VPC, GKE, NAT and Private Services Access, with optional Serverless VPC
Access, pipeline Memorystore and Pub/Sub prerequisites. These modules do not
vend accounts/projects, bootstrap application databases, install Helm, or
establish application runtime compatibility. Keep the foundation backend
separate from data/application state and review each module's external
prerequisites, retained resources and recovery rules before an apply or destroy.
In particular, the GCP Memorystore AUTH option requires explicit acknowledgment
of its sensitive value in Terraform state; that state is not secret-free.

For separate development, staging, production or named installations, see
[`examples/aws-environments`](examples/aws-environments). It adds account/region/
environment state isolation, sizing profiles, a saved-plan runner and opt-in
live data-path checks. Lambda starts inactive there. This does not establish
live full-suite proof or replace the foundation/application installation.

### What the stack consumes

- **Postgres.** Every database is PostgreSQL 17:
  - relay-cloud-api (relaycontrol): Secret keys `database-url` (runtime role `control_api_runtime`) and `database-migrations-url` (owner).
  - relayhistory: `DATABASE_URL` (runtime role `relayhistory_runtime`) and `DATABASE_MIGRATIONS_URL`. It needs the `vector` and `pg_trgm` extensions.
  - sessions-pipeline HoopDb: `HOOPDB_URL` (worker and alleyoop) and `HOOPDB_MIGRATION_URL` (migrate). It also needs `vector` and `pg_trgm`.
  - durable-actors (when enabled): `postgres-url` in the `actors-credentials` Secret.
- **Object storage.**
  - The sessions pipeline Locker: `sessions-pipeline.worker.locker` and `alleyoop.locker`, with provider `s3` or `gcs` and `credentials.mode: podIdentity`.
  - durable-actors `storage.bucket`, plus the relaycast and relayfile artifact and file buckets in the actor profiles (`values-eks-actors.yaml`, `values-gcp-proof-durable-actors.yaml`).
- **OpenSearch.** Optional. Transcript search defaults to Postgres `pg_trgm`,
  in HoopDb and relayhistory. OpenSearch is an **optional replacement for
  ClickHouse as the transcript search index**, which the sessions pipeline
  reaches through its `SearchIndexAdapter` (the interfaces live in
  sessions-pipeline, the OpenSearch adapter in sessions-pipeline-cloud). The
  modules size it for an index of per-event transcript text, with a write role
  for the indexer (the hoopdb-indexer worker, or the functions Lambda in event
  mode) and a read-only role for the session read API. The charts set no
  OpenSearch value of their own.
- **Lambda / Cloud Run functions.** Nothing in these charts consumes them.
  The `functions` modules are the sessions pipeline's **optional event-driven
  mode**. They mirror the hosted AWS stack, AgentWorkforce/96BullSessions
  `stacks/aws/session-pipeline.ts`:
  - The transcripts bucket notifies `manifest.json` puts and deletes to SQS `session-events`.
  - An event source mapping (batch 10, partial batch failures) feeds Lambda `session-pipeline`.
  - Messages that keep failing go to a DLQ (14 days, alarmed).
  - An EventBridge reconcile rule runs on a schedule, and an optional brief schedule is disabled by default.
  - There is no Function URL.

  By default the chart runs the same stages as long-running worker pods (the
  hoopdb-indexer reconcile tick, referee, and the bob-costas sweep). Event
  mode is an alternative runtime, not a requirement. The AWS handler is
  `src/session-pipeline/lambda.ts`. The GCP handler, a Cloud Run entry point
  for Pub/Sub push envelopes and scheduler bodies, comes with the pipeline's
  `PipelineRuntimeAdapter`.
- **Additional GCP prerequisites.** The sessions data path in `values-gcp.yaml` also
  needs Memorystore (Redis) and Pub/Sub settings (`REDIS_*`, `PUBSUB_*` in
  `extraEnv`). These are outside the four capability modules; the optional
  pipeline resources in `gcp/foundation` supply infrastructure references.
  Application bindings, secret delivery and actual queue/Redis compatibility
  still need separate verification.

## Network inputs for the capability modules

The four capability modules take networks and identities as inputs rather than
creating VPCs, subnets, NAT or Private Services Access. Use the separate
foundation modules above or an existing approved foundation. Shared DNS zones,
KMS keys, organization/account/project administration and required platform
permissions remain external prerequisites. The capability inputs are:

| Input | AWS | GCP |
|---|---|---|
| Network | `subnet_ids` (private, 2+ AZs), `vpc_security_group_ids` / `security_group_ids` | `network_self_link` (Private Services Access already configured for Cloud SQL), `vpc_connector` (Serverless VPC Access, for the function) |
| Encryption | `kms_key_arn` (and per-service `*_kms_key_arn`). null uses AWS managed keys | `kms_key_name` (CMEK). null uses Google-managed keys. Grant the service agents on the key first |
| Cluster identity | `cluster_name` / `namespace` / `service_account` for Pod Identity associations, or `oidc_provider_arn` for IRSA | Kubernetes `namespace` / `name` for Workload Identity (`<project>.svc.id.goog`) |
| IAM conventions | `role_path`, `permissions_boundary_arn` on every role | n/a |
| Tags / labels | `tags` | `labels` |

Account-level prerequisites the modules assume:

- **AWS.** The `AWSServiceRoleForAmazonOpenSearchService` service-linked role
  must exist for VPC domains. The EKS Pod Identity Agent must be installed
  (EKS Auto Mode runs it). The Lambda subnets need routes to S3, SQS, Secrets
  Manager and CloudWatch, through NAT or VPC endpoints.
- **GCP.** These APIs must be enabled: `sqladmin`, `servicenetworking`,
  `secretmanager`, `cloudfunctions`, `run`, `cloudbuild`, `artifactregistry`,
  `pubsub`, `cloudscheduler`, `eventarc` and `monitoring`. The GKE cluster must
  have Workload Identity enabled, and NetworkPolicy enforcement (Dataplane V2)
  for the search policy to take effect.

## Secure defaults (all overridable)

- **Networking.** Private only: no public IPs, endpoints or invokers.
  - RDS/Aurora have `publicly_accessible = false`, and Cloud SQL has `ipv4_enabled = false`.
  - OpenSearch is a VPC domain, or a ClusterIP Service on GKE.
  - The functions have no Function URL. Cloud Run is internal-only with OIDC-authenticated push and scheduler calls.
- **Encryption and TLS.**
  - Encryption at rest is on everywhere, with an optional customer key.
  - TLS is enforced: `rds.force_ssl=1`, Cloud SQL `ENCRYPTED_ONLY`, an S3 policy that denies non-TLS and TLS below 1.2, OpenSearch `enforce_https` with TLS 1.2+ and node-to-node encryption, operator-generated TLS on GKE, and SQS policies that deny insecure transport.
- **Data protection.**
  - Deletion protection is on, and a final snapshot is taken.
  - Backups and PITR are on (14 days for RDS/Aurora; 14 backups plus 7 days of PITR for Cloud SQL).
  - Buckets are versioned, with soft delete on GCS, and `force_destroy = false`.
- **Least privilege.**
  - The sessions bucket role gets List on the bucket plus Get, Put and Delete on objects (optionally limited to prefixes).
  - The pipeline role can only read `96bulls/*/v1/*`, consume its queue, read its one secret and invoke itself.
  - The OpenSearch reader role cannot write.
- **Secrets.**
  - RDS and Aurora use RDS-managed master passwords in Secrets Manager (`manage_master_user_password`).
  - The Cloud SQL admin password comes from an ephemeral `random_password`, written through write-only attributes to the user and to Secret Manager.
  - The pipeline secrets are empty containers whose value you set out of band.
  - OpenSearch on GKE takes existing admin and security-config Secrets.
  - No password is ever stored in state or plan output, and no module outputs one.
- **No hardcoded sizing or region.** Instance classes, tiers, node counts and
  disk sizes are variables with documented defaults. Regions come from the
  provider (AWS) or a required variable (GCP).

## How the outputs plug into the chart

Database URLs are credentials, so they go into the release Secret (the
`existingSecret` of each chart), never into values. Build them from the module
outputs and the role passwords you create in the bootstrap. Both Postgres
modules output a `database_url_template`. The External Secrets Operator is the
intended bridge: for example, template an ExternalSecret from the RDS-managed
master secret, or from per-role Secrets Manager / Secret Manager entries.

| Module output | Chart value or Secret key |
|---|---|
| `aws/postgres.host` / `gcp/postgres.private_ip_address`, `port` | Host of `relay-cloud-api` `database-url` and `database-migrations-url`; `relayhistory` `DATABASE_URL` and `DATABASE_MIGRATIONS_URL`; `sessions-pipeline` `HOOPDB_URL` and `HOOPDB_MIGRATION_URL`; `durable-actors` `postgres-url` |
| `aws/postgres.master_user_secret_arn` / `gcp/postgres.admin_password_secret_id` | Bootstrap only (the SQL below). Never an application credential |
| `gcp/postgres.connection_name` | `sessions-pipeline.worker.extraEnv` and `alleyoop.extraEnv` `CLOUD_SQL_CONNECTION_NAME` (`values-gcp.yaml`) |
| `*/object-storage.bucket_name` | `sessions-pipeline.worker.locker.bucket` and `alleyoop.locker.bucket`; or `durable-actors.storage.bucket`, and relaycast/relayfile `artifactBucket`, `fileStore.bucket` and `blobStore.bucket` |
| `aws/object-storage.bucket_region` / `gcp/object-storage.region` (null for dual- and multi-regions) | `worker.locker.region` and `alleyoop.locker.region` (or `durable-actors.storage.s3.region`) |
| `aws/object-storage.access_role_arn` | No chart value with Pod Identity: the module's `pod_identity_associations` bind it to `<release>-worker` and `<release>-alleyoop`. Keep `locker.credentials.mode: podIdentity`. With IRSA, set the `eks.amazonaws.com/role-arn` ServiceAccount annotation |
| `gcp/object-storage.google_service_account_email` | `durable-actors.serviceAccount.googleServiceAccount`, or an `iam.gke.io/gcp-service-account` ServiceAccount annotation. With `direct_kubernetes_service_accounts`, no value is needed |
| `aws/search.url`, `gcp/search.url` | The OpenSearch URL for the sessions pipeline's OpenSearch `SearchIndexAdapter` (in the pipeline secret or its own configuration; no chart value) |
| `aws/search.indexer_role_arn`, `reader_role_arn` | Pod Identity roles for separate indexer and read API ServiceAccounts. The chart needs per-component `serviceAccount` names for them (see `examples/aws`) |
| `aws/functions.*`, `gcp/functions.*` | No chart value. The pipeline secret's JSON holds the same HoopDb URL as `HOOPDB_URL` |

The example roots print the non-secret values-file paths as a `chart_values` output. `CLOUD_SQL_CONNECTION_NAME` is an `extraEnv` entry, not a values path, so the GCP example prints it as `postgres.connection_name` instead.

## Legacy separate-database bootstrap (not the shared-store target)

Do not run this dedicated-database bootstrap against the new shared application
database. The shared schema/role/default-ACL bootstrap requires application-owner
review and isolation proof described in the [new contract](../docs/shared-postgres-storage-contract.md).

The modules create the server, and on GCP optionally the databases. They do
not connect to Postgres. Before you install or upgrade the chart, run this from
a host or Job that can reach the database, as the administrator (the RDS master
user, `rds_superuser`, read from `master_user_secret_arn`; or the Cloud SQL
`admin_user`, `cloudsqlsuperuser`):

1. **Databases and roles.**
   - Create one database per component: `relaycontrol`, `relayhistory`, `hoopdb`, and optionally the durable-actors database. On RDS, `database_name` creates only the first; on Cloud SQL, use `databases`.
   - Create each owner role (the `*-migrations-url` user) and runtime login role: `control_api_runtime`, `relayhistory_runtime`, and the HoopDb runtime role (`sessions_runtime`).
   - Store their passwords in Secrets Manager or Secret Manager. They become the URLs in the release Secret.
2. **Extensions.** In `relayhistory` and `hoopdb`, run `CREATE EXTENSION IF NOT
   EXISTS vector; CREATE EXTENSION IF NOT EXISTS pg_trgm;`. `vector` is not a
   trusted extension, so the migrations' own `IF NOT EXISTS` must find it
   already created. On RDS both are allowed by default. If you set
   `allowed_extensions`, the module always adds them.
3. **HoopDb role bootstrap, before the sessions-pipeline migrate Job.** Run the
   SQL shipped in the services image you deploy (`/app/supabase/bootstrap/`).
   Otherwise migrate fails with `42501` or waits for roles:
   - **Cloud SQL** (`migrations.databaseMode: cloudsql`, `roleBootstrap: false`, `values-gcp.yaml`): run `cloudsql_migration_roles.sql`, `session_directory_search_worker.sql` and `cloudsql_owner_function_default_revoke.sql` as the migration owner (`charts/sessions-pipeline/ci/gcp-cloudsql-values.yaml`).
   - **HoopDb on AWS:** run HoopDb on the chart's in-cluster CloudNativePG (as `values-eks.yaml` does), and use RDS or Aurora for relaycontrol and relayhistory. The chart's pre-migrate Jobs then create the HoopDb runtime role and the function-default revoke; `session_token_verifier.sql` and `session_ingest_roles.sql` (next bullet) stay an operator step. The external-Postgres steps (`databaseMode: selfhosted`, `charts/sessions-pipeline/profiles/external-selfhosted.yaml`: `session_directory_search_worker.sql`, `hoopdb_runtime_role.sql`, `hoopdb_function_default_revoke.sql`) need a true superuser. RDS and Aurora provide `rds_superuser` instead, which cannot run the function-default revoke, so keep HoopDb off RDS until that bootstrap is adapted to the `rds_superuser` model.
   - **Both:** images newer than 7d7229b also need `session_token_verifier.sql` and `session_ingest_roles.sql` (`docs/self-hosted-eks.md`; `scripts/selfhost/eks-proof-install.sh hoopdb-roles` does this for CNPG).
4. Then `helm upgrade --install` the chart, whose migrate Jobs run as the owners.

## Validation

`scripts/check.sh` runs these checks on every module and example, without
cloud credentials. CI runs the same script in
`.github/workflows/terraform.yml`, on Terraform and on OpenTofu:

- `terraform fmt -check`
- `init -backend=false` and `validate`
- tflint (terraform, aws and google rulesets)
- `terraform test` with mock providers
- Python unit tests for environment/plan guards and verifier refusal cases
- terraform-docs drift
- checkov

Tests need Terraform >= 1.7 or OpenTofu >= 1.8 for mock providers. The
`gcp/postgres` module needs >= 1.11 (write-only attributes); the others need
>= 1.6.

Checkov findings that do not apply are skipped inline (`#checkov:skip=<id>:<reason>`)
next to the resource, so each exception carries its reason.
