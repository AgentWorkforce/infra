# Held actual-RDS application SQL fixture

This independent source fixture composes the actual AWS PostgreSQL/object-storage
modules for a new disposable PostgreSQL17 instance, explicit snapshot/restore
clone, versioned S3 bucket, empty runtime Secrets Manager container and temporary
ARM host. Its guest runs the unchanged `rds-activation/v1` driver and HoopDB
migrator from the Sessions commit named by `guest_sources`.

A completed live run proves only those selected SQL/readiness/module storage checks.
Source mocks/imports and synthetic client tests do not prove actual RDS behavior,
projection state, OpenSearch/FGAC/provider conformance, Lambda or the full suite.
There is no untrusted-code, tenant-isolation, production durability or HA claim.
Actual execution remains held for complete TF/host/payload/`proof/runner.py`
review and separate exact saved-plan admission. No platform grant, account/project,
existing app/role, parent DNS, publication or deployment change is made here.

## Shared-database qualification remains blocked

`application_sql_ready` is always `false`. The guest flow now runs as the
[shared PostgreSQL application contract](../../../docs/shared-postgres-storage-contract.md)
requires for one service: database `hoopdb`, non-master owner `hoop`, restricted
runtime `sessions_pipeline_runtime`. It stays held, and a successful run of these
checks would cover only HoopDB. It would not qualify the other services, cross-database
denials or a Terraform-to-Helm application installation. Those need their own service
bindings, a digest-pinned Helm installation and the real application acceptance cases.
The saved-plan runner, `proof/runner.py`, also still requires independent review. Managed
execution remains held.

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

Use an own Sessions worktree at the exact commit named by `guest_sources`, with a
frozen Bun installation and its original bun.lock. Never invent a lock or link another
checkout's modules. The build refuses a dirty tree, a different commit, or an artifact
hash that differs from the driver's own. Only the driver's and migrator's exact
relative-import closure, the driver's artifact files, the migration and bootstrap SQL,
and pg's exact lock closure are copied and hashed. A closed hook resolves only the
vendor scrub alias from shared/log.ts. The separate `rds-profile-proof.ts` emulation
harness is never packaged, imported or executed.

Commit Helm source/provider lock first, then build twice with fresh T7 outputs:

```sh
node proof/build-payload.mjs --source /T7/clean-guest-source \
  --output /T7/new-payload-a --ca /T7/reviewed-public-rds-ca.pem \
  --ca-sha256 REVIEWED_CA_SHA256 --wrong-ca proof/assets/wrong-ca.pem \
  --commit MERGED_SESSIONS_COMMIT --artifact REVIEWED_ARTIFACT_SHA256
```

Use Node24. Public CA bytes/digest are reviewed explicitly and archived; runtime
never fetches them. The wrong-CA public asset is synthetic and its disposable
creation key was removed; it is never production trust. Builder binds clean Helm
commit/tree/source/provider lock, guest manifest/artifact/generation/Bun lock/all
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
`\password` stdin prompts. No password/SCRAM material enters argv, a process's initial
environment, files, raw output logs, Runner command files, cloud-init/journal or foreign
error text. One qualification: the migrator reads `HOOPDB_URL` from `process.env`, so
its `--import` hook receives the URL over a private pipe and sets it in-process; the
owner password is therefore in that migrator's live `process.env` for its lifetime.
The process helper bounds RAM/time, settles owned groups and returns typed errors.
It is not a general remote executor, client approval file or secure-erasure claim.

Original bootstrap/migration/idempotency/runtime readiness and connection closure
must finish before publication. Prior runtime passwords must fail FRESH login
with exact28P01 after rotation; a surviving session, DNS/TLS/timeout/denial is not
password refusal. Wrong CA/hostname must cause real certificate validation errors.
pg overwrites ssl.servername with its DNS host; local negative therefore uses an
alternate DNS alias to the same server, and operational negative invokes Node's
default certificate checker with a deliberately wrong expected hostname.

Credentials are published first: on a fresh database, host PutSecretValue runs before
the activation SQL that makes the passwords live, because after activation no
customer-held login can reset them. On restore it runs after the seeded passwords are
proven and before `rotate-self`. It uses the exact new ARN and pending-recorded UUID,
with secret JSON through stdin. Returned ARN/VersionId must match, and an exact-version
Get readback must match RAM bytes. A published version therefore does not mean success:
success still requires persisted-password fresh TLS/readiness at the end of the guest. Parent receives only nonsecret references,
checks and content-free catalog hashes.

