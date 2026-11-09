# gcp/object-storage

A GCS bucket for agent-relay objects: the sessions pipeline Locker (provider `gcs`, `credentials.mode: podIdentity`) or durable-actors storage. It can also grant GKE Workload Identity access.

- Uniform bucket-level access, `public_access_prevention = "enforced"`, versioning (noncurrent versions deleted after 30 days), 7-day soft delete, incomplete multipart uploads aborted after 7 days, and `force_destroy = false`.
- CMEK through `kms_key_name` (grant the Cloud Storage service agent on the key first).
- `workload_identity`: `roles/storage.objectUser` on this bucket only, in one of two ways:
  - `direct_kubernetes_service_accounts`: the workload pool principal for `ns/<namespace>/sa/<name>`. No Google service account and no annotation.
  - `google_service_account`: a GSA the listed KSAs may impersonate. Annotate them with `iam.gke.io/gcp-service-account`; durable-actors takes it as `serviceAccount.googleServiceAccount`.

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
| [google_service_account.workload](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account_iam_member.workload_identity](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_storage_bucket.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket) | resource |
| [google_storage_bucket_iam_member.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket_iam_member) | resource |
| [google_project.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/project) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| bucket\_name | Globally unique bucket name. Feeds sessions-pipeline worker.locker.bucket and alleyoop.locker.bucket (provider gcs), or durable-actors storage.bucket. | `string` | n/a | yes |
| location | Bucket location (a region such as us-central1, a dual-region or a multi-region). The sessions services expect the bucket's region in locker.region. | `string` | n/a | yes |
| project\_id | Project that owns the bucket. | `string` | n/a | yes |
| abort\_incomplete\_multipart\_upload\_days | Abort incomplete XML API multipart uploads after this many days. | `number` | `7` | no |
| access\_log\_bucket | Existing bucket for usage logs. null disables usage logging. | `string` | `null` | no |
| force\_destroy | Allow destroy to delete every object. Keep false for real data. | `bool` | `false` | no |
| iam\_members | Extra bucket IAM bindings: role => members. | `map(list(string))` | `{}` | no |
| kms\_key\_name | CMEK key for default object encryption. The Cloud Storage service agent needs roles/cloudkms.cryptoKeyEncrypterDecrypter on it first. null uses Google-managed encryption. | `string` | `null` | no |
| labels | Labels applied to the bucket. | `map(string)` | `{}` | no |
| lifecycle\_rules | Extra lifecycle rules: action (Delete or SetStorageClass with storage\_class) and condition fields. | ```list(object({ action_type = string storage_class = optional(string) age_days = optional(number) matches_prefix = optional(list(string)) with_state = optional(string) num_newer_versions = optional(number) }))``` | `[]` | no |
| noncurrent\_version\_retention\_days | Delete noncurrent versions this many days after they become noncurrent (0 keeps them). | `number` | `30` | no |
| soft\_delete\_retention\_seconds | Soft delete retention (0 disables; 604800 = 7 days is the GCS default). | `number` | `604800` | no |
| storage\_class | Default storage class. | `string` | `"STANDARD"` | no |
| versioning\_enabled | Keep noncurrent object versions. | `bool` | `true` | no |
| workload\_identity | Optional GKE Workload Identity access with roles/storage.objectUser on this bucket (read, write, list, delete objects; no IAM). google\_service\_account: creates a Google service account the listed Kubernetes service accounts may impersonate (annotate them iam.gke.io/gcp-service-account=<email>; durable-actors takes it as serviceAccount.googleServiceAccount). direct\_kubernetes\_service\_accounts: grants the Kubernetes service accounts directly through the workload pool principal (no Google service account, no annotation). | ```object({ google_service_account = optional(object({ account_id = string display_name = optional(string) kubernetes_service_accounts = list(object({ namespace = string name = string })) })) direct_kubernetes_service_accounts = optional(list(object({ namespace = string name = string })), []) # <project>.svc.id.goog of the cluster's project (default: project_id). workload_pool = optional(string) })``` | `null` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| bucket\_name | Bucket name. Feeds sessions-pipeline worker.locker.bucket and alleyoop.locker.bucket (provider gcs, endpoint ""), or durable-actors storage.bucket. |
| bucket\_url | gs://<bucket>. |
| google\_service\_account\_email | Workload Google service account (null unless workload\_identity.google\_service\_account is set). Annotate the Kubernetes service accounts iam.gke.io/gcp-service-account=<email>; durable-actors takes it as serviceAccount.googleServiceAccount. |
| location | Bucket location as given (a region, dual-region or multi-region). |
| region | The bucket's region when its location is a single region (null for dual- and multi-regions). Feeds worker.locker.region / alleyoop.locker.region. |
<!-- END_TF_DOCS -->
