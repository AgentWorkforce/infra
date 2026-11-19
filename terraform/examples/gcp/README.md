# examples/gcp

A root for the native-history Agent Relay profile on an existing GKE cluster
and VPC:

- `gcp/postgres` (Cloud SQL with `relaycontrol`, `relaycast` and `hoopdb`, plus
  a retained `relayhistory` database, left over from the removed standalone
  History, so applying to an older installation does not destroy it),
  using a shared CA plus private DNS so application URLs can use
  `sslmode=verify-full`.
- `gcp/object-storage` for the GCS Locker, with direct Workload Identity for
  the worker, read API, ingest edge and search indexer.
- TLS-only Standard HA Memorystore and a Pub/Sub pull queue with a dead-letter
  queue for the native Sessions data path. The current data-path client
  requires `REDIS_AUTH_ENABLED=false`, so use a dedicated workload VPC and
  restrict reachability to the GKE nodes; TLS protects data in transit but is
  not client authentication.
- `gcp/search` on the GKE cluster (`enable_search`).
- `gcp/functions` (`enable_functions`).

```sh
cp terraform.tfvars.example terraform.tfvars   # fill in existing IDs
terraform init && terraform plan
```

`chart_values` is a complete, nested non-secret overlay for
`values-gcp.yaml` (native on its own), including the eight required
worker/search pipeline variables, the `sessions_pipeline_runtime` role and the
Cloud SQL CA bindings for every PostgreSQL client. Save it directly as a Helm
values file after apply:

```sh
terraform output -json chart_values > managed-values.json
```

Apply `values-gcp.yaml`, then `managed-values.json`
(`values-gcp-native.yaml` is now an empty compatibility overlay and may be
kept between them). Run
`scripts/selfhost/cloud-sql-setup.sh pre` after apply and before Helm. Requires
Terraform or OpenTofu >= 1.11 (the Cloud SQL admin password is write-only).

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11 |
| google | >= 7.0, < 8.0 |
| helm | >= 3.0, < 4.0 |
| kubernetes | >= 2.30, < 4.0 |

### Providers

| Name | Version |
| ---- | ------- |
| google | >= 7.0, < 8.0 |

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| desktop\_feed\_bucket | ../../modules/gcp/object-storage | n/a |
| edge\_security | ../../modules/gcp/edge-security | n/a |
| functions | ../../modules/gcp/functions | n/a |
| postgres | ../../modules/gcp/postgres | n/a |
| search | ../../modules/gcp/search | n/a |
| sessions\_bucket | ../../modules/gcp/object-storage | n/a |

### Resources

