# examples/aws-existing-cluster

The AWS services Agent Relay needs, added to a VPC and EKS cluster you already
run. It changes nothing in your VPC, subnets or cluster.

| Creates | Default |
|---|---|
| RDS PostgreSQL 17 | db.r7g.large, Multi-AZ, 35-day backups, deletion protection, private, TLS only |
| S3 bucket for session data | Versioned, TLS only, accessed through EKS Pod Identity (no static keys) |
| Amazon OpenSearch (optional) | 3 × r7g.large.search data nodes with dedicated managers, VPC only |
| ACM certificate | `<domain>`, `api.<domain>`, `cast.<domain>`, `history.<domain>` |

Every service is encrypted at rest, with AWS-managed keys unless you set
`kms_key_arn`. No password is stored in Terraform state: the RDS admin password
lives in Secrets Manager.

## Before you apply

- EKS add-ons: Pod Identity Agent, EBS CSI driver, AWS Load Balancer Controller.
- Private subnets in two Availability Zones for the database, and three for OpenSearch.
- A security group for the database (TCP 5432 from the cluster) and one for OpenSearch (TCP 443 from the cluster).
- An IAM role to administer OpenSearch, and the OpenSearch service-linked role
  (`aws iam create-service-linked-role --aws-service-name opensearchservice.amazonaws.com`).

## Apply

```sh
cp terraform.tfvars.example terraform.tfvars   # fill in your IDs
terraform init
terraform plan -out tfplan
terraform apply tfplan
terraform output certificate_dns_records       # add these to your DNS
```

Use your usual remote state backend: add a `backend "s3"` block, or pass
`-backend-config` to `terraform init`.

The outputs feed the Helm install: `database_host`, `sessions_bucket`,
`search_url` and `certificate_arn`. Install the chart with the `release_name` and
`namespace` set here, because Pod Identity binds to the ServiceAccount names. If
you change `release_name` from `agent-relay`, also set these chart values to
`<release>-search-indexer`, `<release>-session-read` and
`<release>-session-ingest-api`: `sessions-pipeline.searchIndexer.serviceAccount.name`,
`sessions-pipeline.sessionReadApi.serviceAccountName` (with
`serviceAccountCreate: true`) and `sessions-pipeline.ingestEdge.serviceAccountName`.

With search on, map `search_roles` to OpenSearch roles as the admin role before
the first install: see "After apply" in
[`modules/aws/search/README.md`](../../modules/aws/search/README.md).

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

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| database | ../../modules/aws/postgres | n/a |
| search | ../../modules/aws/search | n/a |
| sessions\_bucket | ../../modules/aws/object-storage | n/a |

### Resources

| Name | Type |
| ---- | ---- |
| [aws_acm_certificate.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate) | resource |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | AWS account to install into. Terraform refuses to run against any other account. | `string` | n/a | yes |
| database\_security\_group\_id | Security group for the database. Allow TCP 5432 from your EKS nodes or pods. | `string` | n/a | yes |
| database\_subnet\_ids | Private subnets for the database, in at least two Availability Zones. | `list(string)` | n/a | yes |
| domain | Hostname for the app, e.g. ar.example.com. The certificate also covers api., cast. and history. under it. | `string` | n/a | yes |
| eks\_cluster\_name | Name of your existing EKS cluster. | `string` | n/a | yes |
| region | AWS region of your EKS cluster, e.g. us-east-1. | `string` | n/a | yes |
| sessions\_bucket\_name | Name for the new S3 bucket that holds session data. Must be globally unique. | `string` | n/a | yes |
| database\_backup\_retention\_days | Days of automated database backups (point-in-time recovery). | `number` | `35` | no |
| database\_instance\_class | RDS instance class. | `string` | `"db.r7g.large"` | no |
| enable\_search | Create an Amazon OpenSearch domain for transcript search. | `bool` | `true` | no |
| kms\_key\_arn | Your KMS key for the database, bucket and search. null uses AWS-managed keys. | `string` | `null` | no |
| name | Prefix for every resource name. | `string` | `"agent-relay"` | no |
| namespace | Kubernetes namespace the Helm chart installs into. | `string` | `"agent-relay"` | no |
| release\_name | Helm release name. The chart names its ServiceAccounts after it, and Pod Identity binds to those names. | `string` | `"agent-relay"` | no |
| search\_admin\_role\_arn | Existing IAM role that administers OpenSearch access. Not used by the app at runtime. | `string` | `null` | no |
| search\_instance\_type | OpenSearch data node type. | `string` | `"r7g.large.search"` | no |
| search\_security\_group\_id | Security group for OpenSearch. Allow TCP 443 from your EKS nodes or pods. | `string` | `null` | no |
| search\_subnet\_ids | Private subnets for OpenSearch, one per Availability Zone (three recommended). | `list(string)` | `[]` | no |
| tags | Tags added to every resource. | `map(string)` | ```{ "app": "agent-relay" }``` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| certificate\_arn | ACM certificate for the app's hostnames. Pass it to the Helm install. |
| certificate\_dns\_records | Create these CNAME records in your DNS to validate the certificate. |
| database\_admin\_secret\_arn | Secrets Manager secret holding the RDS admin password. Used once, for database setup. |
| database\_host | RDS endpoint. |
| search\_roles | OpenSearch indexer (write) and reader (read-only) roles (null when search is off). |
| search\_url | OpenSearch endpoint (null when search is off). |
| sessions\_bucket | S3 bucket for session data. |
| sessions\_role\_arn | IAM role the app uses for the bucket, bound through EKS Pod Identity. |
<!-- END_TF_DOCS -->
