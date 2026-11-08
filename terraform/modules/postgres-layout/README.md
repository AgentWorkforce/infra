# Shared PostgreSQL service layout

A provider-free, non-secret contract for one RDS writer endpoint and one
application database, with a separate schema, migration owner and runtime role
for each service. The AWS roots create the physical RDS resource; this module
validates and publishes the application bindings. It performs no SQL operations.

See [the shared-store contract](../../../docs/shared-postgres-storage-contract.md).
`application_sql_ready = false` is deliberate: a valid Terraform output does not
mean schema-aware migrations, Relaycast PostgreSQL support, managed-RDS role
activation or cross-service denial checks have passed. Never feed a schema name
into an unsupported application environment variable or rely on search_path as
a security boundary.

The database name is independent of the schemas. Existing roots retain
`relaycontrol` as the default initial database name to avoid silently replacing
an existing RDS resource; it can host all service schemas. New installations may
explicitly choose a different application database name in their reviewed plan.

A later split instantiates this same layout contract against another RDS/database
for the moved service, preserving its schema and role names. Data migration,
endpoint/Secret updates, cutover and restore proofs are still required. A
binding change alone does not move data.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11 |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| database | The single application database used by every service binding. Preserve an existing database name; changing RDS db\_name may replace infrastructure. | `string` | n/a | yes |
| host | Shared PostgreSQL writer endpoint. No URL, user or credential. | `string` | n/a | yes |
| forbidden\_roles | Administrator/bootstrap identities forbidden in service bindings. Roots must include their configured database master username. | `set(string)` | ```[ "relay_admin" ]``` | no |
| port | Shared PostgreSQL port. | `number` | `5432` | no |
| services | Per-service target schemas and independent owner/runtime roles. This is a non-secret binding contract; it does not create SQL objects, change app migrations or prove runtime support. | ```map(object({ schema = string migration_role = string runtime_role = string }))``` | ```{ "control": { "migration_role": "control_owner", "runtime_role": "control_api_runtime", "schema": "relaycontrol" }, "history": { "migration_role": "history_owner", "runtime_role": "relayhistory_runtime", "schema": "relayhistory" }, "hoopdb": { "migration_role": "hoop", "runtime_role": "sessions_pipeline_runtime", "schema": "sessions" }, "relaycast": { "migration_role": "relaycast_owner", "runtime_role": "relaycast_runtime", "schema": "relaycast" }, "relayfile": { "migration_role": "relayfile_owner", "runtime_role": "relayfile_runtime", "schema": "relayfile" } }``` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| bindings | Non-secret per-service connection identity. Roles and schemas require reviewed bootstrap and schema-aware application support before use. |
| topology | Required relational topology, not live application acceptance. |
<!-- END_TF_DOCS -->
