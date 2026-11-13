#!/usr/bin/env bash
#
# Runs benchmark suites (plans/cloud-suites.json) against one installed arm,
# from inside the cluster on the tainted loadgen node group.
#
#   ARM=pg|actors NS=<namespace> bench/relaycast/scripts/run-arm.sh setup
#   ARM=... NS=... bench/relaycast/scripts/run-arm.sh suite <suite-name>
#   ARM=... NS=... bench/relaycast/scripts/run-arm.sh coldstart
#   ARM=... NS=... bench/relaycast/scripts/run-arm.sh all
#   ARM=... NS=... bench/relaycast/scripts/run-arm.sh cleanup
#
# Load pods run in the arm's namespace (so the chart's NetworkPolicies admit
# them) and only on nodes labelled bench/role=loadgen. Harness code, plans and
# the production profile ship in a ConfigMap; the fixture (tokens) goes into a
# Secret straight from the driver pod (kubectl exec | kubectl create secret,
# never argv, never printed). Results land in RESULTS (default
# bench/relaycast/results/<arm>/<suite>/) and contain no credentials.
#
# Env:
#   RELAYCAST_URL       in-cluster origin (default http://relaycast.<NS>.svc.cluster.local:8787)
#   INTERNAL_SECRET     <secret>/<key> holding RELAYCAST_INTERNAL_SECRET
#                       (default agent-relay-secrets/relaycast-internal-secret)
#   KILL_SELECTOR       pods deleted by the kill-relaycast chaos action
#   ACTOR_SELECTOR      actors arm: one matching pod is also deleted
#   DB_ID               RDS instance for rds-failover and CloudWatch (default relaycast-actors-bench-pg)
#   NODE_IMAGE          default public.ecr.aws/docker/library/node:22-alpine
set -euo pipefail
# Scratch never goes to /tmp on shared hosts.
export TMPDIR="${TMPDIR:-$HOME/.agent-tmp}"; mkdir -p "$TMPDIR"

HERE="$(cd "$(dirname "$0")" && pwd)"
BENCH="$(cd "$HERE/.." && pwd)"
ARM="${ARM:?ARM=pg|actors}"
NS="${NS:?NS=<namespace>}"
SUITES="$BENCH/plans/cloud-suites.json"
RELAYCAST_URL="${RELAYCAST_URL:-http://relaycast.${NS}.svc.cluster.local:8787}"
INTERNAL_SECRET="${INTERNAL_SECRET:-agent-relay-secrets/relaycast-internal-secret}"
KILL_SELECTOR="${KILL_SELECTOR:-app.kubernetes.io/name=relaycast}"
ACTOR_SELECTOR="${ACTOR_SELECTOR:-}"
DB_ID="${DB_ID:-relaycast-actors-bench-pg}"
NODE_IMAGE="${NODE_IMAGE:-public.ecr.aws/docker/library/node:22-alpine}"
REGION="${AWS_REGION:-us-west-2}"
RESULTS_ROOT="${RESULTS:-$BENCH/results}/${ARM}"
K=(kubectl -n "$NS")

log() { printf '%s [%s] %s\n' "$(date -u +%H:%M:%SZ)" "$ARM" "$*" >&2; }
jqs() { node -e 'const s=require(process.argv[1]); const f=new Function("s", "return " + process.argv[2]); const v=f(s); console.log(typeof v === "string" ? v : JSON.stringify(v));' "$SUITES" "$1"; }

# pod_common <indent>: scheduling and hardening shared by every load pod.
pod_common() {
  local p; p="$(printf '%*s' "$1" '')"
  printf '%snodeSelector: {bench/role: loadgen}\n' "$p"
  printf '%stolerations: [{key: bench/loadgen, operator: Exists, effect: NoSchedule}]\n' "$p"
  printf '%sautomountServiceAccountToken: false\n' "$p"
  printf '%ssecurityContext: {runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000, seccompProfile: {type: RuntimeDefault}}\n' "$p"
}
# apply_or_render: kubectl apply, or print the manifest when RENDER_ONLY=1.
apply_or_render() { if [[ -n "${RENDER_ONLY:-}" ]]; then cat; echo '---'; else "${K[@]}" apply -f - >/dev/null; fi; }
CONTAINER_SEC='securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}'

