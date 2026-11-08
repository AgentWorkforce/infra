# Terraform and Helm application proof

The target is a complete customer-owned installation, provisioned through this
repository's Terraform roots and installed through its Helm charts. Passing
module validation, a healthy pod, a mock provider test or an older Alchemy
installation does not establish that result.

## Required relational storage

The current target is [one RDS instance and one application database with isolated
service schemas](shared-postgres-storage-contract.md), including Control, HoopDb
and Relaycast. SQLite and separate-database receipts remain historical evidence;
they do not satisfy this target. Verify schema-aware migrations, owner/runtime
separation and cross-schema access refusals on actual managed RDS.

## Evidence status — 2026-11-07

| Layer | Evidence available | Remaining requirement |
|---|---|---|
| Terraform source | AWS/GCP module validation and mock-provider checks in CI | Checks on the final composed source and locked providers |
| AWS managed data | Scoped synthetic RDS/S3 create, use, restore and cleanup receipts | Bind the complete application to its own Terraform-managed data resources |
| AWS foundation and application | Historical EKS/Helm proof, plus partial artifact checks | Fresh Terraform foundation lifecycle, managed RDS activation, deployed Lambda/OpenSearch path and the complete application trace |
| GCP foundation and application | Retained GKE/Cloud SQL installation and historical Helm proof | Terraform-created foundation/data lifecycle and the complete application trace on that installation |
| Recovery and retirement | Partial fixture recovery/cleanup evidence | Restore the complete deployment, repeat application checks, then prove owned teardown and retained-data disposition |

Full application proof is **OPEN**. AWS execution is blocked by the proof
sandbox's quarantine; its stored cleanup reason does not independently prove
which native resources still exist. Recovery requires the sandbox owner's
reviewed inventory and recovery path. Do not bypass it with a new lease, state
removal or changed IAM. RDS migration-emulation results do not establish that
customer RDS LOGIN activation works; that needs its own reviewed path.

## Source and execution contract

Use separate state for foundation and data/application infrastructure, with an
explicit account or project number, region, environment and backend key. Start
with [the Terraform entry point](../terraform/README.md), the
[AWS environment composition](../terraform/examples/aws-environments/README.md)
and the [GCP foundation root](../terraform/examples/gcp-foundation/README.md).
Pin the repository commit, provider lock hashes, saved-plan hash, application
source commits, chart package digest, image digests, migration generation and
non-secret values digest in each execution receipt. A later source change
requires a new review and proportional rerun; never relabel an older result.

Before apply, enumerate the exact owned resources, cost limits, retention,
protected/adopted resources, runtime identities, DNS authority and cleanup
order. Existing shared proof resources are not disposable targets. Credential
values belong in the approved secret system, never Terraform input files,
Helm values, command arguments or proof receipts. State and saved plans may be
sensitive and need restricted storage even when application secret delivery is
out of band.

GCP setup and recovery follow the
[GCP installation skill](../.agents/skills/setting-up-self-hosted-agent-relay-gcp/SKILL.md),
including project-number/context admission and review of the exact execution
plan. Infrastructure apply, application install, upgrade and teardown have
separate evidence and recovery requirements.

## Required lifecycle

1. **Fresh provisioning.** Apply the reviewed Terraform foundation and data
   plans into the admitted environment. Verify resource IDs against state and
   native APIs, private connectivity, least-privilege workload identity,
   encryption, backup and retention settings. Record any adopted prerequisites.
2. **Application bootstrap.** Install distinct migration-owner and runtime
   identities, extensions and the exact schema generation. Verify runtime ACLs
   using real non-owner connections. For RDS, prove activation on managed RDS;
   local superuser emulation is separate evidence. Build a complete non-secret
   Helm overlay from the actual outputs and existing Secret references.
3. **Helm installation.** Install the pinned packages and images; require
   completed migration Jobs, ready workloads and working public TLS. No Helm
   `--atomic`: it cannot reverse database or object-data changes.
4. **Complete user trace.** Through the deployed control plane, create an
   organization/workspace, sign in through Dashboard and Desktop, register two
   agents, exchange a message and reply, and upload a marked real session.
   Require pipeline ingestion, list/replay/search visibility and one durable
   result after a duplicate delivery. Use a second workspace/tenant for denial
   tests, including direct runtime reads. Restart the relevant workloads and
   repeat the reads. Exercise erasure and require all read paths to stop
   returning the session.
5. **All requested components and profiles.** Include RelayControl, Dashboard
   (target product relay-app; current chart `relay-dashboard`), Sessions Pipeline,
   RelayHistory and Relaycast with authoritative PostgreSQL state in its own
   schema on the shared RDS/database. Prove runtime placement, transaction
   semantics and durable recovery; do not count a SQLite-backed profile. Run the
   reviewed base values plus each selected add-on overlay as separate proof runs;
   the add-on overlays are not standalone installations.
   Exercise Relayfile and Flows when enabled. Pin the reviewed authentication
   contract for each run. The current umbrella chart and requirements registry
   still require RelayAuth for their JWT profile. The target architecture removes
   it from core only after the replacement is implemented and qualified; this
   document does not change those current requirements or define a new installable
   profile. That replacement, using relaycontrol introspection, must prove real
   caller, scope and tenant binding, expiry/revocation
   and fail-closed behavior on introspection failure. Disabling RelayAuth in
   Helm is not proof of replacement authentication. Read-access-only evidence
   does not establish ingest authorization: the complete trace still requires
   the reviewed write/machine-attestation path. Historical RelayAuth results
   remain evidence only for the profile that produced them. Where functions/search are selected, prove
   the actual Lambda/SQS/OpenSearch or GCP function/search dispatch, retries,
   DLQ behavior, role separation and completeness semantics. Do not count a
   worker-only trace as proof of the event-driven mode. Keep exactly one
   pipeline owner active.
6. **Isolation and upgrade.** Use separately owned environments to prove state,
   IAM, queues, objects and tenant data do not cross boundaries. Capture a
   coherent recovery set, restore it into an isolated target and verify the
   same application trace. Perform the reviewed idempotent Helm upgrade and a
   second Terraform plan; require no unexpected changes or migration replay.
7. **Retirement.** Quiesce writers and record retained resources first. Remove
   only the receipt-owned application, DNS and identity bindings, then data and
   foundation in dependency order. Preserve approved recovery/state storage.
   Verify native typed absence and empty owned Terraform state where deletion
   was intended; retained resources need explicit owner and disposition. A
   successful destroy command alone is insufficient.

## Existing drivers and their limits

- [GCP application driver](../scripts/selfhost/e2e-gcp-proof.sh) and its
  [Node driver](../scripts/selfhost/e2e-gcp-proof-driver.mjs) exercise the deployed
  suite. Review their current assertions and supplement missing lifecycle
  cases; they do not provision Terraform infrastructure.
- [EKS application driver](../scripts/selfhost/e2e-eks-proof.sh) adds AWS edge and
  identity checks. Its historical sandbox/install scripts are not evidence of
  a Terraform foundation apply.
- [AWS environment verification](../terraform/examples/aws-environments/README.md#live-verification)
  covers selected data/search/function bindings. Its application contract
  output is not a deployable Helm overlay or a complete user trace.
- [Customer release gate](../scripts/release/validate-customer-release.py)
  checks the supplied release evidence. Keep failures and partial evidence;
  do not invent a passing receipt to unblock a release.

Publish a final result only when every selected layer has a source-bound
receipt, all required positive and refusal cases pass, recovery is demonstrated
and the owned teardown or approved retention inventory is reconciled. Customer
image publication and the sales/customer compatibility review follow that
proof; they do not substitute for it.