Restore pins seed receipt version/hash, historical master/runtime VersionIds and
activation evidence digest. It authenticates using the exact SEED runtime version and proves
TLS/readiness BEFORE any bootstrap/password mutation; host protocol requires the
acknowledgement. Unchanged restored guest then proves both old-password28P01 cases,
new readiness and an unchanged activation evidence digest, and stores a distinct final version.
Seed version/label stays immutable; AWSCURRENT or password derivation is no substitute.

## Parent lifecycle and complete retirement

`proof/runner.py` is the saved-plan/state/history runner and needs its own
independent review before any live use. Required admission binds source, vars,
saved plan, provider lock/binaries, current state, runner and fresh exact Pippen
caller for each phase. Provision without compute, verify native empty
secret/policy/network prerequisites, upload immutable payload version, then review
host launch. Exact successful seed receipt admits the Terraform marker snapshot/
restore. `guest.receipt.evidenceSha256` is an activation evidence digest over the driver
contract, artifact, generation, database name and owner, and the verified role graph.
It is not a digest of the application catalog: any correct activation matches. The
restore is proven by the seed password login and the schema verdict. It pins master
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
PROVISION iff contract.compute is null. After a captured release, contract.compute is
null and history stays populated only with `compute_released=true` in the ledger; in
every other case the last history entry equals the current contract.compute. Missing/truncated/foreign/duplicate inventory refuses before IO.

Separately review protection-release changes: the runner refuses a release plan that
does anything but turn deletion_protection off on database instances and remove
verifier compute, and the plan summary shows each changed attribute. Then exact-owned delete-only Terraform plan/state. No state-rm, old-resource import,
protection bypass or native deletion of unknown DBs. Retire primary/clone, explicit
snapshot, retained primary automated backups by exact DbiResourceId (runner `backups`,
after destroy and before `absence`), runtime container/
ALLversions, managed master secret, cumulative compute/rootvolume/ENI/LT/SG/role/profile
and owned subnet/route/association IDs. Final snapshots are skipped deliberately;
explicit marker snapshot is tracked. `absence` also checks the fixed marker snapshot and
restored instance names, so a resource AWS created but state lost cannot read as absent. Fixed SQL roles retire with whole instances.

S3 drainer admits the exact complete key/version/MPU ledger, including pending
receipt versions, refuses unknown/unrelated inventory BEFORE deletion and retains
the pinned sentinel until Terraform removes its own object. Preserve evidence
externally before bucket deletion. Secret deletion is asynchronous: success or
DeletionDate is not absence. Typed DescribeSecret AND ListSecretVersionIds NotFound
prove exact container/all versions gone. Denied, untyped empty responses, refresh
failure and recovery schedules never count. State0 plus independent specific native
absence closes the fixture; existing VPC/routes/apps/resources remain outside scope.

### Running the phases

Run each command under the lease, with `R="python3 proof/runner.py --execution
<private T7 dir> --variables <inputs.tfvars.json> --terraform <terraform>"`.
Every `plan` stops so a person can read `<phase>.summary.txt`; `apply` then takes
only that plan's digest.

```sh
pippen sandbox up aws-proof
pippen sandbox exec aws-proof -- $R plan --phase provision
pippen sandbox exec aws-proof -- $R apply --phase provision --plan-sha256 <digest>
pippen sandbox exec aws-proof -- $R prerequisites
pippen sandbox exec aws-proof -- $R upload --archive <payload.tar.gz>
pippen sandbox exec aws-proof -- $R plan --phase seed                 # then apply as above
pippen sandbox exec aws-proof -- $R receipt --phase seed
pippen sandbox exec aws-proof -- $R plan --phase restore              # then apply as above
pippen sandbox exec aws-proof -- $R receipt --phase restore
pippen sandbox exec aws-proof -- $R plan --phase release              # then apply as above
pippen sandbox exec aws-proof -- $R inventory                         # prints ledger_sha256
pippen sandbox exec aws-proof -- $R drain --ledger-sha256 <digest>
pippen sandbox exec aws-proof -- $R plan --phase destroy              # then apply as above
pippen sandbox exec aws-proof -- $R backups
pippen sandbox exec aws-proof -- $R absence
pippen sandbox down aws-proof
```

