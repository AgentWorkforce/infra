# Source/offline receipt

No cloud API, credential lookup, real plan/apply, SQL execution, deployment,
bootstrap, IAM rollout, image publication or cleanup was performed by this lane.
This is a held module-proof composition. Actual PG17/S3/restore proof remains
pending independently reviewed operator execution. Existing auxiliary fixture
results and Bulls' separate RDS bootstrap are not validation of this root.

Source base: `4df7bfd54d25aa520bcfe47c3544a87d77f7d3ac` (fresh origin/main).
Only this example path is changed. Exact tested commit and clean artifact hashes
are recorded in the held PR/evidence, avoiding a self-referential source receipt.

- Terraform 1.16.7 and OpenTofu 1.11.14 (CI pins), AWS 6.72.0 and random 3.9.1,
  darwin_arm64: backend-disabled init/validate and 25 mock-provider cases each
  passed. The OpenTofu run used an isolated T7 source copy; its registry/lock
  rewrite stayed in that copy and did not alter the committed Terraform lock.
  The bounded root uses two explicit subnet lookups so both engines test actual
  distinct-AZ/private-addressing guards without unsupported instance overrides.
  Owned-network cases additionally exercise two private subnets/local-only
  associations, mutually exclusive network modes, CIDR containment/overlap/
  canonical form/adjacency, foreign and same-lease inventory, explicit available
  AZs, default VPC and owner checks. No real subnet inventory was read.
- Offline plan/config graph proves 27 transitive prerequisites: verifier waits
  for DB/clone, exact IAM/profile and SG paths; clone waits for snapshot, primary,
  parameter and subnet groups. Both owned route associations precede the module
  DB/subnet group, clone and verifier. The sentinel waits for bucket versioning,
  encryption, public-access block, TLS policy, ownership and lifecycle setup;
  the native mock asserts an explicit versioned SSE-KMS sentinel output. The
  actual postcondition expression is also evaluated with six typed values in
  provider-free Terraform/OpenTofu consoles, refusing null/empty/whitespace/
  literal-null versions and accepting opaque nonempty versions. This avoids
  differing computed-value/failed-apply mock timing between the engines.
  Reverse graph ordering does not prove asynchronous
  native deletion; exact ID checks are required separately.
- TFLint 0.64.0 passed with the repository configuration. terraform-docs 0.24.0
  generated the README with the repository configuration; output-check passed.
  Formatting and Git whitespace checks passed.
- Checkov 3.3.30 scoped to this root including local modules: 99 passed, 0 failed,
  24 explicit skips. Deliberate single-AZ/short-lived monitoring/logging choices,
  protection-release expression and launch-template inheritance are documented
  inline. This is not a whole-repository scan.
- Real npm ci in this example's own T7 `proof/node_modules`, Node24.22.2;
  pg8.16.3/esbuild0.28.2 and a real package-lock. npm audit found 0 vulnerabilities.
  Node syntax and refusal-class regression passed. JavaScript is used here;
  no TypeScript project/typecheck is claimed.
- 15 Python offline tests passed: complete/invalid/foreign pagination, exact
  version-ledger cleanup, unknown-key/upload refusal before mutation, wrong
  native/credential error rejection and version/digest/source/path-bound archive
  extraction using a stub AWS command only. Owned-network checks reject missing
  ledgers, partial association lists, pagination and Denied; external network
  identities are never deletion targets. Python AST and Bash syntax passed.
- Committed-source payload builds must run twice and match exactly; the builder
  refuses any dirty worktree. It bundles pg and the host verifier, with a source,
  lock and per-file digest manifest. Exact artifact size/hash belongs in the PR
  evidence after committing the final reviewed source. It is unsigned and not
  a distributable application/provider artifact.

No cloud availability, IAM enforcement/propagation, private connectivity, actual
CA digest, managed secret history, PostgreSQL extensions/ACL, RDS snapshot restore,
S3 runtime behavior, or teardown success follows from these source checks.
Retained automated backups, service-created ENIs, managed-secret retirement,
complete S3 versions/markers/multipart capture and both compute lifetimes require
native evidence. Missing/foreign/Denied/partial state blocks a clean result.
