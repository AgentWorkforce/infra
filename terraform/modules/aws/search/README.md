# aws/search

**Optional.** An Amazon OpenSearch Service **VPC domain** as the transcript search index. It replaces ClickHouse; the default stays Postgres `pg_trgm`. It is meant for the sessions pipeline's OpenSearch `SearchIndexAdapter` (sessions-pipeline-cloud); the charts set no value for it.

- VPC domain in your subnets and security groups. Zone awareness follows the number of subnets (2 or 3).
- Encryption at rest (customer key optional), node-to-node encryption, HTTPS enforced with `Policy-Min-TLS-1-2-PFS-2023-10`.
- Fine-grained access control with an **IAM master user** (`master_user_arn`). There is no internal user database and no anonymous access.
- Sized for per-event transcript text: 3 `r7g.large.search` data nodes (4 with two subnets, a multiple of the AZ count) with 200 GiB gp3 each, plus 3 dedicated `m7g.large.search` cluster managers. Every size is a variable.
- **Destroy guard:** default domains retain literal `prevent_destroy=true`; the unindexed historical address moves to `aws_opensearch_domain.this[0]`. New synthetic fixtures may explicitly select `disposable=true` and retire through a reviewed Terraform destroy with state intact. An unconditional built-in `terraform_data.creation_mode` stores the selected mode and rejects ordinary flips after correct enrollment. Its destruction remains allowed so disposable teardown works. Never use disposable mode for durable/customer data.
- **Old/unmarked states remain held for independently reviewed unchanged-mode enrollment.** The marker cannot prove historical mode when first added. The two known reviewed AWS runners additionally classify exact native saved-plan prior state and before IDs: an unmarked domain may enroll only its existing branch, with the same ID, all search AWS resources no-op and only the fixed marker created. The qualification is `legacy-or-missing-marker unchanged-domain`: a single snapshot cannot distinguish genuine legacy from an earlier lost marker. Unmarked destroy, a mode flip, mixed/deposed/unknown history, mismatched IDs, marker replacement or marker-only removal while the domain survives is refused. An enrolled full owned disposable destroy deletes its marker and all managed search objects together. Protected retirement still needs a separately reviewed source/lifecycle change.
- This is source/plan history validation, not remote backend attestation or a guard against an operator removing source/state or replacing the marker with raw Terraform. Standalone Terraform cannot enforce first legacy-enrollment provenance. Do not state-rm, natively delete, blindly upgrade/adopt old state, or silently repin existing proof source/inputs to bypass a refusal.

- Two workload roles trusted by EKS Pod Identity (and IRSA): **indexer** (the sessions-pipeline search stage: `ESHttpGet/Head/Post/Put/Delete/Patch`) and **reader** (the session read API: `ESHttpGet/Head/Post`). With the master user, map them as `backend_roles` to OpenSearch roles scoped to the transcript indices.
- Pod Identity allows one role per ServiceAccount. When the pod already has a role, set `workload_roles = { create = false }`, attach `indexer_policy_json` / `reader_policy_json` to that role, and list it in `additional_principal_arns`. Do not attach the indexer policy to a role shared with pods that only read. `examples/aws` binds the two roles to their own `indexer_service_account` and `reader_service_account`.
- Application, search-slow and index-slow logs go to CloudWatch. Add `AUDIT_LOGS` once audit logging is configured in the security plugin.
- Prerequisite: the `AWSServiceRoleForAmazonOpenSearchService` service-linked role.

The mandatory pure classifier is `creation_mode.py`; it accepts only native saved-plan `show -json` objects for exact `module.search` addresses used by `examples/aws-environments` and `examples/aws-search-proof`. It accepts no caller mode, path override, skip flag or digest as authority. Both runner paths check before publishing the plan receipt and again before apply; existing exact-plan review, source/input seals and state locks remain required. Search-proof's closed AWS address/action contract remains unchanged apart from the new built-in marker.