cmd_setup() {
  log "harness ConfigMap"
  "${K[@]}" create configmap rcb-harness --dry-run=client -o yaml \
    --from-file="$BENCH/harness/lib.mjs" --from-file="$BENCH/harness/provision.mjs" --from-file="$BENCH/harness/sink.mjs" \
    --from-file="$BENCH/harness/producer.mjs" --from-file="$BENCH/harness/coldstart.mjs" \
    --from-file=prod-2026-11-12.json="$BENCH/profiles/prod-2026-11-12.json" | "${K[@]}" apply -f - >/dev/null
  log "driver pod"
  driver_manifest | apply_or_render
  "${K[@]}" wait --for=condition=Ready pod/rcb-driver --timeout=5m >/dev/null
  "${K[@]}" exec rcb-driver -- wget -qO- "${RELAYCAST_URL}/health"; echo
}

driver_manifest() {
  local sname="${INTERNAL_SECRET%%/*}" skey="${INTERNAL_SECRET#*/}"
  cat <<EOF
apiVersion: v1
kind: Pod
metadata: {name: rcb-driver, labels: {app: rcb-driver, purpose: relaycast-actors-bench}}
spec:
$(pod_common 2)
  containers:
    - name: driver
      image: ${NODE_IMAGE}
      command: [sleep, infinity]
      ${CONTAINER_SEC}
      resources: {requests: {cpu: "1", memory: 1Gi}, limits: {memory: 4Gi}}
      volumeMounts:
        - {name: harness, mountPath: /bench/harness}
        - {name: profiles, mountPath: /bench/profiles}
        - {name: internal, mountPath: /secrets, readOnly: true}
        - {name: work, mountPath: /work}
  volumes:
    - {name: harness, configMap: {name: rcb-harness, items: [{key: lib.mjs, path: lib.mjs}, {key: provision.mjs, path: provision.mjs}, {key: sink.mjs, path: sink.mjs}, {key: producer.mjs, path: producer.mjs}, {key: coldstart.mjs, path: coldstart.mjs}]}}
    - {name: profiles, configMap: {name: rcb-harness, items: [{key: prod-2026-11-12.json, path: prod-2026-11-12.json}]}}
    - {name: internal, secret: {secretName: ${sname}, items: [{key: ${skey}, path: internal}]}}
    - {name: work, emptyDir: {}}
EOF
}

# Runs a suite's fixture in the driver and stores it as Secret rcb-fixture.
provision() {
  local suite="$1" out="$2" run="$3" shards="$4" envs
  envs="$(jqs "Object.entries(s.suites.find(x=>x.name==='$suite').fixture).map(([k,v])=>k+'='+v).join(' ')")"
  log "provision $suite ($envs)"
  # shellcheck disable=SC2086
  "${K[@]}" exec rcb-driver -- env RCB_BASE_URL="$RELAYCAST_URL" RCB_INTERNAL_SECRET_FILE=/secrets/internal RCB_RUN="$run" \
    RCB_FIXTURE=/work/fixture.json RCB_OUT=/work/provision.json RCB_SINK_SHARDS="$shards" $envs \
    node /bench/harness/provision.mjs 2>&1 | tail -2 >&2
  "${K[@]}" exec rcb-driver -- cat /work/provision.json >"$out/provision.json"
  "${K[@]}" delete secret rcb-fixture --ignore-not-found >/dev/null
  # gzip keeps 10k-node fixtures under the 1 MiB Secret limit.
  "${K[@]}" exec rcb-driver -- sh -c 'gzip -9c /work/fixture.json' | "${K[@]}" create secret generic rcb-fixture --from-file=fixture.json.gz=/dev/stdin >/dev/null
  "${K[@]}" exec rcb-driver -- rm -f /work/fixture.json
}

statefulset() { # name replicas port command-env...
  local name="$1" replicas="$2" port="$3" script="$4" extra_env="$5" cpu="$6" mem="$7"
  apply_or_render <<EOF
apiVersion: v1
kind: Service
metadata: {name: ${name}, labels: {purpose: relaycast-actors-bench}}
spec: {clusterIP: None, selector: {app: ${name}}, ports: [{name: http, port: ${port}}]}
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: ${name}, labels: {purpose: relaycast-actors-bench}}
spec:
  serviceName: ${name}
  replicas: ${replicas}
  podManagementPolicy: Parallel
  selector: {matchLabels: {app: ${name}}}
  template:
    metadata: {labels: {app: ${name}, purpose: relaycast-actors-bench}}
    spec:
