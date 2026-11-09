# relay-control

Supply both `image.repository` and `image.digest` explicitly for the same
verified publication; a chart rename does not republish an old digest.

Public chart names and existing-release compatibility: [Control/Webapp rename](../../docs/control-webapp-chart-rename.md).

Maintained packaging for `packages/selfhost-api` from the Cloud repository.
It provides the minimal self-host control API and does not package the full
Cloud/Next application.

`image.digest` and `existingSecret` are mandatory. The Secret keys are listed
in `values.yaml`; all values are mounted as files. The migration Job projects
only `database-migrations-url`; the API pod cannot read that key. The chart
never creates a Secret or renders credentials. Set `database.runtimeRole` to
the non-secret PostgreSQL role used by `database-url`; after migrations, the
owner grants that role runtime access only to `selfhost_*` application tables.

The image must contain the compiled `relay-control` package. The server runs
`node node_modules/relay-control/dist/server.js`; migrations run
`node node_modules/relay-control/dist/migrate-cli.js`. To pin an older image
built before the rename, set `server.args` and `migrations.args` to its
`node_modules/@cloud/selfhost-api/dist/` paths.

The default image is `ghcr.io/agentworkforce/relay-control` 0.5.0. The session
read handoff and MCP reads (`services.sessionReadApi*`,
`secretKeys.sessionReadApiSecret`) need 0.5.1, which is not published yet; they
stay off by default. `secretKeys.introspectSecret` and
`introspection.audiences` wire token introspection.
`services.relaychiefControlUrl` (`RELAYCHIEF_CONTROL_URL`) forwards the Chief
routes to the optional [relaychief-control](../relaychief-control) add-on and is
off by default. Point it at the internal Service, because that add-on's Ingress
serves only `/chief/v1`. It needs `secretKeys.introspectSecret`, the add-on's
`config.publicOrigin` in `introspection.audiences`, `chief` in `SELFHOST_FEATURES`
and a Control image built with that wiring; the default image ignores it. A
different namespace needs a `networkPolicy.additionalEgress` rule, and a
relaychief-control `networkPolicy.ingressFrom` must admit Control.
`services.relaycastUrl` and `services.relayhistoryUrl` are internal origins;
their `*PublicUrl` counterparts must be public HTTPS origins and are returned
to clients or used as the externally stable RelayHistory assertion audience.

Requires Helm 3.10 or newer (templates use `{{ continue }}`).

## relaycontrol runtime settings

The authoritative contract is the requirements registry
(`self-hosted/requirements.yaml`, rendered to
[docs/self-hosted-requirements.md](../../docs/self-hosted-requirements.md));
this table summarizes it. The chart renders the relaycontrol env contract and refuses at render time
whatever the API would refuse at startup:

