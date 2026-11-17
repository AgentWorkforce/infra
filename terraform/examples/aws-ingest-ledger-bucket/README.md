# examples/aws-ingest-ledger-bucket

A bucket for the sessions-pipeline S3 upload ledger's own objects, in the EKS
cluster's region, next to the ingest edge, and the grants for the two roles that
use it: the ingest edge (`ingestEdge.serviceAccountName`) and, optionally, the
re-arm sweeper. The Locker bucket, its policies and the roles' other grants do
not change.

Today the ingest edge sends every ledger request to the Locker bucket. When that
bucket is in another region, a batch makes about a dozen cross-region round
trips, one after another. With `ingestEdge.ledgerBucket` set to this bucket, the
ledger's objects (each user's `ledger/`, and the ledger-home marker) are read and
written here. The fences, journals, inboxes, fence-authority markers and the
canonical layout stay in the Locker bucket. The services image must include
relayhistory-pipeline `src/session-ingest/ledger-store.ts`. See that repository's
`docs/ledger-relocation.md`.

Encryption defaults to SSE-S3. The ledger holds ids, hashes and revisions, never
transcript content, and with SSE-KMS every GET is a KMS call. Set
`sse_kms_key_arn` to use SSE-KMS with S3 Bucket Keys instead. Versioning is on,
and noncurrent versions expire after `noncurrent_version_days` days.

## Apply

```sh
cp terraform.tfvars.example terraform.tfvars   # fill in your IDs
terraform init -backend-config=...
terraform plan -out tfplan
terraform apply tfplan
```

Creating the bucket is harmless. The edge reads it only once
`ingestEdge.ledgerBucket` is set, and that is a relocation: stop admission,
copy, verify, switch the ledger-home marker, then set the values. It is never
just a values change.

## Cross-account access

`cross_account_ledger_reader_role_arns` and `cross_account_ledger_writer_role_arns`
(both empty by default, which leaves the bucket policy unchanged) add bucket
policy statements for roles in other accounts. Readers and writers may list
`<key_root>/.admission-inbox/*` and the ledger-home marker, and get the ledger
objects (`.admission-inbox/*/ledger/*`) and the marker. Writers may also put
ledger objects. Nobody gets delete or version actions.

A bucket policy is only half of a cross-account grant: each role's own identity
policy, in its account, must allow the same actions (`s3:ListBucket` on the
bucket, `s3:GetObject` and, for writers, `s3:PutObject` on those keys). With
`sse_kms_key_arn` set the plan fails: the KMS key policy would also have to
grant those principals, and this module does not manage it.

```hcl
cross_account_ledger_reader_role_arns = ["arn:aws:iam::111111111111:role/example-backlog-read"]
cross_account_ledger_writer_role_arns = ["arn:aws:iam::222222222222:role/example-backlog-write"]
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
| [aws_iam_role_policy.consumer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.rearm_sweeper](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_s3_bucket.ledger](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.ledger](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_ownership_controls.ledger](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.ledger](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.ledger](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.ledger](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.ledger](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_iam_role.consumer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_role) | data source |
| [aws_iam_role.rearm_sweeper](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_role) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | The EKS cluster's AWS account (the bucket and both roles live here). The provider refuses any other. | `string` | n/a | yes |
| bucket\_name | The ledger bucket (ingestEdge.ledgerBucket.bucket). Must differ from the Locker bucket. | `string` | n/a | yes |
| consumer\_role\_name | The ingest edge's existing Pod Identity role (its ServiceAccount is ingestEdge.serviceAccountName). Gets read/write on the ledger bucket's key root; nothing else about the role changes. | `string` | n/a | yes |
| region | The EKS cluster's region: the ledger bucket is created here, next to the ingest edge. | `string` | n/a | yes |
| cross\_account\_ledger\_reader\_role\_arns | IAM role ARNs in other accounts that may list the ledger prefixes and read the ledger objects and the ledger-home marker (bucket policy). Each role's own identity policy, in its account, must grant the same actions on this bucket. Not supported with sse\_kms\_key\_arn. | `list(string)` | `[]` | no |
| cross\_account\_ledger\_writer\_role\_arns | IAM role ARNs in other accounts that get the reader access plus PutObject on the ledger objects (bucket policy; no delete, no version actions). Each role's own identity policy, in its account, must grant the same actions on this bucket. Not supported with sse\_kms\_key\_arn. | `list(string)` | `[]` | no |
| key\_root | INGEST\_KEY\_ROOT of the ingest edge. | `string` | `"96bulls"` | no |
| noncurrent\_version\_days | Days a replaced or deleted ledger object version is kept (versioning is on, for recovery). | `number` | `30` | no |
| rearm\_sweeper\_role\_name | The re-arm sweeper's existing Pod Identity role, or null when the sweeper runs elsewhere. Gets read on the ledger objects and create on the completion records. | `string` | `null` | no |
| sse\_kms\_key\_arn | null (default): SSE-S3 (AES256), no KMS call per request. A KMS key ARN: SSE-KMS with S3 Bucket Keys, and both roles get the key through S3 only. | `string` | `null` | no |
| tags | Tags for the bucket. | `map(string)` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| bucket | ingestEdge.ledgerBucket.bucket. |
| bucket\_arn | The ledger bucket's ARN. |
| region | ingestEdge.ledgerBucket.region. |
<!-- END_TF_DOCS -->
