# aws/chief-execution-node

One x86 EC2 host that runs a dedicated `agent-relay-node` and the Chief execution bridge side by side, under one service user. Spawned harnesses run as that user.

**Status: not qualified.** The module and its bootstrap have run in one development environment. The bridge has not completed a real assignment.

## What it creates

- One instance: private subnet, no public address, IMDSv2 required with a hop limit of 1, encrypted root volume.
- A security group with no inbound rules and outbound HTTPS only. Operators connect through SSM.
- An IAM role with `AmazonSSMManagedInstanceCore` and read of two secrets, plus `kms:Decrypt` limited to their encryption context.
- Two empty Secrets Manager secrets, `<name>/worker-token` and `<name>/harness-api-key`. Write their values out of band, so they never enter Terraform state.

## Isolation

| Requirement | How it is met |
| --- | --- |
| Token stays out of spawned harnesses' environment | Separate systemd units. `chief-node.service` has no token and no path to one. The token is written by a root-run step to a root-only file that systemd reads for `chief-bridge.service` alone |
| Harness API key reaches spawned harnesses only | A root-run step reads it for `chief-node.service` alone, through a root-only file. The core copies its environment to each harness. The bridge does not receive it. The node starts without a key while the secret is empty |
| Service user has no AWS access | `iptables` owner match drops its traffic to `169.254.169.254`, and that unit is required by both services. Only the root-run step uses the instance role |
| Core reaches only the configured Relay | `RELAY_BASE_URL` is set on the node before any key exists, so an unbound key cannot go to the default public service |
| Scrubbed environment and HOME | systemd starts both units with a fixed environment. `HOME` is `/var/lib/chief-node`, which holds no person's credentials and no MCP servers |

**Same-user limit.** The core socket admits only the same user, so the bridge and the node share one. A spawned agent with shell access can read the bridge's process environment and any file the node can read, including its workspace key. Every spawned agent also receives the harness API key in its environment. Treat all three as reachable by spawned agents.

## After apply

The bootstrap installs everything, applies the core settings the bridge requires and starts the node. It leaves `chief-bridge.service` disabled. Then:

1. Write the worker token into the secret, without printing it.
2. Write the harness API key into its secret, then `systemctl restart chief-node`.
3. Place the workspace key in the node's relay home. The node enrolls itself.
4. Write `/etc/chief-bridge/config.json` with the id and name from `agent-relay-node call spawn.targets`, and `ledgerPath` under `/var/lib/chief-bridge`.
5. Enable `chief-bridge.service`.

Bootstrap runs once. To change it on a running host, use a deliberate replacement.

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
| [aws_iam_instance_profile.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.worker_token](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.ssm](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_instance.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance) | resource |
| [aws_secretsmanager_secret.harness_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret.worker_token](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_ssm_parameter.ami](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |
| [aws_subnet.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| bridge | Public git repository and full commit SHA the execution bridge is built from. | ```object({ repository = string commit = string })``` | n/a | yes |
| harness | npm package, exact version and API key environment variable of the one harness this node runs. | ```object({ npm_package = string version = string api_key_env = optional(string, "ANTHROPIC_API_KEY") })``` | n/a | yes |
| kms\_key\_arn | Key for the root volume and the worker token secret. The key policy must delegate to IAM. | `string` | n/a | yes |
| name | Name of the host and its role, security group and secret. Keep it free of customer names. | `string` | n/a | yes |
| node\_runtime | URL and SHA-256 of a Node.js 22.13+ linux-x64 tar.xz. | ```object({ url = string sha256 = string })``` | n/a | yes |
| relay\_base\_url | Bare https origin of the Relay API. Set on the node so a workspace key can never go to the default public service. | `string` | n/a | yes |
| relay\_node | URL and SHA-256 of the agent-relay-node linux-x64 release binary. Keep it in step with the bridge's core-bridge version. | ```object({ url = string sha256 = string })``` | n/a | yes |
| repositories | GitHub owner/name repositories checked out for spawned agents, under /var/lib/chief-node/repos/<name>. Public repositories only: the host holds no git credential. | `list(string)` | n/a | yes |
| subnet\_id | Private subnet for the host. It needs outbound HTTPS to AWS APIs, the Relay origin, GitHub and npm. | `string` | n/a | yes |
| ami\_id | Exact x86\_64 AMI id. Set exactly one of ami\_id and ami\_ssm\_parameter. | `string` | `null` | no |
| ami\_ssm\_parameter | SSM parameter naming an x86\_64 Amazon Linux 2023 AMI. The image is read once: later releases do not replace the host. | `string` | `"/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"` | no |
| egress\_cidr\_blocks | Destinations allowed for outbound HTTPS. | `list(string)` | ```[ "0.0.0.0/0" ]``` | no |
| iam\_path | Path for the IAM role and instance profile. | `string` | `"/"` | no |
| instance\_type | x86\_64 instance type. The node, the bridge and each spawned harness share this host. | `string` | `"t3.medium"` | no |
| permissions\_boundary\_arn | Permissions boundary for the role, or null. | `string` | `null` | no |
| root\_volume\_size\_gb | Root volume size in GiB. Holds the bridge ledger, the checkouts and the harness login. | `number` | `40` | no |
| tags | Tags for every resource. | `map(string)` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| harness\_key\_secret\_arn | Secret holding the harness API key. Terraform creates it empty; the value is written out of band and never enters state. |
| instance\_id | Target for aws ssm start-session. |
| private\_ip | Private address of the host. It accepts no inbound connections. |
| role\_arn | Instance role: SSM core plus read of the worker token and harness key secrets. |
| security\_group\_id | Security group with no inbound rules and outbound HTTPS only. |
| worker\_token\_secret\_arn | Secret holding the bridge's Relay token. Terraform creates it empty; the value is written out of band and never enters state. |
<!-- END_TF_DOCS -->