| Value | Env | Notes |
| --- | --- | --- |
| `encryption.keyId` (required) | `SELFHOST_ENCRYPTION_KEY_ID` | Non-secret id of `secretKeys.encryptionKey`, 1-64 URL-safe characters. |
| `encryption.previousKeyId` + `secretKeys.previousEncryptionKey` | `SELFHOST_ENCRYPTION_PREVIOUS_KEY_ID`, `SELFHOST_ENCRYPTION_PREVIOUS_KEY_FILE` | Key rotation; both or neither, and the id must differ from `keyId`. |
| `secretKeys.internalToken` | `SELFHOST_INTERNAL_TOKEN_FILE` | Optional service bearer for `/internal/v1` (flows env delivery, telemetry issue reports). Never expose `/internal` publicly: when this or `secretKeys.introspectSecret` is set and `ingress.enabled=true`, this chart routes `/internal` to a selector-less deny Service; the agent-relay GKE ingress denies it at the edge. |
| `global.singleHost.host` | `SELFHOST_PUBLIC_URL` | Single-host mode (normally set on the agent-relay umbrella): `publicUrl` is derived as `https://<host>` and must be empty or equal it, and `ingress.enabled` must be `false` because the dashboard host routes `/cloud/api`, `/login` and `/api` here. |
| `dashboardUrl` | `SELFHOST_DASHBOARD_URL` | Where OAuth callback pages and flow `runUrl`s point. Defaults to `publicUrl` + `/` in the API. |
| `bootstrap.orgName`, `bootstrap.adminEmail` (+ optional `adminName`, `workspaceName`) | `SELFHOST_BOOTSTRAP_ORG_NAME`, `SELFHOST_BOOTSTRAP_ADMIN_EMAIL`, `SELFHOST_BOOTSTRAP_ADMIN_NAME`, `SELFHOST_BOOTSTRAP_WORKSPACE_NAME` | First-boot bootstrap (see "Sign-in, bootstrap and invites" below). `orgName` and `adminEmail` are set together; `adminName` and `workspaceName` are optional overrides. Requires `secretKeys.relaycastInternalSecret` and `dashboardUrl` (outside single-host mode). |
| `secretKeys.relaycastInternalSecret` | `RELAYCAST_INTERNAL_SECRET_FILE` | Relaycast's internal admin secret, which is the same Secret key that `relaycast.secretKeys.internalSecret` names. The bootstrap creates the default workspace's Relaycast workspace with it. |
| `auth.oidc.issuer`, `auth.oidc.clientId`, `secretKeys.oidcClientSecret` (+ `allowedDomains`, `displayName`, `scopes`, `redirectUrl`) | `SELFHOST_OIDC_ISSUER`, `SELFHOST_OIDC_CLIENT_ID`, `SELFHOST_OIDC_CLIENT_SECRET_FILE`, `SELFHOST_OIDC_ALLOWED_DOMAINS`, `SELFHOST_OIDC_DISPLAY_NAME`, `SELFHOST_OIDC_SCOPES`, `SELFHOST_OIDC_REDIRECT_URL` | OpenID Connect sign-in (authorization code with PKCE). The issuer must be https. `auth.oidc.allowHttpIssuer=true` (`SELFHOST_OIDC_ALLOW_HTTP_ISSUER`) also accepts http, and is for tests only. Register `<dashboard origin>/login/oidc/callback` with the IdP. |
| `auth.emailLink.enabled` | `SELFHOST_EMAIL_LOGIN` | Email sign-in links. Requires `smtp.host`. |
| `auth.autoJoinDomains` | `SELFHOST_AUTO_JOIN_DOMAINS` | Verified emails in these domains join as `member` without an invite. |
| `auth.inviteTtlHours` | `SELFHOST_INVITE_TTL_HOURS` | Invite link lifetime, 1-720 hours. The default is 168. |
| `smtp.host`, `smtp.port`, `smtp.security`, `smtp.username`, `smtp.from`, `secretKeys.smtpPassword` | `SELFHOST_SMTP_HOST`, `SELFHOST_SMTP_PORT`, `SELFHOST_SMTP_SECURITY`, `SELFHOST_SMTP_USERNAME`, `SELFHOST_EMAIL_FROM`, `SELFHOST_SMTP_PASSWORD_FILE` | SMTP for invite emails and sign-in links. `from` (and `dashboardUrl` outside single-host mode) is required with `host`. `username` and `secretKeys.smtpPassword` must be set together. |
| `integrations.<provider>.existingSecret` (+ `clientIdKey`, `clientSecretKey`, `scopes`) | `SELFHOST_OAUTH_<PROVIDER>_CLIENT_ID`, `SELFHOST_OAUTH_<PROVIDER>_CLIENT_SECRET_FILE`, `SELFHOST_OAUTH_<PROVIDER>_SCOPES` | The customer's own OAuth app per integration (operator configuration; users connect just in time from the CLI, flow onboarding and flow creation, with no settings page). `<PROVIDER>` is the provider id upper-cased with `-` mapped to `_` (`google-mail` → `GOOGLE_MAIL`). Client ID and secret come from the named Secret (keys default to `client-id` and `client-secret`, and must differ); the secret is mounted as a file. Inline `clientId`/`clientSecret` fields are refused. Render-time rules: provider ids are 1-40 lowercase letters, digits and inner `-` (alphanumeric at both ends); Secret keys use `A-Z a-z 0-9 . _ -`; an integration reading the main `existingSecret` cannot reuse any `secretKeys.*` key (so the migration credential `database-migrations-url` never reaches it). **Register `<publicUrl>/api/v1/integrations/oauth/callback` as the callback URL in each provider app.** A provider without an entry shows users "Your administrator needs to configure the <Provider> app". |
| `flows.storage`, `flows.gcsBucket`, `flows.gcsPrefix` | `SELFHOST_FLOWS_STORAGE`, `SELFHOST_FLOWS_GCS_BUCKET`, `SELFHOST_FLOWS_GCS_PREFIX` | `postgres` (default) or `gcs` (Workload Identity; bucket required). |
| `flows.workerRelaycastUrl` | `SELFHOST_FLOWS_WORKER_RELAYCAST_URL` | Optional Relaycast origin handed to workers. |
| `flows.queuePingMs` | `SELFHOST_FLOWS_QUEUE_PING_MS` | SSE keepalive, 1000-120000 ms; keep it below proxy timeouts. |
| `telemetry.level` | `SELFHOST_TELEMETRY_LEVEL` | `errors` (chart default: scrubbed error metadata and health only, never content), `full` (adds usage counts) or `off` (disabled). The level takes effect once the install is registered; until `telemetry.installId`, `secretKeys.telemetryInstallKey` and (transport `https`) `telemetry.endpoint` are set, the chart renders `off`, so a default install renders and sends nothing. Setting only some of them fails the render. |
| `telemetry.transport` | `SELFHOST_TELEMETRY_TRANSPORT` | Optional; `https` (default) or `file` (reports stay in the outbox for a signed export). |
| `telemetry.installId`, `secretKeys.telemetryInstallKey` | `SELFHOST_TELEMETRY_INSTALL_ID`, `SELFHOST_TELEMETRY_INSTALL_KEY_FILE` | Issued by Agent Relay when the install is registered. Setting either (or the endpoint) registers the install, and then both are required unless the level is `off`. |
| `telemetry.endpoint` | `SELFHOST_TELEMETRY_ENDPOINT` | Required for a registered install when the level is not `off` and the transport is `https`; optional with `file`. Must be an https URL. No default: the hosted ingest URL comes with the registration. |
| `telemetry.egressTo` | (NetworkPolicy) | Destinations of the telemetry egress rule; empty by default. It must not be empty when the level is not `off`, the transport is `https`, `networkPolicy.enabled=true` and `networkPolicy.allowAllEgress=false`, and is unused otherwise. |
| `telemetry.probes` | `SELFHOST_TELEMETRY_PROBES` | Up to 20 extra health probes; `name` is a string of lowercase letters, digits and dashes (quote numeric names). |
| `telemetry.deployment` | `SELFHOST_TELEMETRY_DEPLOYMENT` | Extra flat deployment-shape keys (at most 32): string, number or boolean values only, version-like strings without `//`; the chart-rendered keys (`chart`, `chartVersion`, `appVersion`, `replicas`, `flowsStorage`, `networkPolicy`, `ingress`) cannot be overridden. |
| `extraEnv` | caller-chosen | Non-secret string values or one supported Kubernetes `valueFrom` source appended to API and migration containers. Default `[]`. Chart-managed names, raw FILE aliases and unset OAuth provider names (including consecutive underscores) are reserved. `valueFrom` requires exactly one of `secretKeyRef`, `configMapKeyRef`, `fieldRef`, or `resourceFieldRef`, with its required fields. Literal values are rejected for names ending at an underscore boundary in `SECRET`, `TOKEN`, `PASSWORD`, `CREDENTIAL`, `DSN`, `API_KEY`, `PRIVATE_KEY`, access-key or database-URL names, or `PGPASSWORD`; this heuristic is not a complete credential classifier. Matching credential names require `secretKeyRef` for every source. `resourceFieldRef.containerName` is refused because the API and migration containers share this list. Operators must use Secret references for credentials, never literals or ConfigMaps. References to the main migration credential are refused. |
| `license.existingSecret`, `license.key` | `SELFHOST_LICENSE_FILE` | Optional license Secret (key defaults to `license`), mounted only into the API pod. Must not reuse a `secretKeys.*` key from the main Secret. This mounts a file; signature verification and add-on enforcement remain upstream work. |