$(pod_common 6)
      terminationGracePeriodSeconds: 5
      containers:
        - name: main
          image: ${NODE_IMAGE}
          command: [sh, -c, 'export RCB_SHARD="\${HOSTNAME##*-}"; exec node --max-old-space-size=6144 /bench/harness/${script}']
          ${CONTAINER_SEC}
          env:
            - {name: RCB_FIXTURE, value: /fixture/fixture.json.gz}
            - {name: UV_THREADPOOL_SIZE, value: "16"}
${extra_env}
          resources: {requests: {cpu: "${cpu}", memory: ${mem}}, limits: {memory: 8Gi}}
          volumeMounts:
            - {name: harness, mountPath: /bench/harness}
            - {name: profiles, mountPath: /bench/profiles}
            - {name: plans, mountPath: /bench/plans}
            - {name: fixture, mountPath: /fixture, readOnly: true}
      volumes:
        - {name: harness, configMap: {name: rcb-harness, items: [{key: lib.mjs, path: lib.mjs}, {key: sink.mjs, path: sink.mjs}, {key: producer.mjs, path: producer.mjs}]}}
        - {name: profiles, configMap: {name: rcb-harness, items: [{key: prod-2026-11-12.json, path: prod-2026-11-12.json}]}}
        - {name: plans, configMap: {name: rcb-plan, optional: true}}
        - {name: fixture, secret: {secretName: rcb-fixture}}
EOF
}

wait_ready() { # statefulset replicas path port [max-seconds]
  local name="$1" n="$2" path="$3" port="$4" max="${5:-1800}" i ok
  "${K[@]}" rollout status "statefulset/$name" --timeout=15m >/dev/null
  for _ in $(seq 1 $((max / 5))); do
    ok=0
    for ((i = 0; i < n; i++)); do
      [[ "$("${K[@]}" exec "$name-$i" -- wget -qO- "http://127.0.0.1:${port}${path}" 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);console.log(j.ready===true||j.done===true?1:0)}catch{console.log(0)}})')" == 1 ]] && ok=$((ok + 1))
    done
    ((ok == n)) && return 0
    sleep 5
  done
  log "$name not ready"; return 1
}

metrics_loop() { # out-file
  local out="$1"
  echo "ts,kind,namespace,name,container,cpu_m,mem_mi" >"$out"
  while true; do
    local ts; ts="$(date -u +%s)"
    kubectl top pod -A --containers --no-headers 2>/dev/null | awk -v ts="$ts" '{gsub("m","",$4); gsub("Mi","",$5); print ts",pod,"$1","$2","$3","$4","$5}' >>"$out" || true
    kubectl top node --no-headers 2>/dev/null | awk -v ts="$ts" '{gsub("m","",$2); gsub("Mi","",$4); print ts",node,,"$1",,"$2","$4}' >>"$out" || true
    "${K[@]}" get pods --no-headers 2>/dev/null | awk -v ts="$ts" -v ns="$NS" '{print ts",podcount,"ns","$1",,"($3=="Running"),""}' >>"$out" || true
    sleep 15
  done
}

cloudwatch() { # start-epoch end-epoch out
  local q
  q='[{"Id":"cpu","MetricStat":{"Metric":{"Namespace":"AWS/RDS","MetricName":"CPUUtilization","Dimensions":[{"Name":"DBInstanceIdentifier","Value":"'"$DB_ID"'"}]},"Period":60,"Stat":"Average"}},
{"Id":"conns","MetricStat":{"Metric":{"Namespace":"AWS/RDS","MetricName":"DatabaseConnections","Dimensions":[{"Name":"DBInstanceIdentifier","Value":"'"$DB_ID"'"}]},"Period":60,"Stat":"Maximum"}},
{"Id":"wiops","MetricStat":{"Metric":{"Namespace":"AWS/RDS","MetricName":"WriteIOPS","Dimensions":[{"Name":"DBInstanceIdentifier","Value":"'"$DB_ID"'"}]},"Period":60,"Stat":"Average"}},
{"Id":"riops","MetricStat":{"Metric":{"Namespace":"AWS/RDS","MetricName":"ReadIOPS","Dimensions":[{"Name":"DBInstanceIdentifier","Value":"'"$DB_ID"'"}]},"Period":60,"Stat":"Average"}},
{"Id":"wlat","MetricStat":{"Metric":{"Namespace":"AWS/RDS","MetricName":"WriteLatency","Dimensions":[{"Name":"DBInstanceIdentifier","Value":"'"$DB_ID"'"}]},"Period":60,"Stat":"Average"}},
{"Id":"mem","MetricStat":{"Metric":{"Namespace":"AWS/RDS","MetricName":"FreeableMemory","Dimensions":[{"Name":"DBInstanceIdentifier","Value":"'"$DB_ID"'"}]},"Period":60,"Stat":"Minimum"}},
{"Id":"dbload","MetricStat":{"Metric":{"Namespace":"AWS/RDS","MetricName":"DBLoad","Dimensions":[{"Name":"DBInstanceIdentifier","Value":"'"$DB_ID"'"}]},"Period":60,"Stat":"Average"}}]'
  aws --region "$REGION" cloudwatch get-metric-data --metric-data-queries "$q" \
    --start-time "$1" --end-time "$2" --output json >"$3" 2>/dev/null || log "cloudwatch fetch failed"
}

chaos() { # action out
  local action="$1" out="$2" t
  t="$(date +%s%3N)"
  case "$action" in
    kill-relaycast)
      "${K[@]}" get pods -l "$KILL_SELECTOR" -o name >>"$out.pods" || true
      "${K[@]}" delete pod -l "$KILL_SELECTOR" --wait=false >/dev/null
      ;;
    kill-actor)
      # One busy actor host (sandbox namespace <NS>-agent-relay).
      local an="${ACTOR_NS:-${NS}-agent-relay}" p
      p="$(kubectl -n "$an" get pods -l "${ACTOR_SELECTOR:-terse.ai/purpose=actor}" --field-selector=status.phase=Running -o name | head -1)"
      if [[ -n "$p" ]]; then echo "$p" >>"$out.pods"; kubectl -n "$an" delete "$p" --wait=false >/dev/null; else log "no actor host to kill"; fi ;;
    node-drain)
      # Drain the app node hosting relaycast (PG) or the gateway (actors),
      # then uncordon after 5 min; DaemonSets and emptyDir are tolerated.
      local node; node="$("${K[@]}" get pods -l "$KILL_SELECTOR" -o jsonpath='{.items[0].spec.nodeName}')"
      echo "node/$node" >>"$out.pods"
      kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --force --timeout=120s >/dev/null 2>&1 || true
      ( sleep 300; kubectl uncordon "$node" >/dev/null 2>&1 ) & ;;
    rds-failover)
      aws --region "$REGION" rds reboot-db-instance --db-instance-identifier "$DB_ID" --force-failover >/dev/null ;;
    profile:*)
      NS_SANDBOX="${NS}-agent-relay" "$HERE/profile-actor.sh" "${action#profile:}" "${out%/*}/profile-$(date +%H%M%S)" || log "profile failed" ;;
    *) log "unknown chaos $action"; return 1 ;;
  esac
  printf '{"action":"%s","at":%s}\n' "$action" "$t" >>"$out"
  log "chaos $action fired"
}

