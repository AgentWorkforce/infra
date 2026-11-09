# Self-host without RelayAuth or standalone RelayHistory

`relay-control` with `RELAYHISTORY_BACKEND=native` removes both legacy services
from a self-hosted install: uploads go to the pipeline ingest edge and reads go
through the read API, both on one public origin. It is off by default and does
not change the hosted Cloud path.

## Chart

Apply `-f charts/agent-relay/values-eks.yaml -f charts/agent-relay/values-eks-native.yaml`
with the values marked REQUIRED OVERRIDE. Needed together:

- `components.relayauth: false`, `components.relayhistory: false`
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

The GKE edge (`gkeIngress`) still requires `components.relayhistory`.

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

Run `scripts/selfhost/eks-alb-ingress.sh` with `EKS_ALB_INGEST=true` and without
`EKS_ALB_HISTORY_LEGACY_SERVICE`. The ingest edge then receives `/v1/delivery/*`
(except `GET /v1/delivery/records`), `/v1/turns/*`, `/v1/onboarding/*` and
`POST /v1/auth/token/refresh`. The read API receives `POST /v1/cli/login`,
`GET /v1/delivery/records`, `/v1/sessions*`, `/v1/events`, `/v1/digest/*` and
`/v1/auth/token/revoke`. `/internal` and every other path on the history host,
including `/healthz`, are a fixed 404 at the edge.

## Removing the services

Scale `relayauth` and `relayhistory` to zero only after sign-in, a Desktop upload
and search have passed once with them still running.

`helm uninstall` of the subcharts does not delete PVCs: delete `relayauth` and
`relayhistory` data (and its Postgres database, if external) only after the
proof passes; both can be restored by turning their components back on.

## Proof

`scripts/selfhost/e2e-eks-proof.sh --history-profile pipeline` runs every case
through the ingest edge and read API, replaces the RelayAuth checks in case 7 by
ingest and read API token checks, and fails if the `relayauth` or `relayhistory`
Deployments or their Control URLs still exist. Case 8 is SKIP (the courier path
needs RelayAuth). The dashboard's list filters on `q`, `project`, `since` and
`until` answer `501` on the read API and are not asserted; search goes through
`/sessions/search`. Older installs keep the default `legacy` profile.

## Limits

Relaycast with `credentials.authority=relayauth` needs RelayAuth; the chart
refuses that combination. Self-hosted relayfile (off by default) is not covered.
Deleting the standalone History data is not reversible; its sessions are not
migrated to the pipeline.
