# Pending writer bootstrap source review

Reviewed pipeline [#336 at e680a29a](https://github.com/AgentWorkforce/relayhistory-pipeline/pull/336),
full source revision `e680a29aeffaa69029ed6ec4775ffd5c83f1136c`.
The PR was open and draft when checked. This is source review and a read-only
PostgreSQL catalog lookup, not a writer deployment or bootstrap execution.
The kind reader and writer remain disabled.

The reader's #330 head subsequently advanced to
`0f2e866395c9122721262bb16d1430084955c878`, including tenant-RLS/admission and
bare-pool fail-closed fixes. Those changes do not alter the three reader
bootstrap SQL files in the source checksum list, but the writer at `e680a29a`
has not been qualified together with that newer adapter/runtime source. A
single approved combined image and generation must replace separate-head
assumptions before operator wiring.

## Confirmed bootstrap defects

1. `src/session-pipeline/consumer-bootstrap.ts:136` calls
   `hashtextended('search-consumer-bootstrap', 0)`. The PostgreSQL function is
   `hashtextextended(text,bigint)`. A read-only lookup on the existing kind
   PostgreSQL 17.11 instance returned NULL for
   `pg_catalog.hashtextended(text,bigint)` and the correct signature for
   `pg_catalog.hashtextextended(text,bigint)`. The current bootstrap therefore
   cannot acquire its advisory lock.
2. `serve` opens a transaction before `runBootstrap`, but `ensureRole` submits
   `supabase/bootstrap/session_consumer_role.sql` with its own `BEGIN` and
   `COMMIT`. `stripPsqlMeta` removes only psql metacommands. Once the lock typo
   is fixed, that embedded `COMMIT` would commit schema and role work before
   `verifyRole`; a subsequent verification failure cannot roll it back.
   The owner must establish one transaction boundary and test rollback on a
   real PostgreSQL verification failure, rather than only mocked step order.

Both findings were sent to layered-sessions-pipeline and pipeline-lead. Infra
does not patch the pipeline entrypoint or bypass its role checks.

## Contract facts and remaining proof

- This revision requires `READ_API_COMPLETE_SINCE` and passes its parsed floor
  into `writerComposition`; the earlier proposal with an implicit zero floor
  is superseded. Writer and reader still need the same configured backend ID
  and coverage floor.
- The role SQL creates and verifies a dedicated LOGIN, NOINHERIT,
  NOBYPASSRLS `search_consumer_runtime`. The PR description's NOLOGIN wording
  and the service header's existing-runtime-role wording do not match it.
  The pipeline owner must settle the runtime identity and privileged one-shot
  bootstrap executor before chart credentials are wired.
- The role SQL grants this new role EXECUTE on three `sessions` RPCs. A final
  exact-ACL check against the approved image's own manifest/generation is
  required. No manifest union, additional runtime-role exception, or relaxed
  guard is assumed.
- Prove schema USAGE and table/RPC/RLS access using the actual non-owner LOGIN
  role. The supplied role SQL grants USAGE on `search_index`, but does not
  explicitly grant it on `sessions`. Catalog privilege assertions alone do
  not prove the reconciler can operate under its runtime identity.
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
#336 writer files. They are source-only checksums. They have not been matched
to an approved immutable services image or its migration generation and must
not be used as an executable bootstrap receipt.

Before enablement, the owner must provide the approved entrypoint, role and
grant contract, matching image/source/generation, and a real canonical
reconciliation proof. The proof must cover incomplete reads, changed epochs,
restart/retry behavior and fail-closed completeness without seeded or mirrored
search state. The final one-application-database target also needs its own
approved bootstrap; the dedicated-database recipe is not transferable unchanged.