| Name | Type |
| ---- | ---- |
| [google_artifact_registry_repository.mirror](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/artifact_registry_repository) | resource |
| [google_artifact_registry_repository_iam_member.mirror_node_reader](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/artifact_registry_repository_iam_member) | resource |
| [google_dns_managed_zone.cloud_sql](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/dns_managed_zone) | resource |
| [google_dns_record_set.cloud_sql](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/dns_record_set) | resource |
| [google_pubsub_subscription.pipeline](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_subscription) | resource |
| [google_pubsub_subscription.pipeline_dead_letter](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_subscription) | resource |
| [google_pubsub_subscription_iam_member.pipeline_subscriber](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_subscription_iam_member) | resource |
| [google_pubsub_subscription_iam_member.pubsub_dead_letter](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_subscription_iam_member) | resource |
| [google_pubsub_topic.pipeline](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic) | resource |
| [google_pubsub_topic.pipeline_dead_letter](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic) | resource |
| [google_pubsub_topic_iam_member.pipeline_publisher](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic_iam_member) | resource |
| [google_pubsub_topic_iam_member.pubsub_dead_letter](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic_iam_member) | resource |
| [google_redis_instance.pipeline](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/redis_instance) | resource |
| [google_service_account_iam_member.desktop_feed_sign_self](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_client_config.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/client_config) | data source |
| [google_container_cluster.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/container_cluster) | data source |
| [google_project.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/project) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| network\_self\_link | Existing VPC with Private Services Access configured (Cloud SQL private IP). | `string` | n/a | yes |
| project\_id | GCP project. | `string` | n/a | yes |
| region | GCP region. | `string` | n/a | yes |
| sessions\_bucket\_name | Globally unique GCS bucket name for session objects. | `string` | n/a | yes |
| admin\_secret\_kms\_key\_name | CMEK key for the Secret Manager secret that holds the Cloud SQL admin password (null: Google-managed, automatic replication). The key must be in var.region; the secret is then replicated to that region only. Grant the Secret Manager service agent (service-<project number>@gcp-sa-secretmanager.iam.gserviceaccount.com) roles/cloudkms.cryptoKeyEncrypterDecrypter on it first. Set at creation: a secret's replication cannot be changed afterwards. | `string` | `null` | no |
| deletion\_protection | Prevent deletion of Cloud SQL, Memorystore and Pub/Sub data resources. Disable only for a disposable proof environment. | `bool` | `true` | no |
| desktop\_feed\_bucket\_name | Globally unique bucket for relay-control's signed Desktop feed (SELFHOST\_DESKTOP\_FEED\_GCS\_BUCKET). Empty disables it. | `string` | `""` | no |
| desktop\_feed\_service\_account\_id | account\_id of the Google service account relay-control uses for the Desktop feed bucket (6-30 characters). | `string` | `"agent-relay-control"` | no |
| edge\_max\_advanced\_rules | Rules with an expression one Cloud Armor policy may hold (modules/gcp/edge-security max\_advanced\_rules). Google fixes it at 20; a plan that needs more is refused. | `number` | `20` | no |
| edge\_max\_subexpressions | Subexpressions per Cloud Armor rule expression (modules/gcp/edge-security max\_subexpressions). 10 is what the API accepts; lower it only if your project refuses a rule. | `number` | `10` | no |
| edge\_origin\_secret\_header | Shared-secret request header a fronting proxy adds; requests without one of the accepted values (1-3, for rotation) are denied (modules/gcp/edge-security origin\_secret\_header). Stored in state. | ```object({ name = string values = list(string) })``` | `null` | no |
| edge\_security\_policy | Cloud Armor policy for every GKE Ingress backend (modules/gcp/edge-security security\_policy: create, waf, rate\_limits, source\_ip\_allowlist, cloudflare, client\_ip\_header, client\_ip\_rules). Off unless create = true. It is exported as gkeIngress.securityPolicy in output.edge, not in chart\_values, because the chart then also needs the dashboard Service's backend-config annotation. | `any` | `{}` | no |
| edge\_ssl\_policy | Compute SSL policy for the GKE Ingress HTTPS listener, exported as gkeIngress.sslPolicy in chart\_values. create = false leaves Google's default policy (TLS 1.0 and later). | ```object({ create = optional(bool, true) profile = optional(string, "MODERN") min_tls_version = optional(string, "TLS_1_2") })``` | `{}` | no |
| enable\_functions | Create the optional event-driven pipeline (Cloud Run functions). | `bool` | `false` | no |
| enable\_search | Install the optional OpenSearch cluster on GKE. | `bool` | `false` | no |
| gke\_cluster\_location | Its region or zone. | `string` | `null` | no |
| gke\_cluster\_name | Existing GKE cluster that runs agent-relay (only for enable\_search). | `string` | `null` | no |
| gke\_node\_service\_account | Email of the GKE node pool's service account, granted roles/artifactregistry.reader on the mirror. Empty: the project's default Compute Engine service account (a node pool whose serviceAccount is "default"). | `string` | `""` | no |
| gke\_use\_private\_endpoint | Reach the control plane on its private endpoint. | `bool` | `true` | no |
| image\_mirror\_kms\_key\_name | CMEK key for the image mirror repository (null: Google-managed). Grant the Artifact Registry service agent (service-<project number>@gcp-sa-artifactregistry.iam.gserviceaccount.com) roles/cloudkms.cryptoKeyEncrypterDecrypter on it first. Set at creation: changing it replaces the repository. | `string` | `null` | no |
| image\_mirror\_repository | Artifact Registry repository for the release images (guide step 5), created in var.region. Empty: no repository and no grant. | `string` | `""` | no |
| kms\_key\_name | CMEK key for Cloud SQL and the bucket (null: Google-managed). Grant the service agents on it first. | `string` | `null` | no |
| labels | Labels for every resource that supports them. | `map(string)` | `{}` | no |
| name | Name prefix for every resource. | `string` | `"agent-relay"` | no |
| namespace | agent-relay release namespace. | `string` | `"agent-relay"` | no |
| notification\_channels | Cloud Monitoring notification channels for the pipeline alerts. | `list(string)` | `[]` | no |
| pipeline\_message\_retention | Pub/Sub topic and subscription retention for the native Sessions pipeline. | `string` | `"604800s"` | no |
| pipeline\_pubsub\_kms\_key\_name | Optional CMEK key for the native Sessions pipeline Pub/Sub topics. | `string` | `null` | no |
| pipeline\_redis\_kms\_key\_name | CMEK key for the pipeline Redis instance at rest (null: Google-managed). Same region as the instance; grant the Memorystore service agent (service-<project number>@cloud-redis.iam.gserviceaccount.com) roles/cloudkms.cryptoKeyEncrypterDecrypter on it first. Set at creation: changing it replaces the instance. | `string` | `null` | no |
| pipeline\_redis\_memory\_size\_gb | Memorystore capacity for the native Sessions pipeline. | `number` | `5` | no |
| pipeline\_redis\_reserved\_ip\_range | Optional PSA allocated range name for Memorystore. null lets Google choose from the connection. | `string` | `null` | no |
| pipeline\_redis\_version | Memorystore Redis version. | `string` | `"REDIS_7_2"` | no |
| pipeline\_source\_archive | Function source zip in GCS. Required with enable\_functions. | ```object({ bucket = string object = string generation = optional(number) })``` | `null` | no |
| relay\_control\_service\_account | relay-control's Kubernetes service account. charts/agent-relay/values-gcp.yaml sets fullnameOverride: relay-control, so it is relay-control. | `string` | `"relay-control"` | no |
| release\_name | agent-relay Helm release name. | `string` | `"agent-relay"` | no |
| search\_admin\_credentials\_secret\_name | Existing Secret (in the search namespace) with the OpenSearch admin username and password. | `string` | `"opensearch-admin"` | no |
| search\_security\_config\_secret\_name | Existing Secret (in the search namespace) with the security plugin configuration. | `string` | `"opensearch-security-config"` | no |
| search\_storage\_class | StorageClass for OpenSearch volumes. | `string` | `null` | no |
| vpc\_connector | Existing Serverless VPC Access connector for the pipeline function (reaches the private Cloud SQL). Required with enable\_functions. | `string` | `null` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| chart\_values | Complete non-secret managed-service overlay for values-gcp.yaml plus values-gcp-native.yaml. Save with: terraform output -json chart\_values > managed-values.json. |
| desktop\_feed | Values for relay-control's signed Desktop feed on GCS (null unless desktop\_feed\_bucket\_name is set). Put env into relay-control.extraEnv and annotations into relay-control.serviceAccount.annotations; signing keys go through relay-control.desktopFeed.signingKeys. |
| edge | Edge policy names (edge.tf). rule\_counts is what the Cloud Armor policy needs against the project's quotas (advanced: SECURITY\_POLICY\_CEVAL\_RULES, default 20; total: SECURITY\_POLICY\_RULES, default 100). security\_policy is null unless edge\_security\_policy.create is set; put it in gkeIngress.securityPolicy together with the backend-config annotation the chart asks for. client\_ip\_header set means a proxy fronts the load balancer: relay-control.auth.trustedProxies is 3 instead of 2. |
| functions | Pipeline function, topics and secret (null unless enable\_functions). |
| image\_mirror\_root | MIRROR\_ROOT for install guide step 5 (null unless image\_mirror\_repository is set). |
| pipeline | Native Sessions pipeline values. The Redis CA is public certificate material, not a credential. |
| postgres | Cloud SQL private IP, admin secret and URL template. connection\_name feeds CLOUD\_SQL\_CONNECTION\_NAME in the sessions worker and alleyoop extraEnv. |
| search\_url | In-cluster OpenSearch URL (null unless enable\_search). |
<!-- END_TF_DOCS -->

## Optional: the signed Desktop feed on GCS

Set `desktop_feed_bucket_name` to create a private bucket for relay-control's
signed Desktop feed (relay-control 0.5.25+), a Google service account for
relay-control with Workload Identity, and `roles/iam.serviceAccountTokenCreator`
on itself so it can sign download URLs. Enable `iamcredentials.googleapis.com`
on the project first. `output.desktop_feed` holds the three `extraEnv` entries
for `relay-control.extraEnv` and the two annotations for
`relay-control.serviceAccount.annotations`
(`iam.gke.io/gcp-service-account` and `iam.gke.io/return-principal-id-as-email`).
The feed's signing keys go through `relay-control.desktopFeed.signingKeys`.
Off by default: an install without it plans no change.