Every non-empty `secretKeys.*` value must name a distinct Secret key; the
chart refuses collisions, so the migration credential
(`secretKeys.databaseMigrationsUrl`) is never mounted into the API pod.

The chart adds a TCP 443 egress rule to `telemetry.egressTo` only when all of
these hold: `networkPolicy.enabled=true`, `networkPolicy.allowAllEgress=false`,
the effective level is not `off` (a registered install), and the transport is `https`. With NetworkPolicy
disabled, or with `allowAllEgress=true`, egress is not restricted and no rule
is rendered. The migration Job's NetworkPolicy never gets this rule.

## Sign-in, bootstrap and invites

This needs a selfhost-api image built from relaycontrol #13 or later. With
these values set, an install needs no manual steps after `helm install`:

1. **First boot.** Set `bootstrap.orgName`, `bootstrap.adminEmail`,
   `secretKeys.relaycastInternalSecret` and `dashboardUrl`. On start, the API:
   - creates the organization and makes the admin email its owner;
   - creates a `Default` workspace bound to a new Relaycast workspace (an
     `ar_ws_` key on durable actors), retrying until Relaycast answers.

   The bootstrap is idempotent. An existing organization and workspace are
   kept. A newly configured admin email is made an owner once, and is not
   re-promoted after another owner changes it.
