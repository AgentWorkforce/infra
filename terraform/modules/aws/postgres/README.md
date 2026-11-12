# aws/postgres

PostgreSQL 17 for agent-relay on **RDS for PostgreSQL** (default) or **Aurora PostgreSQL** (`engine_mode = "aurora"`), in your subnets and security groups.

- Private only (`publicly_accessible = false`). Storage encrypted with `kms_key_arn` or the AWS managed key.
- `rds.force_ssl = 1`. Connect with `sslmode=verify-full` and the RDS CA bundle.
- Master password managed by RDS in Secrets Manager (`manage_master_user_password`), so it never enters state. Output: `master_user_secret_arn`.
- Deletion protection, a final snapshot, 14 days of backups and PITR, Multi-AZ (RDS) or two instances (Aurora), and Performance Insights.
- `pg_trgm` and `vector` are always permitted. If you set `allowed_extensions`, the module appends them to `rds.allowed_extensions`.
- Feeds the host of every database URL in the release Secret. Run the bootstrap SQL in [`terraform/README.md`](../../../README.md#postgres-bootstrap-before-the-first-migrate) before the first migrate.

```hcl
module "postgres" {
  source                 = "github.com/AgentWorkforce/infra//terraform/modules/aws/postgres?ref=<tag>"
  name                   = "agent-relay-pg"
  subnet_ids             = ["subnet-a", "subnet-b"]
  vpc_security_group_ids = ["sg-db"]
  kms_key_arn            = "arn:aws:kms:..."
}
```

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.6 |
| aws | >= 6.0, < 7.0 |
| random | >= 3.5, < 4.0 |

### Providers

| Name | Version |
| ---- | ------- |
| aws | >= 6.0, < 7.0 |
| random | >= 3.5, < 4.0 |

### Resources

| Name | Type |
| ---- | ---- |
| [aws_db_instance.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance) | resource |
| [aws_db_parameter_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_parameter_group) | resource |
| [aws_db_subnet_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_subnet_group) | resource |
| [aws_rds_cluster.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster) | resource |
| [aws_rds_cluster_instance.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster_instance) | resource |
| [aws_rds_cluster_parameter_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster_parameter_group) | resource |
| [random_id.final_snapshot](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| name | Identifier for the instance or cluster and the prefix for its subnet and parameter groups. Lowercase letters, digits and hyphens. | `string` | n/a | yes |
| vpc\_security\_group\_ids | Existing security groups for the database. Allow TCP 5432 only from the cluster nodes or pods that run agent-relay. The module never opens anything. Required when enabled; may be empty when enabled = false. | `list(string)` | n/a | yes |
| allocated\_storage | RDS only: initial gp3 storage in GiB. | `number` | `100` | no |
| allowed\_extensions | Value for the rds.allowed\_extensions parameter. null leaves the RDS default (every supported extension). When set, pg\_trgm and vector are always added, because RelayHistory needs them. | `list(string)` | `null` | no |
| apply\_immediately | Apply modifications now instead of in the next maintenance window. | `bool` | `false` | no |
| aurora\_instance\_count | Aurora instances (one writer plus readers). Two or more gives a failover target in another AZ. | `number` | `2` | no |
| auto\_minor\_version\_upgrade | Apply minor engine upgrades in the maintenance window. | `bool` | `true` | no |
| backup\_retention\_days | Automated backup (and point-in-time recovery) retention in days. | `number` | `14` | no |
| ca\_cert\_identifier | Server certificate authority. null uses the account default. | `string` | `"rds-ca-rsa2048-g1"` | no |
| copy\_tags\_to\_snapshot | Copy resource tags to snapshots. | `bool` | `true` | no |
| database\_name | Initial database created with the instance. Create the others (relaycontrol, relayhistory, hoopdb, ...) with the bootstrap SQL in the README. | `string` | `"relaycontrol"` | no |
| db\_subnet\_group\_name | Existing DB subnet group to use instead of creating one from subnet\_ids. | `string` | `null` | no |
| deletion\_protection | Refuse deletion through the API until turned off. | `bool` | `true` | no |
| enabled | Create the database. false creates no AWS resource (for a stack whose database lives elsewhere) and every connection output is null. Default true; turning it off on an existing database plans its destruction, which deletion\_protection refuses. | `bool` | `true` | no |
| enabled\_cloudwatch\_logs\_exports | Log types exported to CloudWatch Logs. | `list(string)` | ```[ "postgresql" ]``` | no |
| engine\_mode | "rds" for RDS for PostgreSQL (one instance, optionally Multi-AZ) or "aurora" for an Aurora PostgreSQL cluster. | `string` | `"rds"` | no |
| engine\_version | PostgreSQL engine version. RDS accepts a major version ("17") and picks the default minor; Aurora needs a full version (for example "17.5"). The agent-relay services are tested on PostgreSQL 17. | `string` | `"17"` | no |
| force\_ssl | Set rds.force\_ssl=1, so the server refuses unencrypted connections. Connect with sslmode=verify-full and the RDS CA bundle. | `bool` | `true` | no |
| iam\_database\_authentication\_enabled | Allow IAM database authentication in addition to passwords (password roles keep working). | `bool` | `true` | no |
| instance\_class | Instance class for RDS, or for each Aurora instance ("db.serverless" for Aurora Serverless v2). | `string` | `"db.r7g.large"` | no |
| iops | RDS only: provisioned IOPS (gp3 above 400 GiB, or io1/io2). null uses the storage type's baseline. | `number` | `null` | no |
| kms\_key\_arn | Customer managed KMS key for storage, Performance Insights and the managed master password secret. null uses the AWS managed keys. | `string` | `null` | no |
| master\_username | Master (rds\_superuser) user name. Its password is generated and stored by RDS in Secrets Manager; it never enters Terraform state. | `string` | `"relay_admin"` | no |
| max\_allocated\_storage | RDS only: storage autoscaling ceiling in GiB (0 disables autoscaling). | `number` | `1000` | no |
| monitoring\_interval | Enhanced Monitoring interval in seconds (0 disables it). Non-zero needs monitoring\_role\_arn. | `number` | `0` | no |
| monitoring\_role\_arn | Existing IAM role for Enhanced Monitoring (rds.amazonaws.com monitoring role). | `string` | `null` | no |
| multi\_az | RDS only: a synchronous standby in a second AZ. | `bool` | `true` | no |
| parameters | Extra parameters for the (cluster) parameter group. rds.force\_ssl is managed by the module through force\_ssl. | ```list(object({ name = string value = string apply_method = optional(string, "pending-reboot") }))``` | `[]` | no |
| performance\_insights\_enabled | Enable Performance Insights (encrypted with kms\_key\_arn when set). | `bool` | `true` | no |
| performance\_insights\_retention\_period | Performance Insights retention in days (7, or 31-731 in multiples of 31). | `number` | `7` | no |
| port | Database port. | `number` | `5432` | no |
| preferred\_backup\_window | Daily backup window (UTC, hh24:mi-hh24:mi). null lets AWS choose. | `string` | `null` | no |
| preferred\_maintenance\_window | Weekly maintenance window (ddd:hh24:mi-ddd:hh24:mi, UTC). null lets AWS choose. | `string` | `null` | no |
| serverlessv2\_scaling | Aurora Serverless v2 capacity range in ACUs, used when instance\_class is db.serverless. | ```object({ min_capacity = number max_capacity = number })``` | ```{ "max_capacity": 8, "min_capacity": 0.5 }``` | no |
| skip\_final\_snapshot | Skip the final snapshot on destroy. Keep false for anything holding real data. | `bool` | `false` | no |
| storage\_type | RDS only: storage type. | `string` | `"gp3"` | no |
| subnet\_ids | Private subnet IDs (at least two Availability Zones) for a new DB subnet group. Ignored when db\_subnet\_group\_name is set. | `list(string)` | `[]` | no |
| tags | Tags applied to every resource. | `map(string)` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| cluster\_identifier | Aurora cluster identifier (null for RDS). |
| database\_url\_template | Connection URL shape for the chart Secrets, with placeholders for role, password and database. sslmode=verify-full needs the RDS CA bundle in the trust store; sslmode=require is the minimum with force\_ssl. |
| db\_subnet\_group\_name | DB subnet group in use. |
| enabled | Whether the database exists. false (enabled = false) creates no AWS resource and every connection output is null. |
| engine\_mode | "rds" or "aurora". |
| host | Writer endpoint host name. The host part of every agent-relay database URL (relay-control database-url, relayhistory DATABASE\_URL, sessions-pipeline HOOPDB\_URL, durable-actors postgres-url). |
| initial\_database | The database created with the instance. |
| instance\_identifier | RDS instance identifier (null for Aurora). |
| master\_user\_secret\_arn | Secrets Manager secret (JSON keys username, password) that RDS manages and rotates for the master user. Read it from the bootstrap job or an External Secrets Operator ExternalSecret; the password never enters Terraform state. |
| master\_username | Master (rds\_superuser) user. Use it only for the bootstrap SQL in the README, never as an application role. |
| port | Database port. |
| reader\_host | Aurora reader endpoint (null for RDS). No agent-relay component reads from replicas. |
| resource\_arn | ARN of the RDS instance or Aurora cluster. |
<!-- END_TF_DOCS -->
