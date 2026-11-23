# agent-relay

Public chart names and existing-release compatibility: [Control/Webapp rename](https://github.com/AgentWorkforce/infra/blob/main/docs/control-webapp-chart-rename.md).

Umbrella chart for the self-hosted messaging and Sessions proof:

- Relaycast (RelayAuth is optional, only for
  `relaycast.credentials.authority=relayauth`)
- Sessions Pipeline, including native History: the Sessions read API and
  ingest edge on the `history` host
- self-host control-plane API (relay-control, native History backend)
- static dashboard

The standalone RelayHistory component was removed in 0.7.0: setting
`components.relayhistory: true` or a non-empty `relayhistory:` values block
fails the render (see `docs/self-hosted-no-relayauth.md`);
`components.relayhistory: false` is accepted and ignored.

Relayflows is an optional add-on (`components.relayflows`, off by default;
see `docs/self-hosted-relayflows.md`). Relayfile (`components.relayfile`) and
the durable-actors control plane (`components.durableActors`) are optional and
off by default; see `docs/self-hosted-durable-actors.md`. Relay Chief
(`components.relayChief`) is also off by default and configured under the
`relay-chief` key; see `charts/relay-chief/README.md`.

Requires Helm 3.10 or newer: the relay-control subchart uses
`{{ continue }}`, which older Helm versions cannot parse.

## Customer-neutral GCP template

`values-gcp.yaml` is the customer-neutral starting point for a full GKE
deployment. It is derived from the proof configuration but uses only
`example-*` resource names, `placeholder.company` hosts, and customer-owned
Artifact Registry placeholders. It contains Secret names and keys, never
Secret values.

History is native: relay-control's native History backend, with the umbrella
GKE Ingress splitting the history host between the Sessions read API and
ingest edge, and a PostgreSQL `searchIndexer`. RelayAuth is off. Replace the
`REQUIRED OVERRIDE` placeholders under `sessionReadApi`, `ingestEdge` and
`searchIndexer` in a site values file; `ci/gcp-native-values.yaml` is a
render-only example of that shape. `values-gcp-native.yaml` is now an empty
compatibility overlay: commands that still name it render identically.

The customer GCP and EKS profiles are release phase 1 for the ruleset-10
scrubber migration: they set `global.scrubEngine.readerMaxRuleset: "10"` on
every workload using the Sessions services image while leaving the selected
engine unchanged. For an existing install, apply the profile and wait for all
Sessions Deployments and Jobs before a second Helm revision adds
`values-scrub-wasm-bindgen.yaml`. That explicit phase-2 overlay requires the
qualified wasm-bindgen image and renders the full
`SCRUB_ENGINE=wasm-bindgen`, `SCRUB_ENGINE_REQUIRED=wasm-bindgen`,
`READER_MAX_RULESET=10` contract everywhere. A fresh install with an empty
Sessions database may include the phase-2 overlay in its initial install.
Keep the reader ceiling at 10 on rollback while ruleset-10 objects exist.

The template is intentionally renderable: all-zero image digests are sentinel
values, not deployable images. Replace every value marked `REQUIRED OVERRIDE`
before installing. The required value overrides are:

| Values path | Required replacement |
| --- | --- |
| `global.imageRegistry` | Artifact Registry hostname for the selected region, such as `us-central1-docker.pkg.dev`. |
| `global.tenant.orgId` | Stable customer organization ID. Do not change it after data has been written. |
| `gkeIngress.name`, `staticIpName`, `managedCertificateName`, `frontendConfigName` | Customer-selected names. `staticIpName` must name a reserved global external IPv4 address; the chart creates the other resources. |
| `gkeIngress.sslPolicy` | Recommended. Name of a Compute SSL policy with a TLS 1.2 minimum; see [GKE edge hardening](#gke-edge-hardening). |
| `gkeIngress.hosts.{root,api,cast,history}` | Four customer-controlled public DNS names whose A records point at the reserved address. |
| `relaycast.image.{repository,digest}` | Customer-accessible Relaycast image mirror and its real immutable digest. |
| `sessions-pipeline.worker.image.{repository,digest}` and `sessions-pipeline.alleyoop.image.{repository,digest}` | Repository path under `global.imageRegistry` and the same immutable Sessions services digest. |
| `relay-control.image.{repository,digest}` | Customer-accessible control API image mirror and its real immutable digest. |
| `relay-webapp.image.{repository,digest}` | Customer-accessible dashboard image mirror and its real immutable digest. |
| All `existingSecret` values set to `example-agent-relay-secrets` | Name of a pre-created Secret in the release namespace. Update every occurrence if separate Secrets are used. |
| `sessions-pipeline.{worker,alleyoop}.locker.bucket` | Existing customer-owned GCS bucket used for session objects. Both values must match. |
| `sessions-pipeline.{worker,alleyoop}.locker.region` | Region of that bucket. Both values must match. |
| `sessions-pipeline.worker.extraEnv` (shared with `alleyoop.extraEnv` through a YAML anchor) | Cloud SQL connection name, Memorystore host/port/server CA bundle, and Pub/Sub topic and subscription. `locker.provider=gcs` arms the Sessions services' GCS data-path readiness check, which requires them; the chart refuses to render without them. |
| `relaycast.baseUrl` | `https://` plus `gkeIngress.hosts.cast`. |
| `sessions-pipeline.sessionReadApi.origin`, `sessions-pipeline.ingestEdge.origin`, `sessions-pipeline.alleyoop.auth.historyOrigin` | `https://` plus `gkeIngress.hosts.history`. |
| `sessions-pipeline.sessionReadApi.postgresCa.sha256`, `ingestEdge.postgres.caSha256`, `searchIndexer` CA SHA-256 | The same lowercase SHA-256 of the Cloud SQL server CA bundle. |
| `sessions-pipeline.ingestEdge.relaycontrol.url` | The Control Service FQDN in the release namespace. |
| `relay-control.publicUrl` | `https://` plus `gkeIngress.hosts.api`. |
| `relay-control.services.relaycastPublicUrl` | Same origin as `relaycast.baseUrl`. |
| `relay-control.services.sessionReadApiPublicUrl`, `relay-control.introspection.audiences` | Same origin as `sessions-pipeline.sessionReadApi.origin`. |
| `relay-webapp.runtime.publicUrl` | `https://` plus `gkeIngress.hosts.root`. |
| `relay-control.service.backendConfig` | `<gkeIngress.name>-api` (the name truncated to 59 characters first). The umbrella renders that BackendConfig and refuses any other value. |
| `relaycast.service.backendConfig` | `<gkeIngress.name>-cast` (the name truncated to 58 characters first), for the Relaycast WebSocket backend timeout. |

The referenced Secret must provide these keys:

- Relaycast: `relaycast-internal-secret` (at least 32 characters) and
  `relaycast-workspace-bootstrap-secret`
- Sessions: `HOOPDB_URL`, `HOOPDB_MIGRATION_URL`, and
  `SUMMARY_MASTER_KEYS`
- control API: `database-url`, `database-migrations-url`,
  `selfhost-bootstrap-token`, `selfhost-encryption-key`,
  `relaycontrol-introspect-secret`, and `session-read-api-secret` (also the
  read API's self-issued internal secret)
- RelayAuth (only with `components.relayauth=true`): `relayauth-internal-secret`,
  `relayauth-signing-key.pem`, `relayauth-bootstrap-api-key`, and the control
  API's `relayauth-api-key`
- RelayAuth-issued relaycast credentials (optional, model B):
  `relaycast-credential-keyring` and `relaycast-relayauth-token`

- Sign-in (optional; see "First boot and sign-in" below): `oidc-client-secret`
  for OIDC, `microsoft-client-secret` for Microsoft sign-in,
  `smtp-password` for SMTP with a username, and an operator-generated
  `selfhost-setup-key` (`openssl rand -hex 32`) for the one-time first-admin
  setup key. The bootstrap reads the existing `relaycast-internal-secret` key.

The read API, ingest edge and search indexer read their database settings from
their own Secrets (`agent-relay-read-api`, `agent-relay-ingest-edge-runtime`,
`search-indexer-runtime`, `search-indexer-owner` in `values-gcp.yaml`).
On fresh Cloud SQL, RDS and Azure installs, both migration/bootstrap keys use
the dedicated `hoopdb_owner` URL, never a provider administrator URL. Legacy
administrator-owned installs copy the URL into `hoopdb-admin-jobs` while the
relevant Jobs run. Upgrade flows retain the old keys until Helm, Jobs and
Deployments succeed for rollback safety, then remove the old keys and delete
the temporary Secret.

> **RDS upgrade note:** the shared `external-rds.yaml` and
> `aws-rds-native.yaml` profiles default to `rdsLayout: separate-database` for
> fresh `hoopdb_owner` installs. Before upgrading an administrator-owned RDS
> install with either profile, run the setup classifier and pass its layout
> overlay, which selects `rdsLayout: master-owner`. Without that override the
> migrator intentionally refuses the legacy layout before changing anything.

With RelayAuth on, `relayauth-api-key` and `relayauth-bootstrap-api-key` must
contain the same value. `selfhost-bootstrap-token` must be at least 32 bytes.
`selfhost-encryption-key` must encode exactly 32 bytes as either 64 hexadecimal
characters or base64.

### First boot and sign-in

Without extra steps, a fresh install has no organization. It also has no way
to sign in except the operator break-glass, where the bootstrap token approves
a device code. Set the commented `relay-control` block in `values-gcp.yaml`
to get a working team straight from `helm install`. This needs a selfhost-api
image from relaycontrol #13 or later.

- `relay-control.bootstrap.{orgName,adminEmail}`,
  `relay-control.secretKeys.relaycastInternalSecret: relaycast-internal-secret`
  and `relay-control.dashboardUrl: https://<root host>/`. On its first start
  the API:
  - creates the organization and makes the admin its owner;
  - creates a `Default` workspace bound to a new Relaycast workspace.

  This is idempotent and safe on an existing install.
- `relay-control.auth.oidc.{issuer,clientId,allowedDomains}` plus
  `secretKeys.oidcClientSecret`. Register
  `https://<root host>/login/oidc/callback` with the identity provider:
  - Google Workspace: an Internal Web-application OAuth client, issuer
    `https://accounts.google.com`;
  - Okta: `https://<org>.okta.com/oauth2/default`;
  - Entra ID: `https://login.microsoftonline.com/<tenant>/v2.0`.
- `relay-control.auth.microsoft.clientId` plus
  `secretKeys.microsoftClientSecret`: "Continue with Microsoft" for
  Outlook.com, Hotmail, Live and Entra ID accounts, beside OIDC. Register
  `https://<root host>/login/microsoft/callback` on the app registration;
  tenant accounts need the `xms_edov` optional claim.
- Optional `relay-control.smtp.*`: invite emails, and email sign-in links
  with `auth.emailLink.enabled`.
- Optional `global.branding.logo.svg` (or `existingConfigMap` + `key`, PNG
  only): the customer logo on the sign-in page. relay-webapp serves it at
  `https://<root host>/brand/<file>` and relay-control points
  `SELFHOST_LOGIN_LOGO_URL` at it (`relay-control.login.logoUrl` overrides;
  `relay-control.login.orgName` sets the name beside it, default
  `bootstrap.orgName`). See the relay-webapp README "Hosted logo".
- `relay-control.auth.password.enabled: true`: email and password sign-in,
  no SMTP required. Add `relay-control.secretKeys.setupKey: selfhost-setup-key`
  so the bootstrap admin can sign in once with the setup key (24 hours, single
  use) and set a password, then hand out temporary passwords to members.
  `relay-control.auth.trustedProxies` (default `1` with password sign-in)
  must equal the number of `X-Forwarded-For` entries the proxies in front of
  the API append: `2` behind the GKE Ingress, whose load balancer appends two. Both need a
  relay-control image from source `bd1c9a03` or later. See the
  [relay-control chart](https://github.com/AgentWorkforce/infra/blob/main/charts/relay-control/README.md#first-admin-without-smtp-or-sso-the-setup-key).

The admin signs in at `https://<root host>/login`. Owners and admins then
invite teammates from Settings → Members. Invite links are single use and
expiring. They are emailed when SMTP is set, and can always be copied.

With `relaycast.credentials.authority=relayauth` (model B, see the commented
`credentials` block in `values-gcp.yaml`), RelayAuth owns the `ar_` credential
tag keyring and pushes `ar_ws_` workspace keys into Relaycast, which verifies
tags through RelayAuth's remote CredentialTagger. The shared Secret then needs
`relaycast-credential-keyring` (mounted by relayauth) and
`relaycast-relayauth-token` (mounted by relaycast); relayauth also mounts
`relaycast-internal-secret` to call Relaycast's internal admin API. It
requires `components.relayauth=true` and a >=12.3.x relaycast engine image.

When `components.relayflows=true` with `mode=cloudWorker`, the Secret named by
`relayflows.credentials.existingSecret` must contain the worker enrollment
token under `relayflows.credentials.existingSecretKey` (default
`AGENT_RELAY_WORKER_ENROLLMENT_TOKEN`). Alternatively
`relayflows.credentials.enrollmentToken` renders a chart-managed Secret — the
only case in which this chart renders Secret material. Standalone mode needs
no enrollment Secret; model and provider credentials reach the flow through
`relayflows.extraEnv`/`extraEnvFrom`.

The template assumes external Cloud SQL and GCS rather than in-cluster
Postgres and MinIO. Provision separate Sessions and control API databases;
install the Sessions database extensions and migrations required by the
Sessions Pipeline; and make each runtime URL use the least-privilege role named
in the values (`sessions_pipeline_runtime` or `control_api_runtime`). Migration
URLs must use the corresponding migration-owner roles.

Sessions objects use the services' native GCS adapter
(`locker.provider=gcs`, `LOCKER_PROVIDER=gcs`) with an empty endpoint, which
means the official `https://storage.googleapis.com` API. The services refuse
HMAC keys on GCS and refuse the S3 client against a GCS endpoint, so there is
no S3-interoperability mode. Grant the rendered Sessions worker and Alleyoop
Kubernetes service accounts GCS access through GKE Workload Identity, and grant GKE nodes or configured
image pull identities read access to every Artifact Registry repository. No
cloud credential belongs in this values file.

The umbrella Ingress is a global external GKE Application Load Balancer with
standalone NEGs. Each public backend NetworkPolicy admits its application port
from same-namespace pods and from the Google Front End proxy/health-check
ranges `35.191.0.0/16` and `130.211.0.0/22`. No other external source range is
allowed. The chart fails rendering when `gkeIngress.enabled=true` and any
public backend disables its policy or omits one of these three sources.

These Kubernetes policies do not replace the corresponding VPC firewall rule.
GKE normally creates that rule for an Ingress; Shared VPC deployments where
the service-project GKE identity cannot manage host-project firewall rules
must have an administrator allow the same two Google ranges to the NEG
backends on their serving ports. See the
[GKE Ingress firewall guidance](https://cloud.google.com/kubernetes-engine/docs/how-to/load-balance-ingress#shared_vpc).

Render the template before supplying any credentials:

```sh
helm lint . -f values-gcp.yaml
helm template agent-relay . -n agent-relay -f values-gcp.yaml >/dev/null

helm lint . -f values-gcp.yaml -f <site-values.yaml>
helm template agent-relay . -n agent-relay -f values-gcp.yaml \
  -f <site-values.yaml> >/dev/null

# Fresh empty database only: start every reader and writer on the qualified
# wasm-bindgen contract in the same install.
helm template agent-relay . -n agent-relay -f values-gcp.yaml \
  -f <site-values.yaml> -f values-scrub-wasm-bindgen.yaml >/dev/null
```

`values-gcp-proof.yaml` is the portable customer proof shape, with native
History. `values-gcp-proof-live.yaml` is a legacy-name overlay on top of it
(the `relay-cloud-api`/`relay-dashboard` object names and proof-registry
images of the original GCP proof release, which is being retired) and the base
of the durable-actors, Relayfile and flows proof overlays.

One umbrella GKE Ingress reserves a global static address
(`gkeIngress.staticIpName`), uses one Google ManagedCertificate for all
four hosts, and enables HTTP-to-HTTPS redirect through a FrontendConfig.
The dashboard host routes `/mcp`, `/cloud/mcp`,
`/.well-known/oauth-protected-resource`,
`/.well-known/oauth-authorization-server`, `/.well-known/openid-configuration`,
`/cloud/.well-known` and `/cloud/oauth` to Control before the `/` dashboard
catch-all. These cover MCP, OAuth discovery, JWKS and browser consent for the
pinned Control 0.5.24 image (source `edad6432`). Token, registration and
revocation already use `/cloud/api`. Only the named root discovery prefixes
are claimed; `/.well-known/acme-challenge` remains available for ACME.
The leaf and GKE Ingress share `relay-webapp.controlPaths`; app-prefixed paths
are derived from the parent of `runtime.apiBasePath` (default `/cloud`).
With `/api` at the root, only named root discovery prefixes are routed;
the broad `/.well-known` route is omitted.

The GKE dashboard rule has 11 Prefix paths in split-host mode and 12 in
single-host mode. All Control paths reuse the `api` backend and its
BackendConfig timeout (`gkeIngress.backends.api.timeoutSec`, default 3600).

For a base domain `relay.example.com`:

- `relay.example.com`: `/cloud/api`, `/login` and `/relay-node` to the
  control API, plus the MCP and OAuth prefixes above, then `/` to the dashboard.
  `/relay-node/v1/*` (Desktop node
  enrolment and the `GET /relay-node/v1/ws` node WebSocket) is served only at
  the root path, never under `/cloud`, and Desktop calls it on this sign-in
  origin.
- `api.relay.example.com`: the same control-plane API Service
- `cast.relay.example.com`: Relaycast
- `history.relay.example.com`: native History (ingest edge for upload
  paths, Sessions read API for read paths)

Leaf ingresses are disabled and each ClusterIP backend uses a GKE standalone
NEG. Sensitive Relaycast paths still route to an endpoint-less deny Service.

## GKE edge hardening

Three optional `gkeIngress` values, each empty by default. Each names
something the chart cannot create, which must exist before the upgrade;
[`terraform/modules/gcp/edge-security`](https://github.com/AgentWorkforce/infra/blob/main/terraform/modules/gcp/edge-security)
creates the two policies. The operator steps and checks are in
[`docs/gcp-install/3-EDGE-HARDENING.md`](https://github.com/AgentWorkforce/infra/blob/main/docs/gcp-install/3-EDGE-HARDENING.md).

| Value | Effect |
| --- | --- |
| `gkeIngress.sslPolicy` | Compute SSL policy for the HTTPS listener (`FrontendConfig.spec.sslPolicy`). Without it Google's default policy applies, which still accepts TLS 1.0 and 1.1. Use a policy with `min_tls_version = TLS_1_2`. |
| `gkeIngress.securityPolicy` | Cloud Armor backend security policy, set as `spec.securityPolicy.name` on the BackendConfig of **every** backend behind the Ingress. |
| `gkeIngress.tlsSecretName` | A `kubernetes.io/tls` Secret served instead of the ManagedCertificate (which is then not rendered). For an edge whose DNS points at a proxy or CDN, where Google cannot issue a managed certificate. The certificate must cover every host. |

The chart leaves `sslPolicy` empty by default because a name that does not
exist in the project stops the Ingress from syncing. `terraform/examples/gcp`
creates the policy and exports it in `chart_values`, so an install made from
the GKE guide has it set.

With `securityPolicy`, the api, cast, history, actors and relaygate
BackendConfigs gain the policy, and the chart renders policy-only BackendConfigs
for the backends that had none: `<gkeIngress.name>-dashboard`,
`<gkeIngress.name>-edge-deny` and, with `gkeIngress.hosts.files`,
`<gkeIngress.name>-files`. The dashboard and Relayfile Services belong to child
charts, so bind them in values (the render fails with the exact value
otherwise):

```yaml
gkeIngress:
  sslPolicy: agent-relay-tls
  securityPolicy: agent-relay-edge
relay-webapp:
  service:
    annotations:
      cloud.google.com/neg: '{"ingress": true}'
      cloud.google.com/backend-config: '{"default": "agent-relay-dashboard"}'
```

Behind a proxy that fronts the load balancer (Cloudflare), also raise
`relay-control.auth.trustedProxies` by one (the Google load balancer alone
needs 2; the guide shows how to check).

## Internal-only GKE edge

For an install that must not be reachable from the internet, set
`gkeIngress.mode: internal` (start from `values-gcp-internal.yaml`). GKE then
creates a regional **internal** Application Load Balancer: a private address,
HTTPS only, reachable from the VPC and from the networks routed to it (VPN,
Interconnect). It is the GKE counterpart of an internal-scheme ALB on EKS.
Hosts, routes, backends and timeouts are the same as on the external edge.

| | External (default) | Internal |
| --- | --- | --- |
| Ingress class | `gce` | `gce-internal` |
| `gkeIngress.staticIpName` | a global external address | a **regional internal** address |
| Certificate | ManagedCertificate, or `tlsSecretName` | `tlsSecretName`, or `internal.preSharedCerts` (regional self-managed certificates). A Google-managed certificate is not possible |
| HTTP | redirected to HTTPS | closed (`allow-http: "false"`) |
| `sslPolicy`, `securityPolicy` | optional | refused: GKE Ingress supports neither FrontendConfig nor Cloud Armor on an internal load balancer |
| Sources the pods see | Google front ends | the VPC's **proxy-only subnet** |

Before the install, the VPC needs a proxy-only subnet in the cluster's region,
a reserved regional internal address, and a firewall rule from that subnet to
the nodes;
[`terraform/modules/gcp/internal-edge`](https://github.com/AgentWorkforce/infra/blob/main/terraform/modules/gcp/internal-edge)
creates the three. Then:

- `gkeIngress.internal.proxyOnlySubnetCidr` is the subnet's range, and every
  backend's `networkPolicy` must allow it next to the two health-check ranges.
  The render fails, naming the backend, when one does not.
  `values-gcp-internal.yaml` restates all five lists.
- DNS: A records for every host, pointing at the private address, in a zone
  your VPN clients resolve (a private zone, or your corporate DNS). The public
  URLs in the values stay `https://<host>`.
- Certificate: with `tlsSecretName`, cert-manager with a DNS-01 challenge
  issues and renews a publicly trusted certificate without the hosts being
  reachable from the internet. If the DNS zone is in another Google Cloud
  project, grant cert-manager's Workload Identity `roles/dns.admin` on that
  zone's project. A private CA works if every desktop, CLI and agent trusts it.
- Agents and desktops outside the VPN cannot upload sessions or connect. Plan
  for that before choosing this mode.
- Pass the overlay on every `helm upgrade`, or merge it into your site values.
  An upgrade without it renders the external edge again.

Rendered and tested in CI; not yet proven on a live cluster.

## Customer-neutral EKS with RDS native History

`values-eks-rds-native.yaml` is the reusable EKS overlay for the supported
native History stack: Amazon RDS, S3 through EKS Pod Identity, OpenSearch, the
session read API, ingest edge and search indexer. It replaces the former leaf
`sessions-pipeline/profiles/aws-rds-native.yaml` file. Apply it after the base
EKS values (already native) and before a private site overlay:

```sh
helm template agent-relay charts/agent-relay \
  --namespace agent-relay-<environment> \
  -f charts/agent-relay/values-eks.yaml \
  -f charts/agent-relay/values-eks-rds-native.yaml \
  -f <private-site-values.yaml> >/dev/null
```

The private overlay must replace every copy marked `REQUIRED OVERRIDE`: the
organization ID, public origins, S3 bucket and region, RDS CA SHA-256,
OpenSearch endpoint/backend ID/region, ALB subnet CIDRs, first owner details,
and the ingest edge's namespace-qualified Control Service URL. The duplicated
service values are deliberate chart boundaries, not fallback defaults: keep
the bucket/region identical under `worker`, `alleyoop`, `sessionReadApi.extraEnv`,
`ingestEdge` and `searchIndexer`; keep the CA SHA-256 identical on all five
clients; and keep the read API and indexer OpenSearch projection settings
identical. `ci/agent-relay/eks-rds-native-site-values.yaml` is a complete
non-secret example, and its render test asserts those equalities. The private
overlay may mirror the four immutable release images into the customer's ECR,
but it must retain their digests. This profile renders no Secret; create the
named Secrets and the immutable `rds-ca` ConfigMap separately.

The chart leaves EKS ingress objects external. Publish dashboard, Control,
Relaycast, native reads and native ingest through the supplied ALB generator
(ingest routes are on by default):

```sh
export EKS_ALB_DOMAIN=relay.example.com
export EKS_ALB_CERT_ARN=arn:aws:acm:<region>:<account>:certificate/<id>
scripts/selfhost/eks-alb-ingress.sh agent-relay-<environment> | kubectl apply -f -
```

This routes the exact native upload paths to `agent-relay-ingest-edge`, the
read paths to `agent-relay-read-api`, and refuses all other History-host paths
at the ALB. Set the script's Service overrides only when the private overlay
renames those Services.

### EKS ALB Ingress

The script stays the documented way to publish the EKS edge. The alternative is
to render the same Ingress from this release, so an install's edge is applied
and versioned with it: set `eksIngress.enabled=true` (default false). For the
same options the chart's Ingress equals the script's output (annotations and
spec, rule order and `pathType` included; the chart only adds
`app.kubernetes.io/name` and `app.kubernetes.io/instance` labels), which
`ci/agent-relay/test_eks_alb_ingress.py` proves by running both. The Ingress
goes into the release namespace. `eksIngress` and `gkeIngress` are exclusive.

```yaml
eksIngress:
  enabled: true
  domain: relay.example.com
  certificateArn: arn:aws:acm:us-east-1:111111111111:certificate/00000000-0000-0000-0000-000000000000
```

| Option | Script variable | Default |
| --- | --- | --- |
| `eksIngress.name` | `EKS_ALB_INGRESS_NAME` | `agent-relay` |
| `eksIngress.className` | `EKS_INGRESS_CLASS` | `alb` |
| `eksIngress.domain` | `EKS_ALB_DOMAIN` | required |
| `eksIngress.certificateArn` | `EKS_ALB_CERT_ARN` | required |
| `eksIngress.aliasDomains` | `EKS_ALB_ALIAS_DOMAINS` (comma-separated) | `[]` |
| `eksIngress.additionalCertificateArns` | `EKS_ALB_EXTRA_CERT_ARNS` (comma-separated) | `[]` |
| `eksIngress.history.enabled` | `EKS_ALB_HISTORY` | `true` |
| `eksIngress.history.readOnly` | `EKS_ALB_HISTORY_READ_ONLY` | `false` |
| `eksIngress.ingest.enabled` | `EKS_ALB_INGEST` | `null`: on when the history host is on and not read-only |
| `eksIngress.ingest.serviceName`, `servicePort` | `EKS_ALB_INGEST_SERVICE`, `_PORT` | `agent-relay-ingest-edge`, `80` |
| `eksIngress.readApi.serviceName`, `servicePort` | `EKS_ALB_READ_API_SERVICE`, `_PORT` | `agent-relay-read-api`, `80` |
| `eksIngress.flows.enabled`, `serviceName`, `servicePort` | `EKS_ALB_RELAYFILE_CONTROL`, `_SERVICE`, `_PORT` | `false`, `relayfile-control`, `3100` |
| `eksIngress.chief.serviceName`, `servicePort` | `EKS_ALB_CHIEF_SERVICE`, `_PORT` | empty (off), `3200` |
| `eksIngress.control.serviceName` | `EKS_ALB_CONTROL_SERVICE` | `relay-control` |
| `eksIngress.webapp.serviceName` | `EKS_ALB_WEBAPP_SERVICE` | `relay-webapp` |
| `eksIngress.controlPaths` | none | `[/cloud/api, /login, /relay-node, /mcp, /cloud/mcp, /.well-known/oauth-protected-resource, /.well-known/oauth-authorization-server, /.well-known/openid-configuration, /cloud/.well-known, /cloud/oauth]` |

The render refuses what the script refuses: no domain or certificate; read-only
without the history host or with ingest on; ingest off on a history host that is
not read-only; ingest on without the history host; Service names that are not
DNS labels and ports outside 1-65535 (each checked only when its route is
rendered). It also refuses non-boolean switches, a domain that is not a DNS
name, a certificate that is not an ARN, and malformed `controlPaths`.

`aliasDomains` serves more base domains on the same load balancer, after
`domain`, each with the same hosts and routes (`<alias>`, `api.`, `cast.` and,
with history on, `history.`). Use it to bring up a new public name next to the
old one during a cutover, then make it `domain` and drop the old one.
`additionalCertificateArns` adds ACM certificates to the HTTPS listener
(`certificateArn` stays the default certificate); together they must cover
every name. Both default to empty, which renders exactly what earlier versions
did. A repeated domain or certificate is refused.

`controlPaths` is the list of dashboard-host (`<domain>`) paths sent to the
control API ahead of the dashboard catch-all, in order (Prefix paths; with Chief
on, each becomes Exact plus `<path>/*` after the Chief wildcards). The script has
no such option; the default is the list it emits, including the MCP and OAuth
discovery/consent prefixes. Only the named root discovery prefixes are routed;
`/.well-known/acme-challenge` stays available. Pin the list your live ALB has
so that a chart upgrade which changes the default does not change your
listener rules unannounced.

Backends are named, never looked up and never required to be part of this
release: Flows (relayfile-control) and Chief are separate releases, and a
read-only history host may name a read API Service this release does not
install. A wrong name renders and the ALB answers 503 for that route.

#### Adopting an Ingress that was applied with the script

Helm will not take over an existing object that lacks its ownership metadata;
the upgrade fails with `invalid ownership metadata`. To move an install from the
script to `eksIngress` without a new load balancer:

1. Set the `eksIngress` options to the values the script ran with (same
   `name`, class, domain, certificate, Service overrides; pin `controlPaths` to
   the live list).
2. Render and diff against the live object:
   `helm template <release> charts/agent-relay -n <namespace> -f <values> --show-only templates/eks-alb-ingress.yaml > eks-ingress.yaml`,
   then `kubectl diff -f eks-ingress.yaml`. Only the two chart labels may
   differ.
3. Add the three ownership fields to the live Ingress:

   ```sh
   kubectl -n <namespace> annotate ingress <name> \
     meta.helm.sh/release-name=<release> meta.helm.sh/release-namespace=<namespace>
   kubectl -n <namespace> label ingress <name> app.kubernetes.io/managed-by=Helm
   ```

4. `helm upgrade` with `eksIngress.enabled=true`.

The same Ingress name and no `alb.ingress.kubernetes.io/group.name` mean the
controller reconciles the same object onto the same load balancer, so its DNS
name and the records pointing at it stay. Stop running the script for that
install afterwards: a later `kubectl apply` of its output would fight Helm.

Install into `agent-relay-<environment>` (or another namespace explicitly
bound in Terraform). EKS Pod Identity associations must name that namespace
and these exact Service Accounts:

- `agent-relay-worker`
- `agent-relay-session-ingest-api`
- `agent-relay-session-read`
- `agent-relay-search-indexer`

Relaycast uses PostgreSQL and a PVC; an empty
`relaycast.persistence.storageClass` means the cluster's default encrypted EBS
StorageClass. Set it explicitly when the cluster has no suitable default.

Run `scripts/selfhost/rds-setup.sh pre` before Helm and `post` only after the
Sessions migration Job succeeds. On a populated database, build the two
coordination-reader partial indexes concurrently before the migration; a fresh
database builds them directly. The exact SQL and verification steps are in
[`docs/self-hosted-session-read-api.md`](https://github.com/AgentWorkforce/infra/blob/main/docs/self-hosted-session-read-api.md).
After each workspace has sessions, run the output-facts bootstrap with a new
`searchIndexer.outputFacts.bootstrap.runId`; the reusable overlay deliberately
leaves that one-shot Job off.

The profile enables Output, digest and their facts writer without a narrative
model, so session content is not sent to an external model. It enables the
coordination-overlaps API but leaves the dashboard view off. It also enables
structured password sign-in with the one-time setup-key Secret entry supported
by the pinned Control image. The session-agent-name dashboard filter also stays
off: its read path remains unavailable until an operator separately plans and
applies the native agent-catalog activation against the database.

For existing data, this is reader-first: the base EKS values set
`READER_MAX_RULESET=10` but leave `SCRUB_ENGINE` and
`SCRUB_ENGINE_REQUIRED` unset. Wait for every Sessions Deployment and Job to
be Ready, then apply `values-scrub-wasm-bindgen.yaml` in a second Helm revision.
A fresh install with an empty Sessions database may include that strict overlay
in its first revision.

### Secrets from AWS SSM Parameter Store (or another external store)

By default the chart renders no Secret and you create the named Secrets
yourself. If they live in AWS SSM Parameter Store, AWS Secrets Manager or any
other [External Secrets Operator](https://external-secrets.io) provider, set
`externalSecrets` instead. The chart then renders one ExternalSecret per
Secret. ESO creates each Kubernetes Secret under the name the components already
read, so nothing else in your values changes.

Prerequisites: ESO (with the `external-secrets.io/v1` CRDs) installed in the
cluster, and IAM for its controller (Pod Identity or IRSA) that can read the
parameters: `ssm:GetParameter`, `ssm:GetParameters` and
`ssm:GetParametersByPath` on the parameter paths, plus `kms:Decrypt` on the key
for SecureString parameters.

```yaml
externalSecrets:
  enabled: true
  store:
    create: true      # or leave false and set secretStoreRef.name to an existing (Cluster)SecretStore
    provider: { aws: { service: ParameterStore, region: us-east-1 } }
  secrets:
    agent-relay-secrets:
      data:
        database-url: /agent-relay/relaycontrol/runtime-url
        database-migrations-url: /agent-relay/relaycontrol/owner-url
        HOOPDB_URL: /agent-relay/hoopdb/runtime-url
        # ...one line per key of the Secret
    agent-relay-ingest-edge-runtime:
      data:
        database-url: /agent-relay/hoopdb/ingest-url
        introspect-secret: /agent-relay/relaycontrol-introspect-secret
```

Map every Secret and key your install's Secrets table lists. A value that a
component reads as JSON (`RELAYHISTORY_READ_API_SECRET`,
`RELAYHISTORY_PIPELINE_CONSUMER_SECRET`) is stored as that JSON in the
parameter, or built with an entry's `template`. Each `data` value is a
parameter name, or a full ESO `remoteRef` map (`key`, `property`, `version`,
...). An entry can also use ESO's `dataFrom` to load every parameter under a
path (`find: {path: /agent-relay/x/, name: {regexp: ".*"}}`; the SSM provider
needs the `name` or `tags` matcher).

#### Google Secret Manager on GKE

The same block works with the `gcpsm` provider. ESO authenticates as a
Kubernetes ServiceAccount through GKE Workload Identity, so there is no
service account key:

```yaml
externalSecrets:
  enabled: true
  store:
    create: true
    provider:
      gcpsm:
        projectID: my-project
        auth:
          workloadIdentity:
            clusterProjectID: my-project
            clusterLocation: us-central1
            clusterName: my-cluster
            serviceAccountRef:
              name: agent-relay-external-secrets   # a ServiceAccount in the release namespace
  secrets:
    agent-relay-secrets:
      data:
        database-url: agent-relay--agent-relay-secrets--database-url   # the Secret Manager secret's name
        HOOPDB_URL: { key: agent-relay--agent-relay-secrets--HOOPDB_URL, version: latest }
        # ...one line per key of the Secret
```

Grant that ServiceAccount's Workload Identity principal
(`principal://iam.googleapis.com/projects/<number>/locations/global/workloadIdentityPools/<project>.svc.id.goog/subject/ns/<namespace>/sa/agent-relay-external-secrets`)
`roles/secretmanager.secretAccessor` on each secret. A `data` value is the
secret's name, or a `remoteRef` map (`key`, `version`, and `property` for one
field of a JSON secret). Secret Manager names cannot contain `/`. With
regional secrets or CMEK, add `location: <region>` under `gcpsm`.
[`docs/gcp-install/external-secrets-values.yaml`](https://github.com/AgentWorkforce/infra/blob/main/docs/gcp-install/external-secrets-values.yaml)
maps all five install Secrets, and step 10 d of the GKE guide has the
commands. The render is tested against the ESO schemas; it has not yet been
proven on a live GKE cluster.

Notes:

- Keep `externalSecrets` in a values file that every `helm upgrade` of the
  release uses. Helm does not carry values over from the previous command, so
  an upgrade without the block removes the ExternalSecrets, and ESO then
  deletes the Secrets it owns (`creationPolicy: Owner`).
- Pods that start before ESO writes their Secret wait in
  `CreateContainerConfigError` and start once it exists. Check
  `kubectl get externalsecret -n <namespace>` reports every entry `Ready`.
- `creationPolicy: Owner` (the default) means the release owns each Secret and
  `helm uninstall` deletes it. For Secrets created by hand before switching,
  set `creationPolicy: Merge` on those entries or delete the Secrets first.
- A rotated parameter updates the Secret within `refreshInterval`; running pods
  see it only after a restart (`kubectl rollout restart`). Fresh installs store
  the dedicated `hoopdb_owner` URL, never the RDS administrator URL. There is
  no supported `hoopdb_owner` rotation helper yet; do not change its password
  until [#480](https://github.com/AgentWorkforce/infra/issues/480) provides the
  coordinated database, saved-state and Secret update. That flow must update
  both owner URL parameters (`HOOPDB_MIGRATION_URL` and
  `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`), force both resources to sync
  (`kubectl annotate externalsecret agent-relay-secrets search-indexer-owner -n <namespace> force-sync=$(date +%s) --overwrite`),
  confirm each ExternalSecret's `status.refreshTime` is later than the update
  (`kubectl get externalsecret agent-relay-secrets search-indexer-owner -n <namespace>
  -o custom-columns='NAME:.metadata.name,REFRESHED:.status.refreshTime,READY:.status.conditions[0].status'`;
  `Ready=True` alone does not prove it), and only then run `helm upgrade`.
- Existing administrator-owned installs use `hoopdb-admin-jobs` temporarily.
  When removing their old long-lived keys, never patch an ESO-owned Secret.
  Remove each key's mapping from the Helm values used for every upgrade and
  from the live ExternalSecret, delete its backing-store value, wait for
  reconciliation, and then delete `hoopdb-admin-jobs`.
- The `rds-ca` ConfigMap is not a Secret; create it as before.

## Single-host mode

The per-service hosts above are the default. Single-host mode is opt-in: set
`global.singleHost.host` and the dashboard and the self-host control API share
that one host. `values-single-host-example.yaml` is an overlay for
`values-gcp.yaml`:

```sh
helm template agent-relay . -n agent-relay -f values-gcp.yaml -f values-single-host-example.yaml
```

For `global.singleHost.host: relay.example.com`:

- `relay.example.com`: `/cloud/api`, `/login`, `/relay-node` and `/api` to
  the control API, along with the MCP and OAuth prefixes listed above, then
  `/` to the dashboard. `/api` carries the flows worker endpoints and the
  integrations OAuth callback, which relaycontrol hands out as
  `<publicUrl>/api/v1/...`; it is not routed in the default mode, where the
  api host serves them.
- There is no api host. Point Desktop's custom origin and `agent-relay login`
  at `https://relay.example.com`; Desktop derives `/cloud/api` from it.
- `cast.relay.example.com` and `history.relay.example.com` (and
  `gkeIngress.hosts.files`/`actors` when set) stay separate hosts, see below.
  The ManagedCertificate covers the single host plus those hosts.

Set the host once. `relay-control.publicUrl` and
`relay-webapp.runtime.publicUrl` are derived as `https://<host>`, and
`relay-webapp.ingress.host` as the bare `<host>`; the chart fails if any of
them is set to something else. `gkeIngress.hosts.root`
must be empty (or equal the host) and `gkeIngress.hosts.api` must be empty.
`relay-control.dashboardUrl` can stay empty: its default, `publicUrl + "/"`,
is the dashboard in this mode. Without the GKE Ingress, enable the
`relay-webapp` leaf Ingress: it routes the same five paths on the derived
host. `relay-control.ingress.enabled` must stay `false`.

The api BackendConfig (flows worker queue SSE and relay-node WebSocket
timeout, `gkeIngress.backends.api.timeoutSec`, default 3600) still binds the
relay-control Service, so it covers `/cloud/api`, `/relay-node` and `/api` on
the single host; the cast BackendConfig (WebSocket timeout) and the edge-deny routes on the
cast host are unchanged. With `global.singleHost.host` empty, every default
render is byte-identical to the previous release apart from the
`helm.sh/chart` labels; `ci/agent-relay/subdomain-golden.sh` checks it in CI
and `ci/agent-relay/subdomain-golden.sh diff origin/main` shows any change.

### What can share the host

| Service | Under a path prefix on the single host | Why |
| --- | --- | --- |
| relay-webapp | Works as is, at `/` | Assets are built for `/`; it calls only same-origin `/cloud/api`. |
| relaycontrol (relay-control) | Works as is, at `/cloud/api`, `/login`, `/relay-node`, `/api` | It serves those paths natively (`/cloud/api/v1/*` aliases `/api/v1/*`; `/relay-node/v1/*` has no `/cloud` alias), so nothing is stripped. `publicUrl` is the single host. `/internal` is not routed. |
| Relaycast | Needs an app change; stays on its own host | The relaycast-self-host entrypoint refuses a `--base-url` with a path. The TypeScript SDK joins with `new URL('/v1/...', base)`, which drops `/cast`. relaycontrol (`RELAYCAST_PUBLIC_URL`) and Desktop (`validated_base_url`, which silently falls back to `cast.agentrelay.com`) refuse a path-prefixed URL. The A2A, inbound-hook and relayfile-inbound URLs are built from the request origin. Prefix stripping alone fixes none of these. |
| History (read API and ingest edge) | Needs an app change; stays on its own host | The History origin (`sessionReadApiPublicUrl`) is a bare-origin token audience and the base URL relaycontrol hands clients, and relaycontrol and Desktop refuse a path. |
| Relayfile | Needs an app change; stays on its own host | The server and actors gateway would work behind prefix stripping, but the mount and `listen` clients build WebSocket URLs by replacing the path, which drops `/files`. |
| durable-actors | Needs an app change; stays on its own host | The control plane refuses a `publicUrl` with a path and issues actor sockets at `<origin>/v1/socket`; the SDK refuses a base path. |

The chart enforces the last four rows: in single-host mode `gkeIngress.hosts.cast`
and `history` are still required, and rendering fails when `relaycast.baseUrl`,
`relay-control.services.*PublicUrl`,
`sessions-pipeline.alleyoop.auth.historyOrigin`,
`sessions-pipeline.{sessionReadApi,ingestEdge}.origin`, `durable-actors.publicUrl` or
a Relaycast or Relayfile leaf ingress host uses the single host.

GCE Ingress cannot rewrite paths. GKE Gateway API (`HTTPRoute` with a
`URLRewrite` `ReplacePrefixMatch` filter) can, but it would mean replacing the
ManagedCertificate, FrontendConfig and BackendConfigs with Certificate Manager,
an HTTP redirect route and `GCPBackendPolicy`. Nothing that can share the host
today needs a rewrite, so single-host mode keeps the GCE Ingress. Once the app
changes above land, a Gateway API variant can strip `/cast`, `/history`,
`/files` and `/actors`.

All application credentials come from existing Secrets. The deployment values
contain no credentials and no imagePullSecret reference. Rendering fails until
all required immutable digests are present. The live proof
(`values-gcp-proof-live.yaml`) pins these proof-registry builds:

- dashboard: `sha256:23361e08b899f272ed5debcbd4e7d6c6555591029357d6fba6c54236063bca62`
  (relay-webapp `53d484b`, the self-host build served at `/`)
- selfhost API: `sha256:99670d253b88c27499f6c4cca6ac1265ed97978ed7a9d5eaaeecd65de9e052dc`
  (relaycontrol `17bdc78`)

`values-gcp-proof-durable-actors.yaml` pins the relaycast actors gateway
`sha256:026e8c1b1e78b2946c53871e8e5701e0cac9b6121c2b4124cd376ceece33cb45` and
deployer `sha256:9b9fee183167a169370c20950caf63824417b8064ea7e1ef4bd00026ab5fd106`
(relaycast main `46281074`, PR #622: the workspace bootstrap secret and proof policy); `values-gcp-proof-relayfile.yaml` pins relayfile-actors
`sha256:7fb2110701a004f9f7ed2b025d25156fbe993208598bfbd0498a48b30df48299` and
relayfile-actors-workspace
`sha256:c5851a1b1f7624390a1a00ebdee69e8e521dc3f23f345c582d62e09dba9a6e83`
(relayfile main `39f84fcf`, PR #557).

These are proof-only identities. The release gate audits the customer profile
(`values-gcp.yaml`) against `self-hosted/customer-images.yaml`, which records
the CI render fixture's dashboard digest (`ci/gcp-proof-values.yaml`) and the
published `ghcr.io/agentworkforce/relay-control` digest, not the live pins; a
proof pin never makes an image customer-ready.

The live overlay expects an existing Secret (the portable example names it
`example-agent-relay-secrets`) in the release namespace with these keys
(values are never stored in this repository):

- Relaycast: `relaycast-internal-secret`,
  `relaycast-workspace-bootstrap-secret`
- selfhost-api: `database-url`, `database-migrations-url`,
  `selfhost-bootstrap-token`,
  `selfhost-encryption-key`, `selfhost-internal-token` (the live overlay sets
  `relay-control.secretKeys.internalToken`, which enables `/internal/v1`;
  the api host denies `/internal` at the edge)

With `values-gcp-proof-durable-actors.yaml` (Relaycast in
`runtime.backend=durable-actors`) the Relaycast gateway reads these keys of
the same Secret instead of the two SQLite Relaycast keys above
(`ci/agent-relay/render.sh` checks this exact set):

- `relaycast-credential-keyring` (`{"current":"a","keys":{"a":"<random>"}}`)
- `relaycast-actors-internal-secret` (at least 32 characters; equal to
  `RELAYCAST_INTERNAL_SECRET` in the sandbox Secret `relaycast-actor-env`)
- `relaycast-file-signing-secret` (equal to `RELAYCAST_FILE_SIGNING_SECRET` in
  `relaycast-actor-env`)
- `relaycast-actors-workspace-bootstrap-secret` (48 or more random characters,
  no trailing newline; the same bytes as `RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET`
  in `relaycast-actor-env`, which also carries
  `RELAYCAST_WORKSPACE_BOOTSTRAP_PROOF_REQUIRED` equal to
  `relaycast.bootstrapProofRequired`; see charts/relaycast/README.md, "Keyed
  workspace creates on durable-actors")

It also needs the Secrets `actors-credentials` (`postgres-url`,
`jwt-signing-key`, `api-key`, `invoke-api-key`) and
`relaycast-durable-actors-invoke` (`durable-actors-invoke-key`, equal to
`invoke-api-key`); see docs/self-hosted-durable-actors.md ("GCP provisioning").

`selfhost-bootstrap-token` must be at least 32 bytes.
`selfhost-encryption-key` must encode exactly 32 bytes as 64 hex characters or
base64. Runtime database URLs should use least-privilege roles. The HoopDb
`HOOPDB_MIGRATION_URL` and search bootstrap credential use the plain
`hoopdb_owner` role, not a cloud administrator; Relay Control's
`database-migrations-url` instead uses `control_owner` on `relaycontrol`.

The portable shape additionally needs `HOOPDB_URL`, `HOOPDB_MIGRATION_URL`,
`SUMMARY_MASTER_KEYS` and the native History keys named in
`values-gcp-proof.yaml` in that Secret.

```sh
helm dependency build charts/sessions-pipeline
helm dependency build charts/agent-relay
helm install agent-relay charts/agent-relay -n agent-relay \
  --create-namespace --no-hooks -f charts/agent-relay/values-gcp-proof.yaml \
  -f charts/agent-relay/values-gcp-proof-live.yaml \
  --set relay-control.image.digest=sha256:...
```

The proof uses single-writer/single-replica components and makes no HA claim.
Cloud SQL networking and database/user provisioning remain operator work.
The headless API supports both `/api/v1` and
Desktop/Dashboard `/cloud/api/v1` routes, including secure browser login,
workspace-scoped session search, and replay.
