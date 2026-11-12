# Relaycast on PostgreSQL versus durable-actors: EKS benchmark

Status: methodology and harness final; results sections are filled from
`bench/relaycast/results/` by `bench/relaycast/scripts/summarize.mjs`.

This compares the two Relaycast backends the `agent-relay` chart ships, on
identical EKS infrastructure, to inform whether a later Automation Anywhere
(AA) upgrade should move Relaycast to durable-actors. The earlier actors proof
(Nov 4, chart 0.3.12, `values-eks-actors.yaml`) proved correctness only; this
is the first performance comparison.

## Arms

| | Postgres arm | Actors arm |
|---|---|---|
| Chart | `charts/agent-relay` 0.6.53 (this branch's base) | same |
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

### Render and install findings

1. **The combined actors + full-suite profile did not render** on 0.6.53:
   `values-eks-rds-native.yaml` sets `relaycast.postgresCa` (ConfigMap `rds-ca`),
   which the durable-actors backend rejects. `arm-actors-suite.yaml` clears it and
   turns the suite back on. Fixed upstream by #267 (chart 0.6.55).
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

Pending the runs.

## Caveats

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

## Issues filed from this work

- AgentWorkforce/relaycast#649: self-host does not exit on SIGTERM while node
  sockets are open (SIGKILL after the grace period; 12 s vs 0.6 s idle).
- AgentWorkforce/relaycast#650: `delivery.ack` has no reply frame, so acks in
  flight at a restart cause at-least-once redelivery.

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
