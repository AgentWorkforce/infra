# examples/aws

The application target is **one RDS instance with a separate PostgreSQL database
per service**. Control uses `relaycontrol` by default; HoopDb uses `hoopdb`,
Relaycast uses `relaycast`, and the optional Relayfile add-on uses `relayfile`.
Each has independent migration/runtime roles and its own canonical schema.
`application_database_name` names only the initial Control database; it stays
unchanged on existing instances. Changing it forces replacement of an existing RDS instance; review the plan and explicit data migration/restore first. `postgres_service_bindings` publishes complete
non-secret database/schema/role targets on the same endpoint. These outputs do
not create SQL databases, prove application compatibility or enable add-ons.
See the [storage contract](../../../docs/shared-postgres-storage-contract.md).
Legacy RelayAuth/standalone History databases and SQLite receipts are not target
acceptance; existing data is retained until a separately reviewed cutover.

A thin root that composes the four AWS modules for one agent-relay install on an existing EKS cluster and VPC:

- `aws/postgres` (RDS by default; `postgres_engine_mode = "aurora"`).
- `aws/object-storage` for session object storage, with Pod Identity for `<release>-worker`, legacy `<release>-alleyoop`, and descriptive `<release>-session-ingest-api`. Keep the actual installed ingest ServiceAccount bound until a deliberate naming cutover completes; override these defaults for custom chart identities.
- `aws/search` (`enable_search`), with a write role for the indexer and a read-only role for the session read API. Set `indexer_service_account` and `reader_service_account` to bind them through Pod Identity. Pod Identity allows one role per ServiceAccount, and the worker and alleyoop ServiceAccounts already carry the sessions bucket role, so these must be separate ServiceAccounts. The agent-relay chart gives the sessions components one shared ServiceAccount, so these bindings take effect once the indexer and the read API run under their own `serviceAccount` names (a chart change outside this module set).
  - With `enable_functions` too, the pipeline Lambda gets the indexer permissions and is allowed by the domain policy. Map its role (`search.lambda_indexer_role_arn`) to the OpenSearch write role, and allow TCP 443 from `function_security_group_ids` in `search_security_group_ids`.
- `aws/functions` (`enable_functions`).

```sh
cp terraform.tfvars.example terraform.tfvars   # fill in existing IDs
terraform init && terraform plan
```

