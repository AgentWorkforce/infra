# Self-hosted Agent Relay architecture

```mermaid
flowchart TB
  subgraph Clients["Customer devices and agents"]
    Desktop["Agent Relay Desktop\ntrusted API origin"]
    Agents["Relay-enabled agents"]
    Browser["Web browser"]
  end

  subgraph GCP["Customer GCP project"]
    LB["Global HTTPS Load Balancer\nDNS + managed TLS"]

    subgraph GKE["GKE · agent-relay namespace"]
      Dashboard["Relay Dashboard\nstatic SPA"]
      API["Headless Control API\ndevice auth · tenancy · credential exchange"]
      Cast["Relaycast\nmessaging · roster · delivery"]
      History["History read API + ingest edge\nsession upload · search · replay"]
      Pipeline["Sessions Pipeline\nworkers · AlleyOop"]
      Secrets["Kubernetes Secrets\nor external secret delivery"]
      CastPVC[("Relaycast RWO PVC")]
    end

    subgraph Data["Managed data services"]
      ControlDB[("PostgreSQL\ncontrol-plane tables")]
      SessionsDB[("PostgreSQL hoopdb\nSessions Pipeline")]
      GCS[("GCS session objects")]
      Registry["Artifact Registry\nimmutable image digests"]
    end
  end

  Browser -->|HTTPS| LB
  Desktop -->|device login · workspace resolution| LB
  Agents -->|WebSocket/HTTPS messaging| LB

  LB -->|/| Dashboard
  LB -->|/cloud/api · api host| API
  LB -->|cast host| Cast
  LB -->|history host| History

  Dashboard -->|same-origin API| API
  API -->|workspace key resolution| Cast
  API -->|scoped History session| History
  Desktop -->|durable delivery batches| History

  API --> ControlDB
  History --> SessionsDB
  History --> GCS
  Pipeline --> SessionsDB
  Pipeline --> GCS
  Cast --> CastPVC
  Secrets -.credentials.-> API
  Secrets -.credentials.-> History
  Secrets -.credentials.-> Pipeline
  Registry -.digest-pinned images.-> GKE
```

## Trust and data boundaries

- The Desktop persists one public HTTPS control-plane origin. It does not store
  a deployment-wide workspace key in `deployment.json`.
- The control API binds users to an organization and workspace, then returns
  scoped Relaycast and History credentials. History is native: relay-control's
  native backend, the Sessions read API and the ingest edge share the history
  host and read and write the Sessions Pipeline `hoopdb` and GCS objects. No
  RelayAuth is needed.
- Public traffic enters through one GKE Ingress. Services remain `ClusterIP`;
  sensitive Relaycast administration paths are denied at the edge.
- Runtime and migration-owner database credentials are separate.
- Relaycast and the proof profile are single-writer components.
  This architecture is `portable-single`, not HA.

## Included and excluded

Included: messaging, agent roster and replies, session upload, durable retry,
search, replay, Dashboard, device login, and custom Desktop origin.

Excluded: Relayflows, Relayfile, billing, provider integrations, hosted fleet,
and hosted MCP.
