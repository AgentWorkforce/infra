# examples/aws-session-analysis-cross-account

A dedicated EKS Pod Identity role for `SERVICE=session-analysis` when the
canonical sessions bucket and KMS key live in another AWS account. It is not
the general worker or ingest identity.

The cluster-account role can list the bucket, read canonical session objects,
and create or strictly erase versioned results only below
`normalized/session-analysis-v2/`. KMS use is through S3 in the bucket Region,
with object-ARN encryption contexts. It deliberately does not admit the bucket
ARN used by S3 Bucket Keys. Do not enable Bucket Keys for this bucket.

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
| [aws_eks_pod_identity_association.runner](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_iam_role.runner](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.runner](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | The EKS cluster account. The provider refuses any other account. | `string` | n/a | yes |
| eks\_cluster\_name | The EKS cluster that runs session-analysis and has the Pod Identity Agent add-on. | `string` | n/a | yes |
| namespace | Namespace of the agent-relay release. | `string` | n/a | yes |
| region | The EKS cluster region. | `string` | n/a | yes |
| role\_name | Name of the runner IAM role in the EKS cluster account. | `string` | n/a | yes |
| sessions\_bucket\_arn | Canonical sessions bucket ARN in the other account, with no key path. | `string` | n/a | yes |
| sessions\_kms\_key\_arn | The bucket SSE-KMS key ARN, not an alias. | `string` | n/a | yes |
| key\_base | Bare canonical key root; session objects live under <key\_base>/<org>/v1/. | `string` | `"96bulls"` | no |
| permissions\_boundary\_arn | Optional permissions boundary for the runner role. | `string` | `null` | no |
| role\_path | IAM path for the role. | `string` | `"/"` | no |
| service\_account | Dedicated session-analysis ServiceAccount; never share the ingest or general worker identity. | `string` | `"agent-relay-worker-session-analysis"` | no |
| tags | Tags for the role and Pod Identity association. | `map(string)` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| resource\_policy\_statements | Exact statements for the bucket owner to merge into the bucket and KMS key policies. The bucket stack must separately carve this role out of its result-delete Deny. |
| role\_arn | Dedicated session-analysis Pod Identity role ARN. |
| service\_account | ServiceAccount the Pod Identity association binds. |
<!-- END_TF_DOCS -->
