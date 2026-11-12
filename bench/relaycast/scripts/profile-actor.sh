#!/usr/bin/env bash
#
# Profiles the busiest Workspace actor host on the actors arm for N seconds.
#
#   NS_SANDBOX=arm-actors-agent-relay bench/relaycast/scripts/profile-actor.sh <seconds> <out-prefix>
#
# Picks the actor host with the most invocations in the last minute. Writes:
#   <out-prefix>.cpu.json          bun-profile.mjs output (CPU by category and
#                                  function, GC events from the Heap domain)
#   <out-prefix>.invocations.json  per-method queue wait / execution / state
#                                  publication from the host's structured logs
#   <out-prefix>.memory.csv        the pod's working set every 5 s
set -euo pipefail
SECS="${1:?seconds}"; OUT="${2:?out prefix}"
NS="${NS_SANDBOX:-arm-actors-agent-relay}"
HERE="$(cd "$(dirname "$0")" && pwd)"
K=(kubectl -n "$NS")

# The busiest actor host: most "invocation completed" lines in the last 60 s.
pod="" best=0
for p in $("${K[@]}" get pods --no-headers -o custom-columns=:metadata.name); do
  n="$("${K[@]}" logs "$p" --since=60s 2>/dev/null | grep -c '"actor host invocation completed"' || true)"
  if (( n > best )); then best="$n"; pod="$p"; fi
done
[[ -n "$pod" ]] || { echo "no busy actor host" >&2; exit 1; }
echo "profiling $pod for ${SECS}s" >&2

( end=$(( $(date +%s) + SECS )); echo "ts,working_set_mib" >"$OUT.memory.csv"
  while (( $(date +%s) < end )); do
    m="$("${K[@]}" exec "$pod" -- sh -c 'cat /sys/fs/cgroup/memory.current 2>/dev/null || cat /sys/fs/cgroup/memory/memory.usage_in_bytes' 2>/dev/null || echo 0)"
    echo "$(date +%s),$(( m / 1048576 ))" >>"$OUT.memory.csv"; sleep 5
  done ) &
mem=$!
# In-process CPU sampling needs Bun started with --inspect; the durable-actors
# host starts Bun in spares before an actor (and its env) is assigned and has
# no flag passthrough, so it is attempted only when the inspector answers.
if "${K[@]}" exec "$pod" -- bun -e 'const w=new WebSocket("ws://127.0.0.1:6499/rcb");w.onopen=()=>process.exit(0);w.onerror=()=>process.exit(1);setTimeout(()=>process.exit(1),2000)' 2>/dev/null; then
  "${K[@]}" exec -i "$pod" -- sh -c 'cat > /tmp/bun-profile.mjs' <"$HERE/../harness/bun-profile.mjs"
  "${K[@]}" exec "$pod" -- bun /tmp/bun-profile.mjs ws://127.0.0.1:6499/rcb "$SECS" >"$OUT.cpu.json"
else
  echo '{"unavailable":"actor Bun process has no inspector (no flag passthrough in the durable-actors host)"}' >"$OUT.cpu.json"
  sleep "$SECS"
fi
wait "$mem" 2>/dev/null || true

# Invocation phases (ms from invocation start) over the profiled window.
"${K[@]}" logs "$pod" --since="$((SECS + 30))s" 2>/dev/null | node -e '
  const lines = require("fs").readFileSync(0, "utf8").split("\n");
  const by = {};
  for (const l of lines) {
    let d; try { d = JSON.parse(l); } catch { continue; }
    if (d.message !== "actor host invocation completed") continue;
    const m = d.method || "?";
    const queue = d.queue_admitted_at_ms ?? 0, done = d.completed_at_ms ?? 0;
    const exec = (d.actor_execution_completed_at_ms ?? done) - (d.pending_commit_resolved_at_ms ?? queue);
    const publish = done - (d.actor_execution_completed_at_ms ?? done);
    (by[m] ||= []).push({ queue, exec, publish, total: done });
  }
  const q = (a, p) => { const s = [...a].sort((x, y) => x - y); return s.length ? +s[Math.min(s.length - 1, Math.floor(p * s.length))].toFixed(1) : null; };
  const out = {};
  for (const [m, a] of Object.entries(by)) out[m] = { n: a.length,
    queue_p50: q(a.map((x) => x.queue), .5), queue_p95: q(a.map((x) => x.queue), .95),
    exec_p50: q(a.map((x) => x.exec), .5), exec_p95: q(a.map((x) => x.exec), .95),
    publish_p50: q(a.map((x) => x.publish), .5), total_p50: q(a.map((x) => x.total), .5) };
  console.log(JSON.stringify(out));' >"$OUT.invocations.json"
echo "wrote $OUT.{cpu,invocations}.json $OUT.memory.csv" >&2
