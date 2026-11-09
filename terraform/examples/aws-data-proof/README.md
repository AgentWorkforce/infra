# Disposable AWS PostgreSQL/S3 module proof — held source

This root composes the actual `modules/aws/postgres` and `object-storage`
modules in a reviewed existing VPC. It prepares a private encrypted PostgreSQL17
instance, its owned subnet/parameter groups, versioned SSE-KMS bucket, synthetic
sentinel, two dedicated security groups, and a temporary ARM verifier with its
own launch template, encrypted delete-on-termination disk/ENI and boundary-capped
`/pippen/workload/` role plus `eks-*` instance profile. An optional mode owns two
private subnets, one local-only route table and their two explicit associations
in the reviewed existing default VPC. It changes no existing VPC, subnet, route
table, application, role, cluster, baseline policy or provider source.

**Source only / held draft. No live plan, apply, credential retrieval, SQL,
cloud call or runtime proof was performed by this source lane.** An authorized
parent operator owns exact private inputs, saved-plan review, execution deadline,
receipts and cleanup. The prior auxiliary Linux/PG fixture is independent.

This proves a module/storage/restore *test composition*, not an application
installer. The guest tests real PostgreSQL17 TLS CA/hostname validation and
plaintext/wrong-CA/wrong-host refusals; private/encrypted native RDS metadata;
`pg_trgm` and `vector` installation; a synthetic marker and restricted login with
real SELECT plus write/other-table/schema/role-creation refusals. S3 checks cover
SSE-KMS put/get/list, two object versions, a delete marker and version recovery,
multipart upload/abort and scoped Get/Put/Delete/List refusals. Its exact version
ledger is cleaned; unknown versions prevent any deletion. The parent independently
compares the unrelated sentinel's bytes/version before allowing final retirement.
The sentinel waits for the complete object-storage module, including versioning,
encryption, ownership/public-access controls, TLS policy and lifecycle setup. Its
postcondition rejects a missing, empty or literal `null` VersionId. Service
propagation can still fail the operation; preserve partial state/native version
evidence for reconciliation rather than accepting an unversioned sentinel.

No master `SELECT 1`, fake RDS emulation or schema mock constitutes runtime
application proof. Bulls' actual RDS/HoopDb migration, roles/column grants,
`HOOPDB_DB_MODE=rds` integration and exact provider composition remain separate
owner-reviewed acceptance. This root never imports those protected SQL files,
changes migration/generation/versions.lock, or bundles a private provider.
OpenSearch, Lambda service/provider and the full suite remain unproved.

## Review and execution stages

These are future operator steps, **not an instruction to apply this draft**.
Use a new private state/execution directory on T7 (0700, encrypted disk, private
backups); retain state until native retirement is proved. Local state is explicit
for this disposable root. Durable customer foundation/data state remains separate
and external. Never use the proof bucket as its own state backend or import old
AWS resources. Provider account restriction plus exact lease caller guard must
remain enabled. No saved credential profile/static credentials belong here.

1. Independently review non-secret lease/account/region, exact available PG17
   minor and instance classes, pinned Amazon AL2023 ARM AMI, existing VPC/subnet
   ownership/AZs/routes, permissions/boundary, quotas and public regional RDS CA
   bundle digest. Select exactly one network mode: two reviewed existing private
   AZ subnets (`private_subnet_ids`), or `create_private_subnets` with exactly two
   explicit canonical IPv4 /24-/28 CIDRs and distinct available AZs in the existing
   default VPC. Do not change modes after provisioning. The created CIDRs must fit
   its primary IPv4 CIDR and overlap neither each other nor any existing subnet.
   Fresh inventory/ownership review remains mandatory; inputs cannot authorize
   adoption/import. Subsequent plans exempt an exact slot/CIDR/AZ with all current
   lease/run/source tags from the overlap check only; an orphan still causes AWS
   CreateSubnet to refuse overlap. Preserve the applied source identity through
   retirement. Supply a distinct existing public host subnet with HTTPS egress.
   The root creates no NAT/IGW, VPC, route to the internet, main-table change or
   association for an existing subnet. Created subnets disable public IPs and
   are explicitly associated with an owned table containing only AWS implicit
   VPC-local routes and no propagated routes. Database creation waits for both
   associations; reverse ordering keeps them until database retirement. Existing
   VPC DNS, default NACL and host routes/return paths remain reviewed external
   prerequisites; private subnet metadata alone does not prove reachability.
   Refuse collisions/adoption of any derived identity or network resource.
