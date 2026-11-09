# Source validation receipt

Base: `d3040fa209ef5c90ce61bde2a776f783c01cfaba` (fresh origin/main, including PR64).
The branch also merges main `dd5185a6e381df98ebee1626de605c428b31b4b7` (PR66 Lambda
environment bindings), preserving the prior review/fix history.
Only this new example and the explicitly reviewed `modules/aws/search` lifecycle
seam change. Exact tested head/source hashes are recorded in the held PR and
external receipt, avoiding a self-referential commit value here.

No cloud calls, credentials, live plans/applies, protected SQL, IAM deployment,
profile activation, image publication, merge or runtime provider proof occurred.
This Terraform/Python-only worktree has no npm manifest and required no npm
install, invented lockfile or dependency symlink.

- Terraform 1.16.7 and OpenTofu 1.11.14: backend-disabled init/validate; seven
  portable module cases and thirteen root cases pass under each engine. Disposable
  native mock apply/teardown succeeds; protected defaults remain literal guarded.
- Terraform-only historical state test shares mock state from the unindexed
  module at the base commit, applies the new default module and asserts the same
  randomly generated resource ID; protected-to-disposable planning is refused.
  The expected protected mock teardown also refuses destruction. This uses
  `state_key`, unsupported by OpenTofu 1.11, and is not a real customer migration.
- Full source parity check compares every domain argument/security block across
  protected/disposable branches, excluding only count and the literal guard.
- Native first-create plans under both engines resolve the policy ARN/JSON and
  passed the then-current fixed product-configuration guard. The current helper
  uses those same private configuration checks only; native `test_plan` UI does
  not establish strict saved-plan/prior-state history admission or apply
  authority. Runtime callers always admit that history separately first. Only
  deterministic computed `tags_all`
  is explicitly supplied in the test helper; no policy/security/nested identity
  overrides or production normalization occur. The original `fd5799c` apply-first
  native tests plus synthetic JSON did not catch the module-wide dependency's
  deferred-policy defect. Its historical failing plan remains review evidence;
  the root dependency is removed while all fully known plan preconditions and
  fresh wrapper identity checks remain intact.
- Existing AWS example (two cases) and aws-environments (37 cases under Terraform and OpenTofu) pass in an
  isolated T7 source copy using the changed shared module. No consumer source is
  edited; the separate Lambda environment-binding follow-up remains open.
- Twenty-four Python offline tests cover all original context hashes, stale/foreign
  context, fresh caller versus cached plan identity, original approval versus
  current teardown hashes, all 16 immutable fields and durable seal/receipt hashes,
  missing/tampered seals, expiry versus historical provenance, pre-apply sealing,
  successful capture and partial-apply pending preservation, exact create/delete payload/address fences, public
  policy/role/metadata/capacity refusal, SG peers, incomplete ENI pages, typed
  NotFound/credential error distinctions, no capability-to-common permission
  fallback, inherited refresh metadata and unrelated evidence preservation.
  The original `fd5799c` runner validated only seven packet hashes and did not
  retain approval ID/fingerprint/expiry after capture. This source correction
  seals all 16 fields; the old validation receipt is not retroactively upgraded.
  An inert local Python parent/grandchild timeout preserves partial output and
  proves its owned process group absent; it invokes no AWS or credential tool.
- TFLint 0.64.0, Terraform formatting, Python AST, Git whitespace and repository
  terraform-docs 0.24.0 output checks pass for the module/root.
- Checkov 3.3.30 whole Terraform tree: 447 passed, zero failed, 110 documented
  skips. New proof root/local module: 18 passed, zero failed, nine skips. Its
  explicit master/HA and content-log exceptions are bounded disposable choices;
  existing protected defaults/security inputs are not weakened.

AWS provider is pinned to 6.72.0 in the committed Terraform lock. OpenTofu checks
use an isolated source copy and its separately verified registry package lock
for the same version; those distribution/checksum changes never modify the
committed lock. Provider binaries are not claimed byte-identical across registries.

Native DNS/routes/NACL/private connectivity, service-linked role and external
identity availability, capability deployment/human provenance/expiry, managed
domain behavior, FGAC/data runtime, exact service ENIs and asynchronous retirement
remain future independent operator evidence. The source runner has not executed
an operational plan. Pending/partial applies require exact-owned recovery, not
an empty-state inference or state/protection bypass.
