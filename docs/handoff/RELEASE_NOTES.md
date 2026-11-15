# Agent Relay self-hosted GCP handoff

Customer handoff for the requested **Helm charts + agent prompts**.

## Artifacts

`scripts/package-customer-handoff.sh build --output-dir <dir>` produces, for
one source revision:

- `agent-relay-customer-handoff-<rev12>.tar.gz`
- `agent-relay-customer-handoff-<rev12>.zip` (identical content)
- `SHA256SUMS` covering both archives

No release workflow publishes these files. The release owner uploads all three,
unchanged, to the agreed delivery channel and gives the customer the full
source revision so they can match it against `RELEASE-MANIFEST.json`. A
`-DEVELOPMENT-PREVIEW` or `-INCOMPLETE` archive must never be delivered as a
customer release.

Each archive unpacks to `agent-relay-customer-handoff/` and contains:

- the `agent-relay` umbrella chart and its leaf charts as source (run
  `helm dependency build` at install time), with the structural
  `values-gcp.yaml` example;
- the reusable `setting-up-self-hosted-agent-relay-gcp` setup skill;
- the reference architecture, image supply chain, backup/restore runbook,
  conformance contract, and license docs;
- read-only verification, pre-upgrade, release-validation, and conformance
  scripts;
- `RELEASE-MANIFEST.json` and an inner `SHA256SUMS`.

See [`HANDOFF.md`](HANDOFF.md) for the full layout and verification steps.

The charts cover Relaycast, Sessions Pipeline (with the native History read
API and ingest edge), the headless control-plane API (relaycontrol), Relay
Dashboard, and custom-origin Desktop setup; RelayAuth is optional. Relayflows, durable actors and Relayfile are optional preview
components, off by default. Billing, hosted (Nango) provider integrations and
hosted fleet are out of scope; operator-configured integration OAuth apps
(relay-cloud-api `integrations`, 0.2.3, in agent-relay 0.3.8) are a preview.

(The standalone RelayHistory component referenced in the entries below was
removed in agent-relay 0.7.0; History is now the native read API and ingest edge.)

## agent-relay 0.3.12 (2026-11-04): durable actors on AWS EKS

