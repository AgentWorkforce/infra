# Control collector adapter

`analytics.enabled` is off by default. With a qualified Control image that
implements `SELFHOST_ANALYTICS_*` (the 0.5.8 contract), it sends business events
to the installation's existing collector. This configuration selects only the
collector adapter. Hosted PostHog remains a separate application adapter.

```yaml
analytics:
  enabled: true
  deploymentId: install_opaque_1
  profile: production
  collectorUrl: https://collector.example.com/v1/events
  existingSecret: control-analytics-producer
  tokenKey: token
  caConfigMap: collector-ca # omit for a collector using system trust
  caKey: ca.crt
```

Register the producer with the collector before enabling it. The Secret must
contain the dedicated Control producer token, separate from application and
introspection credentials. Helm stores references, never the token value.
The application validates the credential and its closed event schema; a chart
render cannot prove that the token is valid or that events reached storage.

The API reads its token from a read-only Secret volume at mode 0440. An optional
public CA ConfigMap is mounted at mode 0444 and passed only to the collector
transport as `SELFHOST_ANALYTICS_COLLECTOR_CA_FILE`. That application transport
uses the specified CA bundle instead of system roots for this sink. With no
bundle it uses system trust. PostgreSQL's `NODE_EXTRA_CA_CERTS` and other clients
are unchanged. HTTPS, normal hostname verification and a complete `/v1/events`
endpoint are required; no insecure switch or HTTP fallback is provided.

The producer label is on the Pod template, never its immutable selector.
The migration Job's template and identity do not change. Neither the migration
container nor the password-pepper init container mounts producer credentials
or the collector CA. Network policies and the collector's admission settings
remain with the operator.

Move old `SELFHOST_ANALYTICS_*` entries out of `extraEnv` before upgrading to
this chart. Those names are reserved for this managed adapter, including raw
token and hosted PostHog settings. The API's bounded queue and retry defaults
come from the selected compatible application image.

# Existing introspection Secret

An installation that already keeps its introspection credential in a separate
Secret can retain it without copying or rotating the value:

```yaml
secretKeys:
  introspectSecret: ""
introspection:
  existingSecret: control-introspection
  key: introspect-secret
  audiences:
    - https://history.example.com
```

Remove the old `RELAYCONTROL_INTROSPECT_SECRET` or `_FILE` extraEnv entry. The
API now reads the same existing credential from its own read-only file mount.
The migration Job and init container do not mount it. Configuring both this
reference and `secretKeys.introspectSecret` refuses to render, as does reusing
an application credential key. Existing `secretKeys.introspectSecret` users can
keep that configuration unchanged. Both forms preserve the public Ingress
shield: `/internal` routes to a Service without endpoints.

Before a retained upgrade, compare the whole rendered release to the current
live objects: image identities, auth mode, TLS, selectors, routes, SQL jobs and
data claims. These options do not select an image, enable a profile, run a
migration or deploy anything by themselves. Verify real domain events in
private collector files and negative authentication separately after rollout.
