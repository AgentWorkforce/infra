# gcp/functions

**Optional.** The sessions pipeline's **event-driven mode** on GCP: the equivalent of `aws/functions`.

```
sessions bucket --(GCS notification: OBJECT_FINALIZE / OBJECT_DELETE / OBJECT_ARCHIVE under <key_prefix>/)--> Pub/Sub <name>-session-events
    <name>-session-events-push --(OIDC push, ack 600 s, retry 10-600 s)--> Cloud Run function <name>-session-pipeline (internal ingress)
    after 8 delivery attempts --> Pub/Sub <name>-session-events-dlq + pull subscription <name>-session-events-dlq-hold (dead_letter_retention: 14 days by default, up to 31)
    Cloud Scheduler every 30 minutes --> POST {"reconcile": true}
    Cloud Scheduler every minute, paused unless briefs_enabled --> POST {"brief": true}
```

- GCS notifications filter on a prefix only, not a suffix, so the handler must ignore everything except `manifest.json`. On a versioned bucket, a delete of the live manifest arrives as `OBJECT_ARCHIVE` (and an overwrite also archives the previous generation), so the handler must check whether a live manifest still exists.
- The function is HTTP with `ALLOW_INTERNAL_ONLY` ingress. Pub/Sub push and Cloud Scheduler in the same project count as internal. Only the invoker service account (push and scheduler) has `roles/run.invoker`; there is no public invoker.
- **Reconcile continuation:** a reconcile that reaches its deadline publishes `{"reconcile": true, "cursor": ...}` to the events topic (`SESSION_PIPELINE_TOPIC`), which pushes it back. It does not make an HTTP self-call, because internal-only ingress refuses one without a VPC route.
- **Runtime service account:** `roles/storage.objectViewer` on the bucket, publisher on its topic (reconcile re-enqueue), and accessor on its one secret. Grant Cloud SQL or search access separately.
- **Secret:** an empty Secret Manager container (`SESSION_PIPELINE_SECRET_ID`). Add its JSON value out of band. The function's service account is granted `secretAccessor` on it; others with project-level Secret Manager access can still read it.
- **Environment:** `PIPELINE_RAW_GCS_BUCKET`, `PIPELINE_KEY_PREFIX`, `PIPELINE_ORG_FROM_PREFIX=true`, `SESSION_PIPELINE_SECRET_ID`, `SESSION_PIPELINE_TOPIC`, `SEARCH_INDEX_ENABLED`, `PIPELINE_FANOUT=off`, `PIPELINE_RECONCILE_LOOKBACK_MINUTES` (twice `reconcile_minutes`), `HOOPDB_POOL_MAX=4`, `OTEL_SERVICE_NAME` and `SESSION_BRIEF_ENABLED`. `environment` merges over them.
- **Alerts:** dead letters, backlog age over 15 minutes, and non-2xx responses (`notification_channels`).
- **Handler contract:** the Cloud Run entry point comes with the pipeline's `PipelineRuntimeAdapter`. It accepts Pub/Sub push envelopes and the scheduler bodies, as `src/session-pipeline/lambda.ts` does on AWS.
- **CMEK:** `kms_key_name` plus a CMEK `docker_repository`. Topics take `topic_kms_key_name`.
- **VPC:** `vpc_connector` (an existing Serverless VPC Access connector) to reach a private Cloud SQL.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.6 |
| google | >= 7.0, < 8.0 |

### Providers

| Name | Version |
| ---- | ------- |
| google | >= 7.0, < 8.0 |

### Resources

