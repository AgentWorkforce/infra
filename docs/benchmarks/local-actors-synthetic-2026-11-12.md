# Local actor dev-runtime synthetic benchmark — 2026-11-12

This report contains synthetic workload measurements only. It contains no hosted traffic observations, production identifiers, credentials or message bodies. Production-derived replay results are deliberately kept in private evidence.

## Setup

- macOS arm64 laptop: 18 host CPUs and 48 GiB RAM; Docker exposed 18 CPUs and about 7.75 GiB RAM. An existing local viewing stack remained co-resident.
- A separate disposable Kind cluster contained one published Relaycast actor gateway and one locally built Terse TypeScript dev sidecar, with local PVC storage.
- Gateway memory limit: 1 GiB; actor limit: 2 GiB; generator limit: 1 GiB. No explicit container CPU limit. Generator in-flight limit: 512 requests.
- Five assumed workspaces, ten workload agents per workspace, fifty sockets and a credential-churn helper agent per workspace. Requests were assigned round-robin across aggregate requests; per-route workspace skew was not independently measured.
- Short fake messages, default API pagination and internal Service HTTP. Ingress TLS was outside this measurement.
- The synthetic mix was 20% delivery polling, 10% heartbeats, 10% roster reads, 20% channel reads, 10% thread reads, 20% channel posts and 10% DMs. These are chosen test weights, not hosted observations.
- Screening SLO: at least 95% of the supported offered rate, at most 1% errors, aggregate request/upgrade p95 at most 200 ms, drain at most 5 seconds, and no generator drops or scheduling pressure.

## Per-step results

Achieved RPS counts all completions during the offered window, including error responses. Errors use all completed requests, including drain. Generator drops occur before a request is issued and are separate from HTTP/network errors. Latencies include requests completing during drain.

Channel-post rates count successful HTTP 201 responses **during the offered window**. Where the original counters did not bind success status to that window, the table gives rigorous lower–upper bounds instead of an invented exact success rate. A 201 response is not proof of downstream message delivery.

| Offered RPS | Window s | Achieved RPS | p50 ms | p95 ms | p99 ms | Errors | Generator drops | Successful channel posts/s | SLO |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 5 | 30 | 4.766 | 59.6 | 128.1 | 140.6 | 0.00% | 0 | 0.966 | pass |
| 10 | 30 | 9.766 | 54.2 | 117.0 | 124.2 | 0.00% | 0 | 1.966 | pass |
| 25 | 30 | 24.631 | 65.3 | 674.9 | 684.3 | 0.00% | 0 | 4.900 | fail |
| 50 | 30 | 49.166 | 66.3 | 1027.3 | 1034.4 | 0.00% | 0 | 9.666 | fail |
| 100 | 30 | 94.314 | 1373.3 | 3596.2 | 3991.6 | 0.00% | 0 | 17.830 | fail |
| 150 | 30 | 121.917 | 2210.3 | 10000.4 | 10001.1 | 8.52% | 327 | 19.397–22.764 | fail |
| 200 | 30 | 120.216 | 3221.5 | 9931.7 | 10001.0 | 4.59% | 1879 | 17.864–19.064 | fail |
| 500 | 60 | 158.182 | 3084.9 | 5307.5 | 5898.7 | 0.00% | 19992 | 13.200 | fail |
| 1000 | 60 | 173.668 | 2897.7 | 3575.1 | 4335.1 | 0.00% | 49060 | 6.666 | fail |
| 2000 | 60 | 223.889 | 2547.5 | 4241.3 | 7935.6 | 32.24% | 106361 | 1.150–1.833 | fail |
| 4000 | 60 | 631.208 | 93.1 | 6180.7 | 7227.4 | 46.11% | 201598 | 1.667–1.700 | fail |

