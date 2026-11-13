# Pending self-host read API contract

> Note (2026-11-12): historical review. The standalone RelayHistory server and its `RELAYHISTORY_URL` proxy target were since removed; History is always the native Sessions path (`relayhistoryBackend=native`).

This is source review and read-only diagnosis, not an enabled deployment or an
end-to-end pass. Historical proofs at `1c203f59` (ar-lap) and `fd8565c`
(local-control) each record 57 PASS, 0 FAIL, 3 PENDING. They predate the
`core.flows_disabled` gate and were not rerun or reattributed. Those counts
are not the result of the current core verifier.

The originally reviewed source heads were pipeline [#317 at a7d7a5db](https://github.com/AgentWorkforce/relayhistory-pipeline/pull/317),
[#318 at 441e4862](https://github.com/AgentWorkforce/relayhistory-pipeline/pull/318)
and the additional PG-only source in [#330 at 44b81b56](https://github.com/AgentWorkforce/relayhistory-pipeline/pull/330).
They were open drafts at that source review. Subsequent status verification
confirmed #317 merged as `d33bfdaa665f1ea5da7eac33e96b3522fa177b06` and #318 as
`a1e1473be4174d1b26c1506159abcbd97b39fa4f`. #330 subsequently merged as
`992f9b17721a3208a1eaeb5933f53359b1919702` from head
`0f2e866395c9122721262bb16d1430084955c878`. Its intervening commits
add reader role admission, forced tenant RLS and fail-closed tenant-bound
operations; that combined runtime is not qualified by the older source review.
No enablement or deployment was done by infra.
Relaycontrol remains a proxy to `RELAYHISTORY_URL`, with no pipeline URL added.

## Supported self-host read scope

Pipeline rollout 1 supports canonical published sessions only. Self-host
owner-buffered reads are unsupported. The Node container assembles the Lambda
read app, whose [source explicitly leaves owner-buffered reads unwired](https://github.com/AgentWorkforce/relayhistory-pipeline/blob/f7cfb90ecd8f03ad7d51ebd6291519ab69402597/src/session-read-api/lambda.ts#L24-L26).
The hosted Worker privacy-head binding from pipeline #341 is outside this
self-host assembly.

Leave `RELAYHISTORY_READ_OWNER_BUFFERED` unset/off and
`READ_API_OWNER_BUFFERED_WORKSPACES` unset. Supply no owner-buffered raw-S3
configuration. Canonical MinIO configuration remains separately required; this
scope does not qualify that binding or the pending courier-to-app proof.

A future self-host owner-buffered design would require an authenticated
in-cluster privacy-controls transport with an owner **TBD**. No supported
transport or follow-up implementation exists for rollout 1. The Fetcher DI seam
is not an approved public endpoint and must not be pointed at one. A new
privacy-head transport is not a prerequisite for canonical-only acceptance.

## Proposed chart inputs

Use the existing sessions-pipeline chart, with a default-off read API component.
No new chart or runtime server wrapper is needed for this reader plumbing.
Infra #81 introduced sessions-pipeline `0.7.1`, relay-cloud-api `0.2.7` and
agent-relay `0.4.2` for
this default-off plumbing; no kind profile enables the read service.

Those are the #81 parent versions. The composed public-name branch #97 uses
agent-relay `0.5.0`, relay-control `0.3.0`, relay-webapp `0.2.0` and
sessions-pipeline `0.7.2` (Secret-reference review follow-up); see
[the upgrade map](../../../docs/control-webapp-chart-rename.md).
Native-ingest child #102 uses umbrella `0.5.1` and pipeline `0.7.3`; see
[its native-ingest contract](../../../docs/self-hosted-native-ingest.md).

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

### RelayAuth and legacy History removal target

Pipeline's source inventory at
`7a946e06b83dff6ed9df96cb75fd1acd0f37d0a7` does not provide a complete native
replacement for those services. The read SERVICE exists; a full upload/read/cost
cutover has no runnable combined artifact yet. Source-program ownership and
artifact/proof dates remain uncommitted.

| Surface | Current source availability | Required replacement work |
| --- | --- | --- |
| Read authentication | `sh_at_` uses relaycontrol introspection. Other bearers still select RelayAuth; absent JWKS/issuer uses hosted defaults. | Explicit control-only verifier mode and service-entry proof; owner TBD. |
| Desktop upload | Main's session-ingest endpoint is a private Cloudflare Worker with HMAC identity. Unmerged #316 adds a Node edge, not a native ingest upstream or a combined entrypoint. | Native edge/upstream with authorized token scopes and non-Cloudflare queue, Postgres and S3 bindings. |
| Canonical writer | Main's writer is Lambda-only; native consumer #336 is draft. | Reviewed native writer, exact function-ACL authorization after bootstrap and normal migrate, tenant-gate admission and matching generation. |
| Read views | List, activity, titles, session events and event search have source implementations, subject to schema/role/coverage/TLS prerequisites. Turns, metadata, timing, catalog and delivery records return 501 in the service assembly. | Canonical object/route bindings and actual readback proof. |
| CLI sync | Reader login is read-only pass-through, with no refresh or `rth:sync`; Control #27 returns `501 sync_not_served` for that sync exchange. | A supported sync-capable backend login or a separately implemented Desktop upload-origin/acquire flow. |
| Usage/cost | No replacement endpoints in this service. | Owner-defined compatible endpoints and actual attribution proof. |
| Native image | Main's dispatcher includes the read API; the proposed edge and consumer branches are not one qualified native image. | Explicit edge/ingest/writer/read entrypoint composition, immutable image/source/generation and compatibility receipts. |

Pipeline's proposed auth follow-up is `READ_API_AUTH_MODE=relaycontrol_only`.
It is **not implemented** and is not a supported chart input. Its proposed
contract never constructs the RelayAuth verifier, returns 401 for non-`sh_at_`
bearers, and refuses startup if `RELAYAUTH_JWKS_URL` or `RELAYAUTH_ISSUER` is set.
A service-entry test must prove refusal with no outbound fetch attempted.
Blank issuer values, a dead local URL or relying on denied hosted egress do not
implement this mode.

Control currently returns one backend origin from
`POST /api/v1/workspaces/{ws}/relayhistory/session`; it does not advertise a
separate upload edge. Splitting ingress paths cannot grant sync authority or
provide Desktop origin discovery. The replacement protocol belongs in its
backend/Desktop source contract, not an infra token or scope shim.

The current kind guard still requires legacy History, and the read chart still
requires explicit temporary issuer/JWKS configuration. Chart cutover must follow
the implemented replacement contracts, then remove both legacy components and
their wiring with qualified native services in place. No such flag, service,
image or workaround configuration is introduced by this source inventory.
Owning-fixture upload, canonical indexing/readback, usage/cost, tenancy/ACL/TLS
and egress proof must accompany the cutover while preserving existing data.
Historical availability and 57/0/3 receipts are not that proof.

### Existing reader assembly prerequisites

1. PR #330 adds a Postgres-only reader composition through the existing adapter
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
proof requirements. Operator wiring requires the same approved image/ACL
migration generation and a final exact-function-manifest receipt; source
hashes alone cannot qualify installation. The accompanying source checksums
do not establish a compatible container image or migration generation.

The #330 service also requires `SESSION_POSTGRES_TLS_PROFILE` explicitly and,
when using Postgres search, a nonempty `SEARCH_INDEX_POSTGRES_BACKEND_ID` matching
the writer. For kind's custom CA, the upstream inputs are
`SESSION_POSTGRES_TLS_PROFILE=custom-ca`, `SESSION_POSTGRES_CA_FILE` and
`SESSION_POSTGRES_CA_SHA256` over the exact mounted public PEM bytes. The chart's
`sessionReadApi.extraEnv`, `extraVolumes` and `extraVolumeMounts` can carry these reviewed
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
