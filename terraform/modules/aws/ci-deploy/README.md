# aws/ci-deploy

Deploy an environment's Helm releases from GitHub Actions without opening the EKS API to GitHub. One instance
per environment (cluster). See [docs/selfhost-ci-deploy.md](../../../../docs/selfhost-ci-deploy.md) for the
workflow, the bundle and the first run.

- **GitHub roles (OIDC).** `plan_role_arn` is trusted for `plan_subjects` (default: the `main` branch only);
  `apply_role_arn` only for jobs in the GitHub environment `apply_environment`, whose required reviewers
  approve every apply and rollback. Each role can only upload a bundle, start its own CodeBuild project and
  read that project's log and report.
- **CodeBuild projects** in the cluster's private subnets run `scripts/selfhost/ci-deploy.sh` from the bundle,
  with pinned, checksummed helm and kubectl. One build at a time per project.
- **Kubernetes access.** plan: `AmazonEKSViewPolicy` in `namespaces` plus get/list on Secrets there (Helm
  release state), from `plan_rbac_manifest`. apply: cluster admin.
- **Artifacts.** A private SSE-KMS bucket: `plan-bundles/`, `apply-bundles/`, `runs/<run>/<mode>/` reports,
  `snapshots/` (pg_dump). RDS snapshots are named `<name>-<run>`.

A plan reads Helm release state, which contains Secrets: never trust `pull_request` for the plan role (the
module refuses it). Pull requests can render offline instead.

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
| terraform | n/a |

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| artifacts | ../object-storage | n/a |

### Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_log_group.builds](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_codebuild_project.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/codebuild_project) | resource |
| [aws_eks_access_entry.build](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_entry) | resource |
| [aws_eks_access_policy_association.apply_admin](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_policy_association) | resource |
| [aws_eks_access_policy_association.plan_view](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_policy_association) | resource |
| [aws_iam_openid_connect_provider.github](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider) | resource |
| [aws_iam_role.build](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.trigger](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.build](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.trigger](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_security_group.builds](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_egress_rule.builds](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.cluster_api](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [terraform_data.guard](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.build](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.build_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.trigger](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.trigger_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| apply\_environment | GitHub environment that gates apply and rollback. Only a job in this environment can start the apply project; set its required reviewers and branch policy in GitHub. | `string` | n/a | yes |
| cluster\_name | EKS cluster the deploy jobs reach through its private endpoint. | `string` | n/a | yes |
| cluster\_security\_group\_id | The cluster security group (aws\_eks\_cluster vpc\_config cluster\_security\_group\_id). The module allows HTTPS to it from the CodeBuild jobs. | `string` | n/a | yes |
| github\_repository | owner/name of the repository whose workflows deploy (it holds the environment's values). | `string` | n/a | yes |
| kms\_key\_arn | Customer managed KMS key for the artifact bucket and the build logs. Its key policy must allow the CloudWatch Logs service for the log group. | `string` | n/a | yes |
| name | Prefix for every resource, e.g. agentrelay-dev-deploy. One module instance per environment (one EKS cluster). | `string` | n/a | yes |
| namespaces | Namespaces holding the releases this environment deploys. The plan job may read them (helm release state); apply is cluster-wide. | `list(string)` | n/a | yes |
| subnet\_ids | Private subnets (with NAT egress) the CodeBuild jobs run in. | `list(string)` | n/a | yes |
| vpc\_id | VPC of the cluster. | `string` | n/a | yes |
| artifact\_retention\_days | Days bundles and run reports are kept. | `number` | `90` | no |
| build\_image | CodeBuild image. The build installs pinned helm, kubectl and a PostgreSQL client itself. | `string` | `"aws/codebuild/amazonlinux-x86_64-standard:5.0"` | no |
| build\_timeout\_minutes | Upper bound for one plan or apply (helm --wait, snapshot). | `number` | `60` | no |
| compute\_type | CodeBuild compute type. | `string` | `"BUILD_GENERAL1_SMALL"` | no |
| create\_github\_oidc\_provider | Create the account's token.actions.githubusercontent.com OIDC provider. false: pass github\_oidc\_provider\_arn (an account has at most one). | `bool` | `true` | no |
| github\_oidc\_provider\_arn | Existing GitHub OIDC provider, when create\_github\_oidc\_provider is false. | `string` | `null` | no |
| plan\_subjects | GitHub OIDC subjects allowed to start a plan. A plan reads the live release, whose storage holds Secrets, so keep it to protected refs: null means the default branch main only. Never add pull\_request: a pull request would run its own bundle with this read access. | `list(string)` | `null` | no |
| rds\_instance\_identifiers | RDS instances the apply job snapshots before an upgrade. Empty: no RDS snapshot permission. | `list(string)` | `[]` | no |
| snapshot\_retention\_days | Days pg\_dump snapshots written by apply are kept (RDS snapshots are managed in RDS). | `number` | `35` | no |
| tags | Tags for every resource. | `map(string)` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| apply\_project | CodeBuild project the apply role starts (apply and rollback). |
| apply\_role\_arn | Role GitHub assumes for apply and rollback (trusted only for apply\_environment). |
| bucket\_name | Artifact bucket: plan-bundles/, apply-bundles/, runs/<run>/<mode>/ reports, snapshots/. |
| log\_group | CloudWatch log group of both projects (streams plan/<build> and apply/<build>). |
| plan\_project | CodeBuild project the plan role starts. |
| plan\_rbac\_manifest | Role and RoleBinding letting the plan job read Helm release state (Secrets) in var.namespaces. kubectl apply -f once; the apply job re-applies it. |
| plan\_role\_arn | Role GitHub assumes for plan (trusted for plan\_subjects). |
<!-- END_TF_DOCS -->
