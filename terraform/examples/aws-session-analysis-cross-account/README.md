# examples/aws-session-analysis-cross-account

A dedicated EKS Pod Identity role for `SERVICE=session-analysis` when the
canonical sessions bucket and KMS key live in another AWS account. It is not
the general worker or ingest identity.

The cluster-account role can list the bucket, read canonical session objects,
and create or strictly erase versioned results only below
`normalized/session-analysis-v2/`. KMS use is through S3 in the bucket Region,
with object-ARN encryption contexts. It deliberately does not admit the bucket
ARN used by S3 Bucket Keys. Do not enable Bucket Keys for this bucket.

`s3:ListBucket` is deliberately unconditioned: without it, S3 answers a missing
canonical object with 403 instead of 404, so the runner cannot distinguish an
absent manifest from an authorization failure. This exposes bucket key names to
the dedicated role. Every reserved dot-prefix namespace (`<key_base>/.*`) is
therefore explicitly denied for object access and KMS decryption; this covers
the upload and admission inboxes, admission probes and DLQ, drain receipts, and
future reserved namespaces. The role cannot read their contents.

Cross-account access needs both sides. This root creates the role, inline
identity policy, and Pod Identity association. The sessions stack must merge
`output.resource_policy_statements` into its bucket and key policies and carve
this exact role out of its eraser-only explicit Deny for the result prefix.
Until that stack change is planned and applied, an identity-policy apply alone
does not grant access.

## Apply

```sh
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=...
terraform plan -out tfplan
terraform apply tfplan
terraform output -json resource_policy_statements
```

The chart must use the same namespace and ServiceAccount, with
`sessionAnalysis.s3Credentials: podIdentity` and the canonical bucket Region.
Keep `sessionAnalysis.run: false` until both accounts' policy plans and the
dormant pod readback are complete.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.0, < 7.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.73.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_eks_pod_identity_association.runner](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_iam_role.runner](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.runner](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_account_id"></a> [account\_id](#input\_account\_id) | The EKS cluster account. The provider refuses any other account. | `string` | n/a | yes |
| <a name="input_eks_cluster_name"></a> [eks\_cluster\_name](#input\_eks\_cluster\_name) | The EKS cluster that runs session-analysis and has the Pod Identity Agent add-on. | `string` | n/a | yes |
| <a name="input_key_base"></a> [key\_base](#input\_key\_base) | Bare canonical key root; session objects live under <key\_base>/<org>/v1/. | `string` | `"96bulls"` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace of the agent-relay release. | `string` | n/a | yes |
| <a name="input_permissions_boundary_arn"></a> [permissions\_boundary\_arn](#input\_permissions\_boundary\_arn) | Optional permissions boundary for the runner role. | `string` | `null` | no |
| <a name="input_region"></a> [region](#input\_region) | The EKS cluster region. | `string` | n/a | yes |
| <a name="input_role_name"></a> [role\_name](#input\_role\_name) | Name of the runner IAM role in the EKS cluster account. | `string` | n/a | yes |
| <a name="input_role_path"></a> [role\_path](#input\_role\_path) | IAM path for the role. | `string` | `"/"` | no |
| <a name="input_service_account"></a> [service\_account](#input\_service\_account) | Dedicated session-analysis ServiceAccount; never share the ingest or general worker identity. | `string` | `"agent-relay-worker-session-analysis"` | no |
| <a name="input_sessions_bucket_arn"></a> [sessions\_bucket\_arn](#input\_sessions\_bucket\_arn) | Canonical sessions bucket ARN in the other account, with no key path. | `string` | n/a | yes |
| <a name="input_sessions_kms_key_arn"></a> [sessions\_kms\_key\_arn](#input\_sessions\_kms\_key\_arn) | The bucket SSE-KMS key ARN, not an alias. | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags for the role and Pod Identity association. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_resource_policy_statements"></a> [resource\_policy\_statements](#output\_resource\_policy\_statements) | Exact statements for the bucket owner to merge into the bucket and KMS key policies. The bucket stack must separately carve this role out of its result-delete Deny. |
| <a name="output_role_arn"></a> [role\_arn](#output\_role\_arn) | Dedicated session-analysis Pod Identity role ARN. |
| <a name="output_service_account"></a> [service\_account](#output\_service\_account) | ServiceAccount the Pod Identity association binds. |
<!-- END_TF_DOCS -->
