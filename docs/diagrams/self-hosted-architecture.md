# Self-hosted Agent Relay — architecture diagram (GCP)

This page and its exported images retain the pre-rename GCP resource layout.
For the new public chart names and explicit compatibility values, use the
[Control/Webapp rename guide](../control-webapp-chart-rename.md). These
History is native: relay-control's native backend, the Sessions read API and
the ingest edge on the `history` host; there is no standalone History server
and RelayAuth is optional.

Start with the overview: [agent-relay-architecture.png](agent-relay-architecture.png)
([SVG](agent-relay-architecture.svg), source [agent-relay-architecture.mmd](agent-relay-architecture.mmd))
and the request flow [agent-relay-request-flow.png](agent-relay-request-flow.png)
([SVG](agent-relay-request-flow.svg), source [agent-relay-request-flow.mmd](agent-relay-request-flow.mmd)).
This page is the detailed view: ports, routes, Secrets and the Relayflows run modes.

Rendered exports of the diagrams below: [architecture SVG](self-hosted-architecture.svg) ·
[architecture PNG](self-hosted-architecture.png) ·
[relayflows modes SVG](self-hosted-relayflows-modes.svg) ·
[relayflows modes PNG](self-hosted-relayflows-modes.png).
They are generated from the mermaid source in this file with
`@mermaid-js/mermaid-cli` (`mmdc -b white`, PNG at `-s 2`); the mermaid
blocks are the source of truth.

One Helm release (`charts/agent-relay`) deploys the full suite into the
customer's GKE cluster and VPC-adjacent managed services. All public traffic
terminates at a single global external HTTPS load balancer on one static IP
with one Google ManagedCertificate covering four customer DNS names; every
backend is a `ClusterIP` Service reached through standalone NEGs, and
NetworkPolicy admits only same-namespace pods plus the Google Front End
ranges. Inside the namespace, Relaycast serves agent messaging over
WebSocket and REST, the control API serves sign-in, tenancy, and credential
exchange, the optional RelayAuth issues Relaycast credentials only in the
model-B layout (pushing `ar_ws_` workspace keys into Relaycast), the Sessions
ingest edge receives the Desktop's durable delivery batches on the `history`
host and writes them to the GCS Locker bucket and hoopdb for the Sessions
Pipeline workers to index, and the Sessions read API serves list, search and
replay on the same host. Durable state is split deliberately: Cloud SQL holds per-service PostgreSQL databases with a
runtime/migration-owner role split, reached through connection URLs held in
Kubernetes Secrets (no IAM database authentication); GCS holds session
objects, reached by the Sessions Pipeline workers, ingest edge and read API through the services'
native GCS adapter (`locker.provider: gcs`, `LOCKER_PROVIDER=gcs`) with GKE
Workload Identity on their Kubernetes service accounts, so no storage key is
stored; and retained RWO PVCs hold the Relaycast and RelayAuth SQLite stores. The
chart renders no `VolumeSnapshot` objects and Relaycast's backup CronJob is
off by default: PVC snapshots are operator-run per the
[backup and restore runbook](../selfhost-backup-restore.md). Credentials arrive
via existing Secrets, never values, with one exception: the optional
Relayflows `credentials.enrollmentToken` can be set inline and the chart
renders it into a Secret (prefer `credentials.existingSecret`). Relayflows is an opt-in add-on; a Terse durable-actors
backend for Relaycast is designed but not yet shipped.

