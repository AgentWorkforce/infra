# aws/functions

**Optional.** The sessions pipeline's **event-driven mode** on AWS. It mirrors the hosted stack (AgentWorkforce/96BullSessions `stacks/aws/session-pipeline.ts`):

```
sessions bucket --(S3 notification, <key_prefix>/**/manifest.json puts and deletes)--> SQS <name>-session-events
    session-events --(event source mapping: batch 10, 20 s window, ReportBatchItemFailures, max concurrency 4)--> Lambda <name>-session-pipeline
    session-events --(after 8 receives)--> SQS <name>-session-events-dlq (14 days, alarmed)
    EventBridge rate(30 minutes) --> Lambda {"reconcile": true}  (a reconcile at its deadline re-invokes itself)
    EventBridge rate(1 minute), DISABLED unless briefs_enabled --> Lambda {"brief": true}
```

By default the chart runs these stages as long-running worker pods (the hoopdb-indexer reconcile tick, referee, and the bob-costas sweep). This module is an alternative, not a requirement. No chart value consumes it.

Set `enabled = false` during initial secret/database/artifact bootstrap to disable
the queue mapping and both schedules. Existing callers retain `enabled = true`
by default. A disabled function can still be explicitly invoked by an authorized
caller, and its queue can accumulate notifications. Enable automatic processing
only after verifying the artifact, bootstrap and retirement of overlapping
worker stages.

- **Package:** `package.image_uri` (ECR, pinned by digest: `<repository>@sha256:<64 hex>`; tags are refused), `package.s3_bucket` + `s3_key`, or `package.filename`. The hosted handler is `src/session-pipeline/lambda.ts`, export `handler`, on `nodejs24.x` / `arm64`.
- **No Function URL.** Only the two EventBridge rules (by source ARN) and the function's own role may invoke it.
- **Execution role:** logs to its own log group, unconditional `s3:ListBucket`, and `s3:GetObject` on `<bucket>/<key_prefix>/*/<layout_version>/*` only. It may consume and re-enqueue its queue, read its one secret, invoke itself, and decrypt through S3 for the bucket key. It gets ENI permissions only in a VPC.
- **Secret:** an empty Secrets Manager container (`SESSION_PIPELINE_SECRET_ARN`). Set its JSON value out of band: the HoopDb URL and, with `search_index_enabled`, the search backend credentials.
- **Environment:** `PIPELINE_RAW_S3_BUCKET`, `PIPELINE_KEY_PREFIX`, `PIPELINE_ORG_FROM_PREFIX=true`, `SESSION_PIPELINE_SECRET_ARN`, `SESSION_PIPELINE_QUEUE_URL`, `SEARCH_INDEX_ENABLED`, `PIPELINE_FANOUT=off`, `PIPELINE_RECONCILE_LOOKBACK_MINUTES` (twice `reconcile_minutes`), `HOOPDB_POOL_MAX=4`, `OTEL_SERVICE_NAME`, `NODE_OPTIONS=--enable-source-maps` and `SESSION_BRIEF_ENABLED`, as in the hosted `sessionPipelineEnv`. `environment` merges over them.
- **Alarms:** DLQ not empty, oldest message older than 15 minutes, and function errors. Actions are enabled when `alarm_actions` is set.
- **VPC:** set `vpc_subnet_ids` and `vpc_security_group_ids` to reach a private HoopDb. The subnets need NAT or VPC endpoints for S3, SQS, Secrets Manager and CloudWatch Logs.
- **Bucket notifications:** `aws_s3_bucket_notification` owns the bucket's whole notification configuration. If anything else notifies from the bucket, set `manage_bucket_notification = false` and add `bucket_notification_queue_configuration` there.

## Operator-owned execution role

`existing_execution_role_arn = null` preserves managed-role behavior. Supplying
an exact same-account/partition role ARN sets the actual Lambda `role` and
`execution_role_arn` output to that ARN and creates **no IAM role or inline
policy**. No IAM role lookup is performed. `role_path` and
`permissions_boundary_arn` configure only a managed role.

Before applying, a separate approved operator phase must create and verify the
role's Lambda service trust, runtime permissions, permissions boundary and any
mandatory guards. An ARN cannot establish those properties. The caller still
needs its approved, scoped `iam:PassRole` permission; this module grants no
caller permissions. `execution_role_policy_json` describes the proposed runtime
permissions in either mode, including `additional_policy_statements`, but does
not attach them in external mode. Some service-generated ARNs may remain
unknown until resources exist; this output alone is not proof of an installed
policy or a bootstrap ordering mechanism. Retain the execution role and required
ENI permissions through function/VPC-interface retirement. The role's owner
must remove the role only after its consumers are gone.

