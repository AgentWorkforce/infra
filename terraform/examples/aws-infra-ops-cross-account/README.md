# examples/aws-infra-ops-cross-account

A standing admin role in one AWS account for the infra operator (the
layered-infra-ops agent), assumable only by the operator's own admin role in its
home account. The operator's home account has one admin role, created by the
layered-agents infrastructure; this root is applied once per other account the
operator must reach, and gives it the same grant there.

The trust names the operator's role by exact ARN: no account root, no wildcard,
no user. `sts:TagSession` is allowed so the caller's session tags pass through.
The home side needs nothing: AdministratorAccess already allows
`sts:AssumeRole`, and this root changes nothing about the home role.

## Bootstrap, by hand, once per account

The first apply into an account must run as a principal that already has IAM
access there (a human administrator), because the operator cannot reach the
account yet. From a checkout of this repository, in that account:

```sh
cp terraform.tfvars.example terraform.tfvars   # the account and the operator's role ARN
terraform init -backend-config=...             # a state bucket in that account
terraform plan -out tfplan
terraform apply tfplan
terraform output role_arn                      # hand to the operator
```

The operator then verifies from its host, with its default profile:

```sh
aws sts assume-role --role-arn <role_arn> --role-session-name verify --query AssumedRoleUser.Arn
```

and adds `terraform output -raw aws_config_profile` to its `~/.aws/config`.

After the bootstrap the operator can re-apply this root itself (for example to
re-trust a recreated home role), but a change to the trust or the grant is a
change to the operator's own access and stays a hand apply by the account's
owner. `terraform destroy` removes the access and nothing else.

IAM stores the trusted principal by its unique id. If the home role is deleted
and recreated, the trust stops matching (the console shows an `AROA...` id)
until this root is applied again.

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
| [aws_iam_role.operator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.operator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | The account that gets the operator role. The provider refuses any other. | `string` | n/a | yes |
| trusted\_role\_arns | The operator's own admin role(s), by exact role ARN, in its home account. Only these may assume the role: no account root, no wildcard, no user. | `list(string)` | n/a | yes |
| external\_id | Optional sts:ExternalId the operator must present. Not a secret; a guard against a mis-targeted assume-role. | `string` | `null` | no |
| max\_session\_duration | Longest session the operator may request, in seconds (1 to 12 hours). | `number` | `3600` | no |
| permissions\_boundary\_arn | Optional permissions boundary for the role. | `string` | `null` | no |
| policy\_arns | Managed policies attached to the role. The default is the same grant the operator has in its home account. | `list(string)` | ```[ "arn:aws:iam::aws:policy/AdministratorAccess" ]``` | no |
| region | Provider region. IAM is global; this only picks the STS/IAM endpoint. | `string` | `"us-west-2"` | no |
| role\_name | Name of the operator role in this account. | `string` | `"layered-infra-ops"` | no |
| role\_path | IAM path for the role. | `string` | `"/"` | no |
| tags | Tags for the role. | `map(string)` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| aws\_config\_profile | A ~/.aws/config profile for the operator (its default profile is the trusted role). |
| role\_arn | The operator role. Assume it from the trusted role: aws sts assume-role --role-arn <this> --role-session-name <who>. |
| role\_name | The operator role's name. |
<!-- END_TF_DOCS -->