2. Review the committed source/lock/artifact hashes and initial saved plan with
   `payload_version_id=null`, `restore_checkpoint=null`, `retire=false`. This
   provisions modules/identity/network prerequisites with **zero EC2 instances**.
   The primary has deletion protection, one-day backups, private access, TLS
   enforcement, 20-GiB gp3 storage and no autoscaling. This bounded single-AZ
   synthetic fixture makes no HA, performance or production-retention claim.
   Managed RDS credentials never enter Terraform state; only the secret ARN does.
3. From `proof/`, perform a real `npm ci`, `npm test`, and `npm run build` under
   Node24. The builder requires a clean committed worktree, bundles pg and emits
   a deterministic three-file archive with source/lock/file digests in `dist/`.
   Rebuild and compare bytes. Upload those exact reviewed bytes to the output
   `payload_key` in the **new proof bucket**, using expected bucket owner and
   checksum validation. Record its actual immutable VersionId; do not use null,
   latest, an arbitrary manifest, presigned URL or baseline workspace object.
4. A new reviewed saved plan supplies that VersionId and launches one verifier.
   Capture the full Terraform output, instance, root-volume and ENI IDs promptly
   before guest shutdown, plus native RDS DbiResourceId, managed-secret ARN and
   all database ENIs attached to the exclusive owned database SG. Verify native
   tags/owner/association before recording any service-created interface. Keep
   the capture as the **seed** entry in `compute_history` after future replacement.
   The parent enforces an external deadline for **all resources**, including
   RDS before guest boot; the guest's two-hour shutdown is only a backup.
5. Wait for the exact `receipts/seed.json` object. Download by its actual version,
   verify metadata SHA256 and JSON `ok`, source/marker, PG17/TLS/refusal/ACL/S3
   results; preserve its bytes, SHA256, VersionId and referenced secret VersionId.
   A missing receipt, failed upload, refresh/network failure or termination is
   not success. The guest writes only a sanitized failure code on error.
6. Supply `restore_checkpoint` with those three non-secret references in a new
   reviewed saved plan. Terraform creates `aws_db_snapshot.marker` from the
   seeded primary and a separate `aws_db_instance.restored` from that snapshot.
   This direct provider resource is explicit: the reusable postgres module has
   **no snapshot restore input**, so this does not test a module restore feature.
   The changed execution barrier replaces the verifier. Retain both compute
   captures; never discard seed instance/storage/ENI history on state refresh.
7. The restore guest first downloads the seed receipt by exact VersionId and
   validates its digest, source, marker and secret version. PostgreSQL restore
   cannot enable RDS-managed credentials during restore; it inherits the
   snapshot's password. The guest reads the seed's exact historical primary
   secret VersionId into memory and connects to the clone. Both the restricted
   reader password (HMAC of that password and synthetic marker) and its ACLs were
   captured in the snapshot. Real marker reads and refusal checks must pass on
   the clone. No password reset, IAM database token or TF secret value is used.
   If version retrieval/rotation timing prevents authentication, fail closed;
   do not reset credentials or call that a restore pass.
8. Preserve `receipts/restore.json` by exact object version/digest and native
   captures. It proves the synthetic snapshot marker only. Stop all verifiers
   and confirm their termination before retiring storage/identity.

The guest uses IMDSv2/hop1 on the host, a no-ingress SG and HTTPS plus only the
owned DB SG on 5432. The pinned Linux ARM64 Node24 Docker image runs on the bridge
network, with read-only root, dropped capabilities and bounded CPU/RAM/PIDs.
AWS credentials are not passed/mounted into it. DB credentials go through stdin
only, never files/environment/argv/receipts. Public RDS CA bytes are digest-pinned;
only disposable synthetic wrong-CA keys are generated in its temporary lifecycle.
The host CLI can read the exact managed secret and version-pinned transport/seed
receipts, and mutate only the owned proof keys/receipt. The module's AWS-managed
S3 KMS key is usable only through S3 with the owned bucket encryption context.

## Cleanup contract

Preserve source/lock/payload/plan/state hashes, both raw success/failure receipts,
object versions, native resource/ownership captures and command outcomes outside
the soon-to-be-deleted bucket. Retain exact identity and lifecycle permission
through cleanup. Never sweep the account, import or touch the old proof, alter
baseline/workspace resources, force-delete unknown objects or service ENIs, or
accept Denied/missing pagination as empty. Partial applies need exact Terraform
state/native reconciliation; incomplete ledgers deliberately cannot pass the
normal retirement verifier.

- RDS protection defaults on. A separately reviewed `retire=true` apply disables
  compute and releases protection on primary and clone before the destroy plan.
  It cannot recreate a self-terminated verifier. Both databases explicitly skip
  **implicit final snapshots**, since they contain only synthetic data; the
  recovery marker snapshot is explicitly Terraform-owned and deleted after the
  clone. No application/customer snapshot retention claim follows.