Moved blocks migrate existing managed-role state without replacing roles when
upgrading to the counted resources. Switching an already-managed deployment to an external ARN
would otherwise propose destroying the previously managed IAM resources. Use a
separately reviewed state ownership handoff before that switch; this module
does not adopt, detach or forget existing IAM resources automatically.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.6 |
| aws | >= 6.0, < 7.0 |

### Providers

| Name | Version |
| ---- | ------- |
| aws | >= 6.0, < 7.0 |

### Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_event_rule.brief](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_rule.reconcile](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.brief](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_event_target.reconcile](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_log_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_metric_alarm.backlog_age](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.dlq_not_empty](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.errors](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_lambda_event_source_mapping.events](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_event_source_mapping) | resource |
| [aws_lambda_function.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_function_event_invoke_config.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function_event_invoke_config) | resource |
| [aws_lambda_permission.brief](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_lambda_permission.reconcile](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_s3_bucket_notification.manifests](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_notification) | resource |
| [aws_secretsmanager_secret.pipeline](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_sqs_queue.dlq](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue) | resource |
| [aws_sqs_queue.events](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue) | resource |
| [aws_sqs_queue_policy.dlq](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue_policy) | resource |
| [aws_sqs_queue_policy.events](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue_policy) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| bucket\_name | The sessions (Locker) bucket that receives manifests: the same bucket as sessions-pipeline worker.locker.bucket. | `string` | n/a | yes |
| name | Prefix for the function, queues, rules, alarms and role (<name>-session-pipeline, <name>-session-events, ...). | `string` | n/a | yes |
| package | The pipeline code, exactly one of: image\_uri (a container image in ECR, package\_type Image), s3\_bucket + s3\_key (a zip in S3), or filename (a local zip). The hosted stack builds src/session-pipeline/lambda.ts from AgentWorkforce/96BullSessions with export "handler". | ```object({ image_uri = optional(string) s3_bucket = optional(string) s3_key = optional(string) s3_object_version = optional(string) filename = optional(string) source_code_hash = optional(string) })``` | n/a | yes |
| additional\_policy\_statements | Extra statements in execution\_role\_policy\_json, attached only for a managed role (for example es:ESHttpPost/Put on an OpenSearch domain once the services have that backend). | `any` | `[]` | no |
| alarm\_actions | SNS topic ARNs for the DLQ, backlog-age and error alarms. Empty creates the alarms with actions disabled. | `list(string)` | `[]` | no |
| architecture | arm64 or x86\_64 (must match the package). | `string` | `"arm64"` | no |
| batch\_size | SQS messages per invocation. | `number` | `10` | no |
| brief\_schedule\_expression | Brief tick schedule. | `string` | `"rate(1 minute)"` | no |
| briefs\_enabled | Session briefs: enables the brief schedule and sets SESSION\_BRIEF\_ENABLED. Model calls also need openai\_api\_key in the pipeline secret. | `bool` | `false` | no |
| bucket\_kms\_key\_arn | The bucket's customer managed KMS key, if any. The role may decrypt with it only through S3. With S3 Bucket Keys the encryption context is the bucket ARN, so the grant covers the bucket; object reads stay limited to key\_prefix by s3:GetObject. | `string` | `null` | no |
| code\_signing\_config\_arn | Lambda code signing configuration for zip packages (null: no signature check). | `string` | `null` | no |
| create\_secret | Create an empty Secrets Manager secret (a container; set its JSON value out of band: HoopDb URL and, with search on, the search backend credentials). Only the pipeline role may read it. | `bool` | `true` | no |
| delivery\_delay\_seconds | Queue delivery delay, so a burst of manifest writes coalesces. | `number` | `30` | no |
| dlq\_retention\_seconds | DLQ retention (14 days, the SQS maximum). | `number` | `1209600` | no |
| enabled | Enable queue consumption and schedules. Set false while provisioning the function, secret and database bootstrap; direct authorized invocations remain possible. | `bool` | `true` | no |
| environment | Extra (non-secret) environment variables, merged over the module's defaults (see the README). Secrets go in the pipeline secret, never here. | `map(string)` | `{}` | no |
| existing\_execution\_role\_arn | Existing same-account Lambda execution role. Null creates the role and inline policy; otherwise this module authors neither. The operator must verify trust, permissions, boundary and guards separately. | `string` | `null` | no |
| handler | Handler for zip packages (ignored for images). | `string` | `"index.handler"` | no |
| key\_prefix | Tenant key base the services write under (the services' TENANT\_KEY\_BASE, "96bulls"). | `string` | `"96bulls"` | no |
| lambda\_kms\_key\_arn | KMS key for the function's environment variables. null uses the AWS managed key. | `string` | `null` | no |
| layout\_version | Object layout version the pipeline reads (<key\_prefix>/<org>/<layout\_version>/...). | `string` | `"v1"` | no |
| log\_kms\_key\_arn | KMS key for the function log group (its key policy must allow CloudWatch Logs). | `string` | `null` | no |
| log\_retention\_days | Function log group retention. | `number` | `30` | no |
| manage\_bucket\_notification | Create the bucket's S3 event notification (manifest.json puts and deletes to the queue). aws\_s3\_bucket\_notification owns the bucket's whole notification configuration, so turn this off when anything else notifies from the bucket and add the queue configuration there (see the bucket\_notification\_queue\_configuration output). | `bool` | `true` | no |
| max\_concurrency | Maximum concurrent Lambda invocations from the queue (event source mapping scaling). | `number` | `4` | no |
| max\_receive\_count | Receives before a message moves to the DLQ. | `number` | `8` | no |
| maximum\_batching\_window\_seconds | How long the mapping waits to fill a batch. | `number` | `20` | no |
| memory\_size | Function memory in MB. | `number` | `3008` | no |
| permissions\_boundary\_arn | Permissions boundary for the managed execution role; unused with existing\_execution\_role\_arn. | `string` | `null` | no |
| queue\_kms\_key\_arn | Customer managed KMS key for both queues. null uses SQS-managed SSE. A CMK's key policy must let s3.amazonaws.com use it (kms:GenerateDataKey, kms:Decrypt) for the bucket notification. | `string` | `null` | no |
| queue\_retention\_seconds | session-events retention. | `number` | `345600` | no |
| reconcile\_minutes | Reconcile schedule (lost notifications). The lookback (PIPELINE\_RECONCILE\_LOOKBACK\_MINUTES) is twice this. | `number` | `30` | no |
| reserved\_concurrent\_executions | Reserved concurrency for the function (-1: unreserved). | `number` | `-1` | no |
| role\_path | IAM path for the managed execution role; unused with existing\_execution\_role\_arn. | `string` | `"/"` | no |
| runtime | Runtime for zip packages (ignored for images). The hosted pipeline runs nodejs24.x. | `string` | `"nodejs24.x"` | no |
| search\_index\_enabled | SEARCH\_INDEX\_ENABLED. Off: pointers only (Postgres pg\_trgm search). On: the pipeline also writes the search index through its SearchIndexAdapter. ClickHouse credentials go in the pipeline secret; Amazon OpenSearch uses IAM instead: grant the execution role with additional\_policy\_statements and list it in the search module's additional\_principal\_arns. | `bool` | `false` | no |
| secret\_arn | Existing pipeline secret ARN, when create\_secret is false. | `string` | `null` | no |
| secret\_kms\_key\_arn | KMS key for the created secret. null uses aws/secretsmanager. | `string` | `null` | no |
| secret\_recovery\_window\_days | Recovery window when the secret is deleted. | `number` | `7` | no |
| tags | Tags applied to every resource. | `map(string)` | `{}` | no |
| timeout\_seconds | Function timeout. The queue's visibility timeout is six times this (AWS guidance for SQS sources) plus maximum\_batching\_window\_seconds. | `number` | `300` | no |
| tracing\_mode | X-Ray tracing (PassThrough or Active). | `string` | `"PassThrough"` | no |
| vpc\_security\_group\_ids | Security groups for the function ENIs (egress to Postgres 5432 and HTTPS). | `list(string)` | `[]` | no |
| vpc\_subnet\_ids | Private subnets for the function ENIs. Needed to reach a private HoopDb (RDS/Aurora); the subnets need a route to S3, SQS, Secrets Manager and CloudWatch (NAT or VPC endpoints). Empty runs outside a VPC. | `list(string)` | `[]` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| activation\_enabled | Whether automatic queue consumption and schedules are enabled. |
| brief\_rule\_arn | EventBridge brief rule ARN (DISABLED unless briefs\_enabled). |
| bucket\_notification\_queue\_configuration | The S3 notification queue configuration, for buckets whose notifications are managed elsewhere (manage\_bucket\_notification = false). |
| dlq\_arn | Dead-letter queue ARN. |
| dlq\_url | Dead-letter queue URL (inspect and redrive from here). |
| execution\_role\_arn | Actual Lambda execution role ARN, managed here or supplied by the operator. |
| execution\_role\_policy\_json | Proposed runtime permissions, including additional\_policy\_statements. Attached only in managed-role mode; external-role installation and validation belong to the operator. May contain values unknown until resources exist. |
| function\_arn | Pipeline function ARN. |
| function\_name | Pipeline function name. |
| queue\_arn | session-events queue ARN. |
| queue\_url | session-events queue URL (SESSION\_PIPELINE\_QUEUE\_URL). |
| reconcile\_rule\_arn | EventBridge reconcile rule ARN. |
| secret\_arn | Pipeline secret ARN (SESSION\_PIPELINE\_SECRET\_ARN). Set its JSON value out of band: the HoopDb URL (the same value as the chart's HOOPDB\_URL key) and the search backend credentials. |
<!-- END_TF_DOCS -->
