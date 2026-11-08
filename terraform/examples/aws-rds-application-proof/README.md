# Held actual-RDS application SQL fixture

This independent source fixture composes the actual AWS PostgreSQL/object-storage
modules for a new disposable PostgreSQL17 instance, explicit snapshot/restore
clone, versioned S3 bucket, empty runtime Secrets Manager container and temporary
ARM host. It runs the unchanged reviewed HoopDB bootstrap/migrator/readiness library
from Sessions composition `292359f0c68b1e4615704fd51d303b7f6b4db445`.

A completed live run proves only those selected SQL/readiness/module storage checks.
Source mocks/imports and synthetic client tests do not prove actual RDS behavior,
projection state, OpenSearch/FGAC/provider conformance, Lambda or the full suite.
There is no untrusted-code, tenant-isolation, production durability or HA claim.
Actual execution remains held for complete TF/host/payload/private parent-driver
review and separate exact saved-plan admission. No platform grant, account/project,
existing app/role, parent DNS, publication or deployment change is made here.

## Shared-database qualification remains blocked

`application_sql_ready` is always `false`. This fixture currently migrates the
synthetic `applicationproof` database as its RDS master, `proof_admin`, with
`proof_runtime` for runtime checks. It does not implement the
[shared PostgreSQL application contract](../../../docs/shared-postgres-storage-contract.md):
one application database, independent service schemas, non-master schema owners
and restricted runtime logins. A successful run of these selected checks must
not qualify that contract or a Terraform-to-Helm application installation.

Closing this gap requires a supported application composition and reviewed
bootstrap/activation path for the non-master owner and runtime, native tests of
the service bindings and cross-schema denials, then a digest-pinned Helm
installation and the real application acceptance cases. Metadata-only schema
bindings are not SQL/bootstrap proof. The private parent saved-plan driver also
still requires independent review. Managed execution remains held.

Both source and restore instances disable automatic minor upgrades. The host
requires the exact selected PostgreSQL version and native upgrade flag, and
requires the restore resource ID, ARN and endpoint to differ from the seed.
These checks prevent version drift or seed substitution from being accepted;
they are not managed restore or cleanup evidence without a real run.

## Ownership and external prerequisites

Use fresh isolated state and a unique run in an existing reviewed account/region/
VPC. Select existing private AZ subnets or two bounded owned local-only subnets;
existing routes are untouched. Public host subnet/IGW route, DNS, NACL/private
connectivity, exact AL2023 ARM64 AMI, PostgreSQL17 minor and current permission
intersection are native prerequisites. Existing RDS service-linked role and regional AWS-managed service
keys (aws/rds, aws/secretsmanager, aws/s3) are external baseline prerequisites,
not authored/imported/deleted here; parent preflight must establish them before
claiming all new fixture resources can retire. Missing permission is reported, never
bypassed or widened. The host has no ingress/key, encrypted delete-on-termination
root disk, IMDSv2/hop1, bounded containers, terminate-on-shutdown and a two-hour OS
timer. Parent owns the hard deadline/finally; self-shutdown is not cleanup evidence.

New `/pippen/workload/` verifier role and `eks*` profile retain the existing boundary.
GetSecretValue names only the new master/runtime ARNs; PutSecretValue names only
the runtime ARN, with explicit other-resource Deny. Every workload Allow expires
at the immutable input deadline. The parent must validate that deadline against
current time/original lease and budget the whole lifecycle. HCL format checks do
not independently prove lease/human authority; do not extend a failed fixture.
S3 grants cover exact-version source/seed reads, fixed receipt/pending keys and
owned synthetic prefix. Specialized search/Lambda permissions are not used.

Terraform owns only an initially empty runtime secret container. Secret values/
versions never enter Terraform variables/state/data/output/user-data. The container
uses AWS-managed encryption and explicit zero-recovery retirement because every
credential is new and disposable. The RDS-managed master secret remains separate;
no production secret is derived, overwritten or re-used.

## Immutable source preparation

Use an own T7 Sessions worktree at exact292359, real Bun1.4.2 frozen installation
and its original bun.lock. The requested npm-ci attempt refuses this Bun-only
project's absent npm lock; never invent a lock or link another checkout's modules.
All11RDS+23portable owner inputs are byte-checked. Original TypeScript paths,
import.meta.url, actual SQL/verifier/JSON assets and pg8.23.1's exact lock closure
are copied and hashed. A closed hook resolves only the vendor scrub alias from
shared/log.ts. The separate `rds-profile-proof.ts` emulation harness is never
packaged, imported or executed.

