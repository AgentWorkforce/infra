# Self-host without RelayAuth (native History)

Self-hosted History is native: `relay-control` with `RELAYHISTORY_BACKEND=native`
sends uploads to the pipeline ingest edge and reads through the Sessions read
API, both on one public `history.<domain>` origin. No RelayAuth is needed. It
does not change the hosted Cloud path.

The standalone RelayHistory component was removed in agent-relay 0.7.0.
`components.relayhistory: true` or a non-empty `relayhistory:` values block
fails the render with a pointer to this page; remove both (a
`components.relayhistory: false` left in site values is accepted and ignored).

## Chart

`values-eks.yaml` and `values-gcp.yaml` are native on their own; replace the
values marked REQUIRED OVERRIDE. (`values-eks-native.yaml` and
`values-gcp-native.yaml` are now empty compatibility overlays, so commands that
still name them render identically.) The profiles set together:

- `components.relayauth: false`
- `relay-control.services`: `relayauthEnabled: false`, `relayhistoryBackend: native`,
  `sessionReadApiUrl`, `sessionReadApiPublicUrl`; `relayhistoryUrl` and
  `relayhistoryPublicUrl` stay empty.
- `relay-control.secretKeys`: `sessionReadApiSecret`, `introspectSecret`; the
  key `relayauthApiKey` empty. `introspection.audiences` includes the history
  origin (or stays empty to default to it).
- `sessions-pipeline.sessionReadApi.enabled: true` with `auth.mode: self_issued`
  and the same `origin`, `directoryWorkspaces: "*"` (a static list would refuse
  new workspaces with 501), and `.ingestEdge.enabled: true` with the same `origin`
  and `sessionSelection: true`. See
  [native ingest](self-hosted-native-ingest.md) and
  [read API](self-hosted-session-read-api.md).

The GKE edge (`gkeIngress`) routes the history host to the read API and ingest
edge Services.

## Images

- relay-control: an image built from a commit containing the native backend
  (`RELAYHISTORY_BACKEND`). Earlier images ignore that variable.
- 96bulls-services for the read API and ingest edge: a build with
  `READ_API_AUTH_MODE=self_issued` and `SERVICE=session-ingest`.

## Migrations

No new Control migration. The ingest edge's `bulls96_session_ingest` login and
the read API's `bulls96_read_api` login must be bootstrapped with their role
Jobs (`docs/selfhost-composition.md` section 4, relayhistory-pipeline), and
pipeline migration 043910 must be applied for `sessionSelection`.

## Edge

Run `scripts/selfhost/eks-alb-ingress.sh` (ingest routes are on by default). The ingest edge then receives `/v1/delivery/*`
(except `GET /v1/delivery/records`), `/v1/turns/*`, `/v1/onboarding/*` and
`POST /v1/auth/token/refresh`. The read API receives `POST /v1/cli/login`,
`GET /v1/delivery/records`, `/v1/sessions*`, `/v1/events`, `/v1/digest/*` and
`/v1/auth/token/revoke`. `/internal` and every other path on the history host,
including `/healthz`, are a fixed 404 at the edge.

## Upgrading an install that ran the standalone services

Upgrading to agent-relay 0.7.0 removes the standalone History Deployment. Its
sessions are not migrated to the pipeline. Helm does not delete PVCs or
external databases: delete the old History and `relayauth` data only after
sign-in, a Desktop upload and search pass on the native path. RelayAuth can be
turned back on with `components.relayauth: true`; the standalone History server
cannot.

## Proof

`scripts/selfhost/e2e-eks-proof.sh` runs every case
through the ingest edge and read API, replaces the RelayAuth checks in case 7 by
ingest and read API token checks, and fails if the `relayauth` or legacy History
Deployments or their Control URLs still exist. Case 8 is SKIP (the courier path
needs RelayAuth). The dashboard's list filters on `q`, `project`, `since` and
`until` answer `501` on the read API and are not asserted; search goes through
`/sessions/search`. Older installs keep the default `legacy` profile.

## Limits

Relaycast with `credentials.authority=relayauth` needs RelayAuth; the chart
refuses that combination. Self-hosted relayfile (off by default) is not covered.
Deleting the former standalone History data is not reversible; its sessions
are not migrated to the pipeline.
