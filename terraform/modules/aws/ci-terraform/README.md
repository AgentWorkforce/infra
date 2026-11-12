# aws/ci-terraform

Plan and apply one Terraform state (the `examples/aws-environments` data stack) from GitHub Actions, with
no local runs. The stack only calls AWS APIs, so the jobs run on GitHub-hosted runners with these two OIDC
roles; no runner or CodeBuild project inside the VPC is needed (compare [ci-deploy](../ci-deploy), which must
reach a private EKS API). See [docs/selfhost-ci-terraform.md](../../../../docs/selfhost-ci-terraform.md) for
the workflow, the saved-plan handoff and the first run.

- **Trust.** `aud` and `sub` only: these are the GitHub claims AWS evaluates (`ref`, `repository_id` and
  `job_workflow_ref` are not condition keys). plan: sub `<prefix>:ref:refs/heads/<branch>`. apply: sub
  `<prefix>:environment:<apply_environment>`. Use a subject template with immutable owner and repository IDs.
  Give the apply job a GitHub environment of its own, with deployment branches limited to `branch`. Without
  required reviewers (GitHub Free, private repository), that branch policy is what keeps other branches out,
  and a dedicated environment keeps other workflows' jobs out.
- **plan** reads the state object, takes and releases the S3 native lock (`<key>.tflock`: the only write
  Terraform needs to plan), refreshes with Describe/Get/List calls, reads the tfvars SSM parameter and saves
  `run.tgz` and `manifest.json` under `plan_store_prefix`. It is denied writes to the state object.
  Plan-store writes are create-only (`s3:if-none-match`): a reviewed plan can never be replaced.
- **apply** applies one saved plan: it can also write the state and create, change or delete resources
  named `<stack.name>-*` (IAM roles, S3 buckets, RDS, OpenSearch, log groups, Pod Identity associations on
  `stack.eks_cluster_name`), Ed25519 desktop-feed signing keys tagged with the environment, and the
  RDS-managed master secret. `lambda_pipeline` adds the Lambda/SQS/EventBridge pipeline (off by default).
  The chief execution node is not covered: EC2 writes cannot be scoped to it by name.
- **Both** are denied `secretsmanager:GetSecretValue`, every S3 object except the state, its lock and the
  plan store, and every SSM parameter except the tfvars one and AWS public parameters.

The apply role can create IAM roles named `<stack.name>-*` with any trust and inline policy: it is as strong
as the stack it applies. What keeps it safe is the trust (one environment, deployable from one branch, used by one
workflow) and that workflow, which applies only an exact reviewed saved plan.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.7 |
| aws | >= 6.72, < 7.0 |

### Providers

| Name | Version |
| ---- | ------- |
| aws | >= 6.72, < 7.0 |

### Resources

| Name | Type |
| ---- | ---- |
| [aws_iam_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.github](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| apply\_environment | GitHub environment the apply job runs in; the apply role trusts its sub. Dedicate it to this workflow and limit its deployment branches to branch, because without required reviewers that policy is what keeps other branches and workflows out. | `string` | n/a | yes |
| github\_oidc\_provider\_arn | The account's token.actions.githubusercontent.com OIDC provider (an account has at most one; ci-deploy creates it). | `string` | n/a | yes |
| name | Prefix for the roles and policies, e.g. agentrelay-prod-data. One instance per Terraform state. | `string` | n/a | yes |
| oidc\_subject\_prefix | Prefix of the caller repository's GitHub OIDC sub claim. Use a subject template with immutable owner and repository IDs (repo:owner@<id>/name@<id>), so a renamed or recreated repository cannot match. | `string` | n/a | yes |
| plan\_store\_prefix | Prefix in the state bucket for saved plans (<prefix>/<run>/run.tgz, manifest.json, apply-attempt.json). No trailing slash. | `string` | n/a | yes |
| stack | What the applied Terraform (examples/aws-environments) manages. name is its name\_prefix-environment: every resource the apply role may create or change is named <name>-*. kms\_key\_arn is the environment key the stack encrypts RDS, OpenSearch and the RDS-managed secret with. | ```object({ name = string environment = string eks_cluster_name = string kms_key_arn = string })``` | n/a | yes |
| state | S3 backend of the Terraform state this CI plans and applies: bucket, key and the KMS key that encrypts it. | ```object({ bucket = string key = string kms_key_arn = string })``` | n/a | yes |
| tfvars\_parameter\_name | SSM SecureString parameter holding the stack's .tfvars.json (non-secret, kept out of git). Both roles read it; neither writes it. | `string` | n/a | yes |
| workflow | Caller workflow file, owner/repo/.github/workflows/<file>.yml. Recorded in the role descriptions; trust itself is the sub claim (see apply\_environment). | `string` | n/a | yes |
| branch | The only branch whose runs may plan or apply. | `string` | `"main"` | no |
| lambda\_pipeline | Also allow the Lambda/SQS/EventBridge pipeline (aws-environments pipeline\_runtime = lambda). | `bool` | `false` | no |
| max\_session\_duration | Seconds a GitHub job may hold either role. | `number` | `3600` | no |
| tags | Tags for the roles and policies. | `map(string)` | `{}` | no |
| tfvars\_kms\_key\_arn | KMS key of the SecureString. null: state.kms\_key\_arn. | `string` | `null` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| apply\_role\_arn | Role the apply job assumes (trusted for workflow on branch in apply\_environment). |
| ci | Non-secret settings for the caller's ci.json. |
| plan\_role\_arn | Role the plan job assumes (trusted for workflow on branch). |
| policies | Policy documents by name (read, plan, apply-*), for review and tests. |
<!-- END_TF_DOCS -->
