# PostgreSQL service layout

A provider-free, non-secret connection contract for services on one PostgreSQL
instance. AWS roots explicitly select **separate logical databases per service**;
owner/runtime roles remain independent and cluster-wide role names are unique.
The module performs no SQL operations and creates no database or credentials.

Set `service_databases` to a complete map matching `services`. Names must be
valid, distinct application identifiers, never maintenance databases. Different
databases may use the same canonical `public` schema. Revoke PUBLIC database
CONNECT and unsafe schema privileges in the reviewed bootstrap: a database name
or search_path alone does not establish isolation.

An empty `service_databases` map preserves the old one-database/isolated-schema
binding for existing callers. Its non-public schema uniqueness guard stays in
place; that compatibility mode is not the new AWS target. `database` remains
the existing initial database name, so this change never renames an RDS resource.

See [the storage contract](../../../docs/shared-postgres-storage-contract.md).
`application_sql_ready=false` remains deliberate until database creation, role
activation, per-service migrations, verified TLS and real denial tests are proved.
Optional-service bindings do not enable their workloads. A later split moves a
complete binding to another endpoint with reviewed data migration and restore.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11 |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| database | The existing initial database name. With service\_databases set, it is normally Control's database only; preserve it because changing RDS db\_name may replace infrastructure. | `string` | n/a | yes |
| host | Shared PostgreSQL writer endpoint. No URL, user or credential. | `string` | n/a | yes |
| forbidden\_roles | Administrator/bootstrap identities forbidden in service bindings. Roots must include their configured database master username. | `set(string)` | ```[ "relay_admin" ]``` | no |
| port | Shared PostgreSQL port. | `number` | `5432` | no |
| service\_databases | Explicit per-service database names on the same instance. An empty map preserves the legacy shared-database binding. A nonempty map must name exactly the configured services, with distinct non-maintenance databases. This metadata does not create databases or grants. | `map(string)` | `{}` | no |
| services | Per-service schemas and independent owner/runtime roles, scoped by the selected database layout. This is a non-secret binding contract; it does not create SQL objects, change app migrations or prove runtime support. | ```map(object({ schema = string migration_role = string runtime_role = string }))``` | ```{ "control": { "migration_role": "control_owner", "runtime_role": "control_api_runtime", "schema": "relaycontrol" }, "history": { "migration_role": "history_owner", "runtime_role": "relayhistory_runtime", "schema": "relayhistory" }, "hoopdb": { "migration_role": "hoop", "runtime_role": "sessions_pipeline_runtime", "schema": "sessions" }, "relaycast": { "migration_role": "relaycast_owner", "runtime_role": "relaycast_runtime", "schema": "relaycast" }, "relayfile": { "migration_role": "relayfile_owner", "runtime_role": "relayfile_runtime", "schema": "relayfile" } }``` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| bindings | Non-secret per-service connection identity. Databases, roles and schemas require reviewed bootstrap and compatible application support before use. |
| topology | Required relational topology, not live application acceptance. |
<!-- END_TF_DOCS -->
