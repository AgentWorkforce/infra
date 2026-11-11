# aws/desktop-feed

**Optional.** AWS resources for Relay Control's private Desktop update feed ([enterprise install guide, step 6](../../../../docs/enterprise-aws-install.md#6-provision-and-promote-the-private-desktop-feed)): one signing key per Desktop profile, a private bucket for feed objects, and Control's workload identity.

- **Keys.** One AWS KMS key per profile ID, with key spec `ECC_NIST_EDWARDS25519` and usage `SIGN_VERIFY`, plus alias `alias/<name>-<profile>`. Each profile's Desktop builds embed its key's public half, so keys are never shared between profiles or rotated in place (KMS has no automatic rotation for asymmetric keys). The key policy only delegates to IAM in this account. Removing a profile schedules its key for deletion after `key_deletion_window_days`, which breaks every Desktop build that trusts it.
- **Bucket.** By default a private bucket made through [`object-storage`](../object-storage): public access blocked, bucket-owner ownership, versioning, TLS-only policy. The name cannot contain dots, because Control signs the virtual-hosted host `<bucket>.s3.<region>.amazonaws.com` into `download_hosts`. Control requests SSE-S3 (`AES256`) on every write; the bucket default (SSE-KMS with `aws/s3`) applies only to other writers. `create_bucket = false` grants access under `prefix` in an existing private bucket instead (set `bucket_region` when it is not in the provider region). Prefer the dedicated bucket: `s3:ListBucket` cannot be narrowed to the prefix without turning missing-key 404s into 403s, so in a shared bucket Control can list other workloads' key names.
- **Control identity.** A role trusted by EKS Pod Identity with `kms:Sign`, `kms:GetPublicKey` and `kms:DescribeKey` on the feed keys, `s3:GetObject`, `s3:PutObject` and `s3:DeleteObject` (plus multipart cleanup) on `<prefix>/*`, and `s3:ListBucket` on the bucket, so a missing key answers 404 instead of 403. `role.pod_identity_associations` binds Control's ServiceAccount: `<release>-relay-control` from the `relay-control` chart, or the `fullnameOverride`/`serviceAccount.name` the overlay sets (`values-eks.yaml` renders `relay-control`). Pod Identity allows one role per ServiceAccount, so when Control already has a role, set `role = { create = false }` and attach `policy_json` to it. `path` and `permissions_boundary_arn` pass through for Pippen (`/pippen/workload/` and its boundary).

`control_env` is the complete Control configuration as a name-to-string map, and `control_extra_env` is the same as the `[{name, value}]` list `relay-control.extraEnv` expects: `SELFHOST_DESKTOP_FEED_SIGNER=awskms`, `SELFHOST_DESKTOP_FEED_STORAGE=s3`, `SELFHOST_DESKTOP_FEED_KMS_REGION`, `SELFHOST_DESKTOP_FEED_KMS_KEY_ALIASES` (a JSON object of profile ID to alias), and `SELFHOST_DESKTOP_FEED_S3_BUCKET`, `_REGION` and `_PREFIX`. It contains no secret.

**Credential source.** Control signs its own AWS requests. At the time of writing it reads static `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN` or the EC2 instance role through IMDSv2, and does not read the EKS Pod Identity container credentials (`AWS_CONTAINER_CREDENTIALS_FULL_URI`). Foundation nodes set an IMDS hop limit of 1, so pods cannot reach the instance role. Before relying on this role, confirm that the selected Control image reads Pod Identity credentials. Do not widen the node role or the IMDS hop limit as a workaround.

```hcl
module "desktop_feed" {
  source = "../../modules/aws/desktop-feed"

  name        = "agent-relay-dev-desktop-feed"
  profiles    = ["<profile-id>"]
  bucket_name = "agent-relay-dev-<account-id>-<region>-desktop-feed"
  role = {
    pod_identity_associations = [{ cluster_name = "<cluster>", namespace = "agent-relay-dev", service_account = "agent-relay-relay-control" }]
  }
}
```

The [aws-environments](../../../examples/aws-environments) composition wires this module behind its default-off `desktop_feed` input.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.6 |
| aws | >= 6.72, < 7.0 |

### Providers

| Name | Version |
| ---- | ------- |
| aws | >= 6.72, < 7.0 |

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| bucket | ../object-storage | n/a |

### Resources

| Name | Type |
| ---- | ---- |
| [aws_eks_pod_identity_association.control](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_iam_role.control](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.control](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_kms_alias.feed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.feed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| bucket\_name | Private feed bucket. Control signs its virtual-hosted host into download\_hosts, so the name cannot contain dots. | `string` | n/a | yes |
| name | Base name for the feed keys, aliases, role and policy, e.g. agent-relay-dev-desktop-feed. | `string` | n/a | yes |
| profiles | Desktop profile IDs, as Control and desktop-feed-provision.sh accept them (^[a-z0-9]{1,32}$). Each gets its own Ed25519 SIGN\_VERIFY key and alias alias/<name>-<profile>. | `set(string)` | n/a | yes |
| access\_log\_bucket | Existing bucket for S3 server access logs of a created bucket. null disables access logging. | `string` | `null` | no |
| bucket\_region | Region of an existing bucket (create\_bucket = false). null means the provider region; a created bucket always uses the provider region. | `string` | `null` | no |
| create\_bucket | Create bucket\_name as a private bucket through modules/aws/object-storage. false grants access to the prefix of an existing private bucket in this account. | `bool` | `true` | no |
| force\_destroy | Allow destroy to delete every feed object in a created bucket. Keep false outside disposable fixtures. | `bool` | `false` | no |
| key\_deletion\_window\_days | Waiting period before a removed profile key is deleted. Deleting a key invalidates every Desktop build that embeds its public key. | `number` | `30` | no |
| prefix | Object key prefix (SELFHOST\_DESKTOP\_FEED\_S3\_PREFIX). Control's default is desktop-feed. | `string` | `"desktop-feed"` | no |
| role | The Relay Control workload identity. create = true makes a role trusted by EKS Pod Identity with the feed policy and the listed Pod Identity associations (Pod Identity allows one role per ServiceAccount). create = false makes no IAM: attach the policy\_json output to Control's existing role instead. | ```object({ create = optional(bool, true) name = optional(string) path = optional(string, "/") permissions_boundary_arn = optional(string) pod_identity_associations = optional(list(object({ cluster_name = string namespace = string service_account = string })), []) })``` | `{}` | no |
| tags | Tags applied to every resource. | `map(string)` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| bucket\_arn | Feed bucket ARN. |
| control\_env | Relay Control's SELFHOST\_DESKTOP\_FEED\_* settings as a name-to-value map. Contains no secret; use control\_extra\_env for relay-control.extraEnv. |
| control\_extra\_env | control\_env as the [{name, value}] list relay-control.extraEnv expects, sorted by name. |
| key\_aliases | Profile ID to KMS alias. |
| key\_arns | Profile ID to KMS key ARN. |
| pod\_identity\_association\_ids | Pod Identity associations created, keyed by cluster/namespace/service-account. |
| policy\_json | The Control feed permissions; attach it to an existing Control role when role.create = false. |
| role\_arn | Control workload role ARN (null when role.create = false). |
<!-- END_TF_DOCS -->
