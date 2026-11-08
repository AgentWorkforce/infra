# examples/gcp

A thin root that composes the four GCP modules for one agent-relay install on an existing GKE cluster and VPC:

- `gcp/postgres` (Cloud SQL with the `relaycontrol`, `relayhistory` and `hoopdb` databases).
- `gcp/object-storage` for the sessions Locker, with direct Workload Identity for `<release>-worker` and `<release>-session-ingest-api`.
- `gcp/search` on the GKE cluster (`enable_search`).
- `gcp/functions` (`enable_functions`).

```sh
cp terraform.tfvars.example terraform.tfvars   # fill in existing IDs
terraform init && terraform plan
```

`chart_values` prints the non-secret values for `values-gcp.yaml`. Requires Terraform or OpenTofu >= 1.11 (the Cloud SQL admin password is write-only).

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
| [google_client_config.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/client_config) | data source |
| [google_container_cluster.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/container_cluster) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| network\_self\_link | Existing VPC with Private Services Access configured (Cloud SQL private IP). | `string` | n/a | yes |
| project\_id | GCP project. | `string` | n/a | yes |
| region | GCP region. | `string` | n/a | yes |
| sessions\_bucket\_name | Globally unique GCS bucket name for session objects. | `string` | n/a | yes |
| enable\_functions | Create the optional event-driven pipeline (Cloud Run functions). | `bool` | `false` | no |
| enable\_search | Install the optional OpenSearch cluster on GKE. | `bool` | `false` | no |
| gke\_cluster\_location | Its region or zone. | `string` | `null` | no |
| gke\_cluster\_name | Existing GKE cluster that runs agent-relay (only for enable\_search). | `string` | `null` | no |
| gke\_use\_private\_endpoint | Reach the control plane on its private endpoint. | `bool` | `true` | no |
| kms\_key\_name | CMEK key for Cloud SQL and the bucket (null: Google-managed). Grant the service agents on it first. | `string` | `null` | no |
| labels | Labels for every resource that supports them. | `map(string)` | `{}` | no |
| name | Name prefix for every resource. | `string` | `"agent-relay"` | no |
| namespace | agent-relay release namespace. | `string` | `"agent-relay"` | no |
| notification\_channels | Cloud Monitoring notification channels for the pipeline alerts. | `list(string)` | `[]` | no |
| pipeline\_source\_archive | Function source zip in GCS. Required with enable\_functions. | ```object({ bucket = string object = string generation = optional(number) })``` | `null` | no |
| release\_name | agent-relay Helm release name. | `string` | `"agent-relay"` | no |
| search\_admin\_credentials\_secret\_name | Existing Secret (in the search namespace) with the OpenSearch admin username and password. | `string` | `"opensearch-admin"` | no |
| search\_security\_config\_secret\_name | Existing Secret (in the search namespace) with the security plugin configuration. | `string` | `"opensearch-security-config"` | no |
| search\_storage\_class | StorageClass for OpenSearch volumes. | `string` | `null` | no |
| vpc\_connector | Existing Serverless VPC Access connector for the pipeline function (reaches the private Cloud SQL). Required with enable\_functions. | `string` | `null` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| chart\_values | Non-secret agent-relay chart values (values-gcp.yaml) these resources feed. Database URLs go in the release Secret, not here; see terraform/README.md. |
| functions | Pipeline function, topics and secret (null unless enable\_functions). |
| postgres | Cloud SQL private IP, admin secret and URL template. connection\_name feeds CLOUD\_SQL\_CONNECTION\_NAME in the sessions worker and alleyoop extraEnv. |
| search\_url | In-cluster OpenSearch URL (null unless enable\_search). |
<!-- END_TF_DOCS -->
