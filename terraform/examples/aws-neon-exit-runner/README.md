# aws-neon-exit-runner

One short-lived EC2 runner for copying the legacy sessions schema out of Neon
into its Supabase target. Nothing here is product infrastructure: apply it for
the copy, terminate it with `terraform destroy` after the seal.

What it creates, in one account and region:

- a private subnet in an existing VPC, a NAT gateway (plus EIP) in an existing
  public subnet, and a route table for egress;
- a security group with **no ingress**; egress only on 443, 5432, 6543 and DNS;
- an empty Secrets Manager secret for the target database owner credential.
  Its value is written out of band (`aws secretsmanager put-secret-value`) by
  whoever holds it, never through this configuration or a chat channel;
- an empty Secrets Manager secret for the Cloud copy connection URLs
  (`neon-exit/cloud/copy-urls`), also written out of band. The runner fetches
  it on the box, so no connection URL appears in SSM command history;
- an instance role with `AmazonSSMManagedInstanceCore` and read of those two
  secrets only, and the instance profile;
- one `m6id.4xlarge` (16 vCPU, 64 GB, 950 GB NVMe) on Amazon Linux 2023,
  IMDSv2 only, encrypted root, with the NVMe mounted at `/scratch` and
  `postgresql17` client, `zstd`, `git`, `jq` and `nodejs22` installed.

Access is Session Manager only: `aws ssm start-session --target <instance_id>`
from a principal with `ssm:StartSession` on the instance. On the runner,
`target-secret` prints the secret to the shell (it needs the instance role).

```sh
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
# ... copy ...
terraform destroy -var-file=terraform.tfvars
```

Approximate on-demand cost in us-east-1: the instance about $0.95 per hour,
the NAT gateway about $0.045 per hour plus $0.045 per GB processed.

## Alerting (`alerting.tf`)

The eraser (`neon-s3-erasure` in relayhistory-pipeline) writes one JSON
object per line to stdout, always with `service: "neon-s3-erasure"`. This
scaffold turns those lines into pages:

- a CloudWatch Logs group (`log_group_name`, default `/neon-exit/runner`) fed
  by the CloudWatch agent from every `*.log` under `runner_log_dir`
  (default `/var/log/neon-exit`, mode 0750, owned by `runner_log_owner`);
- one metric filter and one alarm per `alert_signals` entry, every pattern
  scoped to `$.service = "neon-s3-erasure"`. Defaults:
  `legacy_fence_failed` (the `@metric` line with `legacyFenceFailed > 0` and
  `value > 0`, or the `fence sweep failed` / `live fence sweep failed`
  message lines the eraser on main logs today) and
  `legacy_erasure_requires_supabase_authority` (`error_code` equals that
  string). Any match within a minute puts the alarm in ALARM and pages.
  There are no OK notifications on these: the count metric drops back a
  minute later, which is not "resolved"; close the page after the runbook;
