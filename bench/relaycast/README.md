# Relaycast replay profiles

`plan_replay.py` converts supplied aggregate traffic into bounded 1x, 3x and 10x
steps. It plans traffic only: it performs no HTTP requests, opens no sockets,
creates no fixture and measures no saturation. An executor must consume the
plan using synthetic workspace, agent, message and channel identities in an
approved test environment. Cloud execution requires its own authorization.

```sh
python3 bench/relaycast/plan_replay.py \
  --profile bench/relaycast/profiles/synthetic-example.json
python3 bench/relaycast/test_profile.py
```

Hosted observations belong in ignored `profiles/prod-<date>.json` files kept
locally with mode 0600. Do not commit production identifiers, credentials,
message bodies or hosted usage observations. The tracked example is synthetic.
The input format matches the example; additional descriptive observation fields
are permitted but are not forwarded into plans. Literal invocation IDs and UUID
path segments are normalized and duplicate route groups are merged.

The baseline is `rps_peak_minute_max`, scaled **once**. Route-window average
rates supply the mix and are normalized to that global peak. Provided route
peak estimates are not assumed simultaneous, and their sum is not used as a
substitute for the measured global peak. Different observation windows remain
explicit. Rounded zero shares do not remove observed rare routes.

Per-route burst shape is assumed proportional to each route's average mix;
per-route peaks are not independently measured. A supplied `rps_peak` derived
by multiplying every route average by the same global burst factor adds no
route-specific burst evidence. When the route inventory is incomplete,
normalization redistributes the unlisted tail across the known route mix;
that is a planning assumption, not measured coverage of that tail.

Message counts and WebSocket upgrades are subsets of route requests; adding
them again would double-count load. Production status mix is reference data,
not an instruction to create errors. The hourly curve is retained as supplied;
it does not establish a one-second burst shape. Internal action distributions,
payload sizes, socket lifetime and fixture-specific route bindings still need
executor inputs. A successful plan is not evidence of route coverage.

Unmeasured population defaults are explicitly assumed: five active workspaces,
ten agents per workspace, fifty concurrent WebSockets, ten members per channel,
and no uploads. These are planning inputs, not observed production values.
Default laptop caps are 1000 RPS, 500 sockets, 500 agents and 100 workspaces;
they are protective budgets, not measured laptop capacity. CLI `--max-*`
arguments lower or raise them. If a cap binds, one effective scale preserves
the rate mix. Requested and effective rates/scales are both reported, with
integer population rounding visible. A capped 10x step must not be labelled
an achieved 10x run.

The executing harness must separately report intended versus achieved rates,
per-route latency/error distributions, WebSocket delivery/churn, generator
CPU/backlog, server CPU/memory/throttling/restarts, actor/database contention and
backlog drain. Generator saturation cannot establish backend saturation.
Keep synthetic heavy-load steps separate from the observed replay; passing a
light observed workload does not demonstrate the capacity of the laptop.

## Isolated local execution

The executor requires an infra checkout containing the pinned actor builder
(#268). It creates only `agent-relay-actors-bench`, with its own namespace,
credentials, PVC, kubeconfig and ownership marker. It publishes no host ports
and touches no hosts entries, system CA, Desktop profile or `local-up` state.
An existing cluster is reusable/removable only with matching UID and Docker
socket identity. The final command below removes this benchmark cluster only.

```sh
make local-tools
export PATH="$PWD/.kind/tools:$PATH"
python3 bench/relaycast/fixture.py up --infra-root "$PWD"
# Generate the plan into a private ignored file first (umask 077).
python3 bench/relaycast/fixture.py run --infra-root "$PWD" \
  --plan .kind/bench/production-replay-plan.json --seconds 60
python3 bench/relaycast/fixture.py down --infra-root "$PWD"
```

The generator runs inside this Kind cluster, avoiding a port-forward bottleneck.
The backend has a 1 GiB gateway limit and a 2 GiB actor limit; the generator has
1 GiB. CPU has no explicit container cap; Docker's own limits and co-resident
workloads must accompany every result. Kubelet CPU/memory/restart observations
and the actual image identities are retained in private run receipts.

Replay keeps an **assumed fixed** five workspaces, ten workload agents per
workspace and fifty sockets across rate steps. Each workspace also has a
credential-churn agent; bounded registration/node churn can add identities.
These counts are not measured hosted populations. Use separate population
sweeps before drawing conclusions about production concurrency.

An actor-backed message round trip is required before load. Sockets perform
node registration, heartbeats and delivery acknowledgements. Route bindings
are calibrated once before measurement and remain fixed across steps, so a
later backend failure cannot silently remove a route. Hosted internal actions,
signed Relayfile ingress, terminal/spawn calls and destructive operations have
no substituted cheap endpoint. They are reported as uncovered. A partial
replay cannot be called full production equivalence.

The generator uses open-loop scheduling, a bounded in-flight count, explicit
drops and event-loop/scheduling lag. It distinguishes completions during the
offered window from later drain and reports both throughput denominators.
Latency samples are bounded at 100,000 per route/step. Reports contain route
templates and counters, never tokens or response/message bodies. The complete
fixture is disposable; no result is a release qualification or a collector pass.