`release` may start from any phase. Forward phases refuse an expired deadline;
retirement does not, because refusing would strand resources. A failed or empty
state read after an attempted apply is unknown, never empty, and blocks retirement
until the state can be read and the phase is reconciled. If no contract was captured, `inventory`, `drain` and
`absence` are unavailable, so native absence needs a manual exact-owned check.

A forward phase that did not finish leaves resources the configuration still declares,
so a normal release plan would create them, and the guard refuses any create. For a
partial lifecycle only, `plan --phase release` targets the exact protected database and
compute addresses in state. If state holds neither, it records release as `not-required`
with no plan, and `destroy` may proceed. A complete lifecycle is never targeted. A
tainted or deposed database refuses, because release would replace it; review it and
run `terraform untaint` under the lease if it is intact, then plan release again.

Run `reconcile --phase <phase>` on any phase left `pending` or `unknown` (a killed runner,
a lost host) before retiring; it captures what state holds, or stays `unknown`, and an
unknown empty state still needs exact-owned recovery. A process group that would not
stop is recorded on disk and blocks every later tool or AWS call, across processes,
until `settle` proves the group gone. `backups` reruns safely while a retained backup is
still being created.

## F1 status: separate-database application path (refused)

The fixture consumes the `postgres-layout` contract with one logical database
per service on one RDS instance (#107):
- the initial database `relaycontrol`, which Control binds to;
- the pipeline binding: database `hoopdb`, schema `sessions`, `hoop` /
  `sessions_pipeline_runtime`;
- the RDS master (`proof_admin`) as a forbidden application role.

Expected identities come from `module.layout.bindings["hoopdb"]`, never from a
connection URL. The master is only the narrowly used provisioning executor. It is
never the application migrator or runtime: the host refuses that before any AWS
call or credential read (`application_identity`). The guest's runtime readiness
also requires `session_user` to equal the runtime role, so a `SET ROLE` or
`options=-c role=…` substitution can't pass.

Other services keep their own databases (`relaycontrol`, `relaycast`,
`relayfile`) and owners. A binding existing doesn't mean the service is
implemented, and this fixture doesn't create the `hoopdb` database: that belongs
to the activation contract below.
The layout has no legacy History binding: self-host history remains a
sessions-pipeline capability, and the standalone History server is being removed
separately.

**Application execution is refused by default** and `application_sql_ready` is `false`.
`terraform_data.application_gate` refuses any verifier compute unless
`application_activation` names an entry of `local.approved_activations` that matches
the payload's Sessions commit and generation. That map is intentionally empty until
the driver is merged and reviewed. The host refuses a missing or unregistered
activation before any AWS call or credential read.

The guest was rewritten to run the `rds-activation/v1` driver
(`relayhistory-pipeline` #409). It replaces the earlier guest library, whose pinned
commit was never pushed and could not be recovered. In order:

1. TLS negatives (wrong hostname, wrong CA) against the RDS endpoint.
2. The host generates one distinct password per LOGIN role in the driver's generated
   spec and persists them to the runtime secret **before** any SQL that makes them
   live. After activation no customer-held login can reset a HoopDb role, so a lost
   password is not recoverable.
3. `run` as the provisioning login (the RDS master), with `verify-full` TLS, secrets on
   stdin only and the result on a dedicated descriptor. This is the master's only use.
4. The bootstrap chain, then the migrator twice, as `hoop` with
   `HOOPDB_RDS_LAYOUT=separate-database`.
5. `verify`, then readiness as `sessions_pipeline_runtime` with the persisted password.

The restore phase proves the seeded passwords before changing anything, reruns the
chain and migrator, rotates the runtime password with `rotate-self`, and requires the
same catalog evidence as the seed.

Remaining dependencies (nothing here is a live proof):
1. **Merged and reviewed driver.** Pin `guest_sources` and register the artifact in
   `local.approved_activations` using the merged commit and its `artifact_sha256`.
   Any byte change to the driver or its SQL changes the artifact. Owner: pipeline, then infra.
2. **Independent review of the saved-plan runner `proof/runner.py`**, then exact saved-plan
   admission. Owner: reviewer to be named.
3. **A Pippen lease** for the sandbox account, which needs the `pippen-sandbox-client`
   credential.
4. **A durable application-readiness result.** The application grants and the
   retention, privacy and read-api verifiers must pass, then publish a result
   bound to source, profile, generation and verifier. Missing, pending or stale
   readiness must block service startup. Owner: to be named (pipeline and control).
5. **PUBLIC CONNECT on sibling databases.** Activation closes `hoopdb` only. The
   HoopDb roles can still connect to `postgres` and to the Terraform-created initial
   database `relaycontrol` until a reviewed bootstrap for those databases revokes it.
   This fixture deliberately does not invent one. Owner: infra and control.
6. **Execution proofs (later, separate).** Access denials between databases with
   unchanged foreign objects, real auth/password rotation and restore on RDS, then Helm
   and application behaviour.

Known limits of `rds-activation/v1`: `bulls96_babysitter_retention` stays NOLOGIN, and
the operator `*_role.sql` files are unsupported on this layout. The driver needs
`--experimental-transform-types` on Node because it uses TypeScript parameter properties.

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
| guest\_sources | Sessions source commit, guest manifest digest and migration generation of the payload. Must match the registered application\_activation before any compute. Public provenance only, no credentials. | `object({ composition_commit = string, manifest_sha256 = string, generation = string })` | n/a | yes |
| host\_subnet\_id | Reviewed existing public subnet with HTTPS egress through an IGW. No routing changes. | `string` | n/a | yes |
| payload\_sha256 | Content digest of the secret-free transport archive, checked before extraction. | `string` | n/a | yes |
| pippen | Expected allocated non-secret lease identity. | `object({ agent = string, session_id = string })` | n/a | yes |
| postgres\_version | Exact region-supported PostgreSQL17 minor verified independently by the operator. | `string` | n/a | yes |
| rds\_ca\_sha256 | Reviewed SHA256 of the public regional RDS CA bundle; never a private certificate/key. | `string` | n/a | yes |
| region | Explicit approved existing region. | `string` | n/a | yes |
| run\_id | Lease-unique bounded slug; do not reuse while old resources or sessions exist. | `string` | n/a | yes |
| source\_sha | Exact committed source of the reviewed transport payload. | `string` | n/a | yes |
| vpc\_id | Reviewed existing VPC; unchanged by this proof. | `string` | n/a | yes |
| application\_activation | Reviewed schema-aware Sessions activation artifact for the separate-database application path (source commit, artifact sha256, generation, contract id). Null keeps application execution refused. Must name an entry of local.approved\_activations, which is empty until a reviewed artifact exists. | ```object({ sessions_commit = string artifact_sha256 = string generation = string contract = string })``` | `null` | no |
| create\_private\_subnets | Optional two owned local-only private subnets in the existing default VPC. Explicit reviewed non-overlapping /24-/28 IPv4 CIDRs and distinct available AZs; mutually exclusive with private\_subnet\_ids. | `object({ first = object({ cidr = string, az = string }), second = object({ cidr = string, az = string }) })` | `null` | no |
| payload\_version\_id | Null provisions data without compute. A non-null immutable transport VersionId also requires a registered application activation; none is registered, so verifier execution stays refused. | `string` | `null` | no |
| private\_subnet\_ids | Exactly two reviewed existing private subnets in distinct AZs; null when create\_private\_subnets is selected. | `set(string)` | `null` | no |
| restore\_checkpoint | Null for seed. Supply only after a successful independently reviewed seed receipt; no secret values. | `object({ seed_receipt_sha256 = string, seed_receipt_version_id = string, secret_version_id = string, runtime_secret_version_id = string, seed_evidence_sha256 = string })` | `null` | no |
| retire | Reviewed cleanup apply disables the verifier and releases database deletion protection. | `bool` | `false` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| application\_binding | Expected application identities from the postgres-layout contract (non-secret). Metadata only: not SQL, bootstrap or application proof. |
| application\_sql\_ready | False: this fixture proves one service at most and does not qualify the separate-database application layout or a full installation. |
| proof\_contract | Non-secret source/lease/module/transport identities. Capture before guest termination. |
<!-- END_TF_DOCS -->
