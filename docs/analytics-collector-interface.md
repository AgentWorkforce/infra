# Self-host analytics collector interface

This defines the source implementation target for the
[analytics adapter contract](analytics-adapter-contract.md). No application,
collector, chart, volume or gateway is implemented or enabled by this document.

## Placement and adapters

One single-writer collector workload behind an installation-local Service owns
the persistent, rotated NDJSON export. It has one replica, no overlapping
writer during rollout/restart, and exclusive volume ownership. Two writer pods
must never mount the same file store concurrently; replica count or an RWO
access mode alone is not fencing. Failover needs demonstrated storage fencing.
A multi-writer collector is outside this first contract.

Server components send batches through their analytics adapter;
they do not need an analytics PVC each. The collector's files are an export,
separate from the single RDS application database. An application-local file or
`emptyDir` may be a bounded spool, but is not durable collector acceptance.

A producer exposes its existing typed event port where suitable. `capture`
enqueues bounded asynchronous work; it does not await export on the product
request. A deadline-bounded `flush` supports tests and shutdown. A destination
factory selects `none`, `collector` or `posthog` from explicit configuration.
Preserve existing collection/privacy defaults. The acceptance fixture must
explicitly select the collector and demonstrate an event from every component.

In self-host mode the collector adapter is the file destination. It requires
an installation-local endpoint and a producer credential reference. It never
switches to PostHog on error. The hosted adapter targets `https://i.agentrelay.com`
with the hosted project configuration; no hosted key or endpoint default is
injected into self-hosted workloads. No live hosted configuration is changed here.

## Internal batch endpoint

The proposed source inventory and event records are maintained in
[`analytics-producer-registry.md`](analytics-producer-registry.md), which names
document/component ownership and distinguishes proposed records from future
runtime admission. It creates no active producer registration or credentials;
the collector implementation owner and reviewed runtime bindings remain required.

The collector exposes an authenticated, internal `POST /v1/events`. Browser
and Desktop clients do not receive collector producer credentials or connect
directly to this Service. A separate authenticated local gateway validates
their existing application session/token, derives tenant/workspace authority,
and invokes the producer port. It must not trust caller-supplied authority or
repurpose the operator telemetry issue/export endpoints as analytics intake.

Producer endpoint configuration is the complete URL, including `/v1/events`;
Helm supplies that full URL and the adapter does not append the path again.
Credentials, query parameters and fragments are not part of that URL. Transport
and CA validation still follow the reviewed installation profile.

The batch body is a JSON object with `schema` equal to
`agent-relay.analytics.batch/v1` and an `events` array. Each event contains:

| Field | Meaning |
|---|---|
| `version` | Event envelope version, initially `1` |
| `event_id` | Producer-generated ID unique within deployment/component across all replicas and restarts, retained across retries |
| `occurred_at` | UTC event occurrence time |
| `component` | Registered producer component |
| `deployment_id` | Opaque installation/deployment identity |
| `event` | Registered event kind |
| `trace_id` | Opaque correlation identity for the user trace |
| `tenant_id` | Opaque, authorized native tenant ID when required by the registered event kind |
| `workspace_id` | Opaque, authorized native workspace ID when required by the registered event kind |
| `properties` | Versioned, event-specific allowlisted properties |

Existing native observations are projected into this envelope. The producer
registration binds component and deployment identity; body fields cannot
override that binding. Tenant/workspace attribution is exported only through
the reviewed projector after application authorization. The event-kind registry
fixes each kind's identity model; callers cannot choose a weaker scope:

| Registered event scope | Required attribution |
|---|---|
| Installation-only | Neither tenant nor workspace |
| Tenant | `tenant_id` |
| Workspace in a tenant model | Both `tenant_id` and `workspace_id` |
| Native workspace with no separate tenant model | `workspace_id`; omit `tenant_id` |

Relaycast uses the last model: its authorized native workspace is the boundary,
so its registered workspace events omit `tenant_id`. Never invent a tenant ID,
set it equal to the workspace ID, or reclassify a tenant event merely to omit
required attribution. Native IDs retain their component/registration namespace;
cross-component correlation uses `trace_id` and a verified identity mapping,
not an assumption that different products' workspace IDs are identical.
Tests must reject missing IDs and unauthorized scope/model substitution.

`properties` cannot override these reserved fields. Unregistered scope, missing
required attribution, or unauthorized attribution is invalid. Initial tests use synthetic/install-scoped
identity; these fields add no user identities, names or credentials.

Create an event ID once at event creation, for example with a cryptographically
random UUID, and retain it with the queued immutable event across retries. A
process-local counter reset on restart is insufficient. A different event must
never reuse the same `(deployment_id, component, event_id)` tuple. This is a
producer requirement, not a collector deduplication guarantee.

