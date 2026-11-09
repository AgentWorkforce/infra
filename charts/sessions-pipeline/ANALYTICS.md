# Native pipeline analytics

The native ingest edge, read API and consumer share the pipeline's analytics
adapter. A self-host service uses a private collector; the hosted Workers use
the PostHog adapter. These Helm settings never select PostHog or carry a hosted
project key. Use a qualified pipeline image containing source `71801741` or
later with the three service adapters.

Analytics is off by default. Set `ingestEdge.analytics`,
`nativeConsumer.analytics`, and `sessionReadApi.analytics` separately:

```yaml
analytics:
  enabled: true
  deploymentId: install_opaque_1
  collectorUrl: https://telemetry-collector.example.svc.cluster.local:8443/v1/events
  existingSecret: reader-analytics-producer
  tokenKey: token
  caConfigMap: telemetry-collector-ca
  caKey: ca.crt
```

The standalone `session-read-api` chart uses the same top-level `analytics`
object. Each service needs its own component-bound token, pre-registered by the
collector operator. Register `session-ingest`, `session-read-api`, and
`session-pipeline-consumer` against the same opaque installation identifier.
Use distinct producer tokens; never place their values in values files. The
chart references existing Secrets and does not mint or rotate credentials.
A collector accepting the HTTP request is not enough proof: verify real domain
events are committed to its private files with the expected component and
installation, and that a token cannot impersonate another component.

`caConfigMap` holds public certificates only. When set, the chart mounts it
read-only and sets `NODE_EXTRA_CA_CERTS` in the service container, preserving OS
trust. Leave it empty for an OS-trusted collector certificate. If another
upstream also needs an additional private CA, supply one public CA bundle
containing both certificates. The consumer's bootstrap and preflight containers
receive no analytics token. No certificate-verification bypass is offered.

The chart adds `agentworkforce.dev/analytics-producer: "true"` to the service
Pod only, without changing its Deployment selector. Configure network policy
so these Pods can reach the intended collector and the collector accepts them;
this setting opens no network policy or external egress automatically. Restart
through an explicit `podAnnotations` revision when rotating a referenced token
or CA, after the collector registration is ready.

The read API's `extraEnv` cannot override `ANALYTICS_*`, and cannot set
`NODE_EXTRA_CA_CERTS` when managed analytics is enabled. Move any previous
analytics environment settings into this object and remove a conflicting
analytics CA volume or mount. Disabling analytics emits no analytics environment,
producer label or CA volume. Unrelated runtime credentials, PostgreSQL trust,
canonical storage layout and migration/admission controls stay independent.
