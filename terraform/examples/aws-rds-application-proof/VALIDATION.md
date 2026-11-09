# Source validation and live gates

> **Superseded for the guest flow.** This records validation of the earlier guest composition, which could not be recovered. The guest now runs `rds-activation/v1`; see README "F1 status".

This new example is based on main201f06 (including independently reviewed65/66),
with unchanged shared modules and unchanged Sessions composition292359. Exact
candidate/final head and payload hashes live in the held PR/external receipts to
avoid self-referential commit fields. Original five-file protocol freeze7baaba3
has independent root and GCP SOURCE PASS after13tests each. No AWS call, credential
retrieval, real Terraform plan/apply, platform grant or deployment occurred here.

Source checks completed before installed-payload review:

- Terraform1.16.7 and OpenTofu1.11.14 backend-disabled init/validate and29mock cases
  each: actual modules, empty owned SM container, exact runtime ARN/deadline IAM,
  private network, historical refs, account/lease/AMI/source/deadline refusals,
  protected seed/restore and explicit retirement. ToFu uses isolated T7 source
  copy and verified registry package locks, never changes committed HashiCorp lock.
- Offline config graph checks29transitive relationships: sentinel awaits bucket
  versioning/encryption/public-block/policy/ownership/lifecycle, RDS and verifier
  await private route associations, snapshot/clone/network dependencies, and host/
  role await runtime container. The helper initializes only an empty temporary
  local backend with AWS credentials/metadata disabled; it never runs a plan/API.
  Six typed sentinel VersionId cases pass under both engines, refusing null/empty/
  whitespace/literal-null. Reverse graph still needs native asynchronous absence.
- Python tests cover closed protocol/sequence/duplicate JSON keys, pre-restore auth,
  both rotations, complete receipts/publication/persisted readiness, bounded RAM IO,
  owned process-group timeout/reaping, exact SM ARN/VersionId and stdin-only value,
  expired deadline, nested credential errors, complete zero-version/zero-host
  failure inventory and foreign/truncated/duplicate refusal, S3 unknown keys/MPUs,
  pending versions and pinned sentinel preservation, archive tamper/traversal/link/
  duplicate/decompression limits, rendered shell and embedded Python syntax.
- New-root TFLint0.64.0 and repository terraform-docs0.24.0 checks pass. Pinned
  Checkov3.3.30 new-root scope:93passed/0failed/26documented skips. AWS-managed
  service encryption, short single-AZ capacity and explicit synthetic host rotation
  are bounded proof choices; no production/default-module policy is weakened.
- Original clean guest source: real npm-ci attempt refused absent npm lock, real
  Bun1.4.2 frozen install succeeded. Fresh owner guest/profile tests159pass and full
  root/workspace typecheck pass. All34owner inputs remain byte-identical, with no
  protected SQL/generation/versions.lock edit. These are source tests, not RDS proof.

Preparatory installed evidence is in PREP-VALIDATION.md: original TypeScript/source
assets import on native and Linuxarm64 Node24; actual detached psql17 stdin/client
SCRAM/rotation28P01/TLS negatives passed on a synthetic local server without RDS
catalog emulation or actual guest SQL. All own final containers/network/new volumes
were absent; parent subsequently retired the entire first owned VM/disks, including
two older anonymous volumes whose individual event records were unavailable.
These preparatory archives are distinct from the final committed transport+CA payload.

The final payload must be built twice from the clean exact committed source with
all frozen transitive files, actual pg lock closure, source/generation/lock/provider
and explicit public CA hashes. Final installed import/client/adapter checks and
complete parent-driver source review are separate required receipts. Dirty/source-
only payloads are operationally refused, never upgraded by documentation.

Actual native engine/extension availability, RDS role/catalog hooks, managed-secret
historical continuity, original guest SQL/grants/runtime readiness, snapshot restore,
all complete native inventories and full finally retirement remain future parent-
operated live gates after two independent complete source reviews and exact saved-
plan admission. Existing RDS SLR/regional AWS-managed keys are baseline prerequisites,
not newly owned cleanup targets. Do not interpret source/mocks or this bounded SQL
fixture as OpenSearch/provider/projection-state/Lambda/full-suite proof.
