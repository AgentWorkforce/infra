# One RDS instance, separate service databases

The self-hosted AWS relational target is **one RDS PostgreSQL instance with a
separate logical database for each service**. This replaces the earlier shared
application database with service schemas. Services keep complete bindings so a
later migration to a separate RDS endpoint can preserve their database/schema
and role contract.

## Terraform binding contract

The provider-free `terraform/modules/postgres-layout` publishes non-secret
identities. AWS roots explicitly select this layout:

| Service | Database | Schema | Migration owner | Runtime role |
|---|---|---|---|---|
| Control | `relaycontrol` (existing initial database) | `public` | `control_owner` | `control_api_runtime` |
| HoopDb/pipeline | `hoopdb` | `sessions` | `hoop` | `sessions_pipeline_runtime` |
| Relaycast | `relaycast` | `public` | `relaycast_owner` | `relaycast_runtime` |
| Relayfile, when enabled | `relayfile` | `public` | `relayfile_owner` | `relayfile_runtime` |

The Control `public` schema is the current service's supported default; the older
`relaycontrol` schema assignment was target metadata, not an executed migration.
This table does not inspect existing databases or move data. Before adopting any
existing installation, verify its catalog and preserve its actual namespace in
reviewed bindings; a non-public installation needs compatible application support.

A binding does not create a database or enable an add-on. Database bindings
represent components with authoritative relational stores.
History is a sessions-pipeline capability with no store of its own. Keep an
older installation's History or Auth database until its reviewed cutover; they
are not target dependencies.

All bindings use the same writer endpoint/port and `sslmode=verify-full`, with
independent database names and migration/runtime identities. Credentials remain
in the secret system, never Terraform outputs or assembled credential URLs.
`application_database_name` retains the initial Control database name to avoid
silently replacing RDS. It does not rename other service databases. A later
endpoint split still requires data migration, cutover and restore proof.

A complete, nonempty `service_databases` map selects separate databases. The
module rejects missing/unknown service keys, duplicate or maintenance database
names, and shared or privileged role identities. Public schemas may repeat in
separate databases. An empty map preserves the older shared-database compatibility
contract with distinct non-public schemas; it is not the current AWS target.

## Database creation and application integration

The layout module performs no SQL. RDS `db_name` creates only the initial
Control database; an explicitly reviewed executor must create/own the remaining
databases and install compatible service roles/migrations. That bootstrap must
be reproducible from the reviewed source, rather than manual Secret URL edits.
No existing database or data is renamed, adopted or deleted by publishing this
contract.

- Revoke PUBLIC database CONNECT and grant each application role only its own
  database. Roles are instance-wide: migration owners and runtime identities
  must be distinct across components, with no inherited owner/admin membership.
- Revoke runtime CREATE on databases and schemas, and limit runtime grants to the
  service's accepted surface. A database name or search_path is not authorization.
  The RDS master is a provisioning executor, never an application login.
- Use the service's canonical schemas and accepted migration line inside its
  dedicated database. HoopDb's database-wide function-boundary verifier need not
  admit another service's functions. RDS still needs its supported bootstrap and
  reviewed LOGIN/activation path; a true-superuser CNPG script is not equivalent.
- Pin the RDS CA and verify both chain and hostname. `sslmode=require` or a
  compatibility switch alone is not this proof. Test wrong CA and wrong host as
  refusals, and verify the actual driver's TLS configuration.
- Relaycast must use a qualified PostgreSQL serving adapter and supported image.
  SQLite, connection/migration-only adapters and chart environment switches do
  not prove authoritative PostgreSQL messaging state.
- Control authentication, native ingest/read wiring, publication, privacy/deletion,
  optional-service licensing and Desktop flows still need combined application
  acceptance. Removing a legacy server must preserve its product capability/data.

`application_sql_ready=false` remains deliberate until the application bootstrap
and runtime are qualified. Both AWS roots keep automatic Lambda processing held;
changing database topology does not qualify an artifact or release that gate.
S3 remains the object store and OpenSearch can hold derived indexes; neither
substitutes for the service's authoritative PostgreSQL data.

## Required AWS proof

1. Inspect the reviewed plan/state and native inventory: one application RDS
   instance, with the intended separate service databases. PostgreSQL/RDS
   maintenance databases do not count as service stores. Record the common
   endpoint and per-service database/schema/owner/runtime identity without secrets.
2. Create/bootstrap databases with the named executor. Use real non-owner LOGINs
   over verified TLS. Each runtime must read/write its allowed surface and fail
   connection to every other service database, schema DDL and privileged access.
   Prove unexpected role membership and weak grants fail closed.
3. Migrate each service independently, then install the combined Helm stack.
   Prove app-profile readiness, repeat migration, crash/resume, upgrade and restart.
   Generic schema PASS or a listening log cannot substitute for runtime readiness.
4. Complete the application trace: sign-in, messaging, Desktop capture/upload,
   pipeline indexing, application readback and privacy/deletion. Prove Relaycast
   durable state through pod replacement and real PostgreSQL concurrency.
5. Restore into an owned recovery instance and repeat service behavior plus
   cross-database denial tests. Record data continuity and operational cleanup.

Source/mocked tests and a legacy-stack smoke result are not managed acceptance
of this target. An existing quarantine or environment admission still applies;
this contract does not authorize provider operations or destructive cutovers.
