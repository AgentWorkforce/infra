# examples/aws-sessions-worker-cross-account

An EKS Pod Identity role for the sessions-pipeline worker (`<release>-worker`:
the summary and status workers) when the sessions bucket lives in another AWS
account. The grant matches the pipeline's own worker role: list the bucket, read
session objects, write encrypted summaries under `.../summary/`, and use the
bucket's KMS key through S3 only. No delete.

Cross-account access needs both sides. This root creates the cluster-account
side (role, inline policy, Pod Identity association). The bucket's owner merges
`output.resource_policy_statements` into the bucket policy and the key policy,
by `Sid`, read-merge-write. If another IaC stack owns those policies, add the
statements there, or that stack's next deploy removes them.

## Apply

```sh
cp terraform.tfvars.example terraform.tfvars   # fill in your IDs
terraform init -backend-config=...
terraform plan -out tfplan
terraform apply tfplan
terraform output -json resource_policy_statements   # hand to the bucket owner
```

Install the chart with the same namespace and the worker ServiceAccount named
here (default `agent-relay-worker`), with `worker.locker.credentials.mode:
podIdentity` and `worker.locker.region` set to the bucket's region.

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
| [aws_eks_pod_identity_association.worker](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_iam_role.worker](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.worker](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | The EKS cluster's AWS account. The provider refuses any other. | `string` | n/a | yes |
| eks\_cluster\_name | The EKS cluster that runs the worker (needs the Pod Identity Agent add-on). | `string` | n/a | yes |
| namespace | Namespace of the agent-relay release. | `string` | n/a | yes |
| region | The EKS cluster's region. | `string` | n/a | yes |
| role\_name | Name of the worker's IAM role in the cluster account. | `string` | n/a | yes |
| sessions\_bucket\_arn | The sessions (Locker) bucket in the other account, e.g. arn:aws:s3:::<bucket>. | `string` | n/a | yes |
| sessions\_kms\_key\_arn | The bucket's SSE-KMS key (a key ARN, not an alias). | `string` | n/a | yes |
| key\_base | Tenant key base: session objects live under <key\_base>/<org>/v1/. | `string` | `"96bulls"` | no |
| permissions\_boundary\_arn | Optional permissions boundary for the role. | `string` | `null` | no |
| role\_path | IAM path for the role. | `string` | `"/"` | no |
| service\_account | The sessions-pipeline worker ServiceAccount: <release>-worker for the agent-relay umbrella. | `string` | `"agent-relay-worker"` | no |
| tags | Tags for the role and the association. | `map(string)` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| resource\_policy\_statements | Statements the bucket's owner merges into the bucket policy and the key policy (by Sid). Nothing here writes them: they live in the other account. |
| role\_arn | The worker's role (Pod Identity; the chart needs no annotation). |
| service\_account | The ServiceAccount the association binds; the worker chart must run as it. |
<!-- END_TF_DOCS -->