```mermaid
flowchart TB
  subgraph Clients["Client edge"]
    Desktop["Agent Relay Desktop<br/>trusted API origin"]
    Agents["CLI / SDK agents<br/>WSS + REST · cast host only"]
    Browser["Team members' browsers"]
  end

  subgraph LBEdge["Google global external HTTPS load balancer"]
    direction TB
    LB["Static IP 34.x.x.x<br/>GKE Ingress · class gce"]
    Cert["ManagedCertificate<br/>root · api · cast · history"]
    FE["FrontendConfig<br/>HTTP → HTTPS 301"]
    Deny["cast edge-deny Service<br/>no endpoints"]
    LB --- Cert
    LB --- FE
    LB -. "/internal + /v1/workspaces (exact)<br/>refused at the edge" .-> Deny
  end

  subgraph NS["GKE · agent-relay namespace"]
    direction TB
    Dash["relay-dashboard<br/>nginx SPA · :8080"]
    API["relay-cloud-api<br/>control plane · svc :80 → :3000<br/>device auth · orgs · workspace resolve"]
    Cast["relaycast<br/>WSS + REST · :8787<br/>single-writer engine"]
    Auth["relayauth<br/>JWT issuer · :8787 · optional"]
    Hist["session read API<br/>list · search · replay · :8080"]
    AO["session ingest edge<br/>durable delivery batches · :8081<br/>tokens introspected by relay-cloud-api"]
    Worker["sessions-pipeline sessions workers<br/>index · summarize · eval · health :8081"]
    Flows["relayflows runner<br/>Job / CronJob · optional"]

    subgraph Planned["opt-in durable-actors backend (runtime.backend=durable-actors)"]
      direction TB
      GW["relaycast / relayfile gateways<br/>stateless · :8787 / :8080"]
      CP["durable-actors control plane<br/>:7100 · Redis for &gt;1 replica"]
      SB["Workspace actor pods<br/>gVisor · &lt;ns&gt;-&lt;release&gt; sandbox ns<br/>engine on actor SQLite"]
      GW -->|"invoke Workspace[wsid]<br/>verified credential routes"| CP
      CP -->|"proxy invocation<br/>:7101/:7102"| SB
    end
  end

  subgraph Data["Customer GCP project · data plane"]
    direction TB
    SQL[("Cloud SQL PostgreSQL<br/>control-api · hoopdb<br/>runtime role ≠ migration owner<br/>URLs held in Secrets")]
    GCS[("Cloud Storage<br/>sessions Locker bucket + backup bucket<br/>native GCS API")]
    WI["GKE Workload Identity<br/>worker · ingest · read API KSAs → GCS IAM<br/>storage only, not Cloud SQL"]
    TGCS[("durable-actors GCS<br/>one Standard bucket (state + code)<br/>Rapid optional · file-store buckets")]
    PVCs[("Retained RWO PVCs<br/>relaycast.db · relayauth.db · files")]
    Snap[("VolumeSnapshots — operator-run<br/>backup runbook · not rendered by the chart")]
    SM["Secret Manager /<br/>existing Kubernetes Secrets<br/>DB URLs · signing keys"]
  end

  Browser -->|"HTTPS root host"| LB
  Desktop -->|"HTTPS root + api hosts"| LB
  Agents -->|"WSS/HTTPS cast host"| LB

  LB -->|"root host /<br/>static SPA"| Dash
  LB -->|"root host /cloud/api + /login<br/>api host /"| API
  LB -->|"cast host /"| Cast
  LB -->|"history host<br/>/v1/sessions* · /v1/events · ..."| Hist
  LB -->|"history host<br/>/v1/delivery/* · /v1/turns/* · ..."| AO

  Dash -->|"same-origin /cloud/api"| API
  API -->|"workspace key resolution<br/>/internal admin"| Cast
  API -->|"native History backend<br/>reads"| Hist
  API -->|"control-api database"| SQL
  Desktop -->|"durable delivery batches<br/>history host /v1/delivery"| AO
  AO -->|"token introspection"| API

  Auth -.->|"model B: RelayAuth owns the ar_ keyring,<br/>pushes ar_ws_ workspace keys;<br/>relaycast verifies via remote CredentialTagger"| Cast

  AO -->|"objects · native GCS"| GCS
  AO -->|"metadata"| SQL
  Worker -->|"read chunks · native GCS"| GCS
  Worker -->|"summaries · index"| SQL
  Hist -->|"hoopdb reads"| SQL
  Hist -->|"objects · native GCS"| GCS
  Cast -->|"SQLite + files"| PVCs
  Auth --> PVCs
  Snap -.->|"operator-run backup"| PVCs
  WI -.->|"pod identity"| GCS
  SM -.->|"credentials at mount time"| NS
  Flows -->|"ClusterIP calls<br/>creds via env"| Cast

  GW -.->|"replaces engine pod<br/>when runtime.backend=durable-actors"| Cast
  SB -.-> TGCS
```

## Optional: Relayflows execution modes

`components.relayflows` is off by default. Standalone mode works against a
self-hosted install today; `cloudWorker` mode renders but cannot enroll until
the self-host control plane implements the `/api/v1/workers/*` family.

```mermaid
flowchart LR
  subgraph Today["Shipped — mode: standalone"]
    Job["relayflows Job / CronJob<br/>flows run · flows resume<br/>RWO journal PVC"]
    Suite["in-cluster suite<br/>relaycast · relay-cloud-api · read API<br/>plain ClusterIP DNS"]
    Job -->|"explicit endpoints + creds via env<br/>no control-plane contact"| Suite
  end

  subgraph Blocked["Blocked — mode: cloudWorker"]
    W["relayflows worker Deployment<br/>cloud worker register → start"]
    Routes["control plane /api/v1/workers/*<br/>register · heartbeat · queue (SSE)<br/>assignments ack | status | storage"]
    Gap["selfhost-api today: 404 not_found<br/>works only against hosted Agent Relay Cloud"]
    W -->|"Bearer workerToken"| Routes
    Routes -.-> Gap
  end
```

