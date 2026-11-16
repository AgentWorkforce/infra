# relaygate (optional governance gate)

[relaygate](https://github.com/AgentWorkforce/relaygate) sits between agents and
Relaycast/Sessions. Agents register into a **group** with an enrollment key;
every request is checked against owner/group/other **mode bits**; writes that
cross a group boundary or leave through an external stream (a Slack thread, a
knowledge base) go through a **classifier** (rules, plus an optional Claude
model). Denials never reach upstream. It is opt-in: `components.relaygate` in
the umbrella, or its own release.

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
  adminToken: { name: relaygate-admin, key: token }                        # optional: POST /admin/v1/explain, GET /admin/v1/audit
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

## Control principals: desktop and dashboard on Sessions

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
`SESSION_READ_API_URL` at `http://<release>-relaygate:8080/sessions`: relaygate
forwards the mint calls unchanged and remembers which user each token belongs
to. Each Control user acts as `ctl:<userId>` (the `ctl:` prefix is reserved) and
their own credential still reaches Sessions. Uploads need `rth:sync`, reads
`rth:read`. See relaygate `docs/contract.md`.

## Gate-only (one switch)

The steps above narrow each policy by hand. In the agent-relay umbrella,
`global.relaygate.gateOnly.enabled` does it from one switch, and helm refuses to
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
| relay-control | `SESSION_READ_API_URL` becomes `http://<relaygate>:8080/sessions`, so Control's mint, refresh and service-token calls and its server-side reads go through relaygate, which passes them to the read API; `services.sessionReadApiUrl` stays the read API Service. Its NetworkPolicy (when it lists `ingressFrom`) also admits relaygate for introspection |
| relay-control (discovery) | `SELFHOST_RELAYGATE_PUBLIC_URL` is set from `relay-control.services.relaycastPublicUrl`, the cast host (`https://cast.<domain>`), which gate-only routes to relaygate, so it always equals `RELAYCAST_PUBLIC_URL` (render fails if that isn't `https://<gkeIngress.hosts.cast>`). `/resolve` then returns `urls.relaygateUrl` and withholds the shared Relaycast key, and events-shim temp workspaces are refused. **Needs a relay-control image at cc361ed or later**; older images ignore it and keep handing out the shared key. Unset when gate-only is off |
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

### Routes relaygate serves, and what gate-only therefore cuts off

Cast host, to relaygate: `/v1/register`, `/v1/check`, `/v1/whoami`,
`/v1/agent`, `/v1/agent/node-token`, `/v1/node/ws`, `/v1/search`, `/v1/inbox`
(exact) and `/v1/agents`, `/v1/channels`, `/v1/messages`, `/v1/dm`,
`/v1/streams` (prefix; relaygate refuses methods and sub-paths it doesn't
proxy with `404 relaygate_route_not_proxied`). Every proxied route needs an
`rg_` token.

History host, to relaygate: `/v1/sessions` (prefix: list, `turns` uploads and
the per-session views), `/v1/events`, `/v1/ingest`, `/v1/delivery/batches`,
`/v1/delivery/limits`, `/v1/auth/token/refresh`, `/v1/onboarding/heartbeat`.

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
- Sessions: `/v1/turns/batches`, `/v1/delivery/records`,
  `/v1/delivery/admission` (async/drain admission), `/v1/cli/login`,
  `/v1/auth/token/revoke`, `/v1/digest/*`, `/v1/sessions/users` and
  `/activity` (aggregates, until relaygate's `sessionAggregates`), and the public
  `/healthz`.
- relaycast `runtime.backend: durable-actors`: actors fetch Relaycast's public
  URL from their sandbox, which now reaches relaygate; gate-only is not verified
  with that backend.
