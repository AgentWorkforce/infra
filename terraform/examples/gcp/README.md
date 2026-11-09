# examples/gcp

A root for the native-history Agent Relay profile on an existing GKE cluster
and VPC:

- `gcp/postgres` (Cloud SQL with `relaycontrol`, `relaycast` and `hoopdb`, plus
  a retained `relayhistory` database that prevents destructive legacy updates),
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
`values-gcp.yaml` plus `values-gcp-native.yaml`, including the eight required
worker/search pipeline variables, the `sessions_pipeline_runtime` role and the
Cloud SQL CA bindings for every PostgreSQL client. Save it directly as a Helm
values file after apply:

```sh
terraform output -json chart_values > managed-values.json
```

The native overlay is delivered by the preceding GCP profile change; apply
the three files in this order: `values-gcp.yaml`, `values-gcp-native.yaml`,
then `managed-values.json`. Run
`scripts/selfhost/cloud-sql-setup.sh pre` after apply and before Helm. Requires
Terraform or OpenTofu >= 1.11 (the Cloud SQL admin password is write-only).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_google"></a> [google](#requirement\_google) | >= 7.0, < 8.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | >= 3.0, < 4.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | >= 2.30, < 4.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_google"></a> [google](#provider\_google) | 7.46.2 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_functions"></a> [functions](#module\_functions) | ../../modules/gcp/functions | n/a |
| <a name="module_postgres"></a> [postgres](#module\_postgres) | ../../modules/gcp/postgres | n/a |
| <a name="module_search"></a> [search](#module\_search) | ../../modules/gcp/search | n/a |
| <a name="module_sessions_bucket"></a> [sessions\_bucket](#module\_sessions\_bucket) | ../../modules/gcp/object-storage | n/a |

## Resources

| Name | Type |
| ---- | ---- |
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

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_deletion_protection"></a> [deletion\_protection](#input\_deletion\_protection) | Prevent deletion of Cloud SQL, Memorystore and Pub/Sub data resources. Disable only for a disposable proof environment. | `bool` | `true` | no |
| <a name="input_enable_functions"></a> [enable\_functions](#input\_enable\_functions) | Create the optional event-driven pipeline (Cloud Run functions). | `bool` | `false` | no |
| <a name="input_enable_search"></a> [enable\_search](#input\_enable\_search) | Install the optional OpenSearch cluster on GKE. | `bool` | `false` | no |
| <a name="input_gke_cluster_location"></a> [gke\_cluster\_location](#input\_gke\_cluster\_location) | Its region or zone. | `string` | `null` | no |
| <a name="input_gke_cluster_name"></a> [gke\_cluster\_name](#input\_gke\_cluster\_name) | Existing GKE cluster that runs agent-relay (only for enable\_search). | `string` | `null` | no |
| <a name="input_gke_use_private_endpoint"></a> [gke\_use\_private\_endpoint](#input\_gke\_use\_private\_endpoint) | Reach the control plane on its private endpoint. | `bool` | `true` | no |
| <a name="input_kms_key_name"></a> [kms\_key\_name](#input\_kms\_key\_name) | CMEK key for Cloud SQL and the bucket (null: Google-managed). Grant the service agents on it first. | `string` | `null` | no |
| <a name="input_labels"></a> [labels](#input\_labels) | Labels for every resource that supports them. | `map(string)` | `{}` | no |
| <a name="input_name"></a> [name](#input\_name) | Name prefix for every resource. | `string` | `"agent-relay"` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | agent-relay release namespace. | `string` | `"agent-relay"` | no |
| <a name="input_network_self_link"></a> [network\_self\_link](#input\_network\_self\_link) | Existing VPC with Private Services Access configured (Cloud SQL private IP). | `string` | n/a | yes |
| <a name="input_notification_channels"></a> [notification\_channels](#input\_notification\_channels) | Cloud Monitoring notification channels for the pipeline alerts. | `list(string)` | `[]` | no |
| <a name="input_pipeline_message_retention"></a> [pipeline\_message\_retention](#input\_pipeline\_message\_retention) | Pub/Sub topic and subscription retention for the native Sessions pipeline. | `string` | `"604800s"` | no |
| <a name="input_pipeline_pubsub_kms_key_name"></a> [pipeline\_pubsub\_kms\_key\_name](#input\_pipeline\_pubsub\_kms\_key\_name) | Optional CMEK key for the native Sessions pipeline Pub/Sub topics. | `string` | `null` | no |
| <a name="input_pipeline_redis_memory_size_gb"></a> [pipeline\_redis\_memory\_size\_gb](#input\_pipeline\_redis\_memory\_size\_gb) | Memorystore capacity for the native Sessions pipeline. | `number` | `5` | no |
| <a name="input_pipeline_redis_reserved_ip_range"></a> [pipeline\_redis\_reserved\_ip\_range](#input\_pipeline\_redis\_reserved\_ip\_range) | Optional PSA allocated range name for Memorystore. null lets Google choose from the connection. | `string` | `null` | no |
| <a name="input_pipeline_redis_version"></a> [pipeline\_redis\_version](#input\_pipeline\_redis\_version) | Memorystore Redis version. | `string` | `"REDIS_7_2"` | no |
| <a name="input_pipeline_source_archive"></a> [pipeline\_source\_archive](#input\_pipeline\_source\_archive) | Function source zip in GCS. Required with enable\_functions. | <pre>object({<br/>    bucket     = string<br/>    object     = string<br/>    generation = optional(number)<br/>  })</pre> | `null` | no |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | GCP project. | `string` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | GCP region. | `string` | n/a | yes |
| <a name="input_release_name"></a> [release\_name](#input\_release\_name) | agent-relay Helm release name. | `string` | `"agent-relay"` | no |
| <a name="input_search_admin_credentials_secret_name"></a> [search\_admin\_credentials\_secret\_name](#input\_search\_admin\_credentials\_secret\_name) | Existing Secret (in the search namespace) with the OpenSearch admin username and password. | `string` | `"opensearch-admin"` | no |
| <a name="input_search_security_config_secret_name"></a> [search\_security\_config\_secret\_name](#input\_search\_security\_config\_secret\_name) | Existing Secret (in the search namespace) with the security plugin configuration. | `string` | `"opensearch-security-config"` | no |
| <a name="input_search_storage_class"></a> [search\_storage\_class](#input\_search\_storage\_class) | StorageClass for OpenSearch volumes. | `string` | `null` | no |
| <a name="input_sessions_bucket_name"></a> [sessions\_bucket\_name](#input\_sessions\_bucket\_name) | Globally unique GCS bucket name for session objects. | `string` | n/a | yes |
| <a name="input_vpc_connector"></a> [vpc\_connector](#input\_vpc\_connector) | Existing Serverless VPC Access connector for the pipeline function (reaches the private Cloud SQL). Required with enable\_functions. | `string` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_chart_values"></a> [chart\_values](#output\_chart\_values) | Complete non-secret managed-service overlay for values-gcp.yaml plus values-gcp-native.yaml. Save with: terraform output -json chart\_values > managed-values.json. |
| <a name="output_functions"></a> [functions](#output\_functions) | Pipeline function, topics and secret (null unless enable\_functions). |
| <a name="output_pipeline"></a> [pipeline](#output\_pipeline) | Native Sessions pipeline values. The Redis CA is public certificate material, not a credential. |
| <a name="output_postgres"></a> [postgres](#output\_postgres) | Cloud SQL private IP, admin secret and URL template. connection\_name feeds CLOUD\_SQL\_CONNECTION\_NAME in the sessions worker and alleyoop extraEnv. |
| <a name="output_search_url"></a> [search\_url](#output\_search\_url) | In-cluster OpenSearch URL (null unless enable\_search). |
<!-- END_TF_DOCS -->
