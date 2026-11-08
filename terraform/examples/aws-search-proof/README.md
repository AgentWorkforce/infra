# Disposable private OpenSearch control proof — held source

This independent product root composes the actual `modules/aws/search` module.
It creates one disposable VPC domain and its exact domain access policy, with
one or two `t3.small.search` nodes and 20-GiB gp3 per node. Engine version is an
explicit region-supported input. It retains encryption at rest/node-to-node,
HTTPS with the PFS TLS policy, IAM fine-grained administration, no internal
users and no anonymous access. This is a bounded control-plane composition;
single/two-node sizing is not a production or HA recommendation.

All account/lease, VPC/private subnets, exclusive domain SG, client SGs, distinct
same-account admin/indexer/reader roles, service-linked role, baseline KMS and
capacity prerequisites are external. This root creates no IAM, network, log
group, account, image, grants, SQL, private provider or running application.
`workload_roles.create=false` is fixed. No existing whole-application role fence
is loosened. The domain policy names exactly the three supplied roles; IAM HTTP
permissions/boundaries/trusts and FGAC mappings remain separately reviewed
product identity/bootstrap prerequisites. POST permissions alone are not
read-only data authorization. No private source is imported or republished.

**Source only / held.** This lane performs no live plan/apply, cloud call,
credential retrieval, platform change or runtime proof. The scripts below are
future operator steps after independent review and the separate human platform
gate. The existing common caller is unchanged. Search capability source/CLI and
server approval/install/lifecycle/sweeper deployment are separate prerequisites;
a committed renderer, local client file or peer message is not platform approval.

## Source seam and retirement

The shared module keeps literal `prevent_destroy=true` by default. An explicit
`moved` maps its historical unindexed address to `this[0]` without recreation.
The new `disposable=true` branch has the identical complete domain configuration
and literal `prevent_destroy=false`, and is selected only from inception by this
root. A protected domain cannot be converted by toggling the flag: its still
configured literal guard blocks destruction even at count zero. Do not switch
modes, edit lifecycle protection, remove state, import a domain or use a native
delete to circumvent it. Normal proof teardown is a reviewed Terraform destroy
against intact state. Existing protected domains require their own separately
reviewed lifecycle/source decision.

The local state is deliberately isolated from foundation/data/application and
other proofs. Use a private mode-0700 directory on encrypted storage, on T7 on
this Mac, and preserve state/recovery copies until native absence. The runner
generates its literal local backend and private Terraform CLI config; it binds
backend config/metadata, default workspace, current state, exact provider lock,
selected provider/Terraform executable hashes, clean source, inputs and runner.
It excludes provider dev overrides and inherited variable/CLI/log overrides.
Do not use this disposable local-state arrangement as durable customer state.

## Identity and approval contract

Initial preparation runs inside the ordinary refreshing Pippen CLI environment
with fresh CLI STS identity equal to the allocated common `agent-session` lease.
That identity is honestly recorded by Terraform as **plan identity only**. A
saved plan may retain it at apply; it is never proof of the applying principal.
Initial common-role planning cannot establish native OpenSearch absence.

The root's input/existing-resource preconditions are fully known during planning.
It deliberately has no module-wide dependency on the new local guard resource:
that would defer the module's account/region/partition reads and hide the
permission-bearing policy JSON until apply. Those reads must stay plan-known;
the local guard is a plan-time check, not fresh apply authorization.

Creation/control/destruction require the exact future lease-specific
`/pippen/provisioning/search-control-v1-<full UUID>` role and
`search-<UUID>` STS session. Before actions the runner reads inherited
`PIPPEN_SANDBOX_CAPABILITY_CONTEXT`, validates its closed nonsecret server-response
shape and all original creation-packet hashes, then calls fresh CLI STS. It
never invokes the credential-bearing credential process to inspect metadata,
reads client certificate/key files, or accepts a local approval file as authority.
It preserves the inherited context for SDK credential refresh. The selector is
ephemeral per CLI invocation, never a saved source credential profile.

The immutable context is expected-response provenance from the selected reviewed
CLI. It does not independently authenticate a human or enforce IAM API payloads.
The human-approved `trusted-proof-operator` model acknowledges arbitrary calls
within the approved IAM caps. Human/platform provenance, installed policy/trust
integrity and mint/revocation remain Pippen's authority. Local guards reduce
mistakes; an operator who holds credentials is not constrained by plan hashes in
AWS IAM. Do not claim otherwise.

The creation packet now records `search_mode_history`, rechecked from native saved-plan prior state and before IDs immediately before apply. The mandatory shared pure classifier and this root's closed contract allow only the fresh disposable domain, its exact domain policy, root guard and the new built-in creation-mode marker; no new AWS address/action is allowed. Full captured destroy includes both built-in markers. Old/unmarked domain retirement first requires separately reviewed unchanged-mode enrollment; this fresh-lifecycle root does not adopt or enroll an old domain. Do not repin an existing fixture's immutable source/inputs to add a marker. Raw Terraform first-enrollment provenance and the pinned Tofu legacy shared-state harness gap remain limits documented by the module.

