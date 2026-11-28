# examples/aws-hosted-session-pipeline-ci

One-time bootstrap for [`.github/workflows/hosted-session-pipeline.yml`](../../../.github/workflows/hosted-session-pipeline.yml),
which plans and applies [`aws-hosted-session-pipeline`](../aws-hosted-session-pipeline). It creates the GitHub
OIDC trust, the state bucket and its KMS key, the private tfvars SecureString, and two roles:

| Role | Trusted subject | Can |
|---|---|---|
| plan | `repo:AgentWorkforce/infra:environment:hosted-session-pipeline-plan` | read the pipeline resources, state and tfvars; take the lock; write the plan store once. Denied: state writes, secret values |
| apply | `repo:AgentWorkforce/infra:environment:hosted-session-pipeline` | the same reads, plus changes to the same named resources and state writes. Denied: every delete, secret values |

Both are scoped by name to what the hosted root manages: `<name_prefix>-session-*` queues, rules and alarms; the
pipeline function's policy and its event source mappings; the pipeline role; the secret's metadata; and the
transcripts bucket's policy and notification and key policy.

## Run once (account administrator, pre-approved: #owner-decisions 252346480703528960)

```sh
terraform init -backend=false && terraform apply -var-file=private.tfvars   # first apply, local state
terraform init -migrate-state -backend-config=bucket=<state bucket> -backend-config=key=hosted/ci-bootstrap.tfstate \
  -backend-config=region=<region> -backend-config=encrypt=true -backend-config=use_lockfile=true
terraform output -json github_environment_variables   # set them on both GitHub environments, with the role ARNs
aws ssm put-parameter --name /hosted-session-pipeline-ci/tfvars --type SecureString --overwrite \
  --key-id <STATE_KMS_KEY_ARN> --value file://hosted.tfvars.json   # the hosted root's private tfvars
```

Create the GitHub environments `hosted-session-pipeline-plan` (branch `main`) and `hosted-session-pipeline`
(branch `main`, required reviewers). Set `GATE_ALLOW` on both.

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
| [aws_iam_openid_connect_provider.github](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider) | resource |
| [aws_iam_role.ci](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.ci](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_kms_alias.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_s3_bucket.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_ownership_controls.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_ssm_parameter.tfvars](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [aws_iam_policy_document.trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | The hosted sessions account. | `string` | n/a | yes |
| pipeline | What the hosted root manages, so both roles are scoped to it and nothing else. | ```object({ name_prefix = string # 96bulls-<stage> function_name = string role_name = string bucket_name = string kms_key_arn = string secret_name = string # 96bulls/<stage>/session-pipeline log_group_names = optional(list(string), []) })``` | n/a | yes |
| region | The hosted sessions region. | `string` | n/a | yes |
| apply\_environment | GitHub environment of the apply job (protected: required reviewers, main only). | `string` | `"hosted-session-pipeline"` | no |
| apply\_scope | adoption (default): the apply role may write state and update the pipeline's event source mapping only, which is all the zero-diff import plus the approved ESM change needs. full: changes to every resource the hosted root manages (for later reviewed changes). | `string` | `"adoption"` | no |
| create\_oidc\_provider | Create the GitHub OIDC provider. false when the account already has one. | `bool` | `true` | no |
| github\_repository | owner/repo whose workflow assumes the roles. | `string` | `"AgentWorkforce/infra"` | no |
| name | Prefix for the CI resources (roles, state bucket, key alias, parameter). | `string` | `"hosted-session-pipeline-ci"` | no |
| plan\_environment | GitHub environment of the plan job (its OIDC subject). | `string` | `"hosted-session-pipeline-plan"` | no |
| state\_key | Object key of the hosted root's state. | `string` | `"hosted/session-pipeline.tfstate"` | no |
| tags | Tags on the CI resources. | `map(string)` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| apply\_role\_arn | APPLY\_ROLE\_ARN for the hosted-session-pipeline environment. |
| github\_environment\_variables | Shared variables for both GitHub environments (set them there; never commit them). |
| plan\_role\_arn | PLAN\_ROLE\_ARN for the hosted-session-pipeline-plan environment. |
<!-- END_TF_DOCS -->
