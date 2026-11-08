# Session read API chart preparation

This is default-off chart plumbing for pipeline draft
[#317](https://github.com/AgentWorkforce/relayhistory-pipeline/pull/317) (reviewed
at `a7d7a5db`) and [#318](https://github.com/AgentWorkforce/relayhistory-pipeline/pull/318)
(reviewed at `441e4862`). It does not enable a read service, change relaycontrol
routing, grant database privileges or establish a new runtime proof.

The existing sessions-pipeline chart now accepts `readApi.*`. With `enabled:false`
(the default), it renders no read API objects. Enabling it requires an explicit
compatible image digest, a configuration Secret, bare public HTTPS origin,
coverage floor (`completeSince`), workspace allowlist and temporary issuer.
A separate Secret supplies the optional relaycontrol introspection credential.
`readApi.search.backend` defaults to `postgres` and renders `SEARCH_INDEX_BACKEND`.
It selects the registered adapter in the compatible upstream image; it does not
implement an adapter or fall back to ClickHouse. Other backends may be configured
only when that image registers them. Hosted ClickHouse stays behind the same
upstream seam. OpenSearch work is upstream pipeline PR #315, not implemented or
proved by this chart. The kind core profile explicitly selects postgres while
leaving the component disabled.
These configuration values are passed to the existing upstream service entry;
infra implements no token verification or data-path bridge.

`SERVICE=session-read-api`, `RELAYHISTORY_SELFHOST_READ_API=true` and the HTTP
port are managed by the chart. `extraEnv` cannot duplicate managed names or
itself. It supports Secret key references, while extra read-only CA mounts and
transport/adapter settings can follow the eventual upstream assembly contract.
The services image runs Bun; compatible Node-only images can select
`readApi.probeRuntime=node`. No Kubernetes API token is mounted by default.

The configuration JSON must use the approved least-privilege read-role
connection, not the migration-owner URL. The read image must be compatible with
the deployed worker/migrator generation and published read-role/RPC contract;
a container entry alone does not establish that image pair. Database role creation/ACLs remain with
the pipeline owner. Provide explicit `RELAYAUTH_JWKS_URL`/issuer values so the
runtime does not fall back to hosted defaults. Introspection requires the
matching relaycontrol implementation, exact audience and Secret. The deployment
inherits the namespace network policy; kind already denies external egress to
every pod. No new egress allow rule is introduced.

A dormant service returns HTTP 200 with `enabled:false`. The readiness exec
checks `ok:true` and `enabled:true` using plain JavaScript in the selected
runtime. Liveness checks the HTTP process only. These probes do not establish
backend data availability; the full authenticated session-read proof is still
required.

The Service is ClusterIP on port 80, targeting the configured container port
(default 8080). No ingress or control backend is changed automatically. A future
approved deployment can point relaycontrol at the Service FQDN, but only after
its workspace list/search/events/catalog contract, upload path, reported usage
and tenant isolation all pass together. The new read service does not silently
delegate legacy History ingest/delivery routes.

Current blockers remain: Postgres-only read assembly, PostgreSQL TLS, canonical
object-source binding, and compatible login/introspection. See the base
[kind contract review](../ci/agent-relay/kind/read-api-contract.md). The kind core
and addon profiles leave readApi disabled; their existing running fixture is
untouched by this preparation.

The `ci/read-api-values.yaml` file uses an intentionally fake image identity for
render/schema tests. Never install it. No compatible published read API image
or runtime enablement is claimed by these checks.

Validation in the isolated chart worktree: ten focused render/admission/schema
and executable probe checks pass. Both kind profiles render no read API workload.
The affected chart static checks, existing profile matrix, registry/regression
checks and normalized default-render goldens also pass. This work did not run
kubectl, install the component, change a namespace policy or touch the existing
kind fixture. The fake image appears only in the explicitly render-only fixture.

The ten existing kind profile/schema/trust checks also pass in this worktree.

Control [#27](https://github.com/AgentWorkforce/relay-control/pull/27), reviewed
at `f879eedc`, is stacked on #20. It uses the existing `RELAYHISTORY_URL` and
`RELAYHISTORY_PUBLIC_URL`, forwards caller tokens with RelayAuth unset, passes
unsupported reads through as 501, and refuses `mode=sync` when the reader grants
only `rth:read`. The replacement upload/auth contract must therefore be proved
separately; no successful upload can be inferred from a read-only login. Pipeline
[#316](https://github.com/AgentWorkforce/relayhistory-pipeline/pull/316) provides
a default-off signing edge but its local upstream/runtime contract still needs
owner confirmation. No URL is repointed by this PR.

`relay-cloud-api.services.relayauthEnabled` stays true by default for published
legacy control images. With a compatible #20/#27 image, false omits both the
legacy URL and API-key-file environment variables and the unused legacy key from
the API Secret projection. It does not toggle the RelayAuth component or change
any verifier. The temporary issuer may still serve other consumers. Introspection
URL/Secret/audience configuration uses the existing API extraEnv support; it must
match the read service. Both modes are render-tested, with legacy reintroduction
through extraEnv rejected when the legacy client is disabled. Neither mode is
changed in the live kind fixture.