- The actual postgres module hardcodes `delete_automated_backups=false`. The
  parent must capture its exact DbiResourceId/retained automated-backup ARN and,
  after primary deletion, retire only those owned automated backups through a
  separately reviewed native RDS deletion or wait for observed expiry. The root
  cannot override this module behavior. Terraform destroy alone is insufficient.
- RDS deletes its managed secret and associated metadata when its DB is deleted;
  require fresh `DescribeSecret` **ResourceNotFoundException** on the captured
  exact ARN. A scheduled recovery deletion/date or API denial is not absence.
  The restored instance creates no new managed secret. Never delete the primary
  or its historical secret before the clone's marker verification.
- S3 `force_destroy=false` preserves unknown data. Parent must capture every page
  of object versions/delete markers and multipart uploads, establish ownership,
  and freeze exact `{Key,VersionId}` / `{Key,UploadId}` lists. Only the output
  payload key, seed/restore receipts, Terraform sentinel and exact fixture
  marker/multipart keys may appear. A failed/partial guest can leave objects or
  uploads; recover its precise action ownership before mutation. Unknown entries
  quarantine the run. `python3 proof/drain_bucket.py ledger.json` verifies caller,
  full listings and exact ledger equality **before** deleting any listed owned
  versions or aborting any upload; it refuses unrelated keys. Release the
  sentinel for this final step only after independent preservation checks.
- Review/apply the exact destroy plan. Dependency ordering removes clone before
  snapshot/primary, and compute before role/profile/SG/LT. Capture all RDS ENIs
  and both compute lifetimes; a self-terminated guest does not retire IAM/LT/SG.
  Confirm every volume, ENI, SG, launch template, role/profile, DB, subnet group,
  parameter group, marker snapshot, automated backup, managed secret and bucket.
  In owned-network mode also capture/confirm both subnet IDs, the route-table ID
  and both association IDs from `owned_network`. Database/subnet-group and compute
  retirement precedes association/subnet/table destruction. Native RDS ENI removal
  is asynchronous; wait for specific absence rather than force-detaching an ENI.
  Association absence requires a complete empty exact association-filtered route
  table response; specific subnet/table NotFound is required too. External
  existing subnet IDs are output for composition but never retirement targets.
  AWS-managed KMS/service baseline resources remain external and preserved.

`proof/retirement.py` is a parent-operated **read-only** final check. Its ledger
contains `contract` (the last active `proof_contract` captured **before** the
retire apply clears its compute output), `compute_history` (the
seed and restore `compute` captures), distinct `database_resource_ids`, verified
`database_network_interface_ids`, and `managed_secret_arns` (exact primary ARN).
The contract's optional `owned_network` ledger is required when that mode is used;
capture the CIDRs/AZs, native routes/ownership and association IDs before destroy.
It requires specific service NotFound codes or explicit empty native backup lists;
arbitrary empty/Denied responses cannot pass. Run it only after the destroy and
native backup/secret retirement, retry only within the parent's cleanup deadline,
and preserve a failed result/state for recovery. It is not account-wide absence
proof. Uncaptured/unknown resources remain an explicit blocker.

## Offline checks and limits

`terraform init -backend=false`, `validate`, mock `test`, TFLint, terraform-docs,
Checkov, Python unittest/AST and Node tests/syntax run without credentials. Tests
include `python3 tests/check_graph.py /path/to/terraform` and
`python3 tests/check_sentinel_version.py /path/to/terraform` (repeat with OpenTofu).
The latter evaluates the actual sentinel postcondition with typed values in an
empty provider-free console directory; it never reads native object versions.
These checks cover the real module composition, restore/protection phases, exact caller,
private AZ separation, owned CIDR/VPC/AZ/collision guards, local-only associations
and reverse graph ordering, host IAM/IMDS/storage binding, malformed/foreign S3 pages,
unknown-version refusal, unrelated-key preservation and native NotFound semantics.
Mock passes do not prove service versions/capacity, network paths, deployed IAM,
async RDS cleanup, actual restore or application compatibility. Inline Checkov
exceptions explain the deliberate ephemeral/single-AZ/log/monitoring choices and
launch-template inheritance; no rule is widened for the scanner.