Authenticate every request with exactly one `Authorization: Bearer <producer-token>`
header. The token is an opaque, case-sensitive per-producer credential supplied
through a Secret reference; the adapter treats its value as opaque. Tokens in
query strings, cookies or event bodies are not authentication. Malformed,
unknown or revoked tokens receive `401` with `WWW-Authenticate: Bearer`; multiple
Authorization headers are invalid. The collector verifies the credential
against its producer registration using a constant-time secret comparison, then
checks the registered deployment/component authority (`403` on mismatch).
Never log, echo or export the header/token. Do not
reuse a database, runtime user, Desktop session or migration credential.
Helm wires the endpoint and Secret references; transport/TLS/CA and network
policy must match the reviewed deployment profile. The Service is not a public
ingress, and analytics does not create hosted egress in self-host mode.

## Limits, delivery and privacy

The first implementation must publish finite configurable limits for batch
bytes/event count, individual event bytes, producer queue bytes/count,
per-attempt request timeout, total request/delivery deadline, retries, shutdown
flush, file size, file count and total disk use.
Validate the actual streamed body size, not only `Content-Length`. Reject
oversized/invalid/unauthorized batches before writing their records. Tests
must exercise each configured bound rather than assume unlimited memory/disk.

Producer queue exhaustion drops the newest event and increments the explicit
queue-full counter. Collector retention is configured separately: `reject-new`
is the default at the file-count/byte cap. An explicit
`delete-oldest-closed` policy may remove closed segments by configured age or
capacity; this loses retained exports and increments retention-loss counters.
No implicit deletion or unbounded growth is allowed. Never delete an active
commit to make room for another batch.

Validate each entire batch before persistence and accept it atomically: all
events become committed or none do. One implementation is an immutable NDJSON
batch segment written privately, synchronized, atomically renamed, and followed
by directory synchronization. An equivalent journal must demonstrate the same
crash recovery and visibility boundary. Return success only after the storage
backend's durable-commit boundary, not merely a buffered stream flush. Recovery
must discard incomplete private segments without exposing partial batches.
Durability holds within the configured retention policy; no storage backend is
qualified by this design alone.

| Response | Producer behavior |
|---|---|
| `204` | Entire batch durably accepted; dequeue it |
| `400` | Terminal invalid batch/version/scope; count rejected events, no unchanged retry |
| `401` / `403` | Terminal authentication/authority failure; count and surface configuration failure |
| `413` | Terminal oversized batch; bounded splitting is allowed, oversized individual events are dropped and counted |
| `429` / `503` | Backpressure/unavailable; bounded retry, honoring bounded `Retry-After` |
| `507` | Storage capacity exhausted; bounded retry and observable storage/drop failure |
| Other `5xx`, timeout or connection loss | Bounded retry; the prior batch may already have committed |
| Redirect | Do not follow or forward credentials; count export failure |

Only `204` acknowledges collector acceptance. Other `2xx` responses, including
`200`, `202` and `206`, are protocol errors: never count them as accepted or
dequeue them as a success; use the finite retry budget, then count the loss.
This rule is for the collector adapter, not the separate PostHog protocol.

The configured total request/delivery deadline starts when the event is
enqueued and covers queued time, every request attempt and all retry waits.
A batch uses its earliest event deadline; splitting or retrying never resets
that budget. Each attempt's timeout is also clipped to the remaining total
deadline, and shutdown may impose a shorter one. Exhaustion drops/counts the
remaining events instead of starting another request or wait.

For retryable responses, accept `Retry-After` only as unsigned decimal
delta-seconds. The maximum honored delay is 30 seconds, further clipped to the
remaining total request/delivery deadline or shutdown deadline; a producer may
configure a smaller cap. Ignore malformed values and HTTP-date values and use the bounded local
backoff instead. Waiting still consumes the finite retry/time budget. A zero
delay never permits unbounded attempts. Tests cover malformed, date, zero and
oversized values plus deadline exhaustion.

Error responses carry a stable error code, never event content or credentials.
There is no per-event partial-success response. Delivery is best effort with
bounded retries: events may be dropped when queue or retry budgets expire.
Retries preserve event IDs and can duplicate a committed batch after a lost
acknowledgement. No exactly-once or automatic deduplication guarantee is implied.
Export failures do not turn successful product operations into failures.

Both producer and collector project a typed field allowlist. A private-key
regex alone is insufficient. Never export credential hashes, tokens, raw
requests, product content, sender names or arbitrary exception context/stack.
Exception events need their own scrubbed allowlist. Error names and codes must
map to registered classifications; a code-shaped string alone is not a privacy
allowlist. Unknown values become a fixed classification or are omitted, never
raw exception names, messages or context. An existing internal
credential-proof hop remains distinct from analytics and cannot be forwarded
to this endpoint or PostHog. Operational telemetry retains its separate report,
signature, consent/defaults and outbox contract.

Collector health reports bounded queue/write/drop counters without recursively
emitting its own failures into the event stream. Acceptance requires a real
correlated event trace, restart/rotation and disk-full tests, producer failure
isolation, unauthorized producer/tenant tests, and proof of no hosted export
request in self-host mode. A health HTTP 200 or successful chart render is not
that proof.
