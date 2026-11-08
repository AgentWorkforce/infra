# Pending self-host read API contract

This is source review and read-only diagnosis, not an enabled deployment or an
end-to-end pass. Core local-control proof at `fd8565c` records 57 PASS, 0 FAIL, 3 PENDING.

The originally reviewed source heads were pipeline [#317 at a7d7a5db](https://github.com/AgentWorkforce/relayhistory-pipeline/pull/317),
[#318 at 441e4862](https://github.com/AgentWorkforce/relayhistory-pipeline/pull/318)
and the additional PG-only source in [#330 at 44b81b56](https://github.com/AgentWorkforce/relayhistory-pipeline/pull/330).
They were open drafts at that source review. Subsequent status verification
confirmed #317 merged as `d33bfdaa665f1ea5da7eac33e96b3522fa177b06` and #318 as
`a1e1473be4174d1b26c1506159abcbd97b39fa4f`. #330 remains an open draft and has
advanced to `0f2e866395c9122721262bb16d1430084955c878`. Its intervening commits
add reader role admission, forced tenant RLS and fail-closed tenant-bound
operations; that combined runtime is not qualified by the older source review.
No enablement or deployment was done by infra.
Relaycontrol remains a proxy to `RELAYHISTORY_URL`, with no pipeline URL added.

## Proposed chart inputs

Use the existing sessions-pipeline chart, with a default-off read API component.
No new chart or runtime server wrapper is needed. Draft infra #81 reserves
sessions-pipeline `0.6.2`, relay-cloud-api `0.2.7` and agent-relay `0.3.17` for
this default-off plumbing; no kind profile enables the read service.

| Input | Draft contract |
| --- | --- |
| Container role | `SERVICE=session-read-api` in a compatible pinned services image; the current kind image lacks it. |
| Enablement | `RELAYHISTORY_SELFHOST_READ_API=true`, exactly; other accepted dormant values are unset, empty and `false`. |
| Port | `RELAYHISTORY_READ_API_PORT`, default 8080. |
| Database/search configuration | `RELAYHISTORY_READ_API_SECRET` from a Kubernetes Secret key containing the existing Lambda JSON shape; never inline credentials in values. |
| Auth audience | `READ_API_ORIGIN` is the exact `aud` sent in each introspection request. Include that same public History origin in relaycontrol `SELFHOST_INTROSPECT_AUDIENCES` (defaults to `RELAYHISTORY_PUBLIC_URL`). No separate reader audience environment variable is used. |
| Workspace rollout | Explicit `READ_API_DIRECTORY_WORKSPACES` allowlist containing the real proof workspace. |
| Temporary issuer | Explicit in-cluster `RELAYAUTH_JWKS_URL` and `RELAYAUTH_ISSUER`; do not inherit hosted defaults. |
| Introspection | `RELAYHISTORY_ACCEPT_RELAYCONTROL_TOKENS=true`, configured `RELAYCONTROL_INTROSPECT_URL`, and `RELAYCONTROL_INTROSPECT_SECRET` from a Secret. `readApiAuthConfig` reads these environment variables separately from the JSON database/search secret. |
| Readiness | Verify `/healthz` JSON has `ok:true` **and** `enabled:true`. An HTTP-status-only readiness probe would falsely accept the dormant service, which returns 200 with `enabled:false`. |

The server serves the same Hono API as the Lambda. Its only non-GET exception is
`POST /v1/cli/login`, capped at 8 KiB. Adding that route and catalog does not
establish a replacement for every legacy History delivery/ingest route.

## Remaining integration blockers

1. Draft #330 adds a Postgres-only reader composition through the existing adapter
   registry, without constructing ClickHouse. A compatible approved immutable
   image is still required, together with owner-provided schema/bootstrap/grants
   and a real canonical reconciliation writer. Missing relations/grants return
   503 and missing/stale completeness remains partial; no seeded state or empty
   success can satisfy search acceptance.
2. The assembly requires Postgres TLS. Current kind Postgres deliberately has TLS
   off. A supported TLS configuration is needed; verification must stay enabled.
3. `readAppFromSecret` does not bind a canonical object source. Catalog therefore
   returns 501 `catalog_not_configured`; canonical transcript/object readback is
   not established by the route implementation alone.
4. CLI login source accepts relaycontrol `sh_at_` tokens through introspection.
   The installed fixture still exchanges RelayAuth assertions. Control #20 has
   merged as `bae78a524fbce4fb3ab231372417bc2dfac04cad`; infra #91 qualifies a
   local candidate artifact, without installing it or proving replacement
   upload/read compatibility. A compatible control/read-service auth pair is
   required before repointing the existing History URL. No auth bridge is
   implemented in infra.

These belong to the pipeline/control/History service owners. The chart must not
invent missing runtime composition, bypass grants, mirror session rows between
databases, or claim the service ready from its dormant health response.

The proposed writer in pipeline #336 is tracked in the
[bootstrap source review](writer-bootstrap-review.md). Its entrypoint is not
ready for operator wiring: that review records the two now-fixed bootstrap
source defects and the remaining full-bootstrap/function-ACL/combined-image
proof requirements. The accompanying source checksums
do not establish a compatible container image or migration generation.

The #330 service also requires `SESSION_POSTGRES_TLS_PROFILE` explicitly and,
when using Postgres search, a nonempty `SEARCH_INDEX_POSTGRES_BACKEND_ID` matching
the writer. For kind's custom CA, the upstream inputs are
`SESSION_POSTGRES_TLS_PROFILE=custom-ca`, `SESSION_POSTGRES_CA_FILE` and
`SESSION_POSTGRES_CA_SHA256` over the exact mounted public PEM bytes. The chart's
`readApi.extraEnv`, `extraVolumes` and `extraVolumeMounts` can carry these reviewed
inputs; they do not create a server certificate, schema or writer. The coverage
floor must agree with the writer. No TLS bypass or owner credential belongs in
the reader. Complete upload/sync/cost compatibility must also be established
before replacing the existing History read URL; control #27's read-only exchange
does not provide a sync session.

## Read-only diagnosis of the existing courier fixture

The [diagnostic receipt](pipeline-directory.json) records the exact previously
uploaded session. In HoopDB, `sessions.session_directory` has one matching row
for its org/workspace/session; both canonical identity columns in
`sessions.session_index` are non-null. The separate legacy History database has
no directory table. This fixture is not missing its pipeline directory row.

These catalog/row checks ran in read-only transactions as the diagnostic database
administrator, not as an application acceptance test. No rows, grants or runtime
roles changed. Populated identity columns do not prove the claim-bound canonical
pointer RPC or object-store projection reads. There is no deployed read API or
read allowlist yet; the app still reads the separate legacy History service.
