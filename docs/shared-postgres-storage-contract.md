# One RDS database, isolated service schemas

User direction, 2026-11-07: the self-hosted main relational store is **one RDS
PostgreSQL instance and one application database**. Control and HoopDb share
that database in different schemas. Relaycast must also persist its authoritative
relational state in that database; the portable SQLite profile does not satisfy
this target. Services must remain separable onto another RDS later.

## Terraform binding contract

`terraform/modules/postgres-layout` emits the following independent per-service
bindings against the same host, port and database. The AWS and AWS-environment
roots consume the endpoint and initial database from their single `postgres`
module. These are target namespace/identity assignments, not claims that current
images already support them.

| Service | Schema | Migration owner | Runtime role |
|---|---|---|---|
| Control | `relaycontrol` | `control_owner` | `control_api_runtime` |
| HoopDb/pipeline | `sessions` | `hoop` | `sessions_pipeline_runtime` |
| Relaycast | `relaycast` | `relaycast_owner` | `relaycast_runtime` |
| History | `relayhistory` | `history_owner` | `history_runtime` |
| Relayfile, when enabled | `relayfile` | `relayfile_owner` | `relayfile_runtime` |

A Relayfile binding does not enable that add-on. Runtime roles and migration
owners are distinct for every service. Their credentials remain in the approved
secret system; Terraform outputs contain no passwords or assembled credential
URLs. Shared extension/platform namespaces need their own administrator-owned
contract and cannot become a service's unbounded working schema.

The existing AWS roots default the initial database name to `relaycontrol`.
That database name is retained: it can contain all of the schemas above. The
new `application_database_name` input supports an explicit name for a fresh
installation. Changing it on an existing RDS resource may require replacement;
never use a database rename or replacement as an implicit data migration.

Every service receives a complete `{host, port, database, schema,
migration_role, runtime_role, sslmode}` binding even when the endpoint/database
are shared. A later split creates another RDS/database, preserves the service's
schema contract, migrates its data, and updates that service's secret binding.
It still requires reviewed cutover, restore, and isolation proof. No cross-schema
foreign keys, implicit shared tables, shared migrators or SQL joins between
services should be introduced as a dependency on today's colocation.

## Application integration still required

The module validates bindings; **it does not execute SQL or establish application
compatibility**. The existing Relaycast [PostgreSQL design PR602](https://github.com/AgentWorkforce/relaycast/pull/602)
is documentation only; the engine owner confirmed no PostgreSQL adapter exists
at reported main `ac38905a`. A SQLite-typed engine and migration line need a real
dialect/schema/transaction port before any chart can select PostgreSQL. Its `application_sql_ready` output remains false. Current
SQLite and separate-database development receipts do not qualify this target.

- Relaycast needs the real PostgreSQL engine adapter, schema-qualified migrations,
  transaction/concurrency semantics, delivery and restart tests, and a pinned
  supported image. An environment variable or a SQLite file copied into a blob
  store is not a PostgreSQL adapter.
- Control, History and pipeline migrators must own only their assigned namespaces,
  including migration ledgers, readiness records, functions, policies, indexes,
  sequences and rollback paths. Historical applied migrations must not be edited
  in place to rename schemas. Existing installations need a reviewed forward
  migration/cutover path.
- The current HoopDb function-boundary bootstrap assumes a dedicated database
  and changes defaults for multiple owners. Do not run it unchanged against this
  shared database. Review owner-specific defaults and the exact manifest boundary;
  never relax the verifier or union foreign functions into an allowlist merely
  to make the shared profile pass.
- `search_path` is name resolution, not authorization. Require explicit schema
  identity, safe pinned function resolution, no PUBLIC/service-to-service grants,
  no runtime schema DDL, no migration-owner membership in runtime roles, and
  no application use of the RDS master identity.
- Optional services must meet the same isolation contract. Inventory any other
  authoritative local journals/stores before claiming single-store acceptance.
  S3 may continue to hold file/transcript objects and OpenSearch derived indexes;
  neither substitutes for the shared authoritative relational database.

Both AWS roots keep automatic Lambda processing inactive: the environment root
refuses `activate_lambda=true`, including when artifact/TLS bindings are valid,
and the thin AWS root explicitly sets the functions module inactive. Removing
this hold requires reviewed shared-schema runtime/bootstrap qualification, not a
boolean acknowledgement. Direct invocation by an already authorized identity
remains possible; provisioning inactive queues is not an application access
control boundary or readiness proof.

The schema bootstrap, credentials/LOGIN activation, image compatibility and Helm
binding must be reviewed together before any shared application install. A
Terraform plan/apply can provision RDS without proving those application steps.
No existing database, schema, volume or backup is changed by publishing this
contract.

## Required AWS proof

1. Inspect the reviewed Terraform plan/state and native AWS inventory: exactly
   one application RDS instance and one application database; PostgreSQL's own
   maintenance databases are not service stores. Record the common endpoint and
   per-service schema/owner/runtime identity without credentials.
2. Bootstrap the schemas and service-specific permissions with a reviewed named
   executor. Use TLS verification and real non-owner LOGIN sessions. Each role
   must read/write its own authorized surface and fail reads, writes, schema DDL
   and privileged function execution against every other service.
3. Apply each service's migration independently; install all services together;
   then upgrade and restart them. Adding a foreign schema/function must not poison
   another service's readiness check, and weakening a service's own grant or
   schema contract must fail closed.
4. Prove the complete application trace through control, messaging, upload,
   pipeline indexing and application readback. Verify Relaycast durable state
   through process/pod replacement and real concurrent writers against PostgreSQL.
5. Restore the RDS snapshot/PITR into a separate owned recovery target and repeat
   service behavior and cross-schema denial tests. A later split needs the same
   tests after moving the selected service's data and binding.

Managed AWS execution remains subject to the existing admitted environment and
sandbox recovery requirements. This direction does not authorize bypassing a
quarantine, adopting shared resources, or deleting legacy data to force a pass.
