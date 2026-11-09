# Telemetry collector

The self-hosted analytics adapter sends authenticated batches to this internal
collector, which writes immutable NDJSON segments to a persistent volume.
Hosted adapters send to the hosted PostHog destination at `i.agentrelay.com`.
This chart does not redirect hosted traffic, accept browser credentials or
enable producer adapters automatically.

The runtime contract comes from relay-control source
`d2cb39635bbf163976c354582365b3d97dcd0b56`: the standalone
`agent-relay-analytics-collector` CLI, `POST /v1/events`, `GET /healthz`, and
`ANALYTICS_COLLECTOR_*` settings. It is not OTLP; the optional OpenTelemetry
collector in the pipeline chart serves a separate observability contract.

## Qualified runtime and upgrade

Chart 0.1.3 requires the source above, which restores owned committed segment
files to mode 0600 before listening, including after a volume remount broadens
their permissions. Recovery refuses startup if hardening fails. Event bytes,
retention and the exclusive-writer contract are unchanged.

The signed candidate `ghcr.io/agentworkforce/relay-control@sha256:37aa934ac5a39a950c53b93a5e03509cafaac2268471a3e398f276df6d95331a`
was built from that exact source. Its [source CI](https://github.com/AgentWorkforce/relay-control/actions/runs/42686628619)
and [image publication](https://github.com/AgentWorkforce/relay-control/actions/runs/42687608594)
passed. Qualification verified signed source provenance and both image
platforms, then exercised the native ARM CLI as UID 1000: accepted/rejected
producer controls, restart with 0660 fixtures restored to 0600, unchanged
bytes, and a retained RWOP volume remount with strict TLS health. The predecessor
failed the same private-mode restart check. Operators must still verify their
own storage backend and configured images.

The former qualified source `08cf1142303355a73a94dcf605045cdf363e02c5` is no
longer admitted. Before upgrading, supply the new verified collector image
and matching `image.sourceRevision`; do not retain the old declaration for a
new image. Repository, digest and source remain required operator inputs,
and producer adapters remain disabled until explicitly configured.

## What the chart installs

- One Deployment with one writer replica and `Recreate` updates.
- A retained `ReadWriteOncePod` PVC (or an explicitly supplied existing claim).
- A ClusterIP HTTPS Service on port 8443. An nginx-compatible unprivileged
  sidecar terminates TLS; the file collector binds only to pod loopback.
- Separate Secret mounts for producer credentials and the TLS private key.
- A NetworkPolicy admitting selected producer pods on 8443, with no outbound
  allow rules of its own. Evaluate the union with other namespace policies.

Both containers run without root, writable root filesystems, service-account
tokens or Linux capabilities. Collector readiness checks JSON `ok: true`, not
only an HTTP status. Startup opens/recovers the file store before listening.
HTTP readiness alone is not a durable-write or power-loss test.

The proxy accepts only `POST /v1/events` and `GET /healthz` on those routes;
other methods receive JSON 405 without reaching the collector. Its HTTPS
`/livez` probe answers locally, so an unavailable collector makes readiness
fail without restarting a responsive proxy. An unresponsive proxy fails its
own liveness probe.

## Before installation

Supply accepted immutable collector and TLS-proxy image digests and record the
collector source SHA. The declared source is pinned to the reviewed revision
`d2cb39635bbf163976c354582365b3d97dcd0b56`; accepting a different runtime requires
a reviewed allowlist update. This declaration is not cryptographic verification
of image contents: verify the actual archive/OCI source label separately. The collector image must contain Node 22 or later and
`node_modules/relay-control/dist/collector-cli.js` and `/usr/bin/flock`. The
reviewed public Control package includes the collector CLI. Repository naming
alone does not establish image contents; verify the exact digest and package
before installation. The proxy must contain
nginx and run this chart's configuration as UID/GID 1000. No runnable images
are selected by default. The `ci/` image identities are render-only fixtures.

Create two operator-managed Secrets through your normal secret-management
process. Never put token values in Helm values or a ConfigMap:

1. A producer Secret containing `producers.json` and every token file referenced
   in that JSON, for example:

   ```json
   [{"name":"control","component":"relaycontrol","deployment_id":"deployment_a","token_file":"/var/run/secrets/telemetry-producers/control-token"}]
   ```

   Use a separate random credential per producer and deployment. The collector
   validates identity bindings and refuses shared credentials. This qualified CLI registers `relaycontrol`, `session-ingest`,
   `session-read-api` and `session-pipeline-consumer`, each with a closed typed
   vocabulary. Other components still need a reviewed runtime registry. Dashboard/Desktop events use the
   authenticated Control gateway and never receive producer tokens.
2. A TLS Secret with `tls.crt` and `tls.key`. The certificate must cover the
   exact internal Service DNS name, and producers must trust its issuing CA.
   This chart creates no certificate or trust exception. It refuses using the
   producer Secret as the TLS Secret.

New claims use a CSI storage driver supporting `ReadWriteOncePod` on Kubernetes
1.29+. The command also holds an exclusive kernel file lock for the entire
collector process, including shutdown. A second process exits before the CLI
starts; a crash releases the lock without deleting the lock file. `--no-fork`
keeps signals directed to the collector. The lock is an additional process
guard, not storage fencing: it does not stop another Pod mounting the claim.
An existing claim must independently enforce exclusive Pod ownership (RWOP or
equivalent) and support the file lock. A `ReadWriteOnce` claim and successful
lock contention alone do not meet that storage requirement. Verify both
storage fencing and lock contention before enabling producers. Do not mount
the data directory into another writer that omits the lock. The default 2 GiB volume
leaves space around the collector's 1 GiB closed-segment cap; size the volume
for configured limits, filesystem overhead and operational retention.

## Install and connect a producer

```yaml
image:
  repository: <accepted collector image repository>
  digest: <accepted sha256 digest>
  sourceRevision: <exact 40-character source revision>
tlsProxy:
  image:
    repository: <accepted nginx-compatible image repository>
    digest: <accepted sha256 digest>
producersSecret: telemetry-producers
tlsSecret: telemetry-tls
rolloutRevision: rotation-1
```

Install the standalone chart with these references, or enable the umbrella's
`components.telemetryCollector` and put its configuration under
`telemetry-collector`. The umbrella keeps it off until the runtime dependencies
are accepted. No kind or cloud profile is enabled by this source change.

Label authorized producer pods `agentworkforce.dev/analytics-producer: "true"`,
or configure explicit `networkPolicy.allowedFrom` peers. Configure each
producer's existing adapter, using its own credential Secret mount. For Control:

```text
SELFHOST_ANALYTICS_PROFILE=production
SELFHOST_ANALYTICS_DESTINATION=collector
SELFHOST_ANALYTICS_COLLECTOR_URL=https://<service>.<namespace>.svc.cluster.local:8443/v1/events
SELFHOST_ANALYTICS_COLLECTOR_TOKEN_FILE=<producer-specific mounted token file>
SELFHOST_ANALYTICS_COLLECTOR_CA_FILE=<mounted issuing CA bundle>
```

Do not select a development profile to bypass TLS. Configuring this Service
does not implement adapters in components that lack them. There is no PostHog
endpoint, cloud key or outbound exporter in the collector Deployment.

## Retention, restart and acceptance

The default `reject-new` policy refuses batches at capacity rather than deleting
accepted history. Optional `delete-oldest-closed` retention is an explicit
operator choice. Failed writes must not return a successful durable
acknowledgement; preserve the runtime's 204/error contract through the proxy.
Change `rolloutRevision` when rotating Secrets: tokens load once at startup.
Termination grace must exceed the configured collector shutdown deadline.

Before enabling application telemetry, verify the actual images, certificate
chain and hostname, producer isolation, mounted filesystem ownership, file
content after a successful acknowledgement, restart/crash recovery, disk-full
and write/fsync failures, in-flight shutdown and retention. Verify that a second
pod cannot write the claim and that removing the release preserves it. Test
each component adapter and the client gateway separately; a gateway's queued
202 is not the collector's durable 204. Chart render tests establish none of
these installed lifecycle results.

The umbrella enforces Kubernetes 1.29+ when this component is enabled; other
default-off installations retain their existing Kubernetes compatibility.
Ingress peers must use non-empty label or expression selectors; empty pod or
namespace selectors are refused.
