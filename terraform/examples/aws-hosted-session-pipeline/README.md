# examples/aws-hosted-session-pipeline

The hosted session pipeline's AWS wiring, moved from the relayhistory-pipeline Alchemy stack
(`stacks/aws/session-pipeline.ts`) into Terraform. Terraform/OpenTofu is the single reconciler. The code is
public; **every hosted value comes from private tfvars** (an SSM SecureString read by CI) and is never
committed. Self-hosted installs do not use this root. They run the sessions pipeline on the `agent-relay`
Helm chart, or optionally on `modules/aws/functions` or `modules/gcp/functions`.

## What it manages

| Piece | Notes |
|---|---|
| SQS `session-events` and its DLQ (module), with both queue policies (here) | Old stack values: delay 30 s, visibility 1800 s (an input), wait 20 s, 4 days, 8 receives, DLQ 14 days, SSE |
| Event source mapping (module) | batch 10, window 20 s, partial batch failures; `max_concurrency` from tfvars |
| EventBridge rules and targets | reconcile and brief in the module; the optional groups here (`optional_schedules`) only where declared |
| Lambda invoke permissions | one per rule plus the role's self-invoke; statement ids from tfvars (Alchemy generated them) |
| Three alarms | live names and descriptions, actions disabled |
| Pipeline secret container and its policy | the value is set out of band and never read here |
| Execution role, inline policies and attachments | imported as-is; every field comes from tfvars |
| Transcripts bucket notification, bucket policy and KMS key policy | the pipeline's own statements are rendered here; every other statement (other stacks, TLS and encryption denies, the **ingest-edge cross-account grants**) comes verbatim from tfvars |

**One module.** The queues, the event source mapping and the reconcile and brief rules come from
`modules/aws/functions` in adopt mode (`existing_function_name`), the same module self-host uses. Its
`schedule_description_prefix` keeps the live rule descriptions. The pieces whose live texts or statement ids
differ from the module's (queue policies, invoke permissions, alarms), the secret, the role and the bucket and key
policies are declared here, with the module's own copies switched off. When the function moves here in phase 2,
these converge into the module one reviewed knob at a time.

`aws_s3_bucket_notification` owns the bucket's whole notification configuration. `other_notifications` carries
every other live target verbatim (queues, functions, topics, EventBridge). Anything missing there would be removed,
and the gate refuses that plan.

Not yet: the function itself (phase 2, once the pipeline publishes a pinned artifact for Terraform to deploy),
the upload-inbox stack, the Cloudflare ingest Worker and the rest of `stacks/aws`.

## First run: import, then apply only an approved plan

The import blocks (`imports.tf`) bring every live resource into state. The rule (Khaliq, 2026-11-27/28): import
and apply only through infra CI, and only if the reviewed post-import plan has no changes except the ones
explicitly approved. Today that is one: the ESM's `MaximumConcurrency`, 20 to 25. `gate/zero_diff_gate.py`
enforces it on `terraform show -json`:

```sh
python3 gate/zero_diff_gate.py plan.json \
  --allow 'module.pipeline.aws_lambda_event_source_mapping.events:scaling_config.0.maximum_concurrency=20->25'
```

Any other create, replace, delete or attribute change refuses the plan. The fix is in the private tfvars (make
them equal live) or a separately approved change. Never edit the live resource.

The relayhistory-pipeline stack must stop managing these resources (Alchemy retirement, its own approval) before
the first apply, so the two reconcilers never fight.

## CI

`.github/workflows/hosted-session-pipeline.yml` runs `scripts/hosted/session-pipeline-ci.sh`. A **plan** dispatch reads
the tfvars from SSM (by version), plans, runs the gate, and writes the saved plan, its text, the gate report and a
manifest to the state bucket once. An **apply** dispatch (protected environment) takes the plan run id and SHA-256,
refuses unless that plan passed the gate, re-reads the tfvars at the planned version, re-runs the gate and applies
exactly that plan, once. The repository is public, so the log shows addresses, actions, digests and the verdict only.
`GATE_ALLOW` (environment variable) holds the approved changes, today
`module.pipeline.aws_lambda_event_source_mapping.events:scaling_config.0.maximum_concurrency=20->25`.

## Tests

`terraform test` (mocked provider, `import_existing = false`) checks rendering. `python3 -m unittest discover
-s gate` checks the gate, and `scripts/hosted/tests/smoke.sh` checks the CI script with stub binaries. Only a CI plan against the live account proves zero changes.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11 |
| aws | >= 6.0, < 7.0 |

### Providers

| Name | Version |
| ---- | ------- |
| aws | >= 6.0, < 7.0 |

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| pipeline | ../../modules/aws/functions | n/a |

### Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_event_rule.schedule](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.schedule](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_log_group.pipeline](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_metric_alarm.backlog_age](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.briefs_dlq](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.dlq_not_empty](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.errors](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_iam_role.pipeline](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.pipeline](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.pipeline](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_kms_key_policy.transcripts](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key_policy) | resource |
| [aws_lambda_event_source_mapping.briefs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_event_source_mapping) | resource |
| [aws_lambda_permission.pipeline](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_s3_bucket_notification.transcripts](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_notification) | resource |
| [aws_s3_bucket_policy.transcripts](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_secretsmanager_secret.pipeline](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_policy.pipeline](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_policy) | resource |
| [aws_sqs_queue.briefs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue) | resource |
| [aws_sqs_queue.briefs_dlq](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue) | resource |
| [aws_sqs_queue_policy.briefs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue_policy) | resource |
| [aws_sqs_queue_policy.briefs_dlq](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue_policy) | resource |
| [aws_sqs_queue_policy.dlq](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue_policy) | resource |
| [aws_sqs_queue_policy.events](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue_policy) | resource |
| [aws_lambda_function.pipeline](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/lambda_function) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | The hosted sessions account. The provider refuses any other. | `string` | n/a | yes |
| bucket\_name | The transcripts bucket. | `string` | n/a | yes |
| bucket\_policy\_other\_statements | JSON array of every transcripts-bucket policy statement this root does not render (other stacks' grants, TLS and encryption denies, the ingest-edge cross-account grants), exactly as live. Private: never committed. | `string` | n/a | yes |
| function\_name | The existing session-pipeline Lambda. Its code and environment stay with the pipeline's deploy until it publishes a pinned artifact (phase 2); this root wires everything around it. | `string` | n/a | yes |
| import\_ids | Live identifiers for the first plan's imports. Once in state, the import blocks are no-ops. | ```object({ event_source_mapping_uuid = string secret_arn = string # permission key (reconcile, reconcile_continue, brief, or an optional schedule's) = > live statement id permission_statement_ids = map(string) })``` | n/a | yes |
| kms\_key\_id | The transcripts KMS key (id or ARN). | `string` | n/a | yes |
| kms\_policy\_other\_statements | JSON array of every transcripts-key policy statement this root does not render (key administration, other stacks, the ingest-edge cross-account grants), exactly as live. Private: never committed. | `string` | n/a | yes |
| name\_prefix | Prefix every pipeline resource name carries (the old stack's 96bulls-<stage>). | `string` | n/a | yes |
| region | The hosted sessions region. | `string` | n/a | yes |
| role | The function's execution role, imported into state as-is (Khaliq, 2026-11-27). Every field must equal live, or the plan shows a diff and nothing is applied. | ```object({ name = string path = optional(string, "/") description = optional(string, "") assume_role_policy = string # JSON, as live max_session_duration = optional(number, 3600) permissions_boundary = optional(string) inline_policies = optional(map(string), {}) # name = > JSON policy document, as live managed_policy_arns = optional(set(string), []) tags = optional(map(string), {}) })``` | n/a | yes |
| secret\_name | The pipeline secret container's name. Its value is set out of band and never managed here. | `string` | n/a | yes |
| analysis\_results | Analysis jobs (lane F1): the role may write, version-list and erase analysis results, and get data keys for them. | `bool` | `false` | no |
| briefs\_enabled | The brief schedule's state. Enabling briefs in production needs its own go from Khaliq. | `bool` | `false` | no |
| briefs\_queue | Push-summary queue. create plans the queue, DLQ, policy, alarm and a DISABLED mapping; esm\_enabled turns consumption on (production enablement, held). | ```object({ create = optional(bool, false) esm_enabled = optional(bool, false) max_concurrency = optional(number, 2) batch_size = optional(number, 10) max_receive_count = optional(number, 8) })``` | `{}` | no |
| bucket\_policy\_id | The bucket policy's Id field, if live has one. | `string` | `null` | no |
| function\_timeout\_seconds | The function's live timeout. The queue's visibility timeout must be at least this. | `number` | `300` | no |
| import\_existing | Plan the first-run imports. true for every real plan; false only for offline rendering tests (mock providers cannot import). | `bool` | `true` | no |
| key\_prefix | Tenant key base under which manifests are written (TENANT\_KEY\_BASE). | `string` | `"96bulls"` | no |
| kms\_policy\_id | The key policy's Id field, if live has one. | `string` | `null` | no |
| layout\_version | Object layout version the pipeline reads (LAYOUT\_VERSION). | `string` | `"v1"` | no |
| log\_group | The function's log group, if it exists and should be managed. null leaves it alone. | ```object({ retention_in_days = number tags = optional(map(string), {}) })``` | `null` | no |
| max\_concurrency | Event source mapping MaximumConcurrency. Self-host's module default is 4; the hosted value is set in the private tfvars, equal to live. | `number` | `4` | no |
| optional\_schedules | Optional schedule groups the old stack declared per stage (analysisCache, semanticCopy, analysisJob, bufferedSearchFeed, bufferedErasureDelete): key => enabled. Absent keys plan nothing. | `map(bool)` | `{}` | no |
| other\_notifications | Every other live notification on the transcripts bucket, verbatim (for example the upload-inbox queue). aws\_s3\_bucket\_notification owns the bucket's WHOLE notification configuration, so anything live that is missing here would be removed (the gate refuses that plan). | ```object({ queues = optional(list(object({ id = string queue_arn = string events = list(string) filter_prefix = optional(string) filter_suffix = optional(string) })), []) lambda_functions = optional(list(object({ id = string lambda_function_arn = string events = list(string) filter_prefix = optional(string) filter_suffix = optional(string) })), []) topics = optional(list(object({ id = string topic_arn = string events = list(string) filter_prefix = optional(string) filter_suffix = optional(string) })), []) eventbridge = optional(bool, false) })``` | `{}` | no |
| reconcile\_minutes | Reconcile schedule period. | `number` | `30` | no |
| secret\_description | The secret's description, as live. | `string` | `"96bulls session pipeline: Supabase HoopDb URL and ClickHouse ingest credentials (JSON)"` | no |
| tags | Tags on the pipeline resources, exactly as live (the old stack's stack/component/repo tags). | `map(string)` | `{}` | no |
| visibility\_timeout\_seconds | session-events visibility timeout (old stack: 6 x 300 = 1800). | `number` | `1800` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| briefs\_queue\_url | Push-summary queue URL (SESSION\_BRIEF\_QUEUE\_URL), or null. |
| event\_source\_mapping\_max\_concurrency | The mapping's MaximumConcurrency as planned. |
| optional\_schedules | Optional schedule rule names and states (reconcile and brief live in the module). |
| queue\_url | session-events queue URL. |
<!-- END_TF_DOCS -->
