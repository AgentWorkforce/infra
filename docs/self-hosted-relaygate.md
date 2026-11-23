# relaygate (optional governance gate)

[relaygate](https://github.com/AgentWorkforce/relaygate) sits between agents and
Relaycast/Sessions. Agents register into a **group** with an enrollment key;
every request is checked against owner/group/other **mode bits**; writes that
cross a group boundary or leave through an external stream (a Slack thread, a
knowledge base) go through a **classifier** (rules, plus an optional Claude
model). Denials never reach upstream. It is part of the agent-relay umbrella
(`components.relaygate`), off by default; the install guides for GKE, EKS and
AKS turn it on in [sessions-only](#built-in-sessions-only) mode. It can also
run as its own release.

> **Status: build 2.** Registration, mode checks and ACLs, the classifier,
> `/v1/check` and the audit log, plus proxies in front of Relaycast (REST
> allowlist and `/v1/node/ws`) and Sessions (`/sessions`). Isolation holds only
> when agents can reach Relaycast and Sessions **through relaygate alone**:
> turn the proxies on (`proxy.relaycastUrl`, `proxy.sessionsUrl`) and
> enforce it by narrowing Relaycast's and Sessions' own NetworkPolicies to the
> gate (below, or with one switch: [Gate-only](#gate-only-one-switch)), or keep
> regulated agents in their own install.

![Slack app and relaygate](diagrams/slack-relay-relaygate.png)

([SVG](diagrams/slack-relay-relaygate.svg) · source [slack-relay-relaygate.mmd](diagrams/slack-relay-relaygate.mmd) · one message end to end: [slack-relay-flow.png](diagrams/slack-relay-flow.png))

| Who | Group | May | May not |
| --- | --- | --- | --- |
| Pit agents (Slack thread agents, pit workers) | 22 | read and write pit streams and Slack threads; read local sessions | write into local inboxes or sessions |
| Local agents (laptops, editors) | 11 | write into pit inboxes; read and write local streams | read anything in the pit; post to Slack |
| The Slack bridge (router) | 22 | post to `slack:` streams after `/v1/check` | post anything the classifier denies |

Mode bits follow the filesystem: owner/group/other × read/write. Every
default stream is `660` (owner and group only) plus an explicit **ACL** for
each cross-group grant; there is no catch-all, so a stream no default matches
is private to its owner's group:

| Streams | Owner group | ACL |
| --- | --- | --- |
| `relaycast:channel/`, `relaycast:inbox/local-` | 11 | pit (22) may read |
| `relaycast:channel/pit-`, `relaycast:inbox/pit-`, `relaycast:inbox/slack-` | 22 | local (11) may write |
| `slack:`, `kb:` | 22 | none; classified |
| `relaycast:agent/` (the agent directory) | 22 | none; mode `040`: the pit sees every agent, and seeing grants no write |

Enrollment keys decide an agent's group at registration; give each a name
prefix matching its streams (`local-`, `pit-`, `slack-`) so a key can't take
another group's names. Guests (another company's agents) get their own group,
`guest: true`, an `expiresAt`, and a ceiling (`ceilings: [{gid: 44, never:
[22]}]`) that no ACL can override. A 403 can change after an ACL change
(`PUT /v1/streams/{id}`).

```yaml
# relaygate-values.yaml (Anthropic: use a zero-data-retention key where regulated data may be classified)
image:
  digest: sha256:<published digest>
policy:
  enrollmentKeys:
    # sha256 of each key only; the keys go to the clients that register
    - { id: local, gid: 11, sha256: "<sha256 of the local key>", namePrefix: "local-" }
    - { id: pit, gid: 22, sha256: "<sha256 of the pit key>", namePrefix: "pit-" }
    - { id: slack-bridge, gid: 22, sha256: "<sha256 of the bridge key>", namePrefix: "slack-" }
  classifier:
    model: { enabled: true, model: claude-opus-5-5, effort: low, timeoutMs: 8000 }
secrets:
  anthropicApiKey: { name: relaygate-anthropic, key: api-key }   # only with the model classifier
```

```sh
openssl rand -hex 32 | tee bridge.key | tr -d '\n' | shasum -a 256   # the sha256 goes in the policy
helm upgrade --install relaygate charts/relaygate -n agent-relay -f relaygate-values.yaml
```

The default policy groups agents as **11 local** and **22 pit**, gives `slack:`
and `kb:` streams to the pit (mode 660, classified), and ships two rules (US
SSNs, prompt injection). One replica: the audit log and registrations are
SQLite on the gate's PVC.

Clients: [slack-relay](self-hosted-slack-relay.md#governance-with-relaygate-optional)
takes `relaygate.url` and the bridge key. With the proxy below, agents reach
Relaycast and Sessions only through the gate and need no Relaycast credential
of their own (Relaycast should then accept traffic only from the gate, by
NetworkPolicy).

## Built in: sessions-only

The umbrella deploys relaygate and routes `history.*` through it on every
edge it renders: GKE (`gkeIngress`), EKS (`eksIngress`, the ALB) and AKS
(`traefikIngress`, Traefik). One switch, one model for all three:

```yaml
global:
  relaygate:
    gateOnly:
      enabled: true
      scope: sessions   # all: Relaycast (cast.*) through relaygate as well
components:
  relaygate: true
```

**Sessions-only** (`scope: sessions`) means:

- the history host sends only relaygate's Sessions routes to relaygate and
  denies everything else at the edge (`/internal` and `/admin` explicitly);
- the Sessions reader and the ingest edge admit only relaygate
  (NetworkPolicy), so uploads and reads are checked against the policy;
- relay-control reads Sessions through relaygate's internal listener
  (`SESSION_READ_API_URL=http://<relaygate>-sessions.<ns>.svc.cluster.local:8081`),
  so dashboard and MCP reads are mapped to groups by `policy.controlPrincipals`;
- Relaycast is untouched: the cast host, Relaycast's NetworkPolicy and its
  ingress render as without the gate, Control does not set
  `SELFHOST_RELAYGATE_PUBLIC_URL`, `relaygate.proxy.relaycastUrl` is optional
  and `slack-relay.relaygate.url` is not required. CLI, desktop, Chief and
  other direct Relaycast clients keep working.

`scope: all` is the [gate-only](#gate-only-one-switch) mode below: the cast
host goes through relaygate too. Every gate-only check below applies to both
scopes except the Relaycast ones.

It needs agent-relay chart **0.7.77 or later**. The install guides keep their
pinned releases and describe it as the recommended next step once the release
carries that chart. On EKS the attested pull-based upgrade also needs a release
whose signed image inventory pins relaygate (none does yet).

The example values per platform (release name `agent-relay`):

| Platform | Edge | Example values |
| --- | --- | --- |
| GKE | `gkeIngress`: the history host goes to a `<gkeIngress.name>-gate` NEG Service on the relaygate pods (BackendConfig health check `/healthz`) | [`charts/agent-relay/values-gcp-relaygate.yaml`](../charts/agent-relay/values-gcp-relaygate.yaml), a profile after `values-gcp-native.yaml`; site values in the GCP guide, step 11 |
| EKS | `eksIngress` (render the ALB from the release; `scripts/selfhost/eks-alb-ingress.sh` has no gate mode): the history host goes to the relaygate Service, ALB health check `/healthz` | [`charts/agent-relay/values-eks-relaygate.yaml`](../charts/agent-relay/values-eks-relaygate.yaml) |
| AKS | `traefikIngress` (the release-rendered form of `docs/azure-install/ingress.yaml`): the history host goes to the relaygate Service; denials go to the endpoint-less `edge-deny` Service (Traefik 503) | [`docs/azure-install/relaygate-values.yaml`](azure-install/relaygate-values.yaml), after the guide's `values.yaml`; AKS guide step 8b |

helm refuses to render until each file's REQUIRED values are set (the relaygate
image digest, the history host, the dashboard origin and your
`controlPrincipals`), and names what is missing. `charts/agent-relay/ci/gate-sessions-{gke,eks,aks}-values.yaml`
are complete render examples.

History routes relaygate serves on the history host: `/v1/sessions`,
`/v1/delivery` (batches, limits, admission, sessions/selection, records) and
`/v1/digest` (Prefix; plus `/v1/relayfacts` and `/v1/coordination` with
`relayfactsRoutes`), and `/v1/events`, `/v1/ingest`, `/v1/auth/token/refresh`,
`/v1/auth/token/revoke`, `/v1/onboarding/heartbeat` and `/v1/upload-consent`
(Exact). relaygate refuses any child it does not proxy with
`404 relaygate_route_not_proxied`; `/v1/delivery/records` and `/v1/digest/*`
are aggregate reads, allowed only to `policy.sessionAggregates` groups.
Everything else on that host is denied at the edge, `/internal` and `/admin`
included. Revoke, admission, upload consent, sessions/selection and records
need relaygate #23 or later; digest needs #21 or later. On an older image those
paths answer `relaygate_route_not_proxied`, no worse than the edge deny.

Limits, until the images named here ship:

- **Do not use `readerKinds` in `controlPrincipals` with scope sessions.**
  relay-control puts the reader kind on read-token mints only when
  `SELFHOST_RELAYGATE_PUBLIC_URL` is set, which scope sessions leaves unset
  (it belongs to the Relaycast gate). relaygate fails closed, so a rule with
  `readerKinds` matches no dashboard read. A relay-control change adds a
  separate switch; the chart gets a key for it once its name is fixed.
- **Rules on `roles` need the role on read tokens:** set
  `relay-control.services.sessionReadMintIncludeRole: true` (renders
  `SESSION_READ_MINT_INCLUDE_ROLE=true`; off by default). Without it, list
  admins by `emails` or `userIds`, as the examples do.
- **`global.relaygate.controlPolicy` stays off:** no relay-control image reads
  its settings yet.
- **`/v1/relayfacts` and `/v1/coordination`** are denied at the edge unless
  `global.relaygate.gateOnly.relayfactsRoutes: true` (off by default), which
  routes both (Prefix) to relaygate on every edge. Turn it on only with a
  relaygate image that proxies them (relaygate #49, 8d0e6897, or later); older images
  answer `404 relaygate_route_not_proxied` after authentication.
- relay-control's health check calls `GET /healthz` on its
  `SESSION_READ_API_URL`, so relaygate's internal listener must answer it
  without credentials.
- The isolation holds only on a cluster that enforces NetworkPolicy (GKE
  Dataplane V2 or the NetworkPolicy add-on, the EKS VPC CNI with network policy
  on, AKS with the Cilium dataplane as in the AKS guide). Elsewhere public
  clients still go through relaygate, but a pod in the cluster can reach the
  reader directly.

Turn it on for an existing install in this order: deploy a relaygate image with
Control-principal mapping, prepare the policy, then upgrade with the example
values and [adopt the existing sessions](#existing-sessions-adopt-them-once)
(dry run first). Sessions uploaded before the switch are invisible through the
gate until they are adopted.

## Proxying Relaycast and Sessions (build 2)

```yaml
# relaygate-values.yaml, in addition to the policy above
proxy:
  relaycastUrl: http://relaycast:8787
  sessionsUrl: https://history.example.com   # sessions-pipeline nativeRouting.origin (reads and uploads)
secrets:
  relaycastWorkspaceKey: { name: relaygate-relaycast, key: workspace-key }  # rk_live_ key relaygate registers agents with upstream
  relaygateSecret: { name: relaygate-seal, key: secret }                   # >= 32 chars; keep it for the life of the PVC (seals upstream tokens)
  # sessionsToken: optional; the gate forwards each caller's own Sessions credential
  adminToken: { name: relaygate-admin, key: token }                        # optional: admin explain, audit, sessions/adopt
```

Then close the direct path. NetworkPolicies are additive, so a policy that
admits only the gate does nothing while Relaycast's own policy admits the whole
namespace (its default). Narrow Relaycast's policy instead, in the relaycast
values (or `relaycast:` in the umbrella):

```yaml
networkPolicy:
  enabled: true
  ingressFrom:
    - podSelector: { matchLabels: { app.kubernetes.io/name: relaygate } }
    # plus every caller that must stay direct (relay-control, the ingress
    # controller if Relaycast is exposed, ...); anything not listed is cut off
```

Sessions needs the same on both of its Services: the reader
(`sessions-pipeline.sessionReadApi.networkPolicy.publicFrom`) and the ingest
edge (`sessions-pipeline.ingestEdge.networkPolicy.ingressFrom`). An ingest
policy that admits the install namespace lets any agent holding a Sessions
upload credential upload around relaygate. [Gate-only](#gate-only-one-switch)
sets all three from one switch.

`proxy.sessionsUrl` must be one origin that routes both session reads and
uploads. In the sessions-pipeline chart those are separate Services (the reader
and the ingest edge); `nativeRouting` joins them under one HTTPS origin
([self-hosted-native-routing.md](self-hosted-native-routing.md)), and that
origin is the value to use. If it is served with a private CA, give relaygate
that CA too.

Then point clients at the gate: the Slack app sets `relaygate.url` (it registers
through the gate and uses it as its Relaycast base URL), and session uploads use
`https://<gate>/sessions`. Agents get a relaygate `rg_` token, never the
workspace key.

The default policy gives the Slack app's routing channel (`relaycast:channel/slack`)
to the pit with no local access; if you change the Slack app's
`relaycast.channel`, add a matching stream default. Verified against relaygate
build 2: Slack-app agents register into the pit, create and join their channel,
receive events over the proxied node WebSocket, and reply in threads with their
`data` intact.

## Control principals: desktop and dashboard

Some Sessions callers hold only relay-control credentials: the desktop app
uploads with its device token and the dashboard reads with Control-issued read
tokens. With `control.introspectUrl` (relaygate `sha256:c66696c5` or later) the
gate accepts them on Sessions routes and maps each user to a group by policy:

```yaml
# relaygate-values.yaml, with the Sessions proxy on
control:
  introspectUrl: http://relay-control:8080/internal/v1/auth/introspect
  sessionIngestAudience: https://history.example.com   # the ingest origin relay-control accepts
proxy:
  sessionsCorsOrigins: [https://app.example.com]       # match the read API's list
secrets:
  relaycontrolIntrospectSecret: { name: relaygate-control, key: introspect-secret }
  sessionsInternalSecret: { name: relaygate-sessions-internal, key: secret }   # optional: checks mint calls
policy:
  controlPrincipals:            # first matching rule wins; no match is refused
    - { match: { orgIds: ["<org>"], roles: [owner, admin] }, gid: 33 }
    - { match: { orgIds: ["<org>"] }, gid: 11 }
  sessionAggregates: { gids: [33] }   # who may read cross-session aggregates
```

Device tokens are introspected with relay-control (answers reused for up to
15 s). Read tokens can't be introspected, so point relay-control's
`SESSION_READ_API_URL` at relaygate. It must be an origin with no path (Control
refuses `.../sessions` and crash-loops), so use a relaygate origin that serves Sessions
on a listener where the internal mint is allowed; with gate-only the chart
renders relaygate's internal Sessions listener (`SESSIONS_PORT`, relaygate #28
or later) and points Control at
`http://<relaygate>-sessions.<ns>.svc.cluster.local:8081`. relaygate
forwards the mint calls unchanged and remembers which user each token belongs
to. Each Control user acts as `ctl:<userId>` (the `ctl:` prefix is reserved) and
their own credential still reaches Sessions. Uploads need `rth:sync`, reads
`rth:read`. See relaygate `docs/contract.md`.

### Group badges in the dashboard

To show a group's label on its sessions in the dashboard (a small badge on
session rows and the session header, and a Group filter), give the group a
label in the policy. With relaygate#39, relay-control#204 and relay-web#148 or
later:

```yaml
# relaygate-values.yaml (or the Control-owned policy under Settings, Gate)
policy:
  groupLabels:
    "22": { label: pit }   # key: gid in decimal; label: 1-24 letters, digits, space, . _ -
```

No group has a label by default. A label is display only: it grants nothing.
relaygate adds `relaygate: {gid, label}` only to sessions the reader may already
read, never names the owner, and drops any such key that comes from Sessions
itself. The chart renders `policy` verbatim, so there is no other knob. See
relaygate `docs/contract.md`, "Group labels".

### Desktop enrolment

With relaygate `sha256:b2fcef80` or later and `control.introspectUrl` set (the
Sessions proxy is not needed for this), a person's desktop app enrols its
agents at the gate with their relay-control device token instead of an
enrollment key: `POST /v1/register` with `Authorization: Bearer sh_at_...`.
The person is mapped through `policy.controlPrincipals` (a rule may set
`namePrefix` to limit the names their desktop may enrol); the agent gets a
`rg_` token that expires with the device token and at most 24 hours later, so a
revoked device or a person removed from the org loses their agents within a
day. Enrollment key ids `control` and `device:*` are reserved. relay-control
tells the desktop where the gate is when `SELFHOST_RELAYGATE_PUBLIC_URL` is set
(gate-only installs). The same image adds a delivery queue
(`GET /v1/deliveries`, ack, fail, defer) filtered by what the agent may read.

## Gate-only (one switch)

The steps above narrow each policy by hand. In the agent-relay umbrella,
`global.relaygate.gateOnly.enabled` does it from one switch (`scope: all`, the
default, gates Relaycast and Sessions; `scope: sessions` is
[sessions-only](#built-in-sessions-only)), and helm refuses to
render while any part of it is missing, rather than leaving a door open. It is
off by default; with it off every render is unchanged.

Why it exists: a workspace member can mint their own Sessions read token
(`rth_at_read_`, from Control's `POST /api/v1/workspaces/<ws>/session-read/session`)
and read a pit session directly at `https://history.<domain>/v1/sessions/<id>/events`.
Through relaygate the same read is refused. Relaycast has the same direct path
at `cast.<domain>`. Gate-only closes both.

### Prerequisites

- **A cluster that enforces NetworkPolicy.** On GKE that is Dataplane V2 or the
  NetworkPolicy add-on (checked on the nodes, see the GCP install guide). On a
  cluster that ignores NetworkPolicy the routing changes but nothing stops a pod
  calling Relaycast or Sessions directly.
- **relaygate with Control-principal mapping ("PR B", relaygate#21, main
  be42c916 or later, image `sha256:c66696c5`).** Once
  gate-only is on, people using the dashboard and the desktop app reach
  Sessions through relaygate too, with Control-issued tokens (`sh_at_` upload
  tokens, `rth_` read tokens), not `rg_` tokens, and Control's own mint,
  refresh, service-token and server-side read calls go through it. relaygate
  introspects those tokens at Control and maps each person to a group. **Until
  a relaygate image with that mapping is deployed, turning gate-only on breaks
  dashboard session reads, desktop uploads and Control's session reads (MCP
  included).** The chart renders the settings; it cannot tell whether the
  image supports them.
- **Policy rules for Control callers** ([Control principals](#control-principals-desktop-and-dashboard-on-sessions)).
  relaygate refuses every Control-authenticated caller that no rule maps
  (render fails with gate-only and no rules), so the policy needs:
  - `controlPrincipals`: rules matching on `orgIds`, `roles`, `emails` or
    `userIds`, each with a `gid`; the first match wins. The dashboard's read
    mint may not carry a role yet, so until it does, list admins by `emails`
    or `userIds` rather than `roles`;
  - `sessionAggregates` naming an admin gid (the workspace-wide aggregate
    reads);
  - an admins group with `r` on every entry in `policy.sessionDefaults` (an
    ACL `{gid: <admin>, perm: r}` on each), or the admin per-person view in
    the dashboard comes back empty.

  The `ctl:` principal namespace is reserved for these Control callers: don't
  start an enrollment key id, agent name prefix or other policy name with it.
- Sessions that never came through relaygate have no owner there and are
  invisible through it, so history from before the switch disappears from
  reads.

### Values

```yaml
global:
  relaygate:
    gateOnly:
      enabled: true
      # serviceName: ""   # set it when relaygate.fullnameOverride is set
      # servicePort: 8080 # relaygate.service.port
      # sessionsPort: 8081 # relaygate's internal Sessions listener (SESSIONS_PORT, relaygate #28 or later); relay-control's SESSION_READ_API_URL
components:
  relaygate: true
relaygate:
  proxy:
    relaycastUrl: http://relaycast:8787               # the relaycast Service
    sessionsUrl: https://history.example.com          # the history origin
    sessionsUploadUrl: http://<ingest edge Service>   # sessions-pipeline ingestEdge (port 80)
    sessionsReadUrl: http://<read API Service>        # sessions-pipeline sessionReadApi (port 80)
    sessionsHosts: [history.example.com]              # the history host, served at the root
    sessionsCorsOrigins: [https://app.example.com]    # = sessions-pipeline.sessionReadApi.cors.allowedOrigins (the dashboard origin)
  control:
    introspectUrl: http://relay-control.<ns>.svc.cluster.local/internal/v1/auth/introspect
    sessionIngestAudience: https://history.example.com  # the public history origin (= ingestEdge.origin); Control already accepts it
  policy:
    controlPrincipals: [...]          # required with gate-only; see above
    sessionAggregates: { gids: [<admin gid>] }
  secrets:
    relaycastWorkspaceKey: { name: relaygate-relaycast, key: workspace-key }
    relaygateSecret: { name: relaygate-seal, key: secret }
    # The ingest edge's introspection secret: sessions-pipeline
    # ingestEdge.config.existingSecret and introspectSecretKey.
    relaycontrolIntrospectSecret: { name: <ingestEdge.config.existingSecret>, key: <ingestEdge.config.introspectSecretKey> }  # e.g. key relaycontrol-introspect-secret
    # Recommended: the read API's READ_API_INTERNAL_SECRET (sessions-pipeline
    # sessionReadApi.auth.selfIssued.internalSecret), as SESSIONS_INTERNAL_SECRET.
    sessionsInternalSecret: { name: <internalSecret.existingSecret>, key: <internalSecret.key> }
# With components.slackRelay: slack-relay.relaygate.url (the Slack app must register through the gate).
```

`charts/agent-relay/ci/gate-only-values.yaml` is a complete example on the GKE
proof shape. Rendering fails when gate-only is on and: relaygate, Relaycast or
the Sessions reader and ingest edge are off; a proxy is unset; an upstream is
not the in-cluster Service (a public host would loop back through the gate);
`sessionsHosts` misses the history host; `policy.controlPrincipals` is empty;
`control` is unset, does not point at the Control Service, uses another audience than the ingest origin, or
another Secret than the ingest edge's; `sessionsInternalSecret` is set to
another Secret than the reader's; `sessionsCorsOrigins` differs from the
reader's `cors.allowedOrigins` (the dashboard reads Sessions through relaygate,
and relaygate's own 403s need the same CORS headers to reach it); Relaycast's, the reader's or the ingest
edge's NetworkPolicy is disabled; the reader's own Ingress is enabled; the
Slack app has no `relaygate.url`; or the relaygate Service name doesn't match.

### What the switch changes

| Where | Gate-only |
| --- | --- |
| `gkeIngress` cast host | relaygate's routes (below) go to a `<gkeIngress.name>-gate` edge Service on the relaygate pods (NEG, BackendConfig with the cast timeout and `/healthz`); everything else is denied at the edge |
| `gkeIngress` history host | relaygate's Sessions routes go to the same edge Service; everything else is denied |
| sessions-pipeline `nativeRouting` | relaygate's Sessions routes go to the relaygate Service; nothing else is routed |
| relaycast `ingress` | relaygate's Relaycast routes go to the relaygate Service; everything else is denied |
| relaycast NetworkPolicy | `ingressFrom` is ignored: relaygate, the chart's migration Job and `networkPolicy.gateOnlyFrom` (default: relay-control and relayauth) |
| session-read-api NetworkPolicy | `controlFrom` and `publicFrom` are ignored: relaygate only, for `/v1` and `/internal` |
| ingest edge NetworkPolicy | `ingressFrom` is ignored: relaygate only, plus `ingestEdge.networkPolicy.gateOnlyFrom` (default empty). Without gate-only, a policy that admits the install namespace (or any pod an agent runs in) lets an agent holding a Sessions upload credential upload around relaygate; narrowing Relaycast and the reader alone is not enough |
| relay-control | `SESSION_READ_API_URL` becomes `http://<relaygate>-sessions.<ns>.svc.cluster.local:8081` (an origin; Control refuses a path), so Control's mint, refresh and service-token calls and its server-side reads go through relaygate, which passes them to the read API; `services.sessionReadApiUrl` stays the read API Service. Its NetworkPolicy (when it lists `ingressFrom`) also admits relaygate for introspection |
| relay-control (discovery) | `SELFHOST_RELAYGATE_PUBLIC_URL` is set from `relay-control.services.relaycastPublicUrl`, the cast host (`https://cast.<domain>`), which gate-only routes to relaygate, so it always equals `RELAYCAST_PUBLIC_URL` (render fails if that isn't `https://<gkeIngress.hosts.cast>`). `/resolve` then returns `urls.relaygateUrl` and withholds the shared Relaycast key, and events-shim temp workspaces are refused. **Needs a relay-control image at cc361ed or later**; older images ignore it and keep handing out the shared key. Unset when gate-only is off |
| relaygate internal Sessions listener | `SESSIONS_PORT` (`global.relaygate.gateOnly.sessionsPort`, default 8081; **needs relaygate #28 or later**) serves Sessions at its root with relay-control's internal mint allowed. A ClusterIP Service `<relaygate>-sessions` exposes it; it is never on an Ingress, HTTPRoute or NEG. A relaygate NetworkPolicy keeps the main port 8080 open and admits only relay-control (`relaygate.sessionsListener.controlFrom`) to the listener. The history host stays on port 8080 with `SESSIONS_HOSTS` |
| relaygate | renders `RELAYCONTROL_INTROSPECT_URL`, `RELAYCONTROL_INTROSPECT_SECRET`, `SESSION_INGEST_AUDIENCE`, `SESSIONS_CORS_ORIGINS` and, when named, `SESSIONS_INTERNAL_SECRET`; `SESSIONS_UPLOAD_URL`, `SESSIONS_READ_URL` and `SESSIONS_HOSTS` (the history host) come from `proxy` as before |

relaygate introspects upload tokens for the public history origin, which
Control already accepts (`relay-control.introspection.audiences`; render fails
if a set list misses it), so Control needs no new audience. relaygate has no NetworkPolicy of its own, so
its egress to Control is open; Control's policy admits it.

Escape hatches, each of which reopens a direct path for that caller only:
`relaycast.networkPolicy.gateOnlyFrom` (callers that must stay direct),
`sessions-pipeline.sessionReadApi.networkPolicy.gateOnlyControlDirect: true`
(keeps Control's direct rule on the reader; NetworkPolicy can't limit it to
`/internal`, so Control can then read `/v1` without the gate), and
`sessions-pipeline.ingestEdge.networkPolicy.gateOnlyFrom` (e.g. Control for the
operator session erase API, which the ingest edge otherwise no longer admits).

### Control-owned policy (opt-in)

By default relaygate reads its policy from a file (the `relaygate.policy` values, rendered to a ConfigMap). With `global.relaygate.controlPolicy` the policy lives in relay-control instead: owners and admins edit it under Settings, Gate, every change is a new signed version, and relaygate pulls it (relaygate `docs/contract.md`, "Who decides, who enforces" and "Admin API for relay-control"; design in relaygate `docs/design/control-owned-policy.md`). It needs gate-only, **relaygate main at R1/R2 or later** (#33, #34) and **a relay-control image with C1** (the Control-owned policy storage and routes). The chart can't check either image.

It is two steps, because relaygate with no policy applied or cached answers `503` everywhere:

1. `enabled: true`. relay-control gets `SELFHOST_RELAYGATE_ADMIN_URL` (relaygate's in-cluster origin, `http://<relaygate>.<ns>.svc.cluster.local:8080`; the admin API is on the main port), `SELFHOST_RELAYGATE_ADMIN_TOKEN` and `SELFHOST_RELAYGATE_POLICY_SECRET`. relaygate's `RELAYGATE_ADMIN_TOKEN` comes from the same `adminToken` Secret. relaygate still reads its ConfigMap: import it into Control once (`POST /api/v1/relaygate/policy/import`, owner only; the key sha256s become key rows with no key material).
2. `pull: true`. relaygate gets `RELAYCONTROL_POLICY_URL` (`http://<relay-control>.<ns>.svc.cluster.local:<port>/internal/v1/relaygate/policy`) and `RELAYCONTROL_POLICY_SECRET`, and the chart stops rendering `RELAYGATE_POLICY`, the policy ConfigMap and its volume. relaygate caches each applied version, so it keeps enforcing through a relay-control restart.

```yaml
global:
  relaygate:
    controlPolicy:
      enabled: true
      pull: false                                       # true after the import
      adminToken: { name: relaygate-admin, key: token }  # >= 24 characters
      policySecret: { name: relaygate-policy, key: secret }  # >= 32 characters, not the introspection secret
      controlServiceName: relay-control                 # the relay-control Service (fullnameOverride); checked
      controlServicePort: 80                            # relay-control.service.port; checked
```

Both Secrets are read by relaygate and relay-control from this one place, so they can't drift. Network paths: relaygate reaches relay-control on its Service port (relay-control's NetworkPolicy admits relaygate under gate-only when it lists `ingressFrom`, and the default admits the namespace), and relay-control reaches the admin API on relaygate's main port, which relaygate's policy leaves open; relaygate's internal Sessions listener stays relay-control-only. Rendering fails without gate-only or components.control, without either Secret, with `pull` but not `enabled`, with a Control Service name or port that doesn't match relay-control's, with the policy secret equal to the introspection secret, with a second `relaygate.secrets.adminToken`, and with `pull` plus `relaygate.existingConfigMap`. Every relay-control URL env, `SELFHOST_RELAYGATE_ADMIN_URL` included, is checked in CI to be a bare origin.

### Existing sessions: adopt them once

Sessions uploaded before relaygate was in front of Sessions have no relaygate
owner, so they are invisible through the gate. At the switch, adopt them with
the admin token (relaygate `sha256:c64d6d9b` or later, `relaygate.secrets.adminToken`),
dry run first. `/admin` is never routed publicly (every edge denies it), so
reach relaygate through a port-forward:

```sh
kubectl -n agent-relay port-forward svc/agent-relay-relaygate 18080:8080 &
ADMIN_TOKEN=$(kubectl -n agent-relay get secret relaygate-admin -o jsonpath='{.data.token}' | base64 -d)
# 1. Dry run: reports what would be adopted, changes nothing.
curl -fsS -X POST 'http://127.0.0.1:18080/admin/v1/sessions/adopt?dryRun=1' \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"readToken": "rth_st_read_...", "orgId": "<org>", "workspaceId": "<ws>"}'
# 2. Check the report (every session maps to the principal you expect), then
#    run the same request without dryRun.
curl -fsS -X POST 'http://127.0.0.1:18080/admin/v1/sessions/adopt' \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"readToken": "rth_st_read_...", "orgId": "<org>", "workspaceId": "<ws>"}'
```

relaygate pages the read API's session list with that read service token and
gives each unowned session to its uploader's Control principal
(`ctl:<userId>`, mapped by `policy.controlPrincipals`). Check the report, then
run it without `dryRun`. See relaygate `docs/gate-only.md`.

### Routes relaygate serves, and what gate-only therefore cuts off

Cast host, to relaygate: `/v1/register`, `/v1/check`, `/v1/whoami`,
`/v1/agent`, `/v1/agent/node-token`, `/v1/node/ws`, `/v1/search`, `/v1/inbox`
(exact) and `/v1/agents`, `/v1/channels`, `/v1/messages`, `/v1/dm`,
`/v1/streams`, `/v1/deliveries` (prefix; relaygate refuses methods and sub-paths it doesn't
proxy with `404 relaygate_route_not_proxied`). Every proxied route needs an
`rg_` token.

History host, to relaygate: `/v1/sessions` (prefix: list, `turns` uploads and
the per-session views), `/v1/delivery` and `/v1/digest` (prefix),
`/v1/relayfacts` and `/v1/coordination` (prefix, only with
`global.relaygate.gateOnly.relayfactsRoutes`), and `/v1/events`, `/v1/ingest`,
`/v1/auth/token/refresh`, `/v1/auth/token/revoke`, `/v1/onboarding/heartbeat`,
`/v1/upload-consent` (exact).

Not proxied, so gate-only breaks them for public clients:

- Relaycast: direct registration `POST /v1/agents` (use `/v1/register`),
  `/v1/agents/spawn`, `/release`, `/presence`; the human/dashboard WebSocket
  `/v1/ws`; group DMs (`/v1/dm/group`, `/v1/dm/conversations/all`); files
  (`/v1/files`, `/v1/files/upload`); webhooks, subscriptions, triggers and
  actions; `/v1/workspace*`, `/v1/nodes`, `/v1/routing/*`, `/v1/directory/*`,
  `/v1/console/*`, `/v1/a2a/*`, `/v1/observer-tokens`, `/v1/skills/*`,
  `/v1/certify*`, `/v1/route*`, `/v1/deliveries`, `/v1/activity`,
  `/v1/agent/recovery-credential`; and anything outside `/v1` (health, MCP).
  Clients holding a workspace key or Relaycast agent token (the CLI, Relay
  Chief, relayflows workers, the desktop app's Relaycast connection) stop
  working until they register through relaygate.
- Sessions: `/v1/turns/batches`, `/v1/cli/login` and the public `/healthz`.
  Aggregate reads (`/v1/delivery/records`, `/v1/digest/*`, `/v1/sessions/users`,
  `/activity`) work only for `policy.sessionAggregates` groups.
- relaycast `runtime.backend: durable-actors`: actors fetch Relaycast's public
  URL from their sandbox, which now reaches relaygate; gate-only is not verified
  with that backend.
