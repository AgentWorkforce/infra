# Self-hosted Agent Relay on AWS EKS

Status: proven end to end on EKS Auto Mode inside a Pippen sandbox
(2026-11-04): all 15 cases of the e2e plus the EKS checks pass, with real DNS
(`aws-proof.agentrelay.com`) and TLS (ACM). Chart
`oci://ghcr.io/agentworkforce/charts/agent-relay` 0.3.11 with
[`values-eks.yaml` at 0.3.11](https://github.com/AgentWorkforce/infra/blob/agent-relay-0.3.11/charts/agent-relay/values-eks.yaml); every image is a
public GHCR image pinned by digest. Results: [What was proven](#what-was-proven).
This is a proof profile, not a production reference architecture.

The proof and reproduction commands below use the historical 0.3.11 chart,
whose keys are `relay-cloud-api` and `relay-dashboard`. The current source uses
`relay-control` and `relay-webapp`; its examples are not overrides for 0.3.11.
The proof installer loads the EKS base values from the selected published chart
and emits legacy keys. See the [rename guide](control-webapp-chart-rename.md)
for a separately reviewed upgrade. Existing ALB backends can be retained with
`EKS_ALB_CONTROL_SERVICE` and `EKS_ALB_WEBAPP_SERVICE`. For the recorded 0.3.11
layout use `EKS_ALB_CONTROL_SERVICE=relay-cloud-api` and
`EKS_ALB_WEBAPP_SERVICE=relay-dashboard`; these are also the historical installer
defaults. Explicit overrides are forwarded to the generator.

The 0.3.11 proof also ran RelayAuth and the standalone RelayHistory. The
standalone RelayHistory was removed in agent-relay 0.7.0: the current
`values-eks.yaml` is native History (Control's native backend, the Sessions
read API and ingest edge on the history host, no RelayAuth); see
[self-host without RelayAuth](self-hosted-no-relayauth.md).

Scope: the core suite with Relaycast on SQLite and Relayfile off. For the
separate AWS actor profile, see
[durable actors](self-hosted-durable-actors.md).

Files:

| File | What it is |
| --- | --- |
| [`charts/agent-relay/values-eks.yaml`](../charts/agent-relay/values-eks.yaml) | Customer-neutral EKS values. Replace every `REQUIRED OVERRIDE`. |
| [`scripts/selfhost/eks-alb-ingress.sh`](../scripts/selfhost/eks-alb-ingress.sh) | Prints the ALB Ingress (one ALB, four hosts, ACM TLS, edge denials). The chart ships only the GKE edge. |
| [`scripts/selfhost/eks-proof-dns.sh`](../scripts/selfhost/eks-proof-dns.sh) | ACM certificate (request, wait, delete) and the DNS records (validation CNAMEs, host CNAMEs to the ALB) in the parent Cloudflare zone, removed by recorded id. |
| [`scripts/selfhost/eks-proof-sandbox.sh`](../scripts/selfhost/eks-proof-sandbox.sh) | The proof substrate: VPC, EKS Auto Mode cluster, IAM roles, S3 bucket, Pod Identity, StorageClass/IngressClass. Pippen conventions. |
| `scripts/selfhost/eks-proof-install.sh` (removed in agent-relay 0.7.0; see git history) | The 0.3.x/0.4.x proof installer: CNPG operator, the control-API and RelayHistory Postgres, generated Secret, Helm install, Ingress, installation org, HoopDb role bootstrap, uninstall. It only installed published charts that shipped the standalone RelayHistory, so it was removed with that component. |
| [`scripts/selfhost/e2e-eks-proof.sh`](../scripts/selfhost/e2e-eks-proof.sh) | The e2e: the GKE proof's 15 cases through the HTTPS edge (`e2e-gcp-proof.sh --edge alb --require-public`) plus EKS checks. |
| [`scripts/selfhost/e2e-eks-proof-s3.ts`](../scripts/selfhost/e2e-eks-proof-s3.ts) | The Pod Identity to S3 round trip the e2e runs in the alleyoop pod. |

## Mapping from the GKE profile

| GKE (`values-gcp.yaml`) | EKS (`values-eks.yaml`) |
| --- | --- |
| `gkeIngress` (GCE Ingress, ManagedCertificate, FrontendConfig, static IP) | `gkeIngress.enabled=false`; one ALB Ingress from `eks-alb-ingress.sh` (EKS Auto Mode's built-in ALB controller, IngressClass `alb`; the AWS Load Balancer Controller takes the same annotations): host rules for `<domain>` (dashboard, with `/cloud/api` and `/login` to the control API), `api.`, `cast.`, `history.`; HTTPS 443 with an ACM certificate for the four names, HTTP 80 redirects (301). Edge denials (`/internal`, `//internal*`, Relaycast workspace create) are ALB fixed-response 404 actions. |
| ManagedCertificate | ACM certificate, DNS-validated |
| NEG annotations, BackendConfig | `alb.ingress.kubernetes.io/healthcheck-path` on each Service; ALB idle timeout 3600 s for WebSocket/SSE |
| GKE Workload Identity | The pinned 0.3.11 proof uses `<release>-worker` and `<release>-alleyoop` (one IAM role with S3 access to the bucket). New descriptive-name charts use `<release>-session-ingest-api`; retain the actual legacy identity through a deliberate cutover. No IRSA/OIDC provider needed. |
| GCS Locker bucket (`locker.provider: gcs`) | S3 bucket (`locker.provider: s3`, empty endpoint, `credentials.mode: podIdentity`) |
| Cloud SQL (HoopDb, control API) | HoopDb: the chart's in-cluster CloudNativePG cluster. Control API: any PostgreSQL 17 (the 0.3.11 proof used two more CNPG clusters, one for the control API and one for the since-removed RelayHistory). Production: RDS/Aurora PostgreSQL. |
| Memorystore, Pub/Sub (GCS data-path env) | Not used: the services' S3 data path needs neither |
| GCE load-balancer ranges in NetworkPolicy `ingressFrom` | The ALB's subnet CIDRs (the ALB in IP target mode reaches pods from its subnets). The proof's ALB shares the cluster's public subnets, so it used the VPC CIDR, which also admits any other VPC client |
| Artifact Registry mirrors | Public GHCR images by digest; no pull secret |

## DNS and TLS

The charts accept only `https://` public origins, so a working install needs
DNS names and a certificate. The proof used four names under one domain:

| Host | Origin value |
| --- | --- |
| `aws-proof.agentrelay.com` | `relay-dashboard.runtime.publicUrl`, `relay-cloud-api.dashboardUrl` |
| `api.aws-proof.agentrelay.com` | `relay-cloud-api.publicUrl` |
| `cast.aws-proof.agentrelay.com` | `relaycast.baseUrl`, `relay-cloud-api.services.relaycastPublicUrl` |
| `history.aws-proof.agentrelay.com` | `relay-cloud-api.services.relayhistoryPublicUrl`, `relayhistory.relayauth.historyOrigin`, `sessions-pipeline.alleyoop.auth.historyOrigin` (all three byte-equal) |

Those are the 0.3.11 keys. In the current native profile the history host is
`relay-control.services.sessionReadApiPublicUrl`,
`sessions-pipeline.sessionReadApi.origin`,
`sessions-pipeline.ingestEdge.origin` and
`sessions-pipeline.alleyoop.auth.historyOrigin` (all the same origin).

Steps (any DNS provider; with Route 53 create the same records there):

1. Request one ACM certificate in the cluster's region for the four names,
   DNS validation (`eks-proof-dns.sh cert-request`).
2. Create the validation CNAMEs (`eks-proof-dns.sh cf-validation`) and wait
   for `ISSUED` (`cert-wait`; about 2 minutes in the proof).
3. Install, then apply the Ingress with `EKS_ALB_DOMAIN` and
   `EKS_ALB_CERT_ARN` (`eks-proof-install.sh install` does both).
4. Point the four names at the ALB's DNS name (CNAMEs, unproxied, or Route 53
   alias records): `eks-proof-dns.sh alb`, then `cf-hosts`.

Why the proof's records are in Cloudflare and not in a delegated Route 53
zone: the Pippen sandbox's agent-session policy grants ACM (tagged
`pippen:sandbox`) but no Route 53 writes, so the sandbox cannot own a hosted
zone. Every record the script creates is a name under the proof domain,
unproxied, commented, and recorded by id in `.eks-proof/cloudflare-records.txt`;
`cf-remove` deletes exactly those and checks that nothing is left under the
proof domain. The 96bulls `aws-proof-sandbox` stage validates ACM through
Cloudflare DNS the same way.

## Images used

The EKS deployment was upgraded to the published agent-relay 0.3.11 chart
with its image pins and the interim bearer off. `values-eks.yaml` pins
selfhost-api 0.3.0
(`sha256:95c7877741054dc2f1cafa26be3faa9bfe4660ed85d637aef4524daa10481963`)
and dashboard
(`sha256:c50005fcdd1fc5ab5ef3dac9b621db8e0c7e03480406bfe519743ae435d8f1ad`)
digests, the same as `values-gcp.yaml`. The table below describes that
image set.

| Component in proven 0.3.11 (current source name) | Image | Source |
| --- | --- | --- |
| relaycast | `ghcr.io/agentworkforce/relaycast-self-host@sha256:81274dca…` | chart pin |
| relayauth | `ghcr.io/agentworkforce/relayauth@sha256:c23c92d2…` | chart pin |
| relay-cloud-api (relay-control) | `ghcr.io/agentworkforce/selfhost-api@sha256:95c78777…` (relaycontrol 9b80b04, 0.3.0) | chart pin |
| relay-dashboard (relay-webapp) | `ghcr.io/agentworkforce/relay-dashboard@sha256:c50005fc…` (relay-dashboard e5003d0) | chart pin |
| relayhistory | `ghcr.io/agentworkforce/relayhistory@sha256:d3166bb14e1d6043426a4dd8cc05408b94574c8d79ad5fd6e789e0de00ab371b` | `values-eks.yaml` at 0.3.11 |
| worker, alleyoop, privileged SQL | `ghcr.io/agentworkforce/96bulls-services@sha256:070fe6fd46ecd1e1f9db32ff22379f6df9b9e6c4d48ede5312c8fb986a95f3a9` (sessions-pipeline f1c2672, with #204) | `values-eks.yaml` |
| CNPG Postgres | `ghcr.io/cloudnative-pg/postgresql:17-standard-trixie@sha256:ed6923f9…` | chart pin |

The services image f1c2672 includes sessions-pipeline #204: the ingest
verifies the origin-bound History assertion whenever `RELAYHISTORY_ORIGIN`
(`alleyoop.auth.historyOrigin`) is set, so `allowInterimRelayAuthBearer`
stays `false`. It verifies two privileged HoopDb roles the sessions-pipeline
0.6.0 chart does not create; `eks-proof-install.sh install` runs
`hoopdb-roles` (the image's own bootstrap SQL as the CNPG superuser) as soon
as the HoopDb cluster is Ready. The older 7d7229b build
(`sha256:6f22ea17…`, the one the 0.6.0 chart is audited with) needs no role
bootstrap but accepts a courier push only with the interim bearer on.

## What was proven

Environment: EKS Auto Mode 1.34 (`pippen-sbx-eks-proof`, us-west-2) in the
Pippen sandbox of agent `aws-proof` (account 361835732085), public subnets,
built-in node pools (one to two nodes). Helm release `agent-relay`, chart
0.3.11 from GHCR, `values-eks.yaml` plus the generated proof overlay; all
Deployments Ready, every migration Job Complete, three CNPG clusters healthy.
Edge: one internet-facing ALB, ACM certificate `ISSUED` for the four hosts.

| Run | Services image | Interim bearer | Result |
| --- | --- | --- | --- |
| 2 (2026-11-04 08:00Z) | 7d7229b `6f22ea17…` | on (`environment: local`) | 15/15 PASS, EKS checks PASS |
| 3 (2026-11-04 08:16Z) | f1c2672 `070fe6fd…` | **off** (`environment: production`) | **15/15 PASS, EKS checks PASS** |

Run 3, `scripts/selfhost/e2e-eks-proof.sh` (102 checks PASS, 2 SKIP:
`public.verify_public` is GKE-only, and the control plane has no workspace
delete API):

| Case | Result |
| --- | --- |
| 1 bootstrap (single org, two workspaces, device auth, membership gate) | PASS |
| 2 messaging (register, roster, A to B, reply, history) | PASS |
| 3 session delivery (durable receipt, identical retry, one projection) | PASS |
| 4 reads (dashboard list/replay/search, RelayHistory direct) | PASS |
| 5 isolation (B gets 404 on A's sessions, flows, env, settings, History, Relaycast) | PASS |
| 6 durability (relayhistory and relaycast restarts) | PASS |
| 7 auth (JWKS, assertion signature, token verification) | PASS |
| 8 Sessions Pipeline (courier push with the origin-bound assertion, indexer, referee, summaries, events, no dead letters, S3 objects, scrub, worker logs) | PASS |
| 9 erasure | PASS |
| 10 public edge (authenticated calls through HTTPS; edge denials) | PASS |
| 11 sessions API via `/cloud/api` | PASS |
| 12 admin (env vars masked, audit, `/internal` and `//internal` denied at the edge) | PASS |
| 13 flows (enrollment token, worker Pod, deterministic run) | PASS |
| 14 dashboard (SPA, runtime-config, deep links) | PASS |
| 15 cleanup | PASS |

EKS checks (run 3):

```
EKS|PASS|eks.pod_identity|associations=relaycast agent-relay-alleyoop agent-relay-worker   (relaycast no longer gets one: SQLite needs no bucket)
EKS|PASS|eks.s3_locker_roundtrip|credentials=pod-identity bucket=pippen-sbx-eks-proof-361835732085 ... read_back=true
EKS|PASS|eks.s3_locker_delete|key=e2e-eks-proof/1793780715739.txt
EKS|PASS|eks.alb_targets|alb=k8s-agentrel-agentrel-a5e75ddcd6-28012270.us-west-2.elb.amazonaws.com healthy_target_groups=4
EKS|PASS|eks.acm_certificate|status=ISSUED names=aws-proof.agentrelay.com,history.aws-proof.agentrelay.com,cast.aws-proof.agentrelay.com,api.aws-proof.agentrelay.com
EKS|PASS|eks.tls.dashboard|host=aws-proof.agentrelay.com verify=ok https_status=200 http_redirect=301 issuer="C=US, O=Amazon, CN=Amazon RSA 2048 M01"
EKS|PASS|eks.tls.api|host=api.aws-proof.agentrelay.com verify=ok https_status=200 http_redirect=301
EKS|PASS|eks.tls.cast|host=cast.aws-proof.agentrelay.com verify=ok http_redirect=301
EKS|PASS|eks.tls.history|host=history.aws-proof.agentrelay.com verify=ok https_status=200 http_redirect=301
EKS|PASS|eks.cnpg|control-api-pg, hoopdb, relayhistory-pg: Cluster in healthy state
```

## Reproduce

Inside a Pippen sandbox lease (`pippen sandbox up <agent>`), from this repo
(`CF_API_TOKEN` is a DNS edit token for the parent zone, in the environment
of the `cf-*` commands only):

These are the 0.3.11 proof's commands, kept as a record. `eks-proof-install.sh`
was removed in agent-relay 0.7.0; a current install uses `values-eks.yaml`
(native History) or `values-eks-rds-native.yaml` with your own Secrets and
`eks-alb-ingress.sh`.

```sh
export EKS_PROOF_API_CIDR=<operator egress>/32
export EKS_PROOF_CHART_VERSION=0.3.11
pippen sandbox exec <agent> -- scripts/selfhost/eks-proof-sandbox.sh up
pippen sandbox exec <agent> -- scripts/selfhost/eks-proof-dns.sh cert-request
CF_API_TOKEN=... scripts/selfhost/eks-proof-dns.sh cf-validation
pippen sandbox exec <agent> -- scripts/selfhost/eks-proof-dns.sh cert-wait
pippen sandbox exec <agent> -- scripts/selfhost/eks-proof-install.sh prereqs
pippen sandbox exec <agent> -- scripts/selfhost/eks-proof-install.sh install
pippen sandbox exec <agent> -- scripts/selfhost/eks-proof-dns.sh alb
CF_API_TOKEN=... scripts/selfhost/eks-proof-dns.sh cf-hosts
pippen sandbox exec <agent> -- scripts/selfhost/eks-proof-install.sh bootstrap-org
pippen sandbox exec <agent> -- scripts/selfhost/e2e-eks-proof.sh
# teardown
pippen sandbox exec <agent> -- scripts/selfhost/eks-proof-install.sh uninstall
CF_API_TOKEN=... scripts/selfhost/eks-proof-dns.sh cf-remove
pippen sandbox exec <agent> -- scripts/selfhost/eks-proof-dns.sh cert-delete
pippen sandbox exec <agent> -- scripts/selfhost/eks-proof-sandbox.sh down
pippen sandbox down <agent>          # must report clean: true
```

`EKS_PROOF_DOMAIN` (default `aws-proof.agentrelay.com`) names the domain.
Outside Pippen, run the same scripts with your own AWS credentials and set
`PIPPEN_SANDBOX_ACCOUNT_ID` to your AWS account ID (the scripts read the
account from it): `export PIPPEN_SANDBOX_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)`.
`eks-proof-sandbox.sh` hard-codes the Pippen IAM conventions (the
`pippen:sandbox` tags, the `/pippen/workload/` role path and the
`pippen-agent-session-boundary` permissions boundary, which must exist);
adapt `ROLE_PATH`, `BOUNDARY` and `TAG_KEY` for your account.

## Gaps and follow-ups

1. **The chart has no EKS edge.** `gkeIngress` is GKE-only; the ALB Ingress
   lives in `scripts/selfhost/eks-alb-ingress.sh`. An `albIngress` block in
   the umbrella would make it one install.
2. **ALB rule order.** The controller orders a host's rules Exact, then
   Prefix, then ImplementationSpecific. `//internal*` must be an
   ImplementationSpecific path (Kubernetes refuses `//` in Exact/Prefix
   paths, and the ALB does not collapse it), so the api and cast catch-alls
   are ImplementationSpecific `/*` after it; a Prefix `/` would match first.
3. **One-time organization bootstrap.** A fresh control plane has no
   installation organization; `eks-proof-install.sh bootstrap-org` creates it
   (`POST /api/v1/organizations` with the bootstrap token, from inside the API
   pod). relay-cloud-api 0.2.4 (helm-charts #52) adds first-boot bootstrap
   through chart values.
4. **Services image versus the sessions-pipeline 0.6.0 chart.** Builds newer
   than 7d7229b verify two more privileged roles before they migrate
   (`session_token_verifier`, the session ingest roles), which the 0.6.0 chart
   does not bootstrap; the migrate Job fails with 42501 until an operator runs
   them (`eks-proof-install.sh hoopdb-roles`).
5. **Route 53 in the Pippen sandbox.** The agent-session policy has no
   Route 53 writes, so the proof's DNS is in the parent Cloudflare zone (see
   DNS and TLS). A pippen-tools policy change would allow a delegated zone.
6. **EKS Auto Mode with IAM paths.** A custom NodeClass refused a node role
   under `/pippen/workload/` ("unauthorized to join nodes to the cluster");
   the built-in pools accept it. Custom tags on ALBs (IngressClassParams
   `tags`) break `CreateRule`, because `AmazonEKSLoadBalancingPolicy` allows
   only its own tag keys. Do not tag Auto Mode ALBs.
7. **Flow artifacts** stay inline in PostgreSQL
   (`relay-cloud-api.flows.storage: postgres`); there is no S3 option.
8. **Not yet proven on EKS:** RDS/Aurora instead of CNPG, private subnets
   with NAT, NetworkPolicy enforcement (the policies render with the VPC CIDR,
   but Auto Mode's network policy controller was not enabled), backup/restore
   and upgrade drills, and HA (relaycast and relayauth are single-replica
   SQLite on EBS).
