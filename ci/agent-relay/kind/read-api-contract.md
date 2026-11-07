# Pending self-host read API contract

This is source review and read-only diagnosis, not an enabled deployment or an
end-to-end pass. Core local-control proof records 55 PASS, 0 FAIL, 3 PENDING.

The reviewed drafts are pipeline [#317 at 33f33c4e](https://github.com/AgentWorkforce/relayhistory-pipeline/pull/317)
and [#318 at a4311806](https://github.com/AgentWorkforce/relayhistory-pipeline/pull/318).
Both were open drafts when checked; no merge, enablement or deployment was done.
Relaycontrol remains a proxy to `RELAYHISTORY_URL`, with no pipeline URL added.

## Proposed chart inputs

Use the existing sessions-pipeline chart, with a default-off read API component.
No new chart or runtime server wrapper is needed. Coordinate chart versions with
the chart owners before adding the component; no version is reserved yet.

| Input | Draft contract |
| --- | --- |
| Container role | `SERVICE=session-read-api` in a compatible pinned services image; the current kind image lacks it. |
| Enablement | `RELAYHISTORY_SELFHOST_READ_API=true`, exactly; other accepted dormant values are unset, empty and `false`. |
| Port | `RELAYHISTORY_READ_API_PORT`, default 8080. |
| Database/search configuration | `RELAYHISTORY_READ_API_SECRET` from a Kubernetes Secret key containing the existing Lambda JSON shape; never inline credentials in values. |
| Auth audience | `READ_API_ORIGIN`, matching the introspection audience. |
| Workspace rollout | Explicit `READ_API_DIRECTORY_WORKSPACES` allowlist containing the real proof workspace. |
| Temporary issuer | Explicit in-cluster `RELAYAUTH_JWKS_URL` and `RELAYAUTH_ISSUER`; do not inherit hosted defaults. |
| Introspection | `RELAYHISTORY_ACCEPT_RELAYCONTROL_TOKENS=true`, configured `RELAYCONTROL_INTROSPECT_URL`, and `RELAYCONTROL_INTROSPECT_SECRET` from a Secret. `readApiAuthConfig` reads these environment variables separately from the JSON database/search secret. |
| Readiness | Verify `/healthz` JSON has `ok:true` **and** `enabled:true`. An HTTP-status-only readiness probe would falsely accept the dormant service, which returns 200 with `enabled:false`. |

The server serves the same Hono API as the Lambda. Its only non-GET exception is
`POST /v1/cli/login`, capped at 8 KiB. Adding that route and catalog does not
establish a replacement for every legacy History delivery/ingest route.

## Remaining integration blockers

1. The draft container uses the Lambda assembly without a registered Postgres
   search composition. Its documented search backend is still ClickHouse; core
   requires a real Postgres-only composition, not a disabled or mocked search.
2. The assembly requires Postgres TLS. Current kind Postgres deliberately has TLS
   off. A supported TLS configuration is needed; verification must stay enabled.
3. `readAppFromSecret` does not bind a canonical object source. Catalog therefore
   returns 501 `catalog_not_configured`; canonical transcript/object readback is
   not established by the route implementation alone.
4. Draft CLI login accepts relaycontrol `sh_at_` tokens through introspection.
   Current control still exchanges RelayAuth assertions. Control #20 was checked
   open and unmerged at `4075a088`; the local MCP-capable build also predates it.
   A compatible control/read-service auth pair is required before repointing the
   existing History URL. No auth bridge is implemented in infra.

These belong to the pipeline/control/History service owners. The chart must not
invent missing runtime composition, bypass grants, mirror session rows between
databases, or claim the service ready from its dormant health response.

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
