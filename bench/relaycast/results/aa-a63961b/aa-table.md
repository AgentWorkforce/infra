### AA decision set (relaycast main; robustness first)

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

