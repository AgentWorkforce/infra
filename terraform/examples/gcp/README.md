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
| deletion\_protection | Prevent deletion of Cloud SQL, Memorystore and Pub/Sub data resources. Disable only for a disposable proof environment. | `bool` | `true` | no |
| enable\_functions | Create the optional event-driven pipeline (Cloud Run functions). | `bool` | `false` | no |
| enable\_search | Install the optional OpenSearch cluster on GKE. | `bool` | `false` | no |
| gke\_cluster\_location | Its region or zone. | `string` | `null` | no |
| gke\_cluster\_name | Existing GKE cluster that runs agent-relay (only for enable\_search). | `string` | `null` | no |
| gke\_node\_service\_account | Email of the GKE node pool's service account, granted roles/artifactregistry.reader on the mirror. Empty: the project's default Compute Engine service account (a node pool whose serviceAccount is "default"). | `string` | `""` | no |
| gke\_use\_private\_endpoint | Reach the control plane on its private endpoint. | `bool` | `true` | no |
| image\_mirror\_repository | Artifact Registry repository for the release images (guide step 5), created in var.region. Empty: no repository and no grant. | `string` | `""` | no |
| kms\_key\_name | CMEK key for Cloud SQL and the bucket (null: Google-managed). Grant the service agents on it first. | `string` | `null` | no |
| labels | Labels for every resource that supports them. | `map(string)` | `{}` | no |
| name | Name prefix for every resource. | `string` | `"agent-relay"` | no |
| namespace | agent-relay release namespace. | `string` | `"agent-relay"` | no |
| notification\_channels | Cloud Monitoring notification channels for the pipeline alerts. | `list(string)` | `[]` | no |
| pipeline\_message\_retention | Pub/Sub topic and subscription retention for the native Sessions pipeline. | `string` | `"604800s"` | no |
| pipeline\_pubsub\_kms\_key\_name | Optional CMEK key for the native Sessions pipeline Pub/Sub topics. | `string` | `null` | no |
| pipeline\_redis\_memory\_size\_gb | Memorystore capacity for the native Sessions pipeline. | `number` | `5` | no |
| pipeline\_redis\_reserved\_ip\_range | Optional PSA allocated range name for Memorystore. null lets Google choose from the connection. | `string` | `null` | no |
| pipeline\_redis\_version | Memorystore Redis version. | `string` | `"REDIS_7_2"` | no |
| pipeline\_source\_archive | Function source zip in GCS. Required with enable\_functions. | ```object({ bucket = string object = string generation = optional(number) })``` | `null` | no |
| release\_name | agent-relay Helm release name. | `string` | `"agent-relay"` | no |
| search\_admin\_credentials\_secret\_name | Existing Secret (in the search namespace) with the OpenSearch admin username and password. | `string` | `"opensearch-admin"` | no |
| search\_security\_config\_secret\_name | Existing Secret (in the search namespace) with the security plugin configuration. | `string` | `"opensearch-security-config"` | no |
| search\_storage\_class | StorageClass for OpenSearch volumes. | `string` | `null` | no |
| vpc\_connector | Existing Serverless VPC Access connector for the pipeline function (reaches the private Cloud SQL). Required with enable\_functions. | `string` | `null` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| chart\_values | Complete non-secret managed-service overlay for values-gcp.yaml plus values-gcp-native.yaml. Save with: terraform output -json chart\_values > managed-values.json. |
| functions | Pipeline function, topics and secret (null unless enable\_functions). |
| image\_mirror\_root | MIRROR\_ROOT for install guide step 5 (null unless image\_mirror\_repository is set). |
| pipeline | Native Sessions pipeline values. The Redis CA is public certificate material, not a credential. |
| postgres | Cloud SQL private IP, admin secret and URL template. connection\_name feeds CLOUD\_SQL\_CONNECTION\_NAME in the sessions worker and alleyoop extraEnv. |
| search\_url | In-cluster OpenSearch URL (null unless enable\_search). |
<!-- END_TF_DOCS -->