The 200 ms p95 SLO passed at 10 offered requests/s (about 1.97 successful channel posts/s plus DM traffic) and failed at 25 offered requests/s (about 4.90 successful channel posts/s, with channel-post p95 about 683 ms). This brackets this particular latency budget between 10 and 25 requests/s. It is not the maximum successful-response throughput. At 50 and 100 offered requests/s, requests still completed without errors or generator drops, while latency exceeded the budget.

The higher sweeps reached the 512-request in-flight cap. They demonstrate overload behavior under bounded admission, not uncapped backend capacity. The generator loop stayed responsive (about 11–13 ms p99 in these runs), so in-flight backpressure must be distinguished from generator CPU/scheduling saturation. At 2,000 offered requests/s, the actor working set reached about 2 GiB and HTTP 502 responses appeared. No root-cause profile was collected.

These are short screening steps (30 or 60 seconds), not soak tests. Very low rates are affected by finite-window scheduling quantization. The single-process actor dev runtime and chosen laptop budgets do not establish production-cloud capacity.

## Integrity coverage

**Lost, duplicate and reordered messages were not measured. No zero-loss, zero-duplicate or ordering claim is made.**

The harness checked an actor-backed channel-message round trip before and after each campaign, performed WebSocket node registration/heartbeats/delivery ACKs, and observed unique marker arrivals. It did not keep an accepted-send ledger per recipient, count repeat observations, or validate per-recipient sequence order. An empty pending-marker map therefore is not an integrity proof; pending markers can also include failed sends or undrained work.

| Campaign | Unique markers observed at least once | Pending markers at end | Lost | Duplicate | Reordered |
|---|---:|---:|---|---|---|
| synthetic_baseline | 356 | 0 | not measured | not measured | not measured |
| synthetic_final | 3311 | 0 | not measured | not measured | not measured |
| synthetic_mixed | 1561 | 5552 | not measured | not measured | not measured |

A follow-up integrity lane needs accepted message IDs, expected recipients, per-recipient delivery observations, duplicate counters, monotonic sequence checks and a bounded final drain. These checks must pass independently of HTTP status/latency.

## Artifact identity

- Gateway: `ghcr.io/agentworkforce/relaycast-actors-gateway@sha256:6d4f77c4285becac66f56601a36ac3580b19ad37331db4ad2b87f68b2a68abe4`.
- Upstream durable-actors: `5f0a2d62ed08e3060befd9b009333e1f0c3c6cd8`, SDK 0.14.6.
- Relaycast actor source: `4e90b169c60dc0948ac4d4fc86233fedd831fd80`.
- Local Docker image/index ID: `sha256:7645f6daa40414019cbf3f0876120b8c69bf47180101ff14e11bb2895a163354`.
- Export-bound/imported config digest: `sha256:52c2ed7a5fdb272dbe6d865da766a13646f739910744b08095933d446871dcbc`.
- The pinned two-job source build took 331 seconds after fixing Docker plugin discovery. Host build cache was not purged, so this is not a certified cold-build time.

The isolated benchmark cluster and generated credentials were removed afterward. The existing viewing deployment and JHS app hashes were unchanged; its dashboard still returned verified HTTPS 200. Public image/build cache and private receipts were retained.

## Qualification status

This is a benchmark, not full local-stack acceptance. Actors-default `local-up`, the twelve-item functional sheet and the Postgres collector companion have not been qualified by these measurements. Actor collector analytics remains explicitly unsupported/skipped; see [Relaycast #648](https://github.com/AgentWorkforce/relaycast/issues/648). Inbox tuple/object response semantics are a separate known pre-existing defect tracked in [Relaycast #652](https://github.com/AgentWorkforce/relaycast/pull/652); the benchmark did not assert the inbox shape.

Implementation: [planner #266](https://github.com/AgentWorkforce/infra/pull/266), [executor #269](https://github.com/AgentWorkforce/infra/pull/269), [actor default/builder #268](https://github.com/AgentWorkforce/infra/pull/268), [PVC prerequisite #265](https://github.com/AgentWorkforce/infra/pull/265).
