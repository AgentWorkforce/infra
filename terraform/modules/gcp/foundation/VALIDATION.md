# Source validation — 2026-11-06

This receipt covers source/offline validation only. No cloud credentials, GCP
project reads, live plans/applies, deployment, IAM rollout, DNS changes, teardown,
state import or API enable/disable was performed.

- Terraform 1.16.7 (CI pin), darwin_arm64: `init -backend=false`, `validate`, 22 module mock
  cases and 2 thin-root mock cases passed.
- OpenTofu 1.11.14 (CI pin), darwin_arm64: the same 22+2 cases and validation passed in an
  isolated source copy on T7, with `init -backend=false`.
- Google provider 7.46.2; random 3.9.1 only for the existing PostgreSQL test
  composition fixture (administrator creation disabled, no generated password).
  This is the real local provider: Terraform 1.16 does not support mocked
  ephemeral types even when the resource has zero instances.
  Root lock pins Google; reusable module floor is the tested 7.46.2, <8.
- TFLint 0.64.0, terraform rules 0.15.0, Google 0.40.0, AWS 0.49.0: both module
  and thin root passed with the repository configuration.
- terraform-docs 0.24.0: generated README sections and drift checks passed.
- Checkov 3.3.30 (CI pin), **whole `terraform/` tree**: 178 passed / 0 failed /
  51 inline skips. This corrected the earlier module-only coverage gap: the
  whole-tree graph now sees an explicit logged deny-all ingress firewall bound
  to the owned custom VPC. No ingress allow or firewall-check skip was added.
  A separate narrow CKV_GCP_21 label false-positive exception is documented below.
- `terraform fmt -check -recursive` for both owned paths and Git whitespace
  checks passed.

The new resource-local `CKV_GCP_21` exception preserves the unconditional
`merge(customer labels, reserved environment/managed-by)` map. The pinned
whole-tree scan received that nested expression as unresolved and failed its
literal-dictionary/nonempty check; a diagnostic source copy with only literal
cluster labels passes the same check. No plan/apply was run on that diagnostic
copy. A mock-plan regression asserts final reserved labels cannot be overwritten
and customer labels survive, rather than deleting labels or changing precedence
to satisfy the scanner.

Other skips are specifically documented inline: Dataplane V2 instead of the legacy
Calico flag; external customer Google Group/RBAC authority; external Binary
Authorization policy/attestors; and Google-managed topic encryption unless the
operator supplies approved CMEK. Other fixture skips belong to unchanged existing
capability modules. No security check is globally disabled.

The composition fixture exercises the existing PostgreSQL, object-storage and
functions modules against mocked foundation outputs. PostgreSQL uses distinct
relaycontrol, relayhistory and hoopdb databases; objects use exact KSA Workload
Identity; functions consume the VPC connector and bucket. Search is a later
Kubernetes/Helm application-state consumer of the cluster reference, not installed
in foundation tests/state. No access token provider or service-account key is
created.

Tests assert the explicit logged VPC ingress deny baseline and private GKE/API defaults, node metadata/identity/PD CSI, secondary
ranges, PSA retention, scoped NAT, exact publisher/subscriber principals,
dead-letter forwarding, TLS+AUTH and managed Redis acknowledgment, deletion
protection/protection-release shape, output contract, plus invalid project,
project-number mismatch, environment mismatch/invalid environment, public-wide
and IPv6/empty operator access, overlapping/public networks, actor zone mismatch,
and guessed GKE version rejection. Connector regressions check Google's effective
length rule (hyphens count twice), maximum-length and maximally hyphenated accepted
prefixes, the usual agent-relay prefix, distinct full prefixes with identical
leading characters, environment separation, and a fixed deterministic name.
A label regression verifies reserved identity labels and customer-label preservation.

Mock success does not establish project service-agent readiness, available GKE
versions/channel, organization policy, capacity/quotas, private connectivity,
image pulls, IAM propagation, SQL bootstrap, secret delivery, actual application
queue/Redis compatibility, ingress/certificates/DNS, E2E, convergence,
destroy/recreate or isolated restore. This source is held for review. The existing
GCP proof and its separate Alchemy/CLI/Helm ownership remain untouched. See README
for the Redis AUTH-in-state constraint and approved retirement prerequisites.