The creation packet binds the actual original plan, inputs, source, provider
lock/binaries, artifact and backend/state digests. Here `artifact_sha256` covers
the committed public product source/runner plus fresh network baseline and the
literal CLI config; it is not a Lambda ZIP or private provider artifact. Seven
fixed exact-case tags include the three owners, `proof:source`, Environment,
EnvironmentClass and ManagedBy. All must be within the profile's <=8 approved
keys. Complete metadata is immutable: no retagging to accommodate provider deltas.

Immediately before the first reviewed creation apply, the runner atomically saves
`original-capability-context.json`: exactly the sanitized 16 inherited fields,
without credentials or per-token expiry. It never overwrites this provenance
seal. Pending/captured phases, the raw candidate, creation and teardown records,
and domain/ENI receipts bind its file SHA256. Every subsequent selected operation
requires all 16 inherited fields to equal this original record, including
approval ID, fingerprint and immutable profile expiry. A changed or missing seal
quarantines the lifecycle before selected AWS calls. Common-role ENI reads verify
the sealed record/hash without treating its historical expiry as current
authority; selected operations still require fresh, unexpired context and STS.
The local file does not confer approval or independently prove server provenance.

Cleanup keeps the **original** server approval/context unchanged. It separately
hash-reviews a current delete-only saved plan and current state, under the same
fresh exact capability identity and original domain/metadata scope. The server
does not thereby approve a new destroy-plan hash. Never repin the immutable
approval, extend an expired profile identity, or fall back to the common caller
for es mutations. Profile expiry must cover creation plus cleanup; the runner
requires two hours remaining at creation and one hour at destroy. Missing or
expired authority requires separately approved platform recovery/sweeper work.

## Future operator stages

Use the reviewed CLI's ordinary/capability exec forms once that CLI/server source
is independently approved and installed; no enrollment or installation command is
provided by this product. Copy `inputs.example.json` into a private complete JSON
input file with actual reviewed references and the final clean commit. Use an
approved Terraform binary. The same source checkout, provider binaries, variables,
network baseline, backend and state remain fixed through the entire lifecycle.

The command shape is `python3 proof/runner.py OPERATION --execution PRIVATE_DIR
--variables PRIVATE_INPUTS_JSON --terraform APPROVED_TERRAFORM_BINARY`.

1. In ordinary common-role exec, run `network-before`. It verifies fresh identity,
   existing VPC DNS, private distinct-AZ subnet metadata, peer-only HTTPS domain
   SG, zero pre-existing ENIs on that exclusive SG, exact existing external data
   role ARNs/IDs and the existing OpenSearch service-linked role. Routes/NACL/return paths, external role trust/permissions,
   region/version/type availability, quotas and sweeper readiness also require
   explicit external review. No SLR/network/role is created or retagged here.
2. In ordinary exec, run `prepare`. It requires empty fresh local state and emits
   the exact creation saved-plan/packet hashes. Review the complete JSON payload,
   native prerequisite evidence, policy principals, bounded size and absence of
   IAM/log/network work. Supply these exact hashes to the separate protected
   server human approval process. The baseline must be no older than 15 minutes
   at apply; if it expires, prepare a new packet/approval, never replace it in
   the already approved packet.
3. In selected capability exec, run `apply` with `--reviewed-plan-sha256 SHA256
   --reviewed-packet-sha256 SHA256`. Context hashes, fresh STS, source/state and
   typed native `DescribeDomain` ResourceNotFound are required immediately before
   creation. Existing/foreign/unknown domains are refused, including an untagged
   collision in the truncated lease-derived name. Successful creation is not
   adoption authority. A pending marker is durable before apply; raw output is
   saved before native verification, then exact owned metadata/network/security
   is captured. No content/HTTP or application conformance is exercised.
4. In ordinary exec, run `network-created`. The narrow control profile has no
   `DescribeNetworkInterfaces`; this deliberate separate common-role read phase
   captures every service-managed ENI on the exclusive initially-empty domain SG,
   bound to the exact domain capture/VPC/private subnets. Unknown/shared producers
   quarantine; never add profile grants, detach or force-delete an interface.
5. In capability exec, run `prepare-destroy`, independently review its current
   all-delete plan and state hash, then run `destroy` with those two reviewed
   hashes. The guard permits exactly the original domain/policy/local guard
   addresses and physical domain identity; no create/update/replacement/import.
   This is separate local cleanup review under original trusted-operator scope,
   not a fabricated fresh server approval.
6. After asynchronous service retirement, in capability exec run `domain-absence`
   (exact typed ResourceNotFound), then in ordinary exec run `network-absence`
   (complete empty exclusive-SG inventory plus typed NotFound for **every captured
   ENI ID**). Retain both identity-specific receipts. Denied, credential errors,
   partial pages, a deletion request or an empty generic response are not absence.
   Existing VPC/subnets/SGs/roles/SLR/KMS baselines remain external and preserved.