Public sources: [RDS credential management and restore limitations](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html),
[RDS snapshot restore](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_RestoreFromSnapshot.html),
[RDS TLS verification](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Concepts.General.SSL.html),
[Terraform RDS restore](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/db_instance),
[EC2 shutdown behavior](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/Using_ChangingInstanceInitiatedShutdownBehavior.html).
Network semantics: [VPC subnet route tables](https://docs.aws.amazon.com/vpc/latest/userguide/subnet-route-tables.html)
and [exact association filtering](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-route-tables.html).

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, < 2.0 |
| aws | = 6.72.0 |
| random | = 3.9.1 |

### Providers

| Name | Version |
| ---- | ------- |
| aws | = 6.72.0 |
| terraform | n/a |

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| objects | ../../modules/aws/object-storage | n/a |
| postgres | ../../modules/aws/postgres | n/a |

### Resources

| Name | Type |
| ---- | ---- |
| [aws_db_instance.restored](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/db_instance) | resource |
| [aws_db_snapshot.marker](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/db_snapshot) | resource |
| [aws_iam_instance_profile.verifier](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/iam_instance_profile) | resource |
| [aws_iam_role.verifier](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.verifier](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/iam_role_policy) | resource |
| [aws_instance.verifier](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/instance) | resource |
| [aws_launch_template.verifier](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/launch_template) | resource |
| [aws_route_table.private](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/route_table) | resource |
| [aws_route_table_association.private_first](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/route_table_association) | resource |
| [aws_route_table_association.private_second](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/route_table_association) | resource |
| [aws_s3_object.sentinel](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/s3_object) | resource |
| [aws_security_group.database](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/security_group) | resource |
| [aws_security_group.verifier](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/security_group) | resource |
| [aws_subnet.private_first](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/subnet) | resource |
| [aws_subnet.private_second](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/subnet) | resource |
| [aws_vpc_security_group_egress_rule.database](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.https](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.database](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/vpc_security_group_ingress_rule) | resource |
| [terraform_data.execution](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.guard](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.network_guard](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [aws_ami.host](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/data-sources/ami) | data source |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/data-sources/availability_zones) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/data-sources/caller_identity) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/data-sources/region) | data source |
| [aws_subnet.host](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/data-sources/subnet) | data source |
| [aws_subnet.inventory](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/data-sources/subnet) | data source |
| [aws_subnet.private_first](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/data-sources/subnet) | data source |
| [aws_subnet.private_second](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/data-sources/subnet) | data source |
| [aws_subnets.inventory](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/data-sources/subnets) | data source |
| [aws_vpc.existing](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/data-sources/vpc) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | Exact existing sandbox account; never an account creation request. | `string` | n/a | yes |
| ami\_id | Exact reviewed Amazon AL2023 ARM64 HVM/EBS AMI, not latest. | `string` | n/a | yes |
| host\_subnet\_id | Reviewed existing public subnet with HTTPS egress through an IGW. No routing changes. | `string` | n/a | yes |
| payload\_sha256 | Content digest of the secret-free transport archive, checked before extraction. | `string` | n/a | yes |
| pippen | Expected allocated non-secret lease identity. | `object({ agent = string, session_id = string })` | n/a | yes |
| postgres\_version | Exact region-supported PostgreSQL17 minor verified independently by the operator. | `string` | n/a | yes |
| rds\_ca\_sha256 | Reviewed SHA256 of the public regional RDS CA bundle; never a private certificate/key. | `string` | n/a | yes |
| region | Explicit approved existing region. | `string` | n/a | yes |
| run\_id | Lease-unique bounded slug; do not reuse while old resources or sessions exist. | `string` | n/a | yes |
| source\_sha | Exact committed source of the reviewed transport payload. | `string` | n/a | yes |
| vpc\_id | Reviewed existing VPC; unchanged by this proof. | `string` | n/a | yes |
| create\_private\_subnets | Optional two owned local-only private subnets in the existing default VPC. Explicit reviewed non-overlapping /24-/28 IPv4 CIDRs and distinct available AZs; mutually exclusive with private\_subnet\_ids. | `object({ first = object({ cidr = string, az = string }), second = object({ cidr = string, az = string }) })` | `null` | no |
| payload\_version\_id | Null provisions data without compute. Exact immutable transport VersionId enables the verifier in a separate reviewed apply. | `string` | `null` | no |
| private\_subnet\_ids | Exactly two reviewed existing private subnets in distinct AZs; null when create\_private\_subnets is selected. | `set(string)` | `null` | no |
| restore\_checkpoint | Null for seed. Supply only after a successful independently reviewed seed receipt; no secret values. | `object({ seed_receipt_sha256 = string, seed_receipt_version_id = string, secret_version_id = string })` | `null` | no |
| retire | Reviewed cleanup apply disables the verifier and releases database deletion protection. | `bool` | `false` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| proof\_contract | Non-secret source/lease/module/transport identities. Capture before guest termination. |
<!-- END_TF_DOCS -->