Offline validation separates native HCL history from classifier fixtures. Both pinned engines run shared-root creation/flip/same-mode/ordinary disposable mock-teardown checks. The separate manual Terraform legacy cross-module harness requires historical Git commit `d3040fa209ef5c90ce61bde2a776f783c01cfaba`; it was replayed locally, and is not newly required by shallow-checkout CI. OpenTofu 1.11.14 lacks `state_key`, so equivalent native legacy history remains unproven. `test_plan` UI output is not saved-plan JSON and omits prior state. Pure classifier tests use explicit saved-plan schema fixtures and exact native built-in marker fragments from offline `show -json`; they do not claim a full AWS saved-plan or cloud proof. Primary schemas: [lifecycle](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle), [saved-plan JSON](https://developer.hashicorp.com/terraform/internals/json-format).

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
| terraform | n/a |

### Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_log_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_resource_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_resource_policy) | resource |
| [aws_eks_pod_identity_association.workload](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_iam_role.workload](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.workload](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_opensearch_domain.disposable](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/opensearch_domain) | resource |
| [aws_opensearch_domain.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/opensearch_domain) | resource |
| [aws_opensearch_domain_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/opensearch_domain_policy) | resource |
| [terraform_data.creation_mode](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| domain\_name | OpenSearch domain name (3-28 characters, lowercase letter first). | `string` | n/a | yes |
| master\_user\_arn | IAM principal ARN that becomes the fine-grained access control master user (an admin role, not a workload role). It maps the indexer and reader roles to OpenSearch roles; see the README. | `string` | n/a | yes |
| security\_group\_ids | Existing security groups for the domain ENIs. Allow TCP 443 only from the indexer and read API pods (or their nodes). | `list(string)` | n/a | yes |
| subnet\_ids | Private subnets for the VPC domain, one per Availability Zone (2 or 3). The zone awareness count follows their number. | `list(string)` | n/a | yes |
| additional\_principal\_arns | Extra IAM principals allowed to send HTTP requests to the domain (still subject to fine-grained access control). | `list(string)` | `[]` | no |
| advanced\_options | Extra OpenSearch advanced options. | `map(string)` | `{}` | no |
| auto\_software\_update\_enabled | Apply service software updates in the off-peak window. | `bool` | `true` | no |
| automated\_snapshot\_start\_hour | Hour (UTC) of the daily automated snapshot. Ignored by OpenSearch 5.3+ domains, which take hourly snapshots. | `number` | `3` | no |
| create\_log\_resource\_policy | Create the CloudWatch Logs resource policy that lets OpenSearch write to the log groups. Disable when the account manages one centrally (the per-region limit is 10). | `bool` | `true` | no |
| dedicated\_master\_count | Cluster manager nodes (3 or 5). | `number` | `3` | no |
| dedicated\_master\_enabled | Dedicated cluster manager nodes (recommended for production). | `bool` | `true` | no |
| dedicated\_master\_type | Cluster manager node type. | `string` | `"m7g.large.search"` | no |
| disposable | Explicitly create a new disposable domain with Terraform destruction enabled. Defaults to protected. Stored-mode enrollment blocks later ordinary flips; unmarked existing states require independently reviewed unchanged-mode enrollment. Raw Terraform cannot prove first-enrollment history. | `bool` | `false` | no |
| ebs\_iops | Provisioned IOPS for gp3 (null uses the baseline). | `number` | `null` | no |
| ebs\_throughput | Provisioned throughput (MiB/s) for gp3 (null uses the baseline). | `number` | `null` | no |
| ebs\_volume\_size | gp3 volume per data node in GiB. Size for the transcript text plus replicas plus ~25% headroom. | `number` | `200` | no |
| ebs\_volume\_type | EBS volume type. | `string` | `"gp3"` | no |
| engine\_version | Engine version (OpenSearch\_X.Y). | `string` | `"OpenSearch_2.19"` | no |
| instance\_count | Data nodes, a multiple of the subnet (AZ) count. null picks the smallest multiple that is at least 3 (3 for one or three AZs, 4 for two). | `number` | `null` | no |
| instance\_type | Data node type. Memory-optimized (r7g) fits a full-text index of transcript events; use or1/or2 (OpenSearch Optimized) for heavy ingest. | `string` | `"r7g.large.search"` | no |
| kms\_key\_arn | Customer managed KMS key for encryption at rest. null uses the AWS managed aws/es key. | `string` | `null` | no |
| log\_kms\_key\_arn | KMS key for the log groups (its key policy must allow CloudWatch Logs). null uses CloudWatch's default encryption. | `string` | `null` | no |
| log\_publishing | CloudWatch log types to publish (ES\_APPLICATION\_LOGS, SEARCH\_SLOW\_LOGS, INDEX\_SLOW\_LOGS, AUDIT\_LOGS). Empty disables log publishing. | `list(string)` | ```[ "ES_APPLICATION_LOGS", "SEARCH_SLOW_LOGS", "INDEX_SLOW_LOGS" ]``` | no |
| log\_retention\_days | Retention of the published log groups. | `number` | `30` | no |
| multi\_az\_with\_standby\_enabled | Multi-AZ with Standby (needs 3 AZs, dedicated masters and a multiple of 3 data nodes). | `bool` | `false` | no |
| off\_peak\_window\_start | Off-peak window start (UTC) for service software updates and Auto-Tune. | ```object({ hours = number minutes = number })``` | ```{ "hours": 7, "minutes": 0 }``` | no |
| tags | Tags applied to every resource. | `map(string)` | `{}` | no |
| tls\_security\_policy | Minimum TLS policy for the HTTPS endpoint. | `string` | `"Policy-Min-TLS-1-2-PFS-2023-10"` | no |
| workload\_roles | The two workload roles the module creates, trusted by EKS Pod Identity (and IRSA when oidc\_provider\_arn is set): indexer (the sessions-pipeline search stage: writes transcript events) and reader (the session read API: searches). Set create = false to skip them: attach indexer\_policy\_json / reader\_policy\_json to existing roles and list them in additional\_principal\_arns. EKS Pod Identity allows one association per ServiceAccount, so a ServiceAccount that already has a role (the sessions worker has the bucket role) needs a separate ServiceAccount for search. | ```object({ create = optional(bool, true) name_prefix = optional(string) path = optional(string, "/") permissions_boundary_arn = optional(string) oidc_provider_arn = optional(string) indexer_service_accounts = optional(list(object({ cluster_name = optional(string) namespace = string service_account = string })), []) reader_service_accounts = optional(list(object({ cluster_name = optional(string) namespace = string service_account = string })), []) })``` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| dashboard\_endpoint | OpenSearch Dashboards host inside the VPC. |
| domain\_arn | Domain ARN. |
| domain\_name | Domain name. |
| endpoint | Private VPC HTTPS endpoint host (no scheme). https://<endpoint> is meant for the sessions pipeline's OpenSearch SearchIndexAdapter (no chart value). |
| indexer\_policy\_json | The indexer's IAM policy, to attach to an existing role (EKS Pod Identity allows one role per ServiceAccount, so a pod that already has a role gets this policy on that role). |
| indexer\_role\_arn | Indexer workload role (Pod Identity). Map it to an OpenSearch role with write permissions on the transcript indices (backend\_roles) using the master user. |
| pod\_identity\_association\_ids | Pod Identity associations created, keyed by role/cluster/namespace/service-account. |
| reader\_policy\_json | The reader's IAM policy, to attach to an existing role. |
| reader\_role\_arn | Read API workload role (Pod Identity). Map it to an OpenSearch role with read permissions on the transcript indices. |
| url | https://<endpoint>. |
<!-- END_TF_DOCS -->
