#!/usr/bin/env bash
#
# Time series for recovery analysis: every INTERVAL_S (default 20 s) snapshots
# the producers' cumulative send outcomes and the sinks' cumulative delivery
# counters in <namespace>, appending one CSV row. Differences between rows give
# per-interval OK sends, errors by class, deliveries, socket drops and connected
# sockets, so recovery after each chaos event can be read off.
#
#   bench/relaycast/scripts/sample-series.sh <namespace> <out.csv> [max-seconds]
set -euo pipefail
export TMPDIR="${TMPDIR:-$HOME/.agent-tmp}"; mkdir -p "$TMPDIR"
NS="${1:?namespace}"; OUT="${2:?out csv}"; MAX="${3:-10800}"
INTERVAL="${INTERVAL_S:-20}"
export KUBECONFIG="${BENCH_KUBECONFIG:-$HOME/.agent-tmp/relaycast-actors-bench.kubeconfig}"
[[ -s "$OUT" ]] || echo "ts,ok,err_5xx,err_4xx,err_429,err_timeout,deliveries,ws_drops,connected,sockets" >"$OUT"
end=$(( $(date +%s) + MAX ))
while (( $(date +%s) < end )); do
  ts=$(date +%s)
  p="$(for pod in $(kubectl -n "$NS" get pods -l app=rcb-producer -o name 2>/dev/null); do
        kubectl -n "$NS" exec "${pod#pod/}" -- wget -qO- http://127.0.0.1:9191/result 2>/dev/null | node -e '
          let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);const o={ok:0,e5:0,e4:0,e429:0,e0:0};
          for(const [k,n] of Object.entries(j.status)){const c=k.split(" ").pop();
            if(/^2\d\d$/.test(c))o.ok+=n; else if(c==="429")o.e429+=n; else if(/^5/.test(c))o.e5+=n; else if(/^4/.test(c))o.e4+=n; else if(c==="0")o.e0+=n;}
          console.log([o.ok,o.e5,o.e4,o.e429,o.e0].join(" "))}catch{console.log("0 0 0 0 0")}})' || echo "0 0 0 0 0"
      done | awk '{a+=$1;b+=$2;c+=$3;d+=$4;e+=$5} END{print a+0","b+0","c+0","d+0","e+0}')"
  s="$(for pod in $(kubectl -n "$NS" get pods -l app=rcb-sink -o name 2>/dev/null); do
        kubectl -n "$NS" exec "${pod#pod/}" -- wget -qO- http://127.0.0.1:9090/stats 2>/dev/null | node -e '
          let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);console.log([j.counters.deliver||0,j.drops,j.connected,j.sockets].join(" "))}catch{console.log("0 0 0 0")}})' || echo "0 0 0 0"
      done | awk '{a+=$1;b+=$2;c+=$3;d+=$4} END{print a+0","b+0","c+0","d+0}')"
  echo "$ts,$p,$s" >>"$OUT"
  sleep "$INTERVAL"
done
