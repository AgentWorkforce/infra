# Relaycast on PostgreSQL versus durable-actors: EKS benchmark

Status: AA decision set (as shipped) complete. Tuned-actors soak, the #659 P1
and #665/#667 failover exit tests, headroom and cold start are in progress and
are added to this document as they land. Raw data: `bench/relaycast/results/`
(per-pod `producer-*.json` / `sink-*.json` / `metrics.csv` are gzipped; `gunzip`
them before re-running `harness/report.mjs`).

This compares the two Relaycast backends the `agent-relay` chart ships, on
identical EKS infrastructure, to inform whether a later Automation Anywhere
(AA) upgrade should move Relaycast to durable-actors. The earlier actors proof
(Nov 4, chart 0.3.12, `values-eks-actors.yaml`) proved correctness only; this
is the first performance comparison.

## Summary (robustness first)

Weighting, per Khaliq: robustness first (integrity under failure, behaviour
under overload, recovery without a human, blast radius, crash loops, memory
drift), throughput and latency second.

**Near-term recommendation: make the PostgreSQL backend robust for AA; keep
durable-actors as a candidate only if the tuned-actors soak is clean.**

- **PostgreSQL.** Every blocker found is a discrete defect with a small,
  targeted fix, most of them already in review:
  - deadlock (#651, fixed by #657);
  - heap OOM under overload (#659, P1 in test);
  - no recovery after an RDS failover (#665, #667 in test);
  - heartbeat write amplification capping it near 8k node sockets (#661);
  - a per-workspace event-lock ceiling (#658).

  At AA-shape load it is fast and loses nothing: send p50 37 ms, delivery p99
  207 ms. The structural gap is high availability. One replica plus a zonal RWO
  PVC turns a node drain into minutes of full outage, and an AZ loss into an
  outage. Production grade needs uploads moved off the PVC (S3), then two or
  more replicas with shared realtime, presence and rate-limit state.
- **Durable actors (as shipped).** Not robust at AA load:
  - Hosts at the 256 MiB default fail readiness and are re-placed in a loop,
    without any fault injected.
  - There is no return to steady state after an actor-host kill, a node drain
    or an RDS failover.
  - Seconds of latency: send p50 4.2 s.
  - A serial per-workspace ceiling of about 1.5-2 channel posts/s with 20-member
    fan-out, or about 6 DMs/s.
  - The shared tier saturates first: a single-replica control plane (more
    replicas need Redis) and the gateway.
  - Provisioning is about 50x slower than on PostgreSQL.
  - Some sends return 5xx yet are delivered, so retries need idempotency keys.

  Its strengths are per-workspace isolation, no PVC and horizontal spread.

### AA decision set: as shipped, relaycast main

3 workspaces x 30 agents (10 producers and 20 receivers, all on node
sockets), channels of 12, 3 msgs/s of mixed DM and channel traffic with 5 %
uploads, over a 2 h soak. Chaos is injected during the soak: relaycast/gateway
pod kill at +30 min, actor-host kill at +45, drain of the node hosting relaycast
or the gateway at +60 (uncordoned 5 min later), and an RDS forced Multi-AZ
failover at +80. Both arms ran concurrently on separate RDS instances and
namespaces; the app nodes were shared.

Recovery means that, without intervention, OK sends return to at least 80 % of
the pre-event rate with no new errors, deliveries flowing and every socket
connected (from `results/aa-a63961b/series/`, sampled about every 25 s).

#### Postgres (+#657, as shipped)

| Robustness | Value |
|---|---|
| Integrity after quiescence (lost / duplicate / reordered) | 0 / 4 / 0 of 68798 |
| Redelivered after reconnect (at-least-once) / 5xx-but-delivered | 0 / 0 |
| Send errors | 38.11 % (7852 of 20605: 5xx 0, 429 0, timeouts 8205) |
| Chaos: kill-relaycast | recovered in 47 s, no intervention; errors during 14, socket drops 90 |
| Chaos: kill-actor | recovered in 62 s, no intervention; errors during 0, socket drops 0 |
| Chaos: node-drain | recovered in 367 s, no intervention; errors during 1028, socket drops 90 |
| Chaos: rds-failover | **not recovered** (not recovered before end); errors during -1042, socket drops – |
| Chaos: manual-restart-after-rds-failover | **not recovered** (not recovered before end); errors during 0, socket drops – |
| Memory drift over the soak: relaycast | 87 -> 479 MiB (peak 574) |

| Performance | Value |
|---|---|
| Send p50 / p95 / p99 (corrected) | 37 ms / 30.0 s / 30.0 s |
| Delivery p50 / p95 / p99 | 34 ms / 108 ms / 207 ms |
| POST /v1/files/upload | n=993, errors 35.5 %, p95 30.0 s |
| PUT /_relayfiles | n=640, errors 0.0 %, p95 10 ms |
| POST /v1/files/:id/complete | n=640, errors 0.0 %, p95 35 ms |

#### Durable actors (12.8.0-actors.1, as shipped)

| Robustness | Value |
|---|---|
| Integrity after quiescence (lost / duplicate / reordered) | 0 / 0 / 0 of 76248 |
| Redelivered after reconnect (at-least-once) / 5xx-but-delivered | 19373 / 60 |
| Send errors | 32.46 % (6670 of 20548: 5xx 6268, 429 0, timeouts 961) |
| Chaos: kill-relaycast | recovered in 63 s, no intervention; errors during 50, socket drops 90 |
| Chaos: kill-actor | **not recovered** (not recovered before end); errors during -515, socket drops – |
| Chaos: node-drain | **not recovered** (not recovered before end); errors during -1336, socket drops – |
| Chaos: rds-failover | **not recovered** (not recovered before end); errors during -3035, socket drops – |
| Memory drift over the soak: relaycast gateway | 54 -> 70 MiB (peak 71) |
| Memory drift: control plane | 152 -> 638 MiB (peak 645) |
| Memory: all actor hosts (sum) | 428 -> 363 MiB (peak 1063) |

| Performance | Value |
|---|---|
| Send p50 / p95 / p99 (corrected) | 4.2 s / 28.2 s / 30.0 s |
| Delivery p50 / p95 / p99 | 5.0 s / 181.7 s / 339.1 s |
| POST /v1/files/upload | n=1050, errors 30.3 %, p95 23.7 s |
| PUT /_relayfiles | n=732, errors 22.7 %, p95 5.0 s |
| POST /v1/files/:id/complete | n=732, errors 10.2 %, p95 16.1 s |
Notes:

- **PG RDS failover.** The process stayed up, with all sockets connected, but
  did no work for 2 h. It held 10 ESTABLISHED :5432 sockets to the old primary
  and logged nothing, until a manual pod restart at the end of the soak
  (relaycast#665).
- **PG node drain.** The `relaycast-data` PV is pinned to us-west-2a, and the
  drained node was the only app node in that AZ. Relaycast stayed Pending until
  the node was uncordoned.
- **Actors churn.** From about +27 min, actor hosts sat at 219-237 of 256 MiB,
  failed readiness probes and were killed and re-placed (`Unhealthy` then
  `Killing`). Each re-placement made one workspace (30 sockets) unavailable.
  The control plane logged "actor host is not ready", spare 409s, "alarm
  abandoned after retries" and "socket event … not replayed". Even so, integrity
  after quiescence was 0 lost / 0 duplicate / 0 reordered.
- **PG duplicates.** The 4 duplicates on the same socket come from the redrive
  race the relaycast-pg-deadlock agent root-caused (a fix is on a separate
  branch).

### Findings filed

| Issue | Backend | Finding |
|---|---|---|
| relaycast#649 | self-host | Ignores SIGTERM while node sockets are open (SIGKILL after the grace period) |
| relaycast#650 | both | `delivery.ack` has no reply, so redelivery happens after a restart; same-socket duplicates follow restarts |
| relaycast#651 | PG | Concurrent channel posts deadlock (500s at 10 posts/s). Fixed by #657 |
| relaycast#659 | PG | Heap OOM under overload, then crash-loops; fix in test (P1) |
| relaycast#661 | PG | `node.heartbeat` re-aggregates capabilities on every beat; about 8k idle sockets saturate the DB |
| relaycast#665 | PG | No recovery after an RDS failover (half-open pool sockets); fix #667 in test |
| durable-actors#2 | actors | PR: Bun-flag passthrough to actor hosts, for in-cluster profiling |


## Arms

| | Postgres arm | Actors arm |
|---|---|---|
| Chart | `charts/agent-relay` 0.6.55 (`7bf3bf2`) for the earlier suites; 0.6.58 (`a01566c3`) for the AA decision set | same |
| Profiles | `values-eks.yaml` + `values-eks-rds-native.yaml` | same + `values-eks-actors.yaml` + `bench/relaycast/values/arm-actors-suite.yaml` |
| Relaycast | `relaycast-self-host@sha256:ab9dd678…` (engine 12.8.0), `runtime.backend=postgres`, 1 replica (the chart refuses more), 100m/256Mi requested, **1 CPU / 1Gi limit** (chart default) | `relaycast-actors-gateway@sha256:6d4f77c4…` (relaycast 12.7.0-actors.1), 1 gateway replica, 100m/128Mi requested, **no CPU limit**, one `Workspace` actor per workspace (250m/256Mi each) |
| Relaycast state | RDS PostgreSQL 17 `db.r7g.large` Multi-AZ, gp3 200 GB | durable-actors (control plane + pool manager on `db.r7g.large` Multi-AZ, database `durable_actors`), actor state and files in S3 |
| Rest of the suite | relay-control, webapp, sessions pipeline on the same RDS | same, on the arm's own RDS |

The PG arm's Relaycast block matches the AA customer pack
(`AgentWorkforce/sales` `automation-anywhere/helm-pack/values.yaml` @ `2f72fcc`):
postgres backend, the same image digest, `postgresCa` from `rds-ca`, a PVC for
uploads. The pack's site values are AA-specific (domain, ALB subnets, ECR
prefix), so the arm uses `values-eks-rds-native.yaml`, which carries the same
Relaycast settings, rather than the pack file itself.

The brief named `values-eks.yaml` + `values-eks-native.yaml` for the Postgres
arm, but that pair leaves Relaycast on SQLite. Relaycast on RDS lives in
`values-eks-rds-native.yaml`, which replaces `values-eks-native.yaml`.

Both profiles are used as shipped, with eight string substitutions that only
replace placeholders (`scripts/render-arms.sh`; the full diff is in
`results/profile-substitutions.diff`):

| Placeholder | Bench value |
|---|---|
| `placeholder.company` | `relaycast-bench.agentrelay.com` (an origin string only; no DNS record exists) |
| `10.0.0.0/16` NetworkPolicy ipBlocks | `10.91.0.0/16` (the bench VPC) |
| `example-agent-relay-sessions` | the bench bucket |
| `example-agent-relay-secrets` | `agent-relay-secrets` (written by `rds-setup.sh`) |
| `example-org` | `bench` |
| RDS CA SHA-256 (64 zeros) | the regional bundle hash from `rds-setup.sh pre` |
| `agent-relay-placeholder` namespace | the arm namespace |
| sessions `search.backend: opensearch` | `postgres` (no OpenSearch domain; the read API docs call postgres the default) |

Plus `relaycast.mailbox.depthCap: 20000` on the PG arm and the same
`RELAYCAST_MAILBOX_DEPTH_CAP=20000` in the actors' env Secret, so the 10k
backlog test is not cut at the default 1000 deliveries per recipient.

### Code vintage per result set

| Results dir | PostgreSQL arm | Actors arm |
|---|---|---|
| `pg/`, `actors/` | relaycast-self-host `ab9dd678` (engine 12.8.0, shipped pin) | gateway 12.7.0-actors.1 (`6d4f77c4`), shipped pin |
| `fix651/` | self-built PR #657 `2465d8f3`, 1 CPU / 1 Gi | — |
| `fix651-4cpu/` | same image, 4 CPU / 4 Gi, `--max-old-space-size=3072` | — |
| `aa-a63961b/` | self-built main `a63961bd` (#657 merged), chart defaults | official 12.8.0-actors.1: gateway `5e1dc050`, deployer `a78fe6d6` (main `10e93f94`; differs from `a63961bd` only by #657, which is not on the actor path) |
| `aa-tuned/` | — | same images, tuned: `values/actors-tuned-1024.yaml` |
| `p1-758ff30/` | self-built #659 P1 `758ff306` | — |


### Render and install findings

1. **The combined actors + full-suite profile did not render** on 0.6.53:
   `values-eks-rds-native.yaml` sets `relaycast.postgresCa` (ConfigMap `rds-ca`),
   which the durable-actors backend rejects. Fixed by #267 (chart 0.6.55), which
   this benchmark uses; `arm-actors-suite.yaml` now only turns the rest of the
   suite back on.
2. A raw checkout renders a third of the suite unless `helm dependency build
   charts/sessions-pipeline` runs first (the in-repo `sessions-pipeline-0.8.26.tgz`
   has no nested subcharts). The published 0.6.53 package is complete (33
   resources).
3. The actors backend refuses `mailbox.*` / `retention.*` values; they go in the
   actor env Secret.
4. The actors backend refuses an `http` base URL, and the Workspace actor reads
   uploaded files back through `RELAYCAST_PUBLIC_URL` over **public** egress (the
   sandbox NetworkPolicy blocks RFC 1918). The sandbox account's only Route53
   zone is customer-named, so the bench has no public origin: **actor file
   read-back is NOT MEASURED**. Upload, PUT and complete are timed on both arms.
5. The session read API rejects reserved TLDs (`.invalid`, `.test`,
   `example.com`) as origins, even when nothing resolves them.

## Infrastructure

`bench/relaycast/infra/cluster.sh` (sandbox account 805532413586, us-west-2,
everything tagged `purpose=relaycast-actors-bench`):

- VPC 10.91.0.0/16, three public subnets, no NAT; EKS 1.34 standard mode with
  vpc-cni network policy, EBS CSI (gp3 default), metrics-server, Pod Identity.
- Node groups: `app` (m7i.2xlarge), `actors` (m7i.2xlarge, one zone, tainted,
  actor hosts only; 0 nodes on the PG arm), `loadgen` (c7i.4xlarge, tainted, load
  pods only, so the client never competes with the system under test).
- One RDS PostgreSQL 17 `db.r7g.large` Multi-AZ instance per arm (`rds-setup.sh`
  allows one HoopDb per instance), private, SG open to the VPC only, master
  password managed by RDS in Secrets Manager.
- The arms run one after the other on the same node shape.

## Workload and harness

`bench/relaycast/harness/` is zero-dependency Node 22 (no k6: exact
per-message accounting needs state shared between producers and receivers):

- `provision.mjs`: workspaces through `POST /internal/workspaces`, producer
  agents, channels, nodes; times every control-plane route.
- `sink.mjs`: receivers on `/v1/node/ws` (the agent delivery path; `/v1/ws` is
  observers only). Records send-to-delivery latency per phase and per-stream
  sequence accounting; acks with `delivery.ack up_to_seq` every 50 ms.
- `producer.mjs`: open-loop producers. Sends are scheduled at the target rate
  regardless of completions; latency is reported both raw (from the actual
  send) and **corrected** (from the intended send time), so a slow server shows
  up as latency, not as a lower offered rate. At most one request in flight per
  stream (producer → DM peer or producer → channel), so ordering at the receiver
  is meaningful.
- `coldstart.mjs`: first request to a new workspace, warm requests, and the
  first request after 180 s idle (past `actors.hostIdleTimeoutMs` 120000).
- `report.mjs`: merges per-pod histograms (log-linear, 1 % precision) into
  per-route and per-phase p50/p95/p99, error and 429/5xx rates, and integrity.

Every message carries `rcb1 <phase> <producer> <stream> <seq> <sent_ms>`.
Integrity per (producer stream, receiver):

| Measure | Definition | Gate |
|---|---|---|
| lost | accepted (201) seqs never delivered | 0 |
| duplicate | a seq delivered twice on the same socket | 0 |
| reordered | a seq that arrived after a later one | 0 |
| redelivered | a seq delivered again on a later socket after a reconnect | reported (at-least-once) |
| unexpected | a non-201 send that was nevertheless delivered | reported |

Rate limits are 30,000 requests/min per workspace, counted in each process's
memory, so the heavy steps spread load over 40 workspaces to measure the
backend, not the limiter; a separate single-workspace saturation suite finds the
per-workspace ceiling.

### Suites (`bench/relaycast/plans/cloud-suites.json`)

| Suite | What |
|---|---|
| functional-10/100/1000 | workspace create, N agents (1 workspace), DM + channel traffic, node-socket delivery, file upload |
| single-ws-saturation | one workspace, 50 → 800 msg/s, 5 min steps, stops at the first broken step |
| heavy | 40 workspaces, 10 / 100 / 1000 / 5000 msg/s (20 min each), then 7500 / 10000 (10 min), stops at the first broken step; then 10x bursts and broadcast DMs |
| fanout | one post to a 500-member channel, 2 and 10 posts/s (1000 and 5000 deliveries/s) |
| ws-5k, ws-10k | 5,000 and 10,000 concurrent node sockets under 1000 msg/s |
| backlog | one agent offline while 10,000 messages queue, then reconnect: drain time and order |
| chaos | 1000 msg/s for 15 min; Relaycast pod (and on actors, the gateway and one actor host) killed at 5 min; RDS forced Multi-AZ failover at 10 min |
| replay | hosted production mix (`profiles/prod-2026-11-12.json`, Cloudflare, aggregate) at 1x / 3x / 10x of the peak minute (68 req/s) |
| coldstart | 20 new workspaces: first, warm, after-idle, rewarm |

A step **breaks** when send-to-ack corrected p99 > 2 s, errors > 1 %, or any
message is lost or duplicated.

## Results

<!-- results:start -->
### Send and delivery, per phase

Send = POST `/v1/dm` or channel message, corrected latency in ms (from the intended send time; worst of the two routes in mixed phases). Delivery = send to arrival on the receiver's node socket. Integrity columns are lost / duplicate / reordered (gate 0) and redelivered (at-least-once, reported).

| Suite | Phase | Arm | Offered /s | OK sends /s | Err | 429 | 5xx | Send p50 / p95 / p99 | Deliveries /s | Delivery p50 / p95 / p99 | Lost / dup / reord | Redeliv |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| functional-10 | f10-dm | Postgres (shipped) | 20 | 20.0 | 0.0 % | 0 | 0 | 33 / 42 / 62 | 20.0 | 36 / 46 / 68 | 0 / 0 / 0 | 0 |
| functional-10 | f10-dm | Postgres + #657 | 20 | 20.0 | 0.0 % | 0 | 0 | 33 / 48 / 125 | 20.0 | 37 / 53 / 142 | 0 / 0 / 0 | 0 |
| functional-10 | f10-dm | Actors | 20 | 6.2 | 0.0 % | 0 | 0 | 65.1 s / 121.5 s / 126.7 s | 6.2 | 3.9 s / 4.5 s / 4.8 s | 0 / 0 / 0 | 0 |
| functional-10 | f10-chan | Postgres (shipped) | 10 | 5.5 | 10.6 % | 0 | 118 | 25 / 39.8 s / 69.3 s | 27.6 | 29 / 39 / 71 | 0 / 0 / 0 | 0 |
| functional-10 | f10-chan | Postgres + #657 | 10 | 10.0 | 0.0 % | 0 | 0 | 25 / 38 / 129 | 50.0 | 29 / 46 / 142 | 0 / 0 / 0 | 0 |
| functional-10 | f10-chan | Actors | 10 | 4.3 | 0.0 % | 0 | 0 | 53.3 s / 100.1 s / 103.6 s | 21.6 | 2.1 s / 2.7 s / 3.9 s | 0 / 0 / 0 | 0 |
| functional-10 | f10-upload | Postgres (shipped) | 2.0 | 0.0 | – | 0 | 0 | – / – / – | – | – / – / – | – / – / – | – |
| functional-10 | f10-upload | Postgres + #657 | 2.0 | 0.0 | – | 0 | 0 | – / – / – | – | – / – / – | – / – / – | – |
| functional-10 | f10-upload | Actors | 2.0 | 0.0 | – | 0 | 0 | – / – / – | – | – / – / – | – / – / – | – |
| functional-100 | f100-dm | Postgres (shipped) | 50 | 50.0 | 0.0 % | 0 | 0 | 42 / 329 / 553 | 50.0 | 46 / 399 / 690 | 0 / 0 / 0 | 0 |
| functional-100 | f100-dm | Postgres + #657 | 50 | 50.0 | 0.0 % | 0 | 0 | 48 / 298 / 422 | 50.0 | 52 / 357 / 502 | 0 / 0 / 0 | 0 |
| functional-100 | f100-dm | Actors | 50 | 0.8 | 98.0 % | 0 | 0 | 30.0 s / 30.0 s / 30.0 s | 13.9 | 214.6 s / 417.4 s / 438.2 s | 0 / 0 / 0 | 0 |
| functional-100 | f100-chan | Postgres (shipped) | 20 | 0.0 | 99.2 % | 0 | 32 | 111.8 s / 204.4 s / 220.6 s | 1.6 | 189.4 s / 255.2 s / 255.2 s | 0 / 0 / 0 | 0 |
| functional-100 | f100-chan | Postgres + #657 | 20 | 16.4 | 0.0 % | 0 | 0 | 7.0 s / 34.7 s / 39.5 s | 328.3 | 8.4 s / 12.0 s / 13.1 s | 0 / 0 / 0 | 0 |
| functional-100 | f100-chan | Actors | 20 | 0.0 | 100.0 % | 0 | 0 | 105.1 s / 204.4 s / 204.4 s | – | – / – / – | 0 / 0 / 0 | 0 |
| functional-100 | f100-upload | Postgres (shipped) | 5.0 | 0.0 | – | 0 | 0 | – / – / – | – | – / – / – | – / – / – | – |
| functional-100 | f100-upload | Postgres + #657 | 5.0 | 0.0 | – | 0 | 0 | – / – / – | – | – / – / – | – / – / – | – |
| functional-100 | f100-upload | Actors | 5.0 | 0.0 | – | 0 | 0 | – / – / – | – | – / – / – | – / – / – | – |
| channel-100 | ch100-10 | Postgres + #657 | 10 | 10.0 | 0.0 % | 0 | 0 | 771 / 1.1 s / 2.5 s | 199.1 | 1.2 s / 1.6 s / 3.3 s | 0 / 0 / 0 | 0 |
| channel-100 | ch100-10 | Actors | 10 | 0.5 | 85.7 % | 0 | 0 | 85.4 s / 156.0 s / 161.5 s | 56.7 | 46.4 s / 79.6 s / 82.4 s | 0 / 0 / 0 | 0 |
| channel-100-hi | ch100h-20 | Postgres + #657 | 20 | 14.2 | 0.0 % | 0 | 0 | 24.2 s / 66.5 s / 70.8 s | 540.2 | 13.4 s / 829.1 s / 846.5 s | 0 / 0 / 0 | 64562 |
| channel-100-hi | ch100h-50 | Postgres + #657 | 50 | 10.9 | 0.0 % | 0 | 0 | 96.7 s / 231.6 s / 243.1 s | 436.1 | 28.7 s / 678.1 s / 711.8 s | 0 / 0 / 0 | 65440 |
| channel-100-hi | ch100h-100 | Postgres + #657 | 100 | 4.0 | 32.4 % | 0 | 0 | 134.9 s / 279.2 s / 281.2 s | 169.3 | 161.5 s / 438.2 s / 486.2 s | 0 / 831 / 0 | 24398 |
| heavy | h-10 | Postgres + #657 | 10 | 10.0 | 0.0 % | 0 | 0 | 77 / 856 / 1.4 s | 45.3 | 69 / 815 / 1.3 s | 0 / 0 / 0 | 0 |
| heavy | h-10 | Actors | 10 | 10.0 | 0.0 % | 0 | 0 | 2.5 s / 8.0 s / 10.0 s | 45.7 | 1.9 s / 4.6 s / 7.5 s | 0 / 0 / 0 | 0 |
| heavy | h-100 | Postgres + #657 | 100 | 6.6 | 93.1 % | 0 | 0 | 10.4 s / 35.6 s / 44.2 s | 31.9 | 33.3 s / 594.4 s / 1180.6 s | 39687 / 1 / 285 | 5985 |
| heavy | h-burst | Actors | 300 | 5.8 | 99.1 % | 0 | 137583 | 65.6 s / 246.5 s / 312.0 s | 53.5 | 582.2 s / 1086.4 s / 1117.0 s | 0 / 0 / 3 | 10947 |
| heavy | h-bcast | Actors | 10 | 10.8 | 95.5 % | 0 | 61981 | 10.2 s / 10.5 s / 21.0 s | 16.5 | 353.4 s / 403.2 s / 414.5 s | 0 / 0 / 0 | 1738 |
| backlog | bl-10k | Actors | 100 | 5.5 | 15.0 % | 0 | 1499 | 812.0 s / 1413.8 s / 1413.8 s | 5.5 | 800.8 s / 1463.7 s / 1525.8 s | 0 / 0 / 0 | 0 |
| channel-100-fine | ch100f-2 | Actors | 2.0 | 1.8 | 0.0 % | 0 | 0 | 17.8 s / 24.3 s / 25.2 s | 35.0 | 17.6 s / 24.2 s / 25.0 s | 0 / 0 / 0 | 0 |
| chaos | ch-load | Actors | 10 | 9.2 | 6.8 % | 0 | 464 | 6.3 s / 15.3 s / 30.0 s | 43.4 | 3.4 s / 20.8 s / 98.7 s | 0 / 9 / 0 | 1044 |
| fanout | fo-2 | Actors | 2.0 | 0.2 | 89.1 % | 0 | 481 | 55.2 s / 151.7 s / 161.5 s | 94.7 | 14.3 s / 159.3 s / 586.2 s | 8300 / 0 / 0 | 2575 |
| fanout | fo-10 | Actors | 10 | 0.0 | 99.6 % | 0 | 2723 | 26.5 s / 68.4 s / 72.8 s | 0.6 | 118.2 s / 291.1 s / 293.1 s | 5390 / 0 / 0 | 0 |
| single-ws-saturation | sat-50 | Actors | 50 | 0.8 | 97.5 % | 0 | 927 | 112.6 s / 210.2 s / 234.8 s | 7.9 | 64.2 s / 136.7 s / 142.6 s | 658 / 0 / 0 | 0 |

### Stepped suites: where each arm breaks

| Arm / suite | Steps (verdict) |
|---|---|
| Postgres + #657 / channel-100 | ch100-10: break: p99 2540.935 |
| Postgres + #657 / heavy | h-10: ok; h-100: break: p99 44181.164, errors 0.9313, lost/dup 39688 |
| Actors / channel-100 | ch100-10: break: p99 161496.549, errors 0.8566 |
| Actors / channel-100-fine | ch100f-2: break: p99 25200.134 |
| Actors / heavy | h-10: break: p99 10023.813 |
| Actors / single-ws-saturation | sat-50: break: p99 234811.544, errors 0.9751, lost/dup 658 |

### Other routes (raw latency, ms)

| Suite | Phase | Arm | Route | n | p50 | p95 | p99 | Err |
|---|---|---|---|---|---|---|---|---|
| functional-10 | f10-upload | Postgres (shipped) | `POST /v1/files/upload` | 119 | 9 | 360 | 3.4 s | 0.0 % |
| functional-10 | f10-upload | Postgres (shipped) | `PUT /_relayfiles` | 119 | 4 | 6 | 7 | 0.0 % |
| functional-10 | f10-upload | Postgres (shipped) | `POST /v1/files/:id/complete` | 119 | 10 | 15 | 28 | 0.0 % |
| functional-100 | f100-upload | Postgres (shipped) | `POST /v1/files/upload` | 299 | 30.0 s | 30.0 s | 30.0 s | 77.3 % |
| functional-100 | f100-upload | Postgres (shipped) | `PUT /_relayfiles` | 68 | 70 | 119 | 132 | 0.0 % |
| functional-100 | f100-upload | Postgres (shipped) | `POST /v1/files/:id/complete` | 68 | 30.0 s | 30.0 s | 30.0 s | 100.0 % |
| functional-10 | f10-upload | Postgres + #657 | `POST /v1/files/upload` | 119 | 8 | 11 | 40 | 0.0 % |
| functional-10 | f10-upload | Postgres + #657 | `PUT /_relayfiles` | 119 | 3 | 5 | 19 | 0.0 % |
| functional-10 | f10-upload | Postgres + #657 | `POST /v1/files/:id/complete` | 119 | 9 | 19 | 24 | 0.0 % |
| functional-100 | f100-upload | Postgres + #657 | `POST /v1/files/upload` | 299 | 174 | 695 | 1.6 s | 0.0 % |
| functional-100 | f100-upload | Postgres + #657 | `PUT /_relayfiles` | 299 | 5 | 10 | 56 | 0.0 % |
| functional-100 | f100-upload | Postgres + #657 | `POST /v1/files/:id/complete` | 299 | 331 | 844 | 1.0 s | 0.0 % |
| functional-10 | f10-upload | Actors | `POST /v1/files/upload` | 119 | 917 | 1.4 s | 2.0 s | 0.0 % |
| functional-10 | f10-upload | Actors | `PUT /_relayfiles` | 119 | 2 | 6 | 6 | 100.0 % |
| functional-10 | f10-upload | Actors | `POST /v1/files/:id/complete` | 119 | 850 | 1.1 s | 1.2 s | 100.0 % |
| functional-100 | f100-upload | Actors | `POST /v1/files/upload` | 299 | 22.2 s | 30.0 s | 30.0 s | 100.0 % |

### Backlog drain

| Arm | Phase | Node | Delivered on reconnect | Drain time |
|---|---|---|---|---|
| Actors | bl-10k | 0/n10 | 8500 | 6.1 s |

### Cold versus warm start (ms)

| Arm | Workspace create p50 / p95 | First request p50 / p95 | Warm p50 / p95 | After 180 s idle p50 / p95 | Rewarm p50 / p95 |
|---|---|---|---|---|---|
| Actors | 898 / 7.5 s | 105 / 177 | 24 / 84 | 2.7 s / 25.7 s | 21 / 68 |

### Resources per suite (Relaycast-side pods; RDS from CloudWatch)

| Arm | Suite | CPU peak / mean (m) | Memory peak (MiB) | RDS CPU peak % | RDS connections peak | RDS write IOPS peak |
|---|---|---|---|---|---|---|
| Postgres (shipped) | functional-10 | 250 / 145 | 90 | 36.3 | 15 | 194 |
| Postgres (shipped) | functional-100 | 581 / 200 | 124 | 58.6 | 15 | 417 |
| Postgres + #657 | channel-100 | 667 / 466 | 128 | 70.7 | 15 | 350 |
| Postgres + #657 | functional-10 | 280 / 170 | 127 | 36.0 | 16 | 202 |
| Actors | channel-100 | 699 / 439 | 586 | 11.0 | 17 | 23 |
| Actors | channel-100-fine | 507 / 313 | 584 | 10.3 | 17 | 24 |
| Actors | functional-10 | 433 / 373 | 772 | 11.7 | 17 | 19 |
| Actors | single-ws-saturation | 1246 / 650 | 1407 | 20.6 | 22 | 20 |
<!-- results:end -->

## Caveats

- **Harness corrections**, each documented next to the affected results:
  - The integrity snapshot now waits for quiescence. Earlier "lost" counts that
    were all trailing were re-run.
  - Socket generations start when the socket opens, so a redelivery after a
    reconnect is no longer counted as a duplicate.
  - The sink's connect workers no longer stall under slow registration. The
    earlier `ws-5k` actors and `ws-10k` PG connect results are superseded; see
    their `NOTE.md`.
  - Chaos timing now uses `kubectl exec` instead of a port-forward. The first
    chaos action in the earlier `chaos` suites never fired, and the actor-host
    kill there did not run.
- **Shared nodes.** The AA soaks ran both arms at the same time, on separate
  RDS instances and namespaces but shared app nodes. The load is about 6
  msgs/s in total, and the chaos events were offset by 10 min.
- **Producers.** In the earlier suites, producers were HTTP-only channel
  members, which leaves undeliverable deliveries that are retried every 30 s.
  The AA suites bind every agent to a node socket (`RCB_PRODUCERS_ON_NODES=1`).
- **Not measured.** In-process actor CPU/GC profiling (needs durable-actors#2);
  per-actor SQLite size and snapshot time.
- Account vCPU quota (64 on-demand at the start; increase to 256 requested,
  id 35acfc382b274bf3ad6e5386cccc0d71hhSRYN6e) bounds node counts; heavy
  suites run only after the increase.
- Actor file read-back is not measured (finding 4).
- The Postgres arm's Relaycast runs at the chart default 1 CPU limit (as AA
  ships it); the actors gateway has no CPU limit. One heavy rerun on the PG arm
  at 4 CPU shows the headroom.
- Production replay covers the routes the harness can reproduce safely; the
  skipped share is listed per run. WebSocket count, agents per workspace,
  channel size and upload mix were not measurable from Cloudflare and use the
  defaults above (marked assumed).
- Sender and receiver clocks are on different loadgen nodes (Amazon Time Sync,
  sub-millisecond); delivery latency below ~1 ms is not meaningful.


## Reproduce

```sh
bench/relaycast/scripts/local-smoke.sh            # harness against a local container
bench/relaycast/scripts/render-arms.sh out --check
AWS_PROFILE=<sandbox> BENCH_API_CIDR=<you>/32 bench/relaycast/infra/cluster.sh up
bench/relaycast/infra/install-arm.sh pg prereqs && … install && … post
ARM=pg NS=arm-pg bench/relaycast/scripts/run-arm.sh all
bench/relaycast/infra/install-arm.sh pg uninstall   # then the actors arm
bench/relaycast/infra/cluster.sh down               # prints the AUDIT line
```