`chart_values` prints the non-secret values for `values-eks.yaml`. The database URLs go into the release Secret after the bootstrap in [`terraform/README.md`](../../README.md#postgres-bootstrap-before-the-first-migrate).

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11 |
| aws | >= 6.0, < 7.0 |

### Providers

| Name | Version |
| ---- | ------- |
| terraform | n/a |

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| functions | ../../modules/aws/functions | n/a |
| postgres | ../../modules/aws/postgres | n/a |
| postgres\_layout | ../../modules/postgres-layout | n/a |
| search | ../../modules/aws/search | n/a |
| sessions\_bucket | ../../modules/aws/object-storage | n/a |

### Resources

| Name | Type |
| ---- | ---- |
| [terraform_data.service_account_checks](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| database\_security\_group\_ids | Existing security groups for Postgres (5432 from the EKS nodes/pods). | `list(string)` | n/a | yes |
| eks\_cluster\_name | Existing EKS cluster that runs agent-relay (Pod Identity associations). | `string` | n/a | yes |
| private\_subnet\_ids | Existing private subnets (two or more AZs) for the database and the function. | `list(string)` | n/a | yes |
| region | AWS region. | `string` | n/a | yes |
| sessions\_bucket\_name | Globally unique S3 bucket name for session objects. | `string` | n/a | yes |
| alarm\_actions | SNS topics for the pipeline alarms. | `list(string)` | `[]` | no |
| application\_database\_name | Initial Control database only, on the shared RDS instance. Other services use separate logical databases. Default preserves the existing identity. Changing this value on an existing RDS instance forces instance replacement; review the plan and an explicit data migration/restore before changing it. | `string` | `"relaycontrol"` | no |
| aurora\_engine\_version | Aurora PostgreSQL version when postgres\_engine\_mode is aurora. | `string` | `"17.9"` | no |
| enable\_functions | Create the optional pipeline Lambda resources; automatic queue and schedule processing remains disabled until the per-service-database application is qualified. | `bool` | `false` | no |
| enable\_search | Create the optional OpenSearch domain. | `bool` | `false` | no |
| function\_security\_group\_ids | Existing security groups for the pipeline function ENIs (egress to Postgres and, with enable\_search, to the OpenSearch security groups on 443). | `list(string)` | `[]` | no |
| indexer\_service\_account | ServiceAccount (in namespace) of the search indexer (the hoopdb-indexer worker), bound to the write role. Must differ from reader\_service\_account and the sessions worker/alleyoop ServiceAccounts. null creates the role without an association. | `string` | `null` | no |
| kms\_key\_arn | Customer managed KMS key for Postgres, the sessions bucket and OpenSearch (null: AWS managed keys). The optional pipeline keeps its module defaults (SQS-managed SSE, AWS managed keys); pass the functions module's *\_kms\_key\_arn inputs to change that. | `string` | `null` | no |
| name | Name prefix for every resource (lowercase; at most 21 characters, so <name>-search fits OpenSearch's 28). | `string` | `"agent-relay"` | no |
| namespace | agent-relay release namespace. | `string` | `"agent-relay"` | no |
| pipeline\_package | Pipeline Lambda package (see modules/aws/functions). | ```object({ image_uri = optional(string) s3_bucket = optional(string) s3_key = optional(string) s3_object_version = optional(string) filename = optional(string) source_code_hash = optional(string) })``` | `{}` | no |
| postgres\_engine\_mode | rds or aurora. | `string` | `"rds"` | no |
| reader\_service\_account | ServiceAccount (in namespace) of the session read API, bound to the read-only role. null creates the role without an association. | `string` | `null` | no |
| release\_name | agent-relay Helm release name. | `string` | `"agent-relay"` | no |
| search\_master\_user\_arn | IAM role that administers OpenSearch fine-grained access control. | `string` | `null` | no |
| search\_security\_group\_ids | Existing security groups for OpenSearch. Allow TCP 443 from the indexer and read API pods and, with enable\_functions, from function\_security\_group\_ids. | `list(string)` | `[]` | no |
| search\_subnet\_ids | Existing private subnets for OpenSearch (one per AZ, 2 or 3). | `list(string)` | `[]` | no |
| service\_database\_names | Existing or reviewed new database names for HoopDb, Relaycast and optional Relayfile on the same RDS instance. This metadata does not create or rename databases. Control uses application\_database\_name. | `map(string)` | ```{ "hoopdb": "hoopdb", "relaycast": "relaycast", "relayfile": "relayfile" }``` | no |
| tags | Tags for every resource (provider default\_tags). | `map(string)` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| chart\_values | Non-secret agent-relay chart values (values-eks.yaml) these resources feed. Database URLs go in the release Secret, not here; see terraform/README.md. |
| functions | Pipeline function, queue, DLQ and secret (null unless enable\_functions). |
| postgres | Postgres host, port, master secret and URL template. |
| postgres\_service\_bindings | Separate service databases and independent migration/runtime roles on the same RDS endpoint. Contains no credentials; reviewed database bootstrap, CONNECT/ACL isolation and runtime proof remain required. Optional-service bindings do not enable workloads. |
| postgres\_topology | Single-instance, separate-service-database target; application\_sql\_ready=false until actual service integration and managed-RDS validation are completed. |
| search | OpenSearch endpoint and the roles to map as backend\_roles with the master user: indexer\_role\_arn and lambda\_indexer\_role\_arn (event mode) to the write role, reader\_role\_arn to the read-only role (null unless enable\_search). |
| sessions\_role\_arn | Pod Identity role for the worker and alleyoop ServiceAccounts. |
<!-- END_TF_DOCS -->