Commit Helm source/provider lock first, then build twice with fresh T7 outputs:

```sh
node proof/build-payload.mjs --source /T7/clean-guest-source \
  --output /T7/new-payload-a --ca /T7/reviewed-public-rds-ca.pem \
  --ca-sha256 REVIEWED_CA_SHA256 --wrong-ca proof/assets/wrong-ca.pem
```

Use Node24. Public CA bytes/digest are reviewed explicitly and archived; runtime
never fetches them. The wrong-CA public asset is synthetic and its disposable
creation key was removed; it is never production trust. Builder binds clean Helm
commit/tree/source/provider lock, original guest manifest/generation/Bun lock/all
transitive bytes, pinned Node/psql images and CA. Dirty test builds require a flag
and are marked/rejected for operations. Repeat archive SHA must match. Parent
separately binds selected provider binaries/backend/state/plan/runner and real S3
VersionIds. Source/build commands call no cloud/database APIs or image publisher.

`extract_payload.py` bounds compressed/uncompressed/member sizes, verifies exact
hash/source/lock/CA/inventory before any unpacked execution, and refuses traversal,
duplicates, links, unlisted/test-only/source-only artifacts or emulation bytes.
Host rechecks installed files before secret retrieval. Image VOLUME paths become
bounded tmpfs; any actual volume mount refuses; finally uses rm --volumes. Public
source streams over stdin without host bind mounts/socket/host networking. No
explicit AWS credential values cross guest pipes; same-host trusted code is NOT an
AWS-authority sandbox. Stripped environment/IMDS settings do not prove isolation.

## SQL, password and restore ordering

Host verifies fresh owned-role STS, exact available/private/encrypted/protected
RDS17 ARN/tags/endpoint/VPC and native managed-master mapping. Owner credential is
RAM-only; seed records VersionId, restore retrieves that exact historical version.
Scope/source hashes are expected-response provenance, not independent AWS identity.

The original guest uses explicit pg hostname/CA verification and bounded IO.
Bootstrap admits only six committed path/hash/nonsecret-variable tuples. Detached
psql17 uses -X/-W/ON_ERROR_STOP/-f with owner password through anonymous stdin.
Runtime callbacks generate random initial/rotated values and use client-encrypted
`\password` stdin prompts. No password/SCRAM material enters argv/environment/files,
raw output logs, Runner command files, cloud-init/journal or foreign error text.
The process helper bounds RAM/time, settles owned groups and returns typed errors.
It is not a general remote executor, client approval file or secure-erasure claim.

Original bootstrap/migration/idempotency/runtime readiness and connection closure
must finish before publication. Prior runtime passwords must fail FRESH login
with exact28P01 after rotation; a surviving session, DNS/TLS/timeout/denial is not
password refusal. Wrong CA/hostname must cause real certificate validation errors.
pg overwrites ssl.servername with its DNS host; local negative therefore uses an
alternate DNS alias to the same server, and operational negative invokes Node's
default certificate checker with a deliberately wrong expected hostname.

Only after full original guest success does host PutSecretValue use the exact new
ARN and pending-recorded UUID, with secret JSON through stdin. Returned ARN/VersionId
must match; exact-version Get readback matches RAM bytes, then persisted-password
fresh TLS/readiness precedes success. Parent receives only nonsecret references,
checks and content-free catalog hashes.

Restore pins seed receipt version/hash, historical master/runtime VersionIds and
catalog digest. It authenticates using the exact SEED runtime version and proves
TLS/readiness BEFORE any bootstrap/password mutation; host protocol requires the
acknowledgement. Unchanged restored guest then proves both old-password28P01 cases,
new readiness and unchanged catalog digest, and stores a distinct final version.
Seed version/label stays immutable; AWSCURRENT or password derivation is no substitute.

## Parent lifecycle and complete retirement

Parent owns the separately reviewed private saved-plan/state/history driver; this
source does not implement a duplicate framework. Required admission binds source,
vars, saved plan, provider lock/binaries, backend/current state/runner and fresh
exact Pippen caller for each phase. Provision without compute, verify native empty
secret/policy/network prerequisites, upload immutable payload version, then review
host launch. Exact successful seed receipt admits the Terraform marker snapshot/
restore. Application catalog digest is `guest.receipt.evidenceSha256`, with master
`secret_version_id` and `runtime_secret_version_id`; SELECT1/module marker is insufficient.

Before each SQL/secret write, host saves a nonsecret intent with a real VersionId
at `receipts/{seed|restore}.pending.json`; publication UUID identifies a possible
SM version. Duplicate/timeout/partial SQL/ambiguous publication quarantines, never
silently resumes/rotates/replaces a passing checkpoint. Unsettled group exits75 and
forbids further AWS calls. Parent preserves pending/raw candidates and reconciles
exact owned resources. No grant repair or fixed-role drops on retained instances.