2. **Sign-in.** Configure `auth.oidc` with Google Workspace, Okta, Microsoft
   Entra ID, Keycloak or any OIDC provider. Register
   `<dashboard origin>/login/oidc/callback` as the redirect URI, and store the
   client secret under `secretKeys.oidcClientSecret`. The fallback is
   `auth.emailLink.enabled` with `smtp`, which sends single-use sign-in links.
   The admin signs in at `<dashboard>/login`.
3. **Invites.** Owners and admins invite people by email from Settings →
   Members. Invite links are single use and expire after
   `auth.inviteTtlHours`. They are emailed when `smtp` is set, and can always
   be copied. The invitee signs in with the invited email and joins with the
   invited role. Use `auth.autoJoinDomains` to let a whole domain join as
   members without invites.

Roles: `owner` (everything, including managing owners), `admin` (invites
admins and members, and manages them) and `member`.

The bootstrap token (`secretKeys.bootstrapToken`) remains the operator
break-glass. It approves the **Operator sign-in** code on `/login` for a
member, and can create invites through the API.

With `networkPolicy.allowAllEgress=false`, add `networkPolicy.additionalEgress`
rules for the identity provider (HTTPS) and the SMTP server.

The current runtime is deliberately one replica with `Recreate`: login/device
rate limiting remains process-local. This is a GCP proof shape, not HA.

`networkPolicy.enabled` defaults to true with `allowAllEgress: false`, which
allows egress only to same-namespace pods and DNS. The external PostgreSQL
database (and any service URL outside the namespace) is then unreachable, so
the chart refuses to render until you either list it in
`networkPolicy.additionalEgress` (each rule with a non-empty `to`) or set
`allowAllEgress: true`, as the umbrella GCP profiles do.

The migration is a normal deterministic Job because this repository installs
with `helm template --no-hooks`. An operator or reconciler must wait for it to
complete before considering a rollout successful; the API stays unready while
its database schema is unavailable.

```sh
helm lint --strict charts/relay-control \
  -f charts/relay-control/ci/default-values.yaml
```

### Compatible caller-token images

`services.relayauthEnabled` defaults to true for the published legacy images.
With an owner-approved no-RelayAuth/caller-token image (#20/#27), false omits
`RELAYAUTH_URL`, `RELAYAUTH_API_KEY_FILE` and the legacy key from the API Secret
projection. `secretKeys.relayauthApiKey` may then be empty. This selects existing
application behavior; it implements no verification or introspection logic.
Introspection configuration uses `extraEnv` with Secret refs. The switch does
not disable the RelayAuth component or reroute History automatically, and old
images that require RelayAuth must retain the default. Render-only no-RelayAuth
fixtures are not compatible image releases or runtime acceptance evidence.
