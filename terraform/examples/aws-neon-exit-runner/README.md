# aws-neon-exit-runner

One short-lived EC2 runner for copying the legacy sessions schema out of Neon
into its Supabase target. Nothing here is product infrastructure: apply it for
the copy, terminate it with `terraform destroy` after the seal.

What it creates, in one account and region:

- a private subnet in an existing VPC, a NAT gateway (plus EIP) in an existing
  public subnet, and a route table for egress;
- a security group with **no ingress**; egress only on 443, 5432, 6543 and DNS;
- an empty Secrets Manager secret for the target database owner credential.
  Its value is written out of band (`aws secretsmanager put-secret-value`) by
  whoever holds it, never through this configuration or a chat channel;
- an empty Secrets Manager secret for the Cloud copy connection URLs
  (`neon-exit/cloud/copy-urls`), also written out of band. The runner fetches
  it on the box, so no connection URL appears in SSM command history;
- an instance role with `AmazonSSMManagedInstanceCore` and read of those two
  secrets only, and the instance profile;
- one `m6id.4xlarge` (16 vCPU, 64 GB, 950 GB NVMe) on Amazon Linux 2023,
  IMDSv2 only, encrypted root, with the NVMe mounted at `/scratch` and
  `postgresql17` client, `zstd`, `git`, `jq` and `nodejs22` installed.

Access is Session Manager only: `aws ssm start-session --target <instance_id>`
from a principal with `ssm:StartSession` on the instance. On the runner,
`target-secret` prints the secret to the shell (it needs the instance role).

```sh
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
# ... copy ...
terraform destroy -var-file=terraform.tfvars
```

Approximate on-demand cost in us-east-1: the instance about $0.95 per hour,
the NAT gateway about $0.045 per hour plus $0.045 per GB processed.

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
| [aws_eip.nat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eip) | resource |
| [aws_iam_instance_profile.runner](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_role.runner](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.secret_read](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.ssm](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_instance.runner](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance) | resource |
| [aws_nat_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/nat_gateway) | resource |
| [aws_route.private_default](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route_table.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table_association.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_secretsmanager_secret.copy_urls](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret.db_owner](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_subnet.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_vpc_security_group_egress_rule.dns_tcp](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.dns_udp](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.https](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.postgres](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.postgres_pooler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_iam_policy_document.assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.secret_read](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_ssm_parameter.ami](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |
| [aws_vpc.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | AWS account the runner lives in; the provider refuses any other. | `string` | n/a | yes |
| public\_subnet\_id | Existing public subnet (route to an internet gateway) that hosts the NAT gateway. | `string` | n/a | yes |
| vpc\_id | VPC that gets the private subnet and the NAT gateway. | `string` | n/a | yes |
| ami\_ssm\_parameter | SSM public parameter that resolves to the AMI. | `string` | `"/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"` | no |
| availability\_zone | AZ of the private subnet; the instance type must be offered there. | `string` | `"us-east-1a"` | no |
| copy\_urls\_secret\_name | Secrets Manager name of the Cloud copy connection URLs. Created empty; written out of band and read on the runner. | `string` | `"neon-exit/cloud/copy-urls"` | no |
| db\_owner\_secret\_name | Secrets Manager name of the target database owner credential. Created empty; the value is written out of band by whoever holds it. | `string` | `"neon-exit/relayhistory-legacy/postgres-owner"` | no |
| instance\_type | Instance type with local NVMe for the dump. | `string` | `"m6id.4xlarge"` | no |
| name | Name prefix for every resource. | `string` | `"neon-exit-runner"` | no |
| private\_subnet\_cidr | CIDR of the new private subnet; must be free inside the VPC. | `string` | `"172.31.96.0/20"` | no |
| region | Region of the runner. us-east-1 keeps it next to the Neon and Supabase projects. | `string` | `"us-east-1"` | no |
| root\_volume\_size\_gb | Root EBS volume size. The dump goes to the NVMe instance store at /scratch, not here. | `number` | `50` | no |
| tags | Tags applied to every resource. | `map(string)` | ```{ "ephemeral": "true", "managed": "terraform", "project": "neon-exit" }``` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| copy\_urls\_secret\_arn | Secrets Manager ARN of the empty Cloud copy URLs secret. |
| copy\_urls\_secret\_name | Secrets Manager name of the Cloud copy URLs secret. |
| db\_owner\_secret\_arn | Secrets Manager ARN of the empty target credential. |
| db\_owner\_secret\_name | Secrets Manager name of the target credential. |
| instance\_id | Runner instance id (target of ssm start-session). |
| nat\_gateway\_id | Id of the NAT gateway that gives the private subnet outbound access. |
| private\_subnet\_id | Id of the private subnet the runner instance launches in. |
| runner\_role\_arn | Instance role: SSM core plus read of the two exit secrets. |
| security\_group\_id | Id of the runner security group (no ingress; HTTPS egress only). |
| ssm\_session\_command | Shell on the runner for a principal allowed ssm:StartSession on it. |
<!-- END_TF_DOCS -->