Parent persists pending BEFORE every apply; candidate/state/native IDs and cumulative
compute history survive BEFORE validation. Failed state read/empty JSON after an
attempted apply never means no resources. Uncaptured partial apply, stale capture,
unknown inventory, unsettled processes or expired authority requires exact-owned
recovery; no ordinary automatic cleanup/fallback identity is inferred.

After stopping all owned hosts, metadata-only all-page capture produces
`runtime_secret_inventory={arn,version_ids,complete:true}`, including0 before
publication. No value GET for cleanup. `compute_inventory={complete:true,instance_ids}`
exactly matches unique lifetime compute_history (max2); zero is valid after captured
PROVISION iff contract.compute is null, otherwise last history equals current
contract.compute. Missing/truncated/foreign/duplicate inventory refuses before IO.

Separately review protection-release changes affecting only deletion_protection,
then exact-owned delete-only Terraform plan/state. No state-rm, old-resource import,
protection bypass or native deletion of unknown DBs. Retire primary/clone, explicit
snapshot, retained primary automated backups by exact DbiResourceId, runtime container/
ALLversions, managed master secret, cumulative compute/rootvolume/ENI/LT/SG/role/profile
and owned subnet/route/association IDs. Final snapshots are skipped deliberately;
explicit marker snapshot is tracked. Fixed SQL roles retire with whole instances.

S3 drainer admits the exact complete key/version/MPU ledger, including pending
receipt versions, refuses unknown/unrelated inventory BEFORE deletion and retains
the pinned sentinel until Terraform removes its own object. Preserve evidence
externally before bucket deletion. Secret deletion is asynchronous: success or
DeletionDate is not absence. Typed DescribeSecret AND ListSecretVersionIds NotFound
prove exact container/all versions gone. Denied, untyped empty responses, refresh
failure and recovery schedules never count. State0 plus independent specific native
absence closes the fixture; existing VPC/routes/apps/resources remain outside scope.

## F1 status: shared-database application path (refused)

The fixture now consumes the landed `postgres-layout` contract (#80):
- one application database, `relaycontrol`;
- the pipeline binding `sessions` / `hoop` / `sessions_pipeline_runtime`;
- the RDS master (`proof_admin`) as a forbidden application role.

Expected identities come from `module.layout.bindings["hoopdb"]`, never from a
connection URL. The master is only the narrowly used provisioning executor. It is
never the application migrator or runtime: the host refuses that before any AWS
call or credential read (`application_identity`). The guest's runtime readiness
also requires `session_user` to equal the runtime role, so a `SET ROLE` or
`options=-c role=…` substitution can't pass.

Other services' schemas (`relaycontrol`, `relaycast`, `relayhistory`,
`relayfile`) stay separately owned. A binding existing doesn't mean the service is
implemented.

**Application execution is refused** and `application_sql_ready` is `false`.
`terraform_data.application_gate` refuses any verifier compute unless
`application_activation` names an entry of `local.approved_activations`, which
is intentionally empty. The host additionally refuses a missing activation
(`application_activation_artifact_missing`) and any supplied one
(`application_activation_not_implemented`), because the guest flow hasn't been
ported to a non-master owner.

Remaining dependencies (source/design inventory; nothing here is a proof):
1. **A reviewed, schema-aware Sessions source and artifact.** The pinned
   composition `292359f0c68b1e4615704fd51d303b7f6b4db445` is not retrievable from
   any AgentWorkforce GitHub repository (`relayhistory-pipeline`,
   `sessions-pipeline`, `96BullSessions`, `sessions-pipeline-cloud` all return 422)
   or from this host. It can't be reviewed for non-master owner support.
   Owner: pipeline (`relayhistory-pipeline`).
2. **The RDS application activation contract.** A narrowly privileged, named and
   authenticated provisioning executor creates `hoop` and
   `sessions_pipeline_runtime` with an exact grantor-specific graph. Then, in one
   explicit transaction:
   - LOGIN and default changes;
   - `RESET ROLE`;
   - creator cleanup;
   - final graph validation.

   No helper creator or capability may survive into the ready state. Candidate
   upstream sources to review are `supabase/bootstrap/rds_migration_roles.sql`
   and `hoopdb_runtime_role_rds.sql` in `relayhistory-pipeline`. They must not be
   run as standalone `BEGIN`/`COMMIT` files inside an outer transaction. The
   `rds-profile-proof.ts` emulation is not an activation. Owner: pipeline.
