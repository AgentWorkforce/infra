#!/usr/bin/env bash
# Every 5 s, records relaycast's TCP sockets to PostgreSQL (:5432) with their
# remote address and state, for the RDS-failover exit test (old-primary sockets
# must disappear without a restart).   pg-sockets-watch.sh <ns> <out> [seconds]
set -euo pipefail
export TMPDIR="${TMPDIR:-$HOME/.agent-tmp}"; mkdir -p "$TMPDIR"
export KUBECONFIG="${KUBECONFIG:-$HOME/.agent-tmp/relaycast-actors-bench.kubeconfig}"
NS="${1:?ns}"; OUT="${2:?out}"; MAX="${3:-2400}"
end=$(( $(date +%s) + MAX ))
echo "ts,pod,restarts,remote,state,count" >"$OUT"
while (( $(date +%s) < end )); do
  ts=$(date +%s)
  pod="$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=relaycast --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name} {.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || true)"
  if [[ -n "$pod" ]]; then
    kubectl -n "$NS" exec "${pod% *}" -c relaycast -- cat /proc/net/tcp 2>/dev/null | awk -v ts="$ts" -v p="${pod% *}" -v r="${pod#* }" '
      NR>1 { split($3,a,":"); if (a[2]=="1538") { split(a[1],h,""); ip=strtonum("0x" h[7] h[8]) "." strtonum("0x" h[5] h[6]) "." strtonum("0x" h[3] h[4]) "." strtonum("0x" h[1] h[2]); st=$4; c[ip "," st]++ } }
      END { for (k in c) print ts "," p "," r "," k "," c[k] }' >>"$OUT" || true
  fi
  sleep 5
done