- a dead-man alarm (`heartbeat_enabled`) on the eraser's per-sweep
  `erasure sweep` summary line: fewer than one line per
  `heartbeat_period_seconds` (600, the eraser's default cadence) for
  `heartbeat_evaluation_periods` (2) consecutive periods pages, and missing
  data counts as breaching. It resolves (OK notification) when sweeps
  resume. Arm it only once the eraser runs continuously on the box;
- an SNS topic `<name>-alerts` that the alarms publish to. **Nobody is
  subscribed until `alert_endpoint` is set** (with `alert_protocol`, default
  `https` for a PagerDuty Events v2 CloudWatch integration URL). Until then
  the alarms are visible in the console and fire into nothing.

The agent is installed on the running instance through a Systems Manager
association (`AWS-RunShellScript`), not through `user_data`, so applying this
does not replace the runner. The agent reads its configuration from the SSM
parameter `/<name>/cloudwatch-agent` with the instance role; a changed
configuration re-runs the association. If a run fails (check
`aws ssm describe-association-executions`), re-run it:

```sh
aws ssm start-associations-once --association-ids "$(terraform output -raw cloudwatch_agent_association_id)"
```

### Running the eraser so it is watched

Only files under `runner_log_dir` are shipped, so stdout must land there.
stderr stays local (not JSON, never matches a filter):

```sh
S3X_BUCKET=... S3X_EXPECT_BUCKET=... bun run migration:neon-s3-erasure --execute \
  2>>/var/log/neon-exit/erasure.stderr | tee -a /var/log/neon-exit/erasure.log
```

Delivery proof (canary). This line trips the
`legacy_erasure_requires_supabase_authority` alarm on purpose, so the page
that arrives proves agent, filter, alarm, topic and subscription end to end;
`canary: true` marks it in the log:

```sh
printf '{"at":"%s","service":"neon-s3-erasure","message":"canary","canary":true,"error_code":"legacy_erasure_requires_supabase_authority"}\n' \
  "$(date -u +%FT%TZ)" >> /var/log/neon-exit/canary.log
# within ~2 minutes:
aws logs filter-log-events --log-group-name /neon-exit/runner --filter-pattern '{ $.canary = true }' --query 'events[].message'
aws cloudwatch describe-alarms --alarm-names neon-exit-runner-legacy_erasure_requires_supabase_authority --query 'MetricAlarms[].StateValue'
```

To check a pattern against a real line before changing `alert_signals`:

```sh
aws logs test-metric-filter \
  --filter-pattern '{ ($.service = "neon-s3-erasure") && ($.message = "erasure sweep") }' \
  --log-event-messages '{"at":"2026-11-16T07:00:05Z","service":"neon-s3-erasure","message":"erasure sweep","count":12}'
```

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

### Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_log_group.runner](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_metric_filter.heartbeat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_metric_filter) | resource |
| [aws_cloudwatch_log_metric_filter.signal](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_metric_filter) | resource |
| [aws_cloudwatch_metric_alarm.heartbeat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.signal](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_eip.nat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eip) | resource |
| [aws_iam_instance_profile.runner](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_role.runner](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.log_shipping](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.secret_read](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.ssm](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_instance.runner](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance) | resource |
| [aws_nat_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/nat_gateway) | resource |
| [aws_route.private_default](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route_table.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table_association.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_secretsmanager_secret.copy_urls](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret.db_owner](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_sns_topic.alerts](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic) | resource |
| [aws_sns_topic_subscription.alerts](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_subscription) | resource |
| [aws_ssm_association.cloudwatch_agent](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_association) | resource |
| [aws_ssm_parameter.cloudwatch_agent](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [aws_subnet.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_vpc_security_group_egress_rule.dns_tcp](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.dns_udp](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.https](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.postgres](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.postgres_pooler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_iam_policy_document.assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.log_shipping](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.secret_read](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_ssm_parameter.ami](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |
| [aws_vpc.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | AWS account the runner lives in; the provider refuses any other. | `string` | n/a | yes |
| public\_subnet\_id | Existing public subnet (route to an internet gateway) that hosts the NAT gateway. | `string` | n/a | yes |
| vpc\_id | VPC that gets the private subnet and the NAT gateway. | `string` | n/a | yes |
| alert\_endpoint | Where the ops topic delivers (URL, address or number for alert\_protocol). Unset: the topic exists, the alarms publish to it, and nobody is subscribed. | `string` | `null` | no |
| alert\_protocol | SNS subscription protocol for the ops topic: https (a PagerDuty Events v2 CloudWatch integration URL or Slack workflow URL), email, email-json or sms. | `string` | `"https"` | no |
| alert\_signals | Signals that page: metric name => CloudWatch Logs filter pattern on the eraser's JSON lines (every pattern must also require $.service = "neon-s3-erasure"). One metric filter and one alarm (any match in a minute) per entry. | `map(string)` | ```{ "legacy_erasure_requires_supabase_authority": "{ ($.service = \"neon-s3-erasure\") && ($.error_code = \"legacy_erasure_requires_supabase_authority\") }", "legacy_fence_failed": "{ ($.service = \"neon-s3-erasure\") && ((($.legacyFenceFailed > 0) && ($.value > 0)) || ($.message = \"fence sweep failed\") || ($.message = \"live fence sweep failed\")) }" }``` | no |
| ami\_ssm\_parameter | SSM public parameter that resolves to the AMI. | `string` | `"/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"` | no |
| availability\_zone | AZ of the private subnet; the instance type must be offered there. | `string` | `"us-east-1a"` | no |
| copy\_urls\_secret\_name | Secrets Manager name of the Cloud copy connection URLs. Created empty; written out of band and read on the runner. | `string` | `"neon-exit/cloud/copy-urls"` | no |
| db\_owner\_secret\_name | Secrets Manager name of the target database owner credential. Created empty; the value is written out of band by whoever holds it. | `string` | `"neon-exit/relayhistory-legacy/postgres-owner"` | no |
| heartbeat\_enabled | Create the dead-man alarm on the eraser's per-sweep summary line. Missing data is breaching, so enable only once the eraser runs continuously on the runner. | `bool` | `true` | no |
| heartbeat\_evaluation\_periods | Consecutive periods without a sweep line before the dead-man alarm pages (2 x 600 s = 20 minutes by default). | `number` | `2` | no |
| heartbeat\_pattern | Filter pattern for the eraser's per-sweep summary line. | `string` | `"{ ($.service = \"neon-s3-erasure\") && ($.message = \"erasure sweep\") }"` | no |
| heartbeat\_period\_seconds | Expected sweep cadence in seconds (the eraser's default is 600). One alarm period. | `number` | `600` | no |
| instance\_type | Instance type with local NVMe for the dump. | `string` | `"m6id.4xlarge"` | no |
| log\_group\_name | CloudWatch Logs group that receives the runner's *.log files. | `string` | `"/neon-exit/runner"` | no |
| log\_retention\_days | Days CloudWatch keeps the runner log. | `number` | `90` | no |
| metric\_namespace | CloudWatch metric namespace for the signals extracted from the log. | `string` | `"neon-exit"` | no |
| name | Name prefix for every resource. | `string` | `"neon-exit-runner"` | no |
| private\_subnet\_cidr | CIDR of the new private subnet; must be free inside the VPC. | `string` | `"172.31.96.0/20"` | no |
| region | Region of the runner. us-east-1 keeps it next to the Neon and Supabase projects. | `string` | `"us-east-1"` | no |
| root\_volume\_size\_gb | Root EBS volume size. The dump goes to the NVMe instance store at /scratch, not here. | `number` | `50` | no |
| runner\_log\_dir | Directory on the runner whose *.log files the CloudWatch agent ships. Write the erasure CLI's structured stdout there (for example `| tee -a /var/log/neon-exit/erasure.log`). | `string` | `"/var/log/neon-exit"` | no |
| runner\_log\_owner | User that owns runner\_log\_dir (0750). The eraser runs as this user; the CloudWatch agent reads as root. | `string` | `"ssm-user"` | no |
| tags | Tags applied to every resource. | `map(string)` | ```{ "ephemeral": "true", "managed": "terraform", "project": "neon-exit" }``` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| alarm\_names | Alarms: one per alert\_signals entry, plus the dead-man alarm when heartbeat\_enabled. |
| alerts\_topic\_arn | Ops SNS topic the alarms publish to; subscribe the pager here (or set alert\_endpoint). |
| cloudwatch\_agent\_association\_id | SSM association that installs and configures the CloudWatch agent (re-run with aws ssm start-associations-once). |
| copy\_urls\_secret\_arn | Secrets Manager ARN of the empty Cloud copy URLs secret. |
| copy\_urls\_secret\_name | Secrets Manager name of the Cloud copy URLs secret. |
| db\_owner\_secret\_arn | Secrets Manager ARN of the empty target credential. |
| db\_owner\_secret\_name | Secrets Manager name of the target credential. |
| instance\_id | Runner instance id (target of ssm start-session). |
| log\_group\_name | CloudWatch Logs group that receives the runner's *.log files. |
| nat\_gateway\_id | NAT gateway that carries the runner's egress. |
| private\_subnet\_id | Private subnet the runner sits in. |
| runner\_log\_dir | Directory on the runner whose *.log files are shipped. |
| runner\_role\_arn | Instance role: SSM core plus read of the two exit secrets. |
| security\_group\_id | Runner security group (no ingress). |
| ssm\_session\_command | Shell on the runner for a principal allowed ssm:StartSession on it. |
<!-- END_TF_DOCS -->