3. **A durable application-readiness result.** The application grants and the
   retention, privacy and read-api verifiers must pass, then publish a result
   bound to source, profile, generation and verifier. Ordinary `migrate` and a
   generic schema PASS can't stand in for it. Missing, pending or stale readiness
   must block service startup. Owner: pipeline and control.
4. **Execution proof (later, separate).** Actual non-owner LOGINs, cross-schema
   denials with unchanged foreign objects, and bootstrap failure, crash and
   resume. Ordinary migrate must not substitute for activation. Then real
   auth/TLS/password rotation and restore, then Helm and application behaviour.

Immutable schema steps (including `042000`), historical migration, verifier and
function ACLs are unchanged here, and no migration slot or privilege edge is
added.

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
| layout | ../../modules/postgres-layout | n/a |
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
| [aws_secretsmanager_secret.runtime](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/secretsmanager_secret) | resource |
| [aws_security_group.database](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/security_group) | resource |
| [aws_security_group.verifier](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/security_group) | resource |
| [aws_subnet.private_first](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/subnet) | resource |
| [aws_subnet.private_second](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/subnet) | resource |
| [aws_vpc_security_group_egress_rule.database](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.https](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.database](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/resources/vpc_security_group_ingress_rule) | resource |
| [terraform_data.application_gate](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
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
| deadline | Explicit immutable UTC workload deadline; fresh parent review must budget creation/guest/restore/cleanup. Never extend it to retry a failed fixture. | `string` | n/a | yes |
| guest\_sources | Frozen unchanged source composition, actual manifest and generation. Public provenance only, no credentials. | `object({ composition_commit = string, manifest_sha256 = string, generation = string })` | n/a | yes |
| host\_subnet\_id | Reviewed existing public subnet with HTTPS egress through an IGW. No routing changes. | `string` | n/a | yes |
| payload\_sha256 | Content digest of the secret-free transport archive, checked before extraction. | `string` | n/a | yes |
| pippen | Expected allocated non-secret lease identity. | `object({ agent = string, session_id = string })` | n/a | yes |
| postgres\_version | Exact region-supported PostgreSQL17 minor verified independently by the operator. | `string` | n/a | yes |
| rds\_ca\_sha256 | Reviewed SHA256 of the public regional RDS CA bundle; never a private certificate/key. | `string` | n/a | yes |
| region | Explicit approved existing region. | `string` | n/a | yes |
| run\_id | Lease-unique bounded slug; do not reuse while old resources or sessions exist. | `string` | n/a | yes |
| source\_sha | Exact committed source of the reviewed transport payload. | `string` | n/a | yes |
| vpc\_id | Reviewed existing VPC; unchanged by this proof. | `string` | n/a | yes |
| application\_activation | Reviewed schema-aware Sessions activation artifact for the shared-database application path (source commit, artifact sha256, generation, contract id). Null keeps application execution refused. Must name an entry of local.approved\_activations, which is empty until a reviewed artifact exists. | ```object({ sessions_commit = string artifact_sha256 = string generation = string contract = string })``` | `null` | no |
| create\_private\_subnets | Optional two owned local-only private subnets in the existing default VPC. Explicit reviewed non-overlapping /24-/28 IPv4 CIDRs and distinct available AZs; mutually exclusive with private\_subnet\_ids. | `object({ first = object({ cidr = string, az = string }), second = object({ cidr = string, az = string }) })` | `null` | no |
| payload\_version\_id | Null provisions data without compute. Exact immutable transport VersionId enables the verifier in a separate reviewed apply. | `string` | `null` | no |
| private\_subnet\_ids | Exactly two reviewed existing private subnets in distinct AZs; null when create\_private\_subnets is selected. | `set(string)` | `null` | no |
| restore\_checkpoint | Null for seed. Supply only after a successful independently reviewed seed receipt; no secret values. | `object({ seed_receipt_sha256 = string, seed_receipt_version_id = string, secret_version_id = string, runtime_secret_version_id = string, seed_evidence_sha256 = string })` | `null` | no |
| retire | Reviewed cleanup apply disables the verifier and releases database deletion protection. | `bool` | `false` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| application\_binding | Expected application identities from the postgres-layout contract (non-secret). Metadata only: not SQL, bootstrap or application proof. |
| application\_sql\_ready | False: this synthetic master-role fixture does not qualify the shared-database application layout or its activation. |
| proof\_contract | Non-secret source/lease/module/transport identities. Capture before guest termination. |
<!-- END_TF_DOCS -->