Released by `release-agent-relay.yml` when the `agent-relay-0.3.12` tag is
pushed (`oci://ghcr.io/agentworkforce/charts/agent-relay`, version 0.3.12).
It adds durable actors on AWS (helm-charts #53, #55). **The actor components
stay off by default.** With none of the new values set, every render is
byte-identical to 0.3.11 apart from the `helm.sh/chart` labels. The customer
images and the `values-gcp.yaml` and `values-eks.yaml` pins are unchanged
from 0.3.11.

- **S3 actor storage.** `durable-actors` 0.14.6-awf.1 adds
  `storage.provider: s3` and `storage.s3.{region, actorCredentials,
  actorRoleArn, endpoint, forcePathStyle}`, AWS availability zones in
  `placement.zone`, `sandbox.{runtimeClassName, nodeSelector, tolerations}`
  for a tainted actor node group, and `serviceAccount.annotations` for IRSA.
  It needs a control-plane image from the AgentWorkforce durable-actors fork
  (`charts/durable-actors/UPSTREAM.md` patches 10 and 11). relaycast 0.3.4 and
  relayfile 0.2.1 add an S3 artifact store for their actor deploy Jobs
  (`runtime.durableActors.deployer.artifactStore`).
- **Per-actor STS is the default.** With `storage.s3.actorCredentials:
  assume-role`, the control plane assumes `storage.s3.actorRoleArn` (on
  Pippen, a `/pippen/workload/` storage role) with an inline session policy
  narrowed to one actor, so an actor host cannot read another actor's state.
  The control-plane role needs `sts:AssumeRole` and `sts:TagSession` on that
  role. **`actorCredentials: control-plane` is an opt-in fallback** for an
  account that forbids `sts:AssumeRole`: actor hosts then share the control
  plane's S3 credentials, isolated by prefix only (first-party actors only).
  The chart's NOTES warn when it is set.
- **`values-eks-actors.yaml`**, a standalone profile: Relaycast and Relayfile
  in actor mode on durable actors with S3 storage, runc actor hosts on a
  tainted node group, and EKS Pod Identity (IRSA works through the service
  account annotations). Every other component is off. To run actors next to
  the suite, layer it over `values-eks.yaml` and turn the other components
  back on. It pins six images by digest, all **public on GHCR** (anonymous
  pulls verified 2026-11-04):

| Image | Pinned digest (`values-eks-actors.yaml`) | Source | Platforms |
|---|---|---|---|
| `ghcr.io/agentworkforce/durable-actors-control-plane` | `sha256:0dc76905554055c8f063d764799410e2a2f385c2274661dd07d8fd9b12117971` | AgentWorkforce/durable-actors (fork of TerseAI) tag `awf-v0.14.6-aws.2` (`a5a7e245`), [run 41800410035](https://github.com/AgentWorkforce/durable-actors/actions/runs/41800410035), MIT | linux/amd64 only |
| `ghcr.io/agentworkforce/durable-actors-typescript` | `sha256:b7118ed1377ccc20f0389d194dd589bcd4845394f72f91410cbaf0f62d4a2ed9` | same fork tag and run, MIT | linux/amd64 only |
| `ghcr.io/agentworkforce/relaycast-actors-gateway` | `sha256:6d4f77c4285becac66f56601a36ac3580b19ad37331db4ad2b87f68b2a68abe4` | relaycast main `4e90b169` (#626), [run 41805228035](https://github.com/AgentWorkforce/relaycast/actions/runs/41805228035), Apache-2.0 | linux/amd64, linux/arm64 |
| `ghcr.io/agentworkforce/relaycast-actors-deployer` | `sha256:f539982442305c61f2c7a7d979cb110e18f3be83fed69befd8755b6ad5476b51` | same relaycast revision and run, Apache-2.0 | linux/amd64, linux/arm64 |
| `ghcr.io/agentworkforce/relayfile-actors` | `sha256:27dfc8d5bbceb7161af9aa4c4923c0efd5045b2d332f60c30492fd599b434522` | relayfile main `30a5e007` (#559), [run 41805271012](https://github.com/AgentWorkforce/relayfile/actions/runs/41805271012), Apache-2.0 | linux/amd64, linux/arm64 |
| `ghcr.io/agentworkforce/relayfile-actors-workspace` | `sha256:6845272aa103724e4da8d6f29653e4ea06ab57b71900b807e4a38b8f41c11d32` | same relayfile revision and run, Apache-2.0 | linux/amd64, linux/arm64 |

  The file's header comment still says these packages may be private, and
  that the install script uses the control-plane fallback. Both are out of
  date: the packages are public, and the script defaults to per-actor STS
  (#55). Changing the comment would need a chart version bump, so it is
  fixed in the next chart change.
- **`scripts/selfhost/eks-actors-install.sh`** (`prereqs`, `prepull`,
  `install`, `actor-env`, `status`, `uninstall`) and `eks-actors-sandbox.sh`
  build the proof in a Pippen sandbox. The install defaults to per-actor STS
  with the derived storage role ARN (`EKS_ACTORS_ACTOR_ROLE_ARN` overrides
  it), and `EKS_ACTORS_ACTOR_CREDENTIALS=control-plane` opts in to the
  fallback. `prepull` is only needed for a private mirror.
- **Proof.** In the `actors-proof` Pippen sandbox (EKS, standard mode, runc
  actor hosts) in per-actor STS mode: actor activation, the Relaycast
  harness 18/18, the Relayfile mount e2e, and a cross-actor negative check
  15/15 (one actor's session policy denies another actor's snapshots and
  ownership records and a bucket-wide list, and create-only writes are
  enforced). Proof Postgres and secrets are proof-only (see the script
  header); use a managed Postgres with TLS for a real install.
- Images and licenses are recorded in `self-hosted/customer-images.yaml` as
  inactive entries and in the image supply-chain guide. They are not part of
  the gated customer matrix and need owner approval before they join one.
  The two durable-actors images are linux/amd64 only.

## agent-relay 0.3.11 (2026-11-04): current images, every pin public

Published from the `agent-relay-0.3.11` tag by `release-agent-relay.yml`
([run 41812609280](https://github.com/AgentWorkforce/infra/actions/runs/41812609280);
`oci://ghcr.io/agentworkforce/charts/agent-relay`, version 0.3.11). It
supersedes the never-tagged 0.3.7, 0.3.8, 0.3.9 and 0.3.10 and includes their
changes (below), so it covers everything since 0.3.6. The leaf charts are
unchanged from 0.3.9 (relay-cloud-api 0.2.4, relay-dashboard 0.1.3,
relayhistory 0.1.1, sessions-pipeline 0.6.0). Only `values-gcp.yaml` and the
selfhost-api and dashboard pins in the new `values-eks.yaml` (0.3.10, below)
move.

**Images.** Every image `values-gcp.yaml` renders is now a public GHCR
release digest, with linux/amd64 and linux/arm64 pullable anonymously. The two
REQUIRED OVERRIDE zero digests (RelayHistory, Sessions services) are gone.

| Component | Image | Source |
|---|---|---|
| Control-plane API | `ghcr.io/agentworkforce/selfhost-api@sha256:95c7877741054dc2f1cafa26be3faa9bfe4660ed85d637aef4524daa10481963` (0.3.0) | relaycontrol `9b80b04` (#7-#13) |
| Dashboard | `ghcr.io/agentworkforce/relay-dashboard@sha256:c50005fcdd1fc5ab5ef3dac9b621db8e0c7e03480406bfe519743ae435d8f1ad` | relay-dashboard `e5003d0` (#83-#92) |
| RelayHistory | `ghcr.io/agentworkforce/relayhistory@sha256:d3166bb14e1d6043426a4dd8cc05408b94574c8d79ad5fd6e789e0de00ab371b` | relayhistory-cloud `53c3333` |
| Sessions services (worker, alleyoop) | `ghcr.io/agentworkforce/96bulls-services@sha256:070fe6fd46ecd1e1f9db32ff22379f6df9b9e6c4d48ede5312c8fb986a95f3a9` | sessions-pipeline `f1c2672` |
| Relaycast | `ghcr.io/agentworkforce/relaycast-self-host@sha256:81274dca7ab58673383dc7a9c777f422f29606c7422e81b5ea15724770f1455e` (unchanged) | relaycast `bf713d86` (engine 12.7.0) |
| RelayAuth | `ghcr.io/agentworkforce/relayauth@sha256:c23c92d25fdffef3b5838a1eef4c226925f859706365d9ccece229795b877288` (unchanged) | relayauth `784582e` |
| Sessions wait-for-role | `ghcr.io/cloudnative-pg/postgresql:17-standard-trixie@sha256:ed6923f9ba2399cf9070379a353c710c29ced8a294be73986a2c3dae7e599ce3` (unchanged) | upstream `4c2710a` |

Mirror each one by digest into your registry, as before (image supply-chain
guide).

What the new images bring, in one place:

- **Dashboard redesign.** The self-host dashboard now has the hosted Cloud
  look and feel (relay-dashboard #83), the faceted sessions sidebar and
  customer-profile branding (#84, #86), and Settings pages that match hosted:
  Connections with Coding agents (#85, #89, #90), the Agent Relay Desktop
  link from the customer profile (#88) and Members with email invites (#92).
  Connections now matches hosted visually, and the Integrations tab is
  gone (#91).
- **First-boot bootstrap, OIDC / email sign-in and invites** (relaycontrol
  #13, chart values from 0.3.9, below). The pinned images include it, so no
  digest override is needed any more.
- **Coding-agent credentials and device logins** (relaycontrol #7, #10, #11).
  Workspace model-provider credentials with sandbox and model selection;
  Codex (ChatGPT) and Grok subscription logins, envelope-encrypted and mounted
  per run. Daytona is no longer offered. The envelopes are stored in Postgres
  unless flows storage is `gcs` (then the same bucket).
- **Desktop sign-in origin** (relaycontrol #9): sign-in answers name the
  site the request arrived on, so a custom-origin Desktop signs in to your
  host.
- **Integration OAuth apps** (relaycontrol #12, chart values from 0.3.8,
  below).
- **Origin-bound pipeline auth.** The Sessions services image verifies the
  courier's origin-bound RelayAuth History assertion (sessions-pipeline
  #204), so session ingest works with the interim RelayAuth bearer off, as
  the customer profile ships it. Keep `alleyoop.auth.historyOrigin` equal to
  `relayhistory.relayauth.historyOrigin` (the chart refuses a mismatch).
- **RelayHistory public image** from its reviewed container workflow.

**Flows worker CLI.** The relayflows chart still installs agent-relay
12.4.1 into the flows worker (`runtimeInstaller.agentRelayVersion`). The
agent-relay CLI release with the new coding-agent device logins (15.1.2 or
later) was not on npm when 0.3.11 was cut; raise that value once it ships.

**Upgrade step: ingest JWKS URL.** The new services image only accepts an
https RelayAuth JWKS URL, or plain http to an in-cluster Service FQDN when
`allowInClusterHttp` is on. `values-gcp.yaml` now sets
`sessions-pipeline.alleyoop.allowInClusterHttp: true` and
`auth.jwksUrl: http://relayauth.<release namespace>.svc:8787/.well-known/jwks.json`.
If your overrides set the old short `http://relayauth:8787/...` URL, change
it, or session ingest cannot verify courier tokens.

**Upgrade step: HoopDb roles (required).** The new Sessions services image
checks roles that the sessions-pipeline 0.6.0 chart does not create in the
customer profile (`roleBootstrap: false`). Without them its migrate Job fails
with `42501 role check failed bootstrap:session_token_verifier`. Before you
upgrade, run the three bootstrap scripts shipped in the image, in order, as a
privileged HoopDb user (the Cloud SQL admin user, or the CNPG superuser):

```bash
IMG=ghcr.io/agentworkforce/96bulls-services@sha256:070fe6fd46ecd1e1f9db32ff22379f6df9b9e6c4d48ede5312c8fb986a95f3a9
for f in session_directory_search_worker session_token_verifier session_ingest_roles; do
  docker run --rm --entrypoint cat "$IMG" "/app/supabase/bootstrap/$f.sql" \
    | psql "$HOOPDB_ADMIN_URL" -X -v ON_ERROR_STOP=1
done
```

The scripts are idempotent. On Cloud SQL (`values-gcp.yaml`) a fresh install
runs the full set as the migration owner, in order:
`cloudsql_migration_roles.sql`, `session_directory_search_worker.sql`,
`session_token_verifier.sql`, `session_ingest_roles.sql`,
`cloudsql_owner_function_default_revoke.sql` (all in the same image
directory). An upgrade from 0.3.6 already ran the first, second and last at
install.

EKS validation passed after the upgrade to the published 0.3.11 chart with
its selfhost-api and dashboard digests, services `070fe6fd`, RelayHistory
`d3166bb1` and the interim bearer off. The GKE proof has not been re-run
with the complete 0.3.11 image set. Renders with your own
`image.repository`/`image.digest` overrides are unchanged apart from the
`helm.sh/chart` labels.

## agent-relay 0.3.10 (never tagged; ships in 0.3.11): AWS EKS profile

Never tagged; it ships in 0.3.11 (above). It adds
`charts/agent-relay/values-eks.yaml`, the AWS EKS profile, and
[`docs/self-hosted-eks.md`](../self-hosted-eks.md) (helm-charts #47). The
profile was proven end to end on EKS Auto Mode with real DNS and TLS and the
interim bearer off (15/15 cases). It uses one ALB Ingress with host rules and
an ACM certificate (`scripts/selfhost/eks-alb-ingress.sh`), EKS Pod Identity
to S3 for the Sessions Pipeline, and in-cluster CloudNativePG for HoopDb, the
control API and RelayHistory. Relaycast runs on SQLite.
`scripts/selfhost/eks-proof-install.sh hoopdb-roles` runs the HoopDb role
bootstraps in-cluster on EKS. Durable actors stay GKE-only. Templates are
unchanged. It is a proof profile, not a production reference architecture.
0.3.11 moves its selfhost-api and dashboard pins to the same digests as
`values-gcp.yaml`. The EKS proof ran the earlier `535e6718` and `bbeca872`
digests.

## agent-relay 0.3.9 (never tagged; ships in 0.3.11): first boot, sign-in and invites

Never tagged; it ships in 0.3.11 (above). It
supersedes the never-tagged 0.3.8 (and 0.3.7) and includes their changes. It ships with
relay-cloud-api 0.2.4.

- **First-boot bootstrap.** Set `relay-cloud-api.bootstrap.{orgName,adminEmail}`
  together with `secretKeys.relaycastInternalSecret` and, outside single-host
  mode, `dashboardUrl`. On
  first start the API:
  - creates the organization;
  - makes the admin email its owner;
  - creates a `Default` workspace bound to a new Relaycast workspace.

  It is idempotent, so it is safe on an existing install.
- **Sign-in.** `auth.oidc` adds OpenID Connect with PKCE (Google Workspace,
  Okta, Entra ID, Keycloak). The client secret goes in
  `secretKeys.oidcClientSecret`. Optional `auth.emailLink` sends single-use
  email sign-in links and needs `smtp`. The bootstrap token remains the
  operator break-glass.
- **Invites.** Owners and admins invite from Settings → Members:
  - links are single use and expire after `auth.inviteTtlHours`;
  - they are emailed when `smtp` is set and can always be copied;
  - `auth.autoJoinDomains` lets a domain join without invites.
- `values-gcp.yaml` carries a commented example.

Requirements:
- a selfhost-api image from relaycontrol #13 or later;
- a dashboard image from relay-dashboard #92 or later, for the invite UI.

0.3.11 pins images that include both.

With none of these values set, renders are byte-identical apart from the
`helm.sh/chart` labels.

## agent-relay 0.3.8 (never tagged; ships in 0.3.11): integration OAuth apps

Never tagged; it ships in 0.3.11. 0.3.7 was also never tagged; its changes ship here (below). relay-cloud-api 0.2.3 adds
`integrations.<provider>.existingSecret`: the customer's own OAuth app per
integration (GitHub, Slack, Linear, Notion, ...), read from an existing
Secret (client ID as `SELFHOST_OAUTH_<PROVIDER>_CLIENT_ID`, client secret
mounted as a file), so users connect integrations just in time from the
CLI, flow onboarding and flow creation instead of a settings page. Register
`<publicUrl>/api/v1/integrations/oauth/callback` as the callback URL in each
provider app; a provider without an entry tells users their administrator
needs to configure it. It needs a selfhost-api image with operator OAuth
apps (relaycontrol `selfhost/jit-integrations`). A default render is
unchanged apart from the `helm.sh/chart` labels.

From the never-released 0.3.7, a GKE proof-overlay and documentation patch of
0.3.6:
`values-gcp-proof-live.yaml` sets `relay-dashboard.customerProfile.desktop`
(`urlScheme`, `siteUrl`) for the proof's custom Desktop build, and the
relay-dashboard chart (0.1.3) documents `customerProfile.desktop`. The
dashboard's "Connect your agents" link uses it with a dashboard image from
relay-dashboard #88 or later. Templates, images and `values-gcp.yaml` are
unchanged from 0.3.6; renders differ only in the `helm.sh/chart` labels
(and `DASHBOARD_CUSTOMER_PROFILE` in the gcp-proof-live render).

## agent-relay 0.3.6 (2026-11-04): single-host mode and dashboard branding

Published from the `agent-relay-0.3.6` tag
(`oci://ghcr.io/agentworkforce/charts/agent-relay`, version 0.3.6; release run
41769269329). 0.3.5 was
never tagged; its changes ship here. The leaf charts are relay-cloud-api 0.2.2
and relay-dashboard 0.1.2.

- **Single-host mode** (opt-in, `global.singleHost.host`, off by default). The
  dashboard and the control-plane API share one host (`/`, `/cloud/api`,
  `/login`, `/api`): relay-cloud-api derives its `publicUrl` and the dashboard
  derives `runtime.publicUrl` and `ingress.host` from it, and the GKE Ingress
  drops the `api.` host. Relaycast, Relay History, Relayfile and
  durable-actors keep their own hosts (see the agent-relay README "Single-host
  mode" and `values-single-host-example.yaml`).
- **Enterprise branding.** The new optional `relay-dashboard.customerProfile`
  (product name and title, light and dark logos, favicon, accent and primary
  button colors, a support link, and the "Powered by Agent Relay" line) is
  rendered into `DASHBOARD_CUSTOMER_PROFILE` and served in
  `/runtime-config.js`, so a customer brand needs no per-customer image, but
  it requires a dashboard image built from relay-dashboard `8eac2bd` or later
  (see below). It is empty by default; `values-gcp.yaml` carries a commented
  example, and the relay-dashboard README documents every field.
- **Sessions sidebar facets** (dashboard image). Picking a project or harness
  no longer collapses the sidebar to that option. Each facet's options and
  counts ignore its own selection and respect the other filters, and a
  project is sent to the server only as an exact project id.

Branding and the facet fix need a dashboard image built from relay-dashboard
`8eac2bd` or later. The customer profile's pinned dashboard digest predates it:
it ignores `customerProfile` and keeps the earlier sessions sidebar until a
new release image is published and pinned. With single-host mode off and no
`customerProfile`, every default render is byte-identical to 0.3.4 apart from
the `helm.sh/chart` labels; images are unchanged from 0.3.4.

## agent-relay 0.3.4 (2026-11-03): documentation patch

Published from the `agent-relay-0.3.4` tag
(`oci://ghcr.io/agentworkforce/charts/agent-relay`, version 0.3.4). The relaycast leaf chart
is 0.3.3 and the relayauth leaf chart is 0.1.3. Both drop the stale
instruction to override the Relaycast `image.digest` for `ar_` credentials:
the pinned default (engine 12.7.0) already satisfies the `>=12.3.x`
requirement. The `values-gcp.yaml` credentials comment says the same. Images,
templates and the rendered `values-gcp.yaml` are unchanged from 0.3.3, so the
image matrix below still applies.

## agent-relay 0.3.3 (2026-11-03)

Published from the `agent-relay-0.3.3` tag. Pins the attested Relaycast image:
`relaycast-self-host@sha256:81274dca…` (relaycast main `bf713d86`, engine
12.7.0; SPDX SBOM, max-mode provenance and a GitHub build-provenance
attestation; public, amd64+arm64). The relaycast leaf chart is 0.3.2 with the
same default. This image has not run the GKE upgrade/restore drills; its kind
smoke runs in this repository's CI. It also carries the untagged 0.3.2 GKE
proof-overlay refresh (proof values only). Everything else is as in 0.3.1.

Images in `charts/agent-relay/values-gcp.yaml` (0.3.3 and 0.3.4). Only the
Relaycast row differs from 0.3.1:

| Component | Image | Source | Supply chain |
|---|---|---|---|
| Control-plane API | `ghcr.io/agentworkforce/selfhost-api@sha256:535e6718…` | relaycontrol `8e989a1` | SBOM + max provenance; **private package, not pullable by customers yet** (installation blocker) |
| Dashboard | `ghcr.io/agentworkforce/relay-dashboard@sha256:bbeca872…` | relay-dashboard `b213406` | SBOM + max provenance + GitHub attestation; public |
| RelayAuth | `ghcr.io/agentworkforce/relayauth@sha256:c23c92d2…` | relayauth `784582e` | SBOM + provenance; public |
| Relaycast | `ghcr.io/agentworkforce/relaycast-self-host@sha256:81274dca…` | relaycast `bf713d86` (engine 12.7.0) | SBOM + max provenance + GitHub attestation; public |
| Sessions wait-for-role | `ghcr.io/cloudnative-pg/postgresql@sha256:ed6923f9…` | upstream `4c2710a` | as in 0.3.1 |
| Sessions services | `ghcr.io/agentworkforce/96bulls-services` | no release revision yet | **not published** (zero digest); REQUIRED OVERRIDE, installation blocker |
| RelayHistory | `ghcr.io/agentworkforce/relayhistory` | relayhistory-cloud | **not published** (zero digest); REQUIRED OVERRIDE, installation blocker |

## agent-relay 0.3.1 (2026-11-03): reviewable release

This is the first release of the umbrella chart, published from the
`agent-relay-0.3.1` tag (`oci://ghcr.io/agentworkforce/charts/agent-relay`,
version 0.3.1). It is meant
for review by a company evaluating self-hosted Agent Relay on GCP. It is a
`portable-single` preview, not an HA or production-readiness claim, and the
handoff archive is labelled a development preview because the fail-closed
customer release gate does not pass yet. **[STATUS.md](STATUS.md)** lists
what is proven, what is preview, and what is planned.

Images in `charts/agent-relay/values-gcp.yaml`. Five images are pinned by
immutable digest. Four of them (dashboard, RelayAuth, Relaycast, PostgreSQL)
are public; mirror those to your registry by digest. The control-plane API
(`selfhost-api`) package is still private, so customers cannot pull it yet;
it blocks installation until the package is public. The
Sessions services and RelayHistory images are not published: they render a
zero digest (REQUIRED OVERRIDE) and block installation until a release image
exists and you pin it.

| Component | Image | Source | Supply chain |
|---|---|---|---|
| Control-plane API | `ghcr.io/agentworkforce/selfhost-api@sha256:535e6718…` | relaycontrol `8e989a1` | SBOM + max provenance; **private package, not pullable by customers yet** (installation blocker) |
| Dashboard | `ghcr.io/agentworkforce/relay-dashboard@sha256:bbeca872…` | relay-dashboard `b213406` | SBOM + max provenance + GitHub attestation; public |
| RelayAuth | `ghcr.io/agentworkforce/relayauth@sha256:c23c92d2…` | relayauth `784582e` | SBOM + provenance; public |
| Relaycast | `ghcr.io/agentworkforce/relaycast-self-host@sha256:a05732ad…` | relaycast `bdf1b69` | public; **no SBOM, min-mode provenance only** (attested rebuild pending; closed in 0.3.3) |
| Sessions wait-for-role | `ghcr.io/cloudnative-pg/postgresql@sha256:ed6923f9…` | upstream `4c2710a` | upstream revision label `4c2710a`, run 40291448784; SBOM + SLSA attestation manifests; keyless cosign signature verified with `--certificate-github-workflow-sha` |
| Sessions services | `ghcr.io/agentworkforce/96bulls-services` | no release revision yet (last audited private image: `7d7229b`; the release is to be built from `main` at or after `51b38ff`) | **not published** (zero digest): the attested publish needs the owner's dispatch; REQUIRED OVERRIDE, installation blocker |
| RelayHistory | `ghcr.io/agentworkforce/relayhistory` | relayhistory-cloud | **not published** (zero digest): the self-host runtime PR is held; REQUIRED OVERRIDE, installation blocker |

Full revisions, release runs, platforms and blockers are in
`self-hosted/customer-images.yaml`.

Changes since the unreleased 0.2.x/0.3.0 profiles (0.3.0 renamed the `96bulls:` values key to `sessions-pipeline:`):

- `values-gcp.yaml` pins the five release images above by digest instead of
  placeholders (`selfhost-api` is still private). Sessions services and RelayHistory keep zero-digest
  placeholders (REQUIRED OVERRIDE).
- `values-gcp.yaml` sets `sessions-pipeline.alleyoop.auth.issuer` to RelayAuth's issuer
  and asks for `historyOrigin` (REQUIRED OVERRIDE; it must equal
  `relayhistory.relayauth.historyOrigin`, and the chart refuses to render when
  they differ). The chart default (`https://96bulls.local`)
  rejected every RelayAuth-signed courier assertion.
- The self-host dashboard image talks only to the same-origin `/cloud/api`
  prefix. Keep `relay-dashboard.runtime.apiBasePath` at `/cloud/api` and route
  `/cloud/api` and `/login` to the control-plane API, as the GKE ingress does.
- Session ingest from Desktop couriers needs machine-bound History assertions.
  The generic RelayAuth bearer is refused unless an operator opts in to the
  interim `ALLOW_INTERIM_RELAYAUTH_BEARER` setting, which is off in the
  customer profile.
- The handoff now includes the end-to-end harness (`scripts/selfhost/e2e-gcp-proof.sh`,
  `--secret` is now required) and sanitized GKE evidence summaries
  (`docs/handoff/evidence/`).