# breaks <dir>: prints "break" when the step in <dir> crosses breakOn.
breaks() {
  node -e '
    const s = require(process.argv[1] + "/summary.json"); const b = require(process.argv[2]).breakOn;
    const sends = s.routes.filter(r => /POST \/v1\/(dm|channels\/:name\/messages)/.test(r.route));
    const p99 = Math.max(0, ...sends.map(r => r.corrected_p99 || 0));
    const req = sends.reduce((a, r) => a + r.requests, 0), ok = sends.reduce((a, r) => a + r.ok, 0);
    const lost = s.integrity.reduce((a, r) => a + r.lost + r.duplicate, 0);
    const err = req ? (req - ok) / req : 1;
    const why = [p99 > b.correctedP99Ms && "p99 " + p99, err > b.errorRate && "errors " + err.toFixed(4), lost > b.lost && "lost/dup " + lost].filter(Boolean);
    console.log(why.length ? "break: " + why.join(", ") : "ok");' "$1" "$SUITES"
}

run_phases() { # suite dir phases(json array) nprod nsink chaos(json)
  local suite="$1" dir="$2" phases="$3" np="$4" ns_="$5" chaosj="$6" i
  mkdir -p "$dir"
  "${K[@]}" create configmap rcb-plan --dry-run=client -o yaml \
    --from-literal=plan.json="{\"name\":\"$suite\",\"phases\":$phases}" | "${K[@]}" apply -f - >/dev/null
  local sinks="" ; for ((i = 0; i < ns_; i++)); do sinks+="http://rcb-sink-$i.rcb-sink:9090,"; done
  "${K[@]}" delete statefulset rcb-producer --ignore-not-found --wait=true >/dev/null
  statefulset rcb-producer "$np" 9191 producer.mjs "            - {name: RCB_PLAN, value: /bench/plans/plan.json}
            - {name: RCB_SHARDS, value: \"$np\"}
            - {name: RCB_STATUS_PORT, value: \"9191\"}
            - {name: RCB_LINGER_S, value: \"86400\"}
            - {name: RCB_SINK_URLS, value: \"${sinks%,}\"}" 4 4Gi
  "${K[@]}" rollout status statefulset/rcb-producer --timeout=10m >/dev/null
  local chaos_pids=()
  if [[ -n "$chaosj" && "$chaosj" != "[]" ]]; then
    while IFS=$'\t' read -r cph cat cact; do
      # Status via kubectl exec (a long-lived port-forward can die silently and
      # leave the trigger polling forever, which lost the first action twice).
      ( STATUS_CMD="kubectl -n $NS exec rcb-producer-0 -- wget -qO- http://127.0.0.1:9191/status" \
          "$HERE/at-phase.sh" "unused" "$cph" "$cat" -- true >>"$dir/chaos-trigger.log" 2>&1 \
          && chaos "$cact" "$dir/chaos.jsonl" >>"$dir/chaos-trigger.log" 2>&1 ) </dev/null &
      chaos_pids+=($!)
    done < <(node -e 'for (const c of JSON.parse(process.argv[1])) console.log([c.phase, c.atS, c.action].join("\t"))' "$chaosj")
  fi
  local budget; budget="$(node -e 'console.log(JSON.parse(process.argv[1]).reduce((a,p)=>a+p.durationS+(p.drainS??60)+(p.offlineHoldS??0),0)+900)' "$phases")"
  wait_ready rcb-producer "$np" /status 9191 "$budget"
  for ((i = 0; i < np; i++)); do "${K[@]}" exec "rcb-producer-$i" -- wget -qO- http://127.0.0.1:9191/result >"$dir/producer-$i.json"; done
  ((${#chaos_pids[@]})) && wait "${chaos_pids[@]}" 2>/dev/null || true
  quiesce "$ns_" "$dir"
  for ((i = 0; i < ns_; i++)); do "${K[@]}" exec "rcb-sink-$i" -- wget -qO- http://127.0.0.1:9090/stats >"$dir/sink-$i.json"; done
  node "$BENCH/harness/report.mjs" "$dir" --arm "$ARM" >/dev/null
}

# quiesce <nsinks> <dir>: wait until the sinks stop receiving deliveries (no
# change for QUIET_S, default 60 s; at most QUIESCE_MAX_S, default 900 s) so
# integrity is judged on what was delivered, not on what was still queued.
quiesce() {
  local n="$1" dir="$2" prev=-1 cur same=0 waited=0 i
  local quiet="${QUIET_S:-60}" max="${QUIESCE_MAX_S:-900}"
  while ((waited < max)); do
    cur=0
    for ((i = 0; i < n; i++)); do
      cur=$((cur + $("${K[@]}" exec "rcb-sink-$i" -- wget -qO- http://127.0.0.1:9090/stats 2>/dev/null \
        | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).counters.deliver||0)}catch{console.log(0)}})')))
    done
    if ((cur == prev)); then same=$((same + 15)); else same=0; fi
    ((same >= quiet)) && break
    prev=$cur; sleep 15; waited=$((waited + 15))
  done
  printf '{"quiesced_after_s":%s,"deliveries":%s,"capped":%s}\n' "$waited" "$cur" "$((waited >= max))" >"$dir/quiesce.json"
  log "quiesced after ${waited}s ($cur deliveries)"
}

cmd_suite() {
  local suite="$1" run dir np ns_ stepped phases after chaosj start
  np="$(jqs "s.suites.find(x=>x.name==='$suite').producers")"
  ns_="$(jqs "s.suites.find(x=>x.name==='$suite').sinks")"
  stepped="$(jqs "!!s.suites.find(x=>x.name==='$suite').stepped")"
  chaosj="$(jqs "s.suites.find(x=>x.name==='$suite').chaos||[]")"
  run="${ARM}$(date +%m%d%H%M)"
  dir="$RESULTS_ROOT/$suite"; rm -rf "$dir"; mkdir -p "$dir"
  start="$(date -u +%s)"
  metrics_loop "$dir/metrics.csv" & local mpid=$!
  provision "$suite" "$dir" "$run" "$ns_"
  "${K[@]}" delete statefulset rcb-sink --ignore-not-found --wait=true >/dev/null
  statefulset rcb-sink "$ns_" 9090 sink.mjs "            - {name: RCB_PORT, value: \"9090\"}
            - {name: RCB_READY_FRACTION, value: \"${SINK_READY_FRACTION:-0.95}\"}" 2 4Gi
  wait_ready rcb-sink "$ns_" /ready 9090
  if [[ "$stepped" == true ]]; then
    local n label verdict
    n="$(jqs "s.suites.find(x=>x.name==='$suite').phases.length")"
    for ((k = 0; k < n; k++)); do
      label="$(jqs "s.suites.find(x=>x.name==='$suite').phases[$k].label")"
      log "$suite step $label"
      run_phases "$suite" "$dir/$label" "$(jqs "[s.suites.find(x=>x.name==='$suite').phases[$k]]")" "$np" "$ns_" "[]"
      verdict="$(breaks "$dir/$label")"
      echo "$label $verdict" >>"$dir/steps.txt"; log "$label: $verdict"
      [[ "$verdict" == ok ]] || break
    done
    after="$(jqs "s.suites.find(x=>x.name==='$suite').after||[]")"
    [[ "$after" != "[]" ]] && run_phases "$suite" "$dir/after" "$after" "$np" "$ns_" "[]"
  else
    phases="$(jqs "s.suites.find(x=>x.name==='$suite').phases")"
    run_phases "$suite" "$dir/all" "$phases" "$np" "$ns_" "$chaosj"
  fi
  kill "$mpid" 2>/dev/null || true
  "${K[@]}" delete statefulset rcb-producer rcb-sink --ignore-not-found >/dev/null
  "${K[@]}" delete secret rcb-fixture --ignore-not-found >/dev/null
  cloudwatch "$start" "$(date -u +%s)" "$dir/rds-cloudwatch.json"
  printf '{"suite":"%s","arm":"%s","start":%s,"end":%s}\n' "$suite" "$ARM" "$start" "$(date -u +%s)" >"$dir/window.json"
  log "$suite done -> $dir"
}

cmd_coldstart() {
  local dir="$RESULTS_ROOT/coldstart"; mkdir -p "$dir"
  "${K[@]}" exec rcb-driver -- env RCB_BASE_URL="$RELAYCAST_URL" RCB_INTERNAL_SECRET_FILE=/secrets/internal \
    RCB_RUN="${ARM}cold$(date +%H%M)" RCB_COLD_WORKSPACES="${COLD_WORKSPACES:-20}" RCB_IDLE_WAIT_S="${IDLE_WAIT_S:-180}" \
    RCB_OUT=/work/coldstart.json node /bench/harness/coldstart.mjs 2>&1 | tail -1 >&2
  "${K[@]}" exec rcb-driver -- cat /work/coldstart.json >"$dir/coldstart.json"
}

cmd_cleanup() {
  "${K[@]}" delete statefulset rcb-producer rcb-sink --ignore-not-found >/dev/null
  "${K[@]}" delete svc rcb-producer rcb-sink --ignore-not-found >/dev/null
  "${K[@]}" delete pod rcb-driver --ignore-not-found >/dev/null
  "${K[@]}" delete secret rcb-fixture --ignore-not-found >/dev/null
  "${K[@]}" delete configmap rcb-harness rcb-plan --ignore-not-found >/dev/null
}

case "${1:-}" in
  setup) cmd_setup ;;
  suite) shift; for s in "$@"; do cmd_suite "$s"; done ;;
  coldstart) cmd_coldstart ;;
  all) cmd_setup; for s in $(jqs 's.suites.map(x=>x.name).join(" ")'); do cmd_suite "$s"; done; cmd_coldstart ;;
  cleanup) cmd_cleanup ;;
  render) RENDER_ONLY=1; driver_manifest; echo '---'
    statefulset rcb-sink 2 9090 sink.mjs "            - {name: RCB_PORT, value: \"9090\"}" 2 4Gi
    statefulset rcb-producer 2 9191 producer.mjs "            - {name: RCB_PLAN, value: /bench/plans/plan.json}" 4 4Gi ;;
  *) echo "usage: ARM=pg|actors NS=<ns> $0 setup|suite <name...>|coldstart|all|cleanup" >&2; exit 2 ;;
esac
