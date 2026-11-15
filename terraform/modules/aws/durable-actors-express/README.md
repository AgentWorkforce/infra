# aws/durable-actors-express

Durable-actors state on **S3 Express One Zone**, with an asynchronous checkpoint to a regional **S3 Standard** bucket, plus the IAM to reach both with least privilege.

| resource | purpose |
| --- | --- |
| `aws_s3_directory_bucket.express` | `<name>--<az id>--x-s3`: low-latency actor state, in one zone |
| `module.checkpoint` (`aws/object-storage`) | regional bucket: async copy of the Express bucket, plus compiled actor artifacts. Versioned, SSE-KMS, TLS-only, public access blocked |
| `aws_iam_role.actor` | actor storage role, assumable only by the control plane, which narrows every session to one actor |
| `aws_iam_role_policy.control_plane` | inline policy on the existing control-plane role |
| `aws_iam_role_policy.deployer` | create-only artifact upload for each relaycast/relayfile deployer role |
| `aws_s3_bucket_policy.express` | denies `s3express:CreateSession` to everyone but the control plane, the actor role and named operators |

## Express permissions

Directory buckets do not evaluate `s3:*` object actions. A principal calls `s3express:CreateSession` on the bucket, and that session authorizes object reads and writes. Every Express grant here is `CreateSession` on exactly one directory bucket ARN.

- **Control plane:** a `ReadWrite` session for its own bucket access.
- **Actor role:** the ceiling for actor hosts. The control plane assumes it per actor, attaching an inline session policy. That policy grants `CreateSession` on this bucket (`ReadOnly` session mode for read-only scopes) and only the actor's own prefixes on the checkpoint and artifact bucket (durable-actors `s3_access.rs`, AgentWorkforce/durable-actors#4).
- **Deployers:** no Express access.

IAM cannot narrow `CreateSession` to a key prefix, so actors are isolated per bucket on Express and per prefix on the regional copy. TerseAI/durable-actors#273 adds per-actor isolation on Express through control-plane-signed per-object URLs. Hosts then hold no Express credentials, and the `ExpressSessions` statement can be dropped from the actor role.

## Zone choice

`express_az_id` is an Availability Zone **ID**. AZ names map to different IDs in each account; in ours, `us-west-2a` is `usw2-az2`, which has no S3 Express.

- The plan fails for zone IDs that are not in `express_supported_az_ids`, and for zone names.
- `express_zone_name` (output) is this account's name for the zone. Pin the actor node group and durable-actors `placement.zone` to it, so hosts stay in the same zone as their state.

## Single-zone risk

Losing the Express zone loses whatever the checkpoint had not copied yet. The checkpoint copies in the background and logs its lag as `event="storage_checkpoint"` / `storage_checkpoint_lag_exceeded`. The RPO and the recovery runbook (`durable-actors checkpoint-restore`) are in durable-actors `docs/s3-express-checkpoint.md`. To restore into a new Express bucket, apply this module with a new `express_az_id`.

## Usage

```hcl
module "actors_express" {
  source = "../../modules/aws/durable-actors-express"

  name                    = "relay-actors"
  express_az_id           = "usw2-az1"
  checkpoint_bucket_name  = "relay-actors-regional"
  control_plane_role_name = "relay-actors-control-plane"
  deployer_role_names     = ["relaycast-actors-deployer", "relayfile-actors-deployer"]
  kms_key_arn             = module.foundation.kms_key_arn
}
```

`durable_actors_values` (output) has the durable-actors chart values: `storage.bucket`, `storage.artifactBucket`, `storage.s3.{region,actorRoleArn,checkpoint.bucket}`, and `placement.zone`. Set the relaycast and relayfile `runtime.durableActors.deployer.artifactBucket` to `checkpoint_bucket`.

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

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| checkpoint | ../object-storage | n/a |

### Resources

| Name | Type |
| ---- | ---- |
| [aws_iam_role.actor](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.actor](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.control_plane](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.deployer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_s3_bucket_policy.express](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_directory_bucket.express](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_directory_bucket) | resource |
| [aws_availability_zone.express](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zone) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_role.control_plane](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_role) | data source |
| [aws_iam_session_context.operator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_session_context) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| checkpoint\_bucket\_name | Regional S3 Standard bucket that asynchronously checkpoints the Express bucket and holds compiled actor artifacts. | `string` | n/a | yes |
| control\_plane\_role\_name | Existing IAM role of the durable-actors control plane (EKS Pod Identity or IRSA). Gets an inline policy; the role itself is not managed here. | `string` | n/a | yes |
| express\_az\_id | Availability Zone ID (not name) of the S3 Express One Zone directory bucket, e.g. usw2-az1. AZ names map to different IDs in each account, so use the ID: in our account us-west-2a is usw2-az2, which has no S3 Express. Place the actor node group in the same zone. | `string` | n/a | yes |
| name | Name prefix for the Express directory bucket (<name>--<az id>--x-s3) and the actor storage role. | `string` | n/a | yes |
| actor\_role\_permissions\_boundary\_arn | Optional permissions boundary for the actor storage role. | `string` | `null` | no |
| checkpoint\_noncurrent\_version\_expiration\_days | Days the checkpoint bucket keeps overwritten owner records, for point-in-time recovery from a bad write. | `number` | `7` | no |
| deployer\_role\_names | Existing IAM roles of the relaycast/relayfile actor deployers. Each gets create-only artifact upload on the checkpoint bucket and nothing on Express. | `list(string)` | `[]` | no |
| express\_operator\_principal\_arns | Extra role ARNs allowed to open Express sessions (break-glass, `durable-actors checkpoint-restore`). The directory bucket policy denies every other principal. | `list(string)` | `[]` | no |
| express\_supported\_az\_ids | Availability Zone IDs that offer S3 Express One Zone. Extend when AWS adds zones; usw2-az2 is deliberately absent. | `list(string)` | ```[ "use1-az4", "use1-az5", "use1-az6", "usw2-az1", "usw2-az3", "usw2-az4", "apne1-az1", "apne1-az4", "eun1-az1", "eun1-az2", "eun1-az3" ]``` | no |
| kms\_key\_arn | Customer-managed KMS key for the checkpoint bucket (null: the AWS-managed aws/s3 key). The roles get Decrypt/GenerateDataKey on it. | `string` | `null` | no |
| storage\_prefix | durable-actors object root. | `string` | `"durable-actors/v3/"` | no |
| tags | Tags applied to every resource. | `map(string)` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| actor\_role\_arn | Actor storage role. Feeds storage.s3.actorRoleArn (actorCredentials: assume-role). |
| checkpoint\_bucket | Regional checkpoint and artifact bucket. Feeds storage.s3.checkpoint.bucket, storage.artifactBucket and the relaycast/relayfile deployer artifactBucket. |
| durable\_actors\_values | durable-actors chart values for this storage. |
| express\_bucket | S3 Express directory bucket. Feeds durable-actors storage.bucket. |
| express\_bucket\_arn | s3express ARN of the directory bucket (the only resource s3express:CreateSession is granted on). |
| express\_zone\_name | This account's name for the Express zone. Pin the actor node group (durable-actors placement.zone) here. |
<!-- END_TF_DOCS -->