| Name | Type |
| ---- | ---- |
| [google_cloud_run_v2_service_iam_member.invoker](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/cloud_run_v2_service_iam_member) | resource |
| [google_cloud_scheduler_job.brief](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/cloud_scheduler_job) | resource |
| [google_cloud_scheduler_job.reconcile](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/cloud_scheduler_job) | resource |
| [google_cloudfunctions2_function.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/cloudfunctions2_function) | resource |
| [google_monitoring_alert_policy.backlog_age](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/monitoring_alert_policy) | resource |
| [google_monitoring_alert_policy.dead_letters](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/monitoring_alert_policy) | resource |
| [google_monitoring_alert_policy.errors](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/monitoring_alert_policy) | resource |
| [google_pubsub_subscription.dlq](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_subscription) | resource |
| [google_pubsub_subscription.push](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_subscription) | resource |
| [google_pubsub_subscription_iam_member.pubsub_dead_letters](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_subscription_iam_member) | resource |
| [google_pubsub_topic.dlq](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic) | resource |
| [google_pubsub_topic.events](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic) | resource |
| [google_pubsub_topic_iam_member.function_publishes](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic_iam_member) | resource |
| [google_pubsub_topic_iam_member.gcs_publishes](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic_iam_member) | resource |
| [google_pubsub_topic_iam_member.pubsub_dead_letters](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic_iam_member) | resource |
| [google_secret_manager_secret.pipeline](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret) | resource |
| [google_secret_manager_secret_iam_member.function_reads_secret](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_iam_member) | resource |
| [google_service_account.function](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account.invoker](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_storage_bucket_iam_member.function_reads](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket_iam_member) | resource |
| [google_storage_notification.manifests](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_notification) | resource |
| [google_project.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/project) | data source |
| [google_storage_project_service_account.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/storage_project_service_account) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| bucket\_name | The sessions (Locker) bucket: the same bucket as sessions-pipeline worker.locker.bucket. | `string` | n/a | yes |
| name | Prefix for every resource (<name>-session-pipeline, <name>-session-events, ...). | `string` | n/a | yes |
| project\_id | Project for the function, topics, subscriptions and jobs. | `string` | n/a | yes |
| region | Region for the function (and, unless scheduler\_region is set, the Cloud Scheduler jobs). | `string` | n/a | yes |
| source\_archive | Function source: a zip in GCS (bucket, object, optional generation). Cloud Build builds it with the runtime's buildpack. | ```object({ bucket = string object = string generation = optional(number) })``` | n/a | yes |
| ack\_deadline\_seconds | Push subscription ack deadline (10-600). Must be at least timeout\_seconds. | `number` | `600` | no |
| available\_cpu | vCPU per instance. | `string` | `"1"` | no |
| available\_memory | Memory per instance. | `string` | `"2Gi"` | no |
| brief\_schedule | Brief tick cron. | `string` | `"* * * * *"` | no |
| briefs\_enabled | Session briefs: unpauses the brief job and sets SESSION\_BRIEF\_ENABLED. | `bool` | `false` | no |
| build\_service\_account | Service account Cloud Build uses for the function build (projects/<p>/serviceAccounts/<email>). null uses the project default. | `string` | `null` | no |
| create\_alerts | Create Cloud Monitoring alert policies (dead letters, backlog age, function errors). | `bool` | `true` | no |
| create\_secret | Create an empty Secret Manager secret (a container; add its JSON value out of band). Its resource name is passed as SESSION\_PIPELINE\_SECRET\_ID. | `bool` | `true` | no |
| dead\_letter\_retention | Retention of the dead-letter topic and of its hold subscription (up to 31 days for both). | `string` | `"1209600s"` | no |
| docker\_repository | Artifact Registry repository for the built image (projects/<p>/locations/<r>/repositories/<repo>). null uses gcf-artifacts. | `string` | `null` | no |
| entry\_point | Exported HTTP handler. It receives Pub/Sub push envelopes ({message: {data, attributes}, subscription}) and Cloud Scheduler bodies ({"reconcile": true} or {"brief": true}). | `string` | `"sessionPipeline"` | no |
| environment | Extra non-secret environment variables, merged over the module's defaults. | `map(string)` | `{}` | no |
| key\_prefix | Tenant key base the services write under (TENANT\_KEY\_BASE, "96bulls"). GCS notifications filter on this prefix; they cannot filter on the manifest.json suffix, so the handler ignores other objects. | `string` | `"96bulls"` | no |
| kms\_key\_name | CMEK for the function (and its image). Needs docker\_repository encrypted with the same key, and the Cloud Functions, Artifact Registry and Cloud Run service agents granted on the key. | `string` | `null` | no |
| labels | Labels applied where supported. | `map(string)` | `{}` | no |
| max\_delivery\_attempts | Deliveries before a message moves to the dead-letter topic (5-100). | `number` | `8` | no |
| max\_instance\_count | Concurrency cap (the AWS module's max\_concurrency). | `number` | `4` | no |
| max\_instance\_request\_concurrency | Concurrent requests per instance. | `number` | `1` | no |
| notification\_channels | Cloud Monitoring notification channel IDs for the alerts. | `list(string)` | `[]` | no |
| reconcile\_minutes | Reconcile schedule (15, 20, 30, 60 or 120). The lookback is twice this. | `number` | `30` | no |
| runtime | Cloud Run functions runtime. | `string` | `"nodejs22"` | no |
| scheduler\_region | Cloud Scheduler region (null: region). | `string` | `null` | no |
| search\_index\_enabled | SEARCH\_INDEX\_ENABLED (off: pointers only, Postgres pg\_trgm search). | `bool` | `false` | no |
| secret\_id | Existing secret resource name (projects/<p>/secrets/<id>) when create\_secret is false. | `string` | `null` | no |
| secret\_kms\_key\_name | CMEK for the created secret (automatic replication). | `string` | `null` | no |
| time\_zone | Cloud Scheduler time zone. | `string` | `"Etc/UTC"` | no |
| timeout\_seconds | Request timeout. Kept at or below the subscription's ack deadline (600 s). | `number` | `300` | no |
| topic\_kms\_key\_name | CMEK for both topics (the Pub/Sub service agent needs encrypter/decrypter on it). | `string` | `null` | no |
| vpc\_connector | Existing Serverless VPC Access connector (projects/<p>/locations/<r>/connectors/<c>) for reaching a private Cloud SQL. null: no VPC egress. | `string` | `null` | no |
| vpc\_connector\_egress\_settings | PRIVATE\_RANGES\_ONLY or ALL\_TRAFFIC. | `string` | `"PRIVATE_RANGES_ONLY"` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| dead\_letter\_subscription\_id | Pull subscription holding dead-lettered messages. |
| dead\_letter\_topic\_id | Dead-letter topic. |
| events\_topic\_id | session-events topic (SESSION\_PIPELINE\_TOPIC). |
| function\_name | Function (and Cloud Run service) name. |
| function\_service\_account\_email | Runtime service account. Grant it Cloud SQL access (roles/cloudsql.client for the connector path) or search backend access as needed. |
| function\_uri | Internal-only HTTPS URI (push endpoint and scheduler target). |
| invoker\_service\_account\_email | Identity Pub/Sub push and Cloud Scheduler use to invoke the function. |
| secret\_id | Pipeline secret (SESSION\_PIPELINE\_SECRET\_ID). Add its JSON value out of band: the HoopDb URL (the chart's HOOPDB\_URL value) and the search backend credentials. |
<!-- END_TF_DOCS -->
