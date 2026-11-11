# aws/object-storage

An S3 bucket for agent-relay objects: the sessions pipeline Locker (`sessions-pipeline.worker.locker` / `alleyoop.locker`, provider `s3`) or durable-actors storage. It can also create the IAM role that the pods use through **EKS Pod Identity** or IRSA.

- All four public access blocks are on, ACLs are disabled (`BucketOwnerEnforced`), and SSE-KMS uses an S3 Bucket Key by default (customer key optional). Opt-in `history_upload` disables Bucket Keys and requires a customer-managed key so the per-user object encryption context remains enforceable.
- The bucket policy denies non-TLS requests and TLS below 1.2. Versioning is on, noncurrent versions expire after 30 days, incomplete multipart uploads are aborted after 7 days, and `force_destroy = false`.
- `access_role`: List on the bucket (unconditional: S3 returns 404, not 403, for a missing key only with it), plus Get, Put and optional Delete on objects (optionally limited to `prefixes`), and KMS through S3 only.
- `pod_identity_associations` binds the role to existing ServiceAccounts. The compatibility examples keep `<release>-worker`, legacy `<release>-alleyoop` and descriptive `<release>-session-ingest-api`. Use the actual installed/rendered names when chart overrides differ, and retain old identities until their workloads are drained. Keep `locker.credentials.mode: podIdentity` in the chart.
- EKS Pod Identity allows one role per ServiceAccount. Give other access (for example OpenSearch) to this same role.

```hcl
module "sessions_bucket" {
  source      = "github.com/AgentWorkforce/infra//terraform/modules/aws/object-storage?ref=<tag>"
  bucket_name = "example-agent-relay-sessions"
  access_role = {
    name = "agent-relay-sessions"
    pod_identity_associations = [
      { cluster_name = "my-eks", namespace = "agent-relay", service_account = "agent-relay-worker" },
      { cluster_name = "my-eks", namespace = "agent-relay", service_account = "agent-relay-session-ingest-api" },
      { cluster_name = "my-eks", namespace = "agent-relay", service_account = "agent-relay-alleyoop" },
    ]
  }
}
```

See [self-host direct uploads](../../../../docs/selfhost-direct-uploads.md) for upload roles, issuer/consumer separation, secret references, native scanning and rollout checks.

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
| [aws_eks_pod_identity_association.access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_iam_role.access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.history_upload](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.history_upload](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.history_upload_issuer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_s3_bucket.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_logging.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_logging) | resource |
| [aws_s3_bucket_ownership_controls.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_caller_identity.upload](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| bucket\_name | Globally unique S3 bucket name. Feeds sessions-pipeline worker.locker.bucket and alleyoop.locker.bucket (or durable-actors storage.bucket). | `string` | n/a | yes |
| abort\_incomplete\_multipart\_upload\_days | Abort incomplete multipart uploads after this many days. | `number` | `7` | no |
| access\_log\_bucket | Existing bucket for S3 server access logs. null disables access logging. | `string` | `null` | no |
| access\_log\_prefix | Key prefix for access logs. | `string` | `null` | no |
| access\_role | Optional IAM role for workloads that read and write the bucket (the sessions worker and alleyoop, durable-actors). The trust policy admits EKS Pod Identity (pods.eks.amazonaws.com) and, when oidc\_provider\_arn is set, IRSA for the listed service accounts. prefixes limits object access to those key prefixes (empty: the whole bucket). pod\_identity\_associations creates aws\_eks\_pod\_identity\_association resources on an existing cluster. | ```object({ name = string path = optional(string, "/") prefixes = optional(list(string), []) allow_delete = optional(bool, true) oidc_provider_arn = optional(string) permissions_boundary_arn = optional(string) pod_identity_associations = optional(list(object({ cluster_name = string namespace = string service_account = string })), []) irsa_service_accounts = optional(list(object({ namespace = string service_account = string })), []) })``` | `null` | no |
| additional\_policy\_statements | Extra bucket policy statements (decoded IAM statement objects), merged after the TLS-only denies. | `any` | `[]` | no |
| force\_destroy | Allow destroy to delete every object. Keep false for real data. | `bool` | `false` | no |
| history\_upload | Optional direct-upload issuer and write-only role. Consumer role ARNs alone may read the raw upload inbox (including versions). Control role must already exist; its KMS key policy must delegate IAM permissions to this account. Bucket Keys are disabled for new objects so per-user session encryption-context restrictions work. No credentials or witness keys belong in Terraform. | ```object({ name = string path = optional(string, "/") permissions_boundary_arn = optional(string) control_role_arn = string consumer_role_arns = set(string) key_root = optional(string, "96bulls") })``` | `null` | no |
| kms\_key\_arn | Customer managed KMS key for SSE-KMS (with an S3 Bucket Key). null uses SSE-KMS with the AWS managed aws/s3 key. | `string` | `null` | no |
| lifecycle\_rules | Extra lifecycle rules: id, optional prefix, and optional expiration\_days / transition (days, storage\_class). | ```list(object({ id = string prefix = optional(string, "") expiration_days = optional(number) transitions = optional(list(object({ days = number storage_class = string })), []) }))``` | `[]` | no |
| noncurrent\_version\_expiration\_days | Delete noncurrent object versions after this many days (0 keeps them forever). | `number` | `30` | no |
| object\_lock\_enabled | Create the bucket with Object Lock enabled (cannot be changed later). | `bool` | `false` | no |
| tags | Tags applied to every resource. | `map(string)` | `{}` | no |
| versioning\_enabled | Keep object versions (recovery from overwrites and deletes). | `bool` | `true` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| access\_role\_arn | Workload role ARN (null when access\_role is unset). With Pod Identity no chart value is needed (the association binds it; keep locker.credentials.mode podIdentity); with IRSA annotate the ServiceAccount with eks.amazonaws.com/role-arn. |
| access\_role\_name | Workload role name (null when access\_role is unset). |
| bucket\_arn | Bucket ARN (for IAM policies and the functions module's S3 notification). |
| bucket\_name | Bucket name. Feeds sessions-pipeline worker.locker.bucket and alleyoop.locker.bucket (provider s3, endpoint ""), or durable-actors storage.bucket and the relaycast/relayfile artifactBucket in values-eks-actors.yaml. |
| bucket\_region | Bucket region. Feeds worker.locker.region / alleyoop.locker.region (or durable-actors storage.s3.region). |
| history\_upload\_role\_arn | Write-only upload role for Control's SELFHOST\_HISTORY\_UPLOAD\_ROLE\_ARN (null when disabled). |
| pod\_identity\_association\_ids | Pod Identity associations created, keyed by cluster/namespace/service-account. |
<!-- END_TF_DOCS -->