## Component map

| Diagram box | Chart / component | Port | Datastore |
| --- | --- | --- | --- |
| Global HTTPS LB | `gkeIngress` in `charts/agent-relay` | 443 (80 → 301) | static IP, ManagedCertificate, FrontendConfig |
| cast edge-deny Service | `gkeIngress` template | cast servicePort | none — selectorless, routes `/internal` and exact `/v1/workspaces` to nowhere |
| relay-dashboard | `charts/relay-dashboard` | 8080 (nginx SPA) | none |
| relay-cloud-api | `charts/relay-cloud-api` | svc 80 → container 3000 | Cloud SQL control-api DB (`control_api_runtime` + migration owner) |
| relaycast | `charts/relaycast` | 8787 WSS + REST | retained RWO PVC: `relaycast.db` + uploaded files; operator-run VolumeSnapshots (backup CronJob off by default) |
| relayauth | `charts/relayauth` (optional) | 8787 | retained RWO PVC: `relayauth.db`; signing key from Secret |
| session read API | `sessions-pipeline.sessionReadApi` (`charts/session-read-api`) | 8080 | hoopdb (read login) + GCS Locker |
| session ingest edge | `sessions-pipeline.ingestEdge` | 8081 | GCS Locker bucket (native GCS, Workload Identity) + hoopdb (PG 17, `pg_trgm`) |
| sessions-pipeline workers | `charts/sessions-pipeline-worker` | 8081 health | hoopdb + GCS Locker via native GCS and Workload Identity |
| relayflows | `charts/relayflows` (optional) | — | run-journal `ReadWriteOncePod` PVC |
| Cloud SQL | customer-provisioned | 5432 | per-service databases; runtime vs migration-owner role split; connection URLs from Secrets |
| GCS | customer-provisioned buckets | HTTPS, native GCS API | sessions Locker objects, recovery/backup prefixes; no stored key |
| Workload Identity | GKE KSA → GCP service account → bucket IAM | — | grants worker, ingest edge and read API KSAs GCS object access; databases still use Secret-held URLs |
| VolumeSnapshots | operator-run, [backup runbook](../selfhost-backup-restore.md) | — | Relaycast and RelayAuth PVC recovery sets; not rendered by any chart |
| Secrets | existing Secrets or Secret Manager (ESO) | — | DB URLs, signing keys, internal secrets; Relayflows enrollment token unless set inline (then chart-rendered) |
| durable-actors control plane (opt-in) | vendored `charts/durable-actors`, `components.durableActors` | 7100 | PostgreSQL registry + one Standard GCS bucket (Rapid optional); Redis for more than one replica |
| Workspace actors (opt-in) | gVisor sandbox pods, `<namespace>-<release>` ns | 7101/7102 | actor SQLite derived per activation from GCS |
| relaycast / relayfile gateways (opt-in) | `charts/relaycast` and `charts/relayfile` `runtime.backend=durable-actors` | 8787 / 8080 | file bytes in GCS or S3 (local PVC for one Relaycast replica) |

## Key flows

- **Agent messaging:** agent → `cast` host → relaycast :8787 (WSS + REST) →
  SQLite/files on its RWO PVC. With the opt-in `durable-actors` backend
  ([docs](../self-hosted-durable-actors.md)), the pod becomes a stateless
  gateway: the `ar_` credential names the workspace, the durable-actors control
  plane proxies the invocation to a `Workspace` actor pod, and the actor's
  SQLite is derived from GCS.
- **Sessions:** the Desktop sends durable delivery batches
  (`/v1/delivery/batches`) to the `history` host → ingest edge :8081 (token
  introspected by relay-cloud-api) → objects in the GCS Locker bucket +
  metadata in hoopdb → Sessions Pipeline workers index/summarize into
  PostgreSQL. Dashboard list, search and replay go through relay-cloud-api's
  native History backend to the read API :8080, which serves the same `history`
  host for clients.
- **Key issuance (model B, optional RelayAuth):** RelayAuth owns the `ar_`
  tag keyring and pushes `ar_ws_` workspace keys into Relaycast's internal
  admin API; Relaycast verifies tags through RelayAuth's remote
  CredentialTagger.
