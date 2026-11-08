# Pending writer bootstrap source review

Initially reviewed pipeline [#336 at e680a29a](https://github.com/AgentWorkforce/relayhistory-pipeline/pull/336),
full source revision `e680a29aeffaa69029ed6ec4775ffd5c83f1136c`. The current
source follow-up is `4bec3158a446da080416b0291cb01cc42e4bf37b`, still an open
draft. The two bootstrap defects below are fixed in that source, LOGIN wording
is aligned, and schema USAGE on `sessions` is explicit. Test execution is
owner-reported; infra inspected its source and has not rerun the native PG suite.
The PR was open and draft when checked. This is source review and a read-only
PostgreSQL catalog lookup, not a writer deployment or bootstrap execution.
The kind reader and writer remain disabled.

The reader's #330 head subsequently advanced to
`0f2e866395c9122721262bb16d1430084955c878`, including tenant-RLS/admission and
bare-pool fail-closed fixes. Those changes do not alter the three reader
bootstrap SQL files in the source checksum list, but the current writer at `4bec3158`
has not been qualified together with that newer adapter/runtime source. Their
Git ancestry diverges at `441e4862`, and the adapter and reader Lambda blob
hashes differ. Rebase-to-main alone does not supply a combined qualification. A
single approved combined image and generation must replace separate-head
assumptions before operator wiring.

## Historical bootstrap defects, fixed in current source

1. At `e680a29a`, `src/session-pipeline/consumer-bootstrap.ts:136` called
   `hashtextended('search-consumer-bootstrap', 0)`. The PostgreSQL function is
   `hashtextextended(text,bigint)`. A read-only lookup on the existing kind
   PostgreSQL 17.11 instance returned NULL for
   `pg_catalog.hashtextended(text,bigint)` and the correct signature for
   `pg_catalog.hashtextextended(text,bigint)`. That source revision therefore
   could not acquire its advisory lock; `4bec3158` uses the correct name.
2. At `e680a29a`, `serve` opened a transaction before `runBootstrap`, but
   `ensureRole` submitted `supabase/bootstrap/session_consumer_role.sql` with its own `BEGIN` and
   `COMMIT`. `stripPsqlMeta` removes only psql metacommands. Once the lock typo
   is fixed, that embedded `COMMIT` would commit schema and role work before
   `verifyRole`; a subsequent verification failure cannot roll it back.
   The inner wrapper is removed in `4bec3158`. Full-bootstrap failure
   injection is still needed to guard that transaction boundary.

Both findings were sent to layered-sessions-pipeline and pipeline-lead. Infra
does not patch the pipeline entrypoint or bypass its role checks.

The new native test named "verify failure rolls back atomically" begins a
transaction, adds a stray TRUNCATE grant, executes verification, and rolls back.
It does not execute the role bootstrap SQL or `runBootstrap` inside that failing
transaction. Consequently it would not catch reintroducing the original inner
COMMIT. Required regression evidence must run the full bootstrap under the
production transaction boundary, inject verification failure, and prove its
new schema/role/grant effects roll back.

## Contract facts and remaining proof

- This revision requires `READ_API_COMPLETE_SINCE` and passes its parsed floor
  into `writerComposition`; the earlier proposal with an implicit zero floor
  is superseded. Writer and reader still need the same configured backend ID
  and coverage floor.
- The role SQL creates and verifies a dedicated LOGIN, NOINHERIT,
  NOBYPASSRLS `search_consumer_runtime`; the prior wording mismatch is corrected.
  The privileged one-shot bootstrap executor and production grant/identity
  contract still need qualification before chart credentials are wired.
- The role SQL grants this new role EXECUTE on eight `sessions` RPCs. A final
  exact-ACL check against the approved image's own manifest/generation is
  required. No manifest union, additional runtime-role exception, or relaxed
  guard is assumed. The new 48-pair test queries `pg_class.relacl`; it covers
  table privileges, not `pg_proc.proacl` or the full sessions function manifest.
  Those are distinct proof obligations.
- Prove schema USAGE and table/RPC/RLS access using the actual non-owner LOGIN
  role. The new role SQL explicitly grants USAGE on both schemas and adds
  native runtime tests; their existence does not substitute for a final
  same-generation migrator ACL receipt or operator qualification.
- The adapter's `ensureSchema` implementation is source code, not evidence
  that its relations or grants exist. The existing kind fixture has not run
  this bootstrap. The reader remains `bulls96_read_api`, with no owner or
  writer credentials.
- Canonical object binding, PostgreSQL Service-DNS TLS, compatible control
  introspection and upload/sync/cost behavior remain separate integration
  gates. A writer alone does not resolve them.

## Source provenance

[Source file checksums](pending-read-source-files.json) record full Git blob
IDs and SHA256 over the exact downloaded bytes for the #330 reader SQL and
#336 writer files, retaining both the original and updated source pins. They
are source-only checksums. They have not been matched to an approved immutable
services image or its migration generation and must
not be used as an executable bootstrap receipt.

Before enablement, the owner must provide the approved entrypoint, role and
grant contract, matching image/source/generation, and a real canonical
reconciliation proof. The proof must cover incomplete reads, changed epochs,
restart/retry behavior and fail-closed completeness without seeded or mirrored
search state. The final one-application-database target also needs its own
approved bootstrap; the dedicated-database recipe is not transferable unchanged.
