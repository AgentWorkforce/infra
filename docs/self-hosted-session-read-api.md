# Session read API chart preparation

This is default-off chart plumbing for merged pipeline
[#317](https://github.com/AgentWorkforce/relayhistory-pipeline/pull/317) (reviewed
at `a7d7a5db`) and [#318](https://github.com/AgentWorkforce/relayhistory-pipeline/pull/318)
(reviewed at `441e4862`). It does not enable a read service, change relaycontrol
routing, grant database privileges or establish a new runtime proof.

The session read API now has its own chart, `charts/session-read-api`, which installs on its own. The sessions-pipeline chart carries it as a default-off dependency under `sessionReadApi.*`. The old `readApi` key refuses to render with a migration message, so two readers cannot run; the Deployment and Service keep the name `<release>-read-api`. Move the old block, taking Postgres TLS from `extraEnv` to `postgres.tlsProfile` and `postgresCa`, and do not use `--reuse-values` for this upgrade. With `enabled:false`
(the default), it renders no read API objects. Enabling it requires an explicit
compatible image digest, a configuration Secret, public HTTPS origin with multi-label DNS (no credentials, IP/single-label/local
host, path, query or fragment; optional port 1–65535),
coverage floor (`completeSince`), workspace allowlist and an explicit auth mode.
A separate Secret supplies the optional relaycontrol introspection credential.
`sessionReadApi.search.backend` defaults to `postgres` and renders `SEARCH_INDEX_BACKEND`.
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
`sessionReadApi.probeRuntime=node`. No Kubernetes API token is mounted by default.

The configuration JSON must use the approved least-privilege read-role
connection, not the migration-owner URL. The read image must be compatible with
the deployed worker/migrator generation and published read-role/RPC contract;
a container entry alone does not establish that image pair. Database role creation/ACLs remain with
the pipeline owner. The default is now `sessionReadApi.auth.mode=relaycontrol_only`. `legacy` requires explicit
`sessionReadApi.auth.relayauth.jwksUrl` and `.issuer` values so the runtime does not fall
back to hosted defaults. Introspection requires the
matching relaycontrol implementation, exact audience and Secret. The deployment
inherits the namespace network policy; kind already denies external egress to
every pod. No new egress allow rule is introduced.

For an image containing merged pipeline
[#364](https://github.com/AgentWorkforce/relayhistory-pipeline/pull/364)
(`8a075b26ca8ff693e068bec4f1e22bcb9dbb8413`),
`sessionReadApi.auth.mode=relaycontrol_only` selects the backend's Control-only verifier.
It requires `sessionReadApi.auth.relaycontrol.enabled=true`, its URL and Secret
reference, and empty `sessionReadApi.auth.relayauth.jwksUrl` and `.issuer` settings.
The chart emits `READ_API_AUTH_MODE=relaycontrol_only` and omits both legacy
issuer variables. It rejects contradictory settings and managed-variable
extraEnv overrides. The default legacy mode emits no `READ_API_AUTH_MODE`,
preserving compatibility with earlier reader images. Neither mode is enabled
by a profile, and the earlier reader-only image predates this backend feature.

## Self-issued tokens

`auth.mode=self_issued` makes the read API issue and check its own opaque tokens
([contract](https://github.com/AgentWorkforce/relayhistory-pipeline/blob/main/docs/contracts/session-read-api-v1.openapi.yaml)).
It needs an image from pipeline `eebaced9` or later:
`ghcr.io/agentworkforce/96bulls-services@sha256:d55840ab4bf4e2fea3769db690f3c8d32979ab455ef251172f914ac011cb8c33`.
The database must also carry the token functions from pipeline migration
`20261105044000`. `relaycontrol_only` stays the default.

| Value | Renders | Notes |
| --- | --- | --- |
| `auth.mode: self_issued` | `READ_API_AUTH_MODE=self_issued` | Fails closed: anything below that is missing refuses to render |
| `auth.relaycontrol.enabled: false` | omits every `RELAYCONTROL_*` setting and `RELAYHISTORY_ACCEPT_RELAYCONTROL_TOKENS` | Required; the service refuses Control introspection in this mode. `url` and `existingSecret` must be empty |
| `auth.selfIssued.internalSecret.existingSecret` and `.key` (default `READ_API_INTERNAL_SECRET`) | `READ_API_INTERNAL_SECRET` from that Secret | Required. At least 32 characters with no surrounding whitespace; the service checks this at startup, because Helm cannot read the Secret. Control presents the same value |
| `auth.selfIssued.previousInternalSecret.existingSecret` and `.key` (default `READ_API_INTERNAL_SECRET_PREVIOUS`) | `READ_API_INTERNAL_SECRET_PREVIOUS` from that Secret | Optional, for a rotation overlap. Must hold a different value |
| `auth.selfIssued.accessTokenTtlSeconds` (default 300) | `READ_API_ACCESS_TOKEN_TTL_SECONDS` | Integer from 60 to 300 |
| `origin` | `READ_API_ORIGIN` | The token audience; Control must send this origin |
| `login.advertisesSync: false` | | Required; `POST /v1/cli/login` does not exist in this mode |
| `networkPolicy.enabled: true`, `networkPolicy.controlFrom` | a NetworkPolicy admitting those peers on the service port | Required. `controlFrom` entries need `podSelector` labels |

`/internal/*` is kept off public paths in two ways. The chart's optional Ingress
(`ingress.enabled`) routes only the `/v1` prefix; the host comes from `origin`.
The NetworkPolicy admits Control through `controlFrom`, and the carriers of public
traffic through `networkPolicy.publicFrom` (required with `ingress.enabled`).
The service serves both on one port, and a NetworkPolicy cannot tell paths apart,
so `publicFrom` peers can reach `/internal/*` at the network layer. That is why
they must be proxies that route only `/v1`: never a whole namespace of workloads,
and never a catch-all (`0.0.0.0/0`, or a peer with no selector labels, refuses
to render). `/internal/*` also still requires the internal secret. A proxy you
run yourself instead of this Ingress must route only `/v1` and must not forward
un-normalized paths such as `/v1/../internal/...`, which the service normalizes.

`events.messageIds` (default false) renders `READ_API_EVENT_MESSAGE_IDS=true` and
requires `LOCKER_BUCKET`, because the service serves message ids only from the
canonical store.

The same backend merge adds canonical detail reads from `LOCKER_*` (S3 static
keys or Pod Identity supported). When `LOCKER_BUCKET` is configured, upstream
requires `PIPELINE_ORG_FROM_PREFIX=true`. For the inline test/pilot assembly,
`PIPELINE_KEY_PREFIX` is the bare `INGEST_KEY_ROOT` (`96bulls`), never an org
suffix. These transport settings still use explicit extraEnv and CA mounts;
the chart requires nonempty literal `LOCKER_BUCKET`, literal
`PIPELINE_ORG_FROM_PREFIX=true` and `PIPELINE_KEY_PREFIX=96bulls` together when
a bucket is supplied. Missing or false flags, org-suffixed roots and valueFrom
references for these layout inputs are refused before a Deployment is rendered.
Bucket literals reject surrounding whitespace. When ingest is enabled too, the
reader bucket must equal `ingestEdge.locker.bucket`.
Credential settings require Secret key references. This auth-mode change adds
no object-store configuration or native image acceptance. See the
[native composition contract](self-hosted-native-ingest.md).

A dormant service returns HTTP 200 with `enabled:false`. The readiness exec
checks `ok:true` and `enabled:true` using plain JavaScript in the selected
runtime. Liveness checks the HTTP process only. These probes do not establish
backend data availability; the full authenticated session-read proof is still
required.

The Service is ClusterIP on port 80, targeting the configured container port
(default 8080, allowed range 1024–65535 for the non-root container). The shared
Deployment/Service name must be a letter-first DNS-1035 label. The container
port restriction does not change the public origin port contract. No ingress
or control backend is changed automatically. A future
approved deployment can point relaycontrol at the Service FQDN, but only after
its workspace list/search/events/catalog contract, upload path, reported usage
and tenant isolation all pass together. The new read service does not silently
delegate legacy History ingest/delivery routes.

Runtime blockers remain: qualified combined reader/writer image and schema,
native PostgreSQL TLS and canonical-object binding proof, and authenticated
upload-to-readback acceptance. Source support alone does not close them. See the base
[kind contract review](../ci/agent-relay/kind/read-api-contract.md). The kind core
and addon profiles leave readApi disabled; their existing running fixture is
untouched by this preparation.

The `ci/read-api-values.yaml` file uses an intentionally fake image identity for
render/schema tests. Never install it. No compatible published read API image
or runtime enablement is claimed by these checks.

Historical validation of the initial chart preparation: eleven focused render/admission/schema
and executable probe checks pass. Both kind profiles render no read API workload.
The affected chart static checks, existing profile matrix, registry/regression
checks and normalized default-render goldens also pass. This work did not run
kubectl, install the component, change a namespace policy or touch the existing
kind fixture. The fake image appears only in the explicitly render-only fixture.

After composing the reviewed PR79 base, all 60 base offline checks also pass
in this worktree, including its thirteen profile/schema/trust checks. Together
with the eleven read API checks, this is 71 offline checks; it is not runtime
acceptance of the new service.

Control [#27](https://github.com/AgentWorkforce/relay-control/pull/27), reviewed
at `f879eedc`, is stacked on #20. It uses the existing `RELAYHISTORY_URL` and
`RELAYHISTORY_PUBLIC_URL`, forwards caller tokens with RelayAuth unset, passes
unsupported reads through as 501, and refuses `mode=sync` when the reader grants
only `rth:read`. The replacement upload/auth contract must therefore be proved
separately; no successful upload can be inferred from a read-only login. Pipeline
[#316](https://github.com/AgentWorkforce/relayhistory-pipeline/pull/316) provides
a default-off signing edge but its local upstream/runtime contract still needs
owner confirmation. No URL is repointed by this PR.

`relay-control.services.relayauthEnabled` stays true by default for published
legacy control images. With a compatible #20/#27 image, false omits both the
legacy URL and API-key-file environment variables and the unused legacy key from
the API Secret projection. It does not toggle the RelayAuth component or change
any verifier. The temporary issuer may still serve other consumers. Introspection
URL/Secret/audience configuration uses the existing API extraEnv support; it must
match the read service. Both modes are render-tested, with legacy reintroduction
through extraEnv rejected when the legacy client is disabled. Neither mode is
changed in the live kind fixture.
