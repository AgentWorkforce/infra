# Session read API chart preparation

This is default-off chart plumbing for pipeline draft
[#317](https://github.com/AgentWorkforce/relayhistory-pipeline/pull/317) (reviewed
at `33f33c4e`) and [#318](https://github.com/AgentWorkforce/relayhistory-pipeline/pull/318)
(reviewed at `a4311806`). It does not enable a read service, change relaycontrol
routing, grant database privileges or establish a new runtime proof.

The existing sessions-pipeline chart now accepts `readApi.*`. With `enabled:false`
(the default), it renders no read API objects. Enabling it requires an explicit
compatible image digest, a configuration Secret, bare public HTTPS origin,
coverage floor (`completeSince`), workspace allowlist and temporary issuer.
A separate Secret supplies the optional relaycontrol introspection credential.
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

Validation in the isolated chart worktree: seven focused render/admission/schema
and executable probe checks pass. Both kind profiles render no read API workload.
The affected chart static checks, existing profile matrix, registry/regression
checks and normalized default-render goldens also pass. This work did not run
kubectl, install the component, change a namespace policy or touch the existing
kind fixture. The fake image appears only in the explicitly render-only fixture.

The ten existing kind profile/schema/trust checks also pass in this worktree.