Every attempted creation, failed/partial apply, interrupted subprocess or
incomplete capture is quarantined. There is no blind retry, automatic clean-state
inference or restart/resume from a stale ledger. Preserve saved plans, private
command outputs, raw contract, phase marker and state; reconcile exact planned
names/native resources under retained approved authority. Provider/API cancellation
does not cancel asynchronous AWS work. An external operator deadline/observer and
qualified sweeper are mandatory; process timeouts alone do not retire resources.
The runner persists partial logs and stops/reaps its own subprocess group before
returning, but does not make account-wide cleanup claims.

## Offline validation and limits

Use backend-disabled init/validate and native mocked Terraform/OpenTofu tests;
run Python `unittest discover -s proof`, module `tests/check_lifecycle.py`, and
Terraform-only `tests/check_migration.py /path/to/terraform`. The latter shares
mock state from the exact historical module through `state_key`, asserts the
same resource ID after the default migration, then requires protected conversion
and mock teardown to fail. OpenTofu 1.11 lacks this test feature, so its portable
module mocks are separate evidence. No real migration or domain was performed.

`python3 tests/check_first_plan.py /path/to/terraform` (repeat with OpenTofu)
validates the actual native first-create mocked `test_plan` UI with the same
private fixed product-configuration checks used after strict runtime history
admission. UI output is not saved-plan/prior-state evidence: this helper does
not call history admission, prove ownership or authorize apply. Runtime
`changes()` always performs strict native saved-plan history admission first,
then those same closed address/policy/FGAC/disposable-boolean checks. The helper
is mandatory in the known search-proof CI block on both pinned engines.
Only the generic AWS mock's computed `tags_all` is explicitly substituted with
the configured tags in this test helper. Policy/security values and nested
account/region/partition data are never overridden or normalized. No production
normalization exists. The earlier `fd5799c` synthetic-plan/apply-first tests
missed the deferred-policy defect; the native first-plan regression closes that
coverage gap. Unconfigured domain policy readback, service-generated IDs/endpoints
and the AWS-managed KMS key ID may remain computed; the standalone policy payload
and all configured security/identity inputs consumed by the guard must be known.

TFLint, repository-config terraform-docs, Checkov, Python AST and Git whitespace
checks apply. Terraform-only source has no npm manifest/install or symlinked
dependencies. Mocks establish source contracts, not managed-domain behavior,
FGAC/runtime IAM enforcement, Unicode/provider conformance, application schema,
private HTTP reachability, data backup/restore or full-suite acceptance.

Primary references: [Terraform lifecycle literal rules](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle),
[Terraform test shared state](https://developer.hashicorp.com/terraform/language/tests),
[OpenSearch domain deletion](https://docs.aws.amazon.com/opensearch-service/latest/APIReference/API_DeleteDomain.html),
[OpenSearch IAM actions](https://docs.aws.amazon.com/service-authorization/latest/reference/list_es.html).

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, < 2.0 |
| aws | = 6.72.0 |

### Providers

| Name | Version |
| ---- | ------- |
| aws | = 6.72.0 |
| terraform | n/a |

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| search | ../../modules/aws/search | n/a |

### Resources

| Name | Type |
| ---- | ---- |
| [terraform_data.guard](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [aws_caller_identity.plan](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/data-sources/caller_identity) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/data-sources/region) | data source |
| [aws_security_group.clients](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/data-sources/security_group) | data source |
| [aws_security_group.domain](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/data-sources/security_group) | data source |
| [aws_subnet.first](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/data-sources/subnet) | data source |
| [aws_subnet.second](https://registry.terraform.io/providers/hashicorp/aws/6.72.0/docs/data-sources/subnet) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | Exact existing sandbox account; no account vending. | `string` | n/a | yes |
| approved\_tag\_keys | Exact profile-approved metadata keys, at most eight. No arbitrary tag values are accepted. | `set(string)` | n/a | yes |
| client\_security\_group\_ids | Reviewed existing client SGs permitted by the domain SG; no network changes or workload installation. | `set(string)` | n/a | yes |
| domain\_security\_group\_id | Existing exclusive domain SG: only HTTPS ingress from the exact client groups; no world/prefix ranges. | `string` | n/a | yes |
| engine\_version | Explicit region-supported OpenSearch engine version reviewed separately; never a guessed latest default. | `string` | n/a | yes |
| pippen | Expected existing lease identity; immutable for the entire proof. | `object({ agent = string, session_id = string })` | n/a | yes |
| region | Explicit approved existing region. | `string` | n/a | yes |
| roles | Pre-existing distinct same-account admin, indexer and reader IAM role ARNs. This root never authors IAM/trust/grants. | `object({ admin = string, indexer = string, reader = string })` | n/a | yes |
| source\_sha | Exact clean committed Helm source; also bound by the source runner. | `string` | n/a | yes |
| subnet\_ids | One or two existing private subnets, one per distinct AZ. Single-AZ is explicitly disposable and has no HA claim. | `list(string)` | n/a | yes |
| vpc\_id | Reviewed existing VPC; never modified by this root. | `string` | n/a | yes |

### Outputs

| Name | Description |
| ---- | ----------- |
| proof\_contract | Nonsecret immutable domain/external prerequisite identity; plan caller is explicitly not apply evidence. |
<!-- END_TF_DOCS -->
