# Route the native session services through one origin

The native ingest edge and reader use one public HTTPS origin. The reader's
login response may advertise sync only when Control granted it; the edge
independently introspects the caller on every upload. Routing supplies neither
credentials nor scopes.

This opt-in configures an already qualified native ingest/consumer/reader
installation. It does not bootstrap the database, provision role credentials,
grant a license or enable deletion. The existing legacy `kind-up` bootstrap
does not establish native first-boot support; native orchestration needs its
own qualification.

## Chart configuration

Compose this partial overlay with the installation's existing native service
values, immutable images, Secret references and CA configuration:

```yaml
sessions-pipeline:
  nativeRouting:
    enabled: true
    origin: https://history.kind.agentrelay.com:8443
    className: traefik
    tls:
      existingSecret: kind-tls
  readApi:
    enabled: true
    loginAdvertisesSync: true
    origin: https://history.kind.agentrelay.com:8443
    auth:
      mode: relaycontrol_only
  ingestEdge:
    enabled: true
    origin: https://history.kind.agentrelay.com:8443

relayhistory:
  ingress:
    enabled: false

relay-control:
  services:
    relayauthEnabled: false
    relayhistoryPublicUrl: https://history.kind.agentrelay.com:8443
    relayhistoryReadApiUrl: https://history.kind.agentrelay.com:8443
    relayhistoryReadApiEvents: true
```

The overlay deliberately omits image and credential values. Keep the qualified
native image, schema generation, database roles and bootstrap order from the
[native ingest](self-hosted-native-ingest.md) and native consumer contracts.
The reader and consumer need the same **bare** key root and
`PIPELINE_ORG_FROM_PREFIX=true`; a tenant-suffixed root reads a different layout.
For the sync-capable pattern, set `readApi.loginAdvertisesSync: true`. This moves
the supported `RELAYHISTORY_SELFHOST_LOGIN_ADVERTISES_SYNC` setting out of
`readApi.extraEnv`; remove that old entry when upgrading. The reader only
advertises sync already granted by Control, and the ingest edge still checks it
independently. The default is read-only, and native routing requires this
explicit managed selection.

The generated Ingress sends exactly these paths to the selected Services:

| Path | Match | Backend |
| --- | --- | --- |
| `/v1/delivery/batches` | Exact | Native ingest |
| `/v1/turns/batches` | Exact | Native ingest |
| `/v1/delivery/limits` | Exact | Native ingest |
| `/` | Prefix | Reader |

Backends use Service ports, not container ports. `/v1/delivery/records`,
sessions, events, turns, search and login stay on the reader. Method and auth
checks still belong to the services. Selection, resets, recovery and onboarding
are not advertised as working features by these rules.

Origins must match byte-for-byte, including the port. The umbrella rejects a
competing standalone History ingress or the older shared GKE History backend.
A selected legacy server and its data can remain internally available for
rollback without owning the public route. Routing is not permission to erase it.

## Control and verified TLS

Use a Control image that implements `RELAYHISTORY_READ_API_EVENTS`. The managed
URL emits `RELAYHISTORY_READ_API_URL` and an explicit true/false events setting
in the **API** container, not the migration Job. Existing introspection Secret
references and an exactly matching allowed audience are still required. The
chart does not mint them. Remove corresponding URL/events `extraEnv` entries
when selecting managed fields; duplicate definitions refuse render.

The connection retains the public DNS name, HTTPS, SNI and audience. An optional
explicit in-cluster address maps only that reader hostname:

```yaml
relay-control:
  services:
    relayhistoryHostAliases:
      - ip: 10.96.137.234 # Example only: discover this installation's address.
        hostnames: [history.kind.agentrelay.com]
```

Do not copy this example IP into another cluster. This value accepts one
canonical IPv4 address and exactly the configured reader hostname. Its empty
default emits no mapping. Certificate verification still requires the public
name and an approved CA in the container's trust configuration. Project private
CA bundles read-only as public certificate material, never server private keys.

## Local kind network preparation

The local helper prepares the gateway before discovering its allocated internal
Service address, then writes private proposed values. It does not issue
readiness or install native database roles. The site on port443 and History on
port8443 remain distinct contracts.

After preparing the complete selected-values JSON and creating an owned kind
cluster, run:

```sh
python3 ci/agent-relay/kind/stack.py prepare-native-network --profile core \
  --native-values /path/to/private/selected-native-values.json
```

The command validates existing resource ownership before changing the gateway,
then writes `.kind/core/native-network-values.json`. It leaves active profile
values, the app Helm release, database, readiness and proof untouched. Review
the proposed file and complete the app installation separately. For addons,
select `--profile addons` and its own explicit local fixture values; core
ownership and addresses do not authorize the addons cluster.

Existing manual resources need a separately reviewed, identity-bound ownership
transition. Do not use broad `--take-ownership`, duplicate an Ingress or silently
replace an existing Service. The helper refuses foreign or unqualified existing
resources before mutation.

## Verification

Render the complete values and check actual Service names/ports, TLS Secret,
origin and absence of a competing route. Then test caller-bound login/sync,
strict TLS, a marked upload in the bucket, its canonical pointer and that same
session's real dashboard conversation. Render tests or an empty HTTP200 list
do not prove that path. Historical backfill, Desktop automatic sync, summaries
and privacy/deletion need separate tests.

### Edge egress policy ownership

Native network preflight also checks `kind-edge-no-external-egress` in
`kind-edge` before gateway installation. An existing policy must carry the
source ownership label, profile, fixture name and original cluster UID, have no
foreign release/controller ownership, and match the exact backend/API/DNS-only
policy computed from the current Kubernetes API endpoints. A manual, changed or
terminating policy refuses before gateway or local readiness/selection changes;
matching contents alone do not authorize adoption. Establish any existing
manual policy's ownership through a separately reviewed handoff.

Installation repeats that gate. An exact owned policy is a no-op. An absent
policy is created with source ownership and its returned contents verified;
`CREATE` refuses a policy that races preflight. Installation does not apply over
an existing policy.
