#!/usr/bin/env bash
#
# Proves the load generator is not the bottleneck: producers on the loadgen
# node group drive the no-op target (harness/noop-target.mjs, on the app node
# group) at <rate> msgs/s for <seconds>, split over <producers> shards, using a
# synthetic 40-workspace fixture. Passes when the achieved OK rate is within
# 2 % of the offered rate and corrected send p99 stays under 100 ms.
#
#   bench/relaycast/scripts/loadgen-check.sh <rate> <seconds> <producers>
#
# Runs in its own namespace (rcb-loadgen-check), deleted afterwards.
set -euo pipefail
# Scratch never goes to /tmp on shared hosts.
export TMPDIR="${TMPDIR:-$HOME/.agent-tmp}"; mkdir -p "$TMPDIR"
HERE="$(cd "$(dirname "$0")" && pwd)"; BENCH="$(cd "$HERE/.." && pwd)"
RATE="${1:?rate}"; SECS="${2:?seconds}"; NP="${3:?producers}"
NS=rcb-loadgen-check
IMG="${NODE_IMAGE:-public.ecr.aws/docker/library/node:22-alpine}"
OUT="${RESULTS:-$BENCH/results}/loadgen-check-${RATE}"
export KUBECONFIG="${BENCH_KUBECONFIG:-$HOME/.agent-tmp/relaycast-actors-bench.kubeconfig}"
K=(kubectl -n "$NS")
mkdir -p "$OUT"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl label --local -f - purpose=relaycast-actors-bench -o yaml | kubectl apply -f - >/dev/null
"${K[@]}" create configmap rcb-harness --dry-run=client -o yaml --from-file="$BENCH/harness/lib.mjs" \
  --from-file="$BENCH/harness/producer.mjs" --from-file="$BENCH/harness/noop-target.mjs" | "${K[@]}" apply -f - >/dev/null
node -e '
  const W = 40, P = 10, R = 25, base = "http://rcb-noop:8787";
  const ws = [...Array(W).keys()].map((i) => ({ i, id: "w" + i, key: "k", producers: [...Array(P).keys()].map((p) => ({ name: "p" + p, id: "a" + p, token: "t" })),
    receivers: [...Array(R).keys()].map((r) => "r" + r), backlog: [], channels: [0, 1, 2, 3].map((c) => ({ name: "c" + c, members: ["r0", "r1"] })), nodes: [] }));
  process.stdout.write(JSON.stringify({ version: 1, run: "noop", baseUrl: base, shards: 1, workspaces: ws }));' \
  | "${K[@]}" create secret generic rcb-fixture --from-file=fixture.json=/dev/stdin --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
printf '{"name":"loadgen-check","phases":[{"label":"noop-%s","kind":"mixed","dmShare":0.6,"rate":%s,"durationS":%s,"drainS":30}]}' "$RATE" "$RATE" "$SECS" \
  | "${K[@]}" create configmap rcb-plan --from-file=plan.json=/dev/stdin --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
"${K[@]}" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: rcb-noop}
spec:
  replicas: 3
  selector: {matchLabels: {app: rcb-noop}}
  template:
    metadata: {labels: {app: rcb-noop}}
    spec:
      nodeSelector: {bench/role: app}
      containers:
        - name: noop
          image: ${IMG}
          command: [node, /h/noop-target.mjs]
          resources: {requests: {cpu: "2", memory: 512Mi}}
          volumeMounts: [{name: h, mountPath: /h}]
      volumes: [{name: h, configMap: {name: rcb-harness}}]
---
apiVersion: v1
kind: Service
metadata: {name: rcb-noop}
spec: {selector: {app: rcb-noop}, ports: [{port: 8787}]}
---
apiVersion: v1
kind: Service
metadata: {name: rcb-producer}
spec: {clusterIP: None, selector: {app: rcb-producer}, ports: [{port: 9191}]}
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: rcb-producer}
spec:
  serviceName: rcb-producer
  replicas: ${NP}
  podManagementPolicy: Parallel
  selector: {matchLabels: {app: rcb-producer}}
  template:
    metadata: {labels: {app: rcb-producer}}
    spec:
      nodeSelector: {bench/role: loadgen}
      tolerations: [{key: bench/loadgen, operator: Exists, effect: NoSchedule}]
      containers:
        - name: main
          image: ${IMG}
          command: [sh, -c, 'export RCB_SHARD="\${HOSTNAME##*-}"; exec node --max-old-space-size=6144 /h/producer.mjs']
          env:
            - {name: RCB_FIXTURE, value: /f/fixture.json}
            - {name: RCB_PLAN, value: /p/plan.json}
            - {name: RCB_SHARDS, value: "${NP}"}
            - {name: RCB_STATUS_PORT, value: "9191"}
            - {name: RCB_LINGER_S, value: "86400"}
          resources: {requests: {cpu: "4", memory: 4Gi}}
          volumeMounts: [{name: h, mountPath: /h}, {name: f, mountPath: /f}, {name: p, mountPath: /p}]
      volumes:
        - {name: h, configMap: {name: rcb-harness}}
        - {name: f, secret: {secretName: rcb-fixture}}
        - {name: p, configMap: {name: rcb-plan}}
EOF
"${K[@]}" rollout status deploy/rcb-noop --timeout=5m >/dev/null
"${K[@]}" rollout status statefulset/rcb-producer --timeout=10m >/dev/null
for _ in $(seq 1 $(( (SECS + 120) / 5 ))); do
  done_n=0
  for ((i = 0; i < NP; i++)); do
    "${K[@]}" exec "rcb-producer-$i" -- wget -qO- http://127.0.0.1:9191/status 2>/dev/null | grep -q '"done":true' && done_n=$((done_n + 1))
  done
  ((done_n == NP)) && break; sleep 5
done
for ((i = 0; i < NP; i++)); do "${K[@]}" exec "rcb-producer-$i" -- wget -qO- http://127.0.0.1:9191/result >"$OUT/producer-$i.json"; done
node "$BENCH/harness/report.mjs" "$OUT" --arm noop >/dev/null
node -e '
  const s = require(process.argv[1] + "/summary.json"); const rate = Number(process.argv[2]);
  const sends = s.routes.filter((r) => /POST \/v1\/(dm|channels)/.test(r.route));
  const ok = sends.reduce((a, r) => a + r.rps_ok, 0); const p99 = Math.max(...sends.map((r) => r.corrected_p99));
  const pass = ok >= rate * 0.98 && p99 < 100;
  console.log(JSON.stringify({ offered: rate, achieved_ok_per_s: +ok.toFixed(1), corrected_p99_ms: p99, pass }));' "$OUT" "$RATE" | tee "$OUT/verdict.json"
kubectl delete namespace "$NS" --wait=false >/dev/null
