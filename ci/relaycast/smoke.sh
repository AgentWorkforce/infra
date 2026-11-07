#!/usr/bin/env bash
# Live kind smoke for charts/relaycast. Proves, against the pinned image:
#   - upgrade from the published 0.1.0 keeps workspaces, keys and history
#   - anonymous POST /v1/workspaces is refused; the documented first-run
#     bootstrap (kubectl exec -> /internal/workspaces) creates a workspace
#   - register -> /v1/node/ws -> DM -> RECEIVE (+ack), observer stream, search
#   - a pod restart keeps state
#   - a backup CronJob run, then ci/relaycast/restore.sh, rolls data back
# Usage: ci/relaycast/smoke.sh   (uses the current kubectl context, or
# creates kind cluster $CLUSTER when CREATE_CLUSTER=1)
# Env: FROM_VERSION (published chart to upgrade from, default 0.1.0; empty
# skips the upgrade step), NS (default relaycast-smoke), SMOKE_HELM_ARGS
# (extra helm args for the chart under test, e.g. a locally built image).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HERE="$ROOT/ci/relaycast"
NS=${NS:-relaycast-smoke}
RELEASE=${RELEASE:-rc}
FROM_VERSION=${FROM_VERSION-0.1.0}
PORT=${PORT:-18787}
CHART="$ROOT/charts/relaycast"
WORK=$(mktemp -d)
chmod 700 "$WORK"
PF_PID=
cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT
K="kubectl -n $NS"
SEL="app.kubernetes.io/name=relaycast,app.kubernetes.io/instance=$RELEASE"

if [ "${CREATE_CLUSTER:-0}" = 1 ]; then
  CLUSTER=${CLUSTER:-relaycast-smoke}
  kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --wait 120s
  kubectl config use-context "kind-$CLUSTER" >/dev/null
fi
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

forward() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
  $K wait --for=condition=Ready pod -l "$SEL" --timeout=300s >/dev/null
  $K port-forward "svc/$RELEASE-relaycast" "$PORT:8787" >"$WORK/pf.log" 2>&1 &
  PF_PID=$!
  for _ in $(seq 60); do curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && return 0; sleep 1; done
  cat "$WORK/pf.log"; return 1
}
smoke() { B="http://127.0.0.1:$PORT" STATE="$WORK/state-$1.json" node "$HERE/smoke.mjs" "$2"; }
status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

# Kind-only throwaway secrets, generated in place and never printed.
umask 077
openssl rand -hex 32 >"$WORK/internal"; openssl rand -hex 32 >"$WORK/bootstrap"
$K create secret generic relaycast-secrets \
  --from-file=internal-secret="$WORK/internal" --from-file=workspace-bootstrap-secret="$WORK/bootstrap" \
  --dry-run=client -o yaml | $K apply -f - >/dev/null

VALUES=(--set baseUrl=https://relay.example.com --set existingSecret=relaycast-secrets
  --set backup.enabled=true --set backup.keep=2)
read -ra EXTRA <<<"${SMOKE_HELM_ARGS:-}"
VALUES+=("${EXTRA[@]}")

if [ -n "$FROM_VERSION" ]; then
  echo "--- install published relaycast $FROM_VERSION"
  helm repo add agentworkforce https://agentworkforce.github.io/infra --force-update >/dev/null 2>&1
  helm repo update agentworkforce >/dev/null
  helm install "$RELEASE" agentworkforce/relaycast --version "$FROM_VERSION" -n "$NS" \
    --set baseUrl=https://relay.example.com --wait --timeout 5m >/dev/null
  forward
  smoke old seed-anon
  echo "--- upgrade to $(sed -n 's/^version: *//p' "$CHART/Chart.yaml") (this checkout)"
  helm upgrade "$RELEASE" "$CHART" -n "$NS" "${VALUES[@]}" --wait --timeout 5m >/dev/null
  forward
  smoke old upgrade
else
  helm install "$RELEASE" "$CHART" -n "$NS" "${VALUES[@]}" --wait --timeout 5m >/dev/null
  forward
fi

echo "--- edge checks"
code=$(status -XPOST -H 'content-type: application/json' -d '{"name":"x"}' "http://127.0.0.1:$PORT/v1/workspaces")
[ "$code" = 404 ] && echo "PASS anonymous POST /v1/workspaces -> 404" || { echo "FAIL anonymous create -> $code"; exit 1; }

echo "--- first-run bootstrap (README)"
$K exec "deploy/$RELEASE-relaycast" -- node -e '
  const s = require("fs").readFileSync("/run/secrets/relaycast/internal-secret", "utf8").trim();
  fetch("http://127.0.0.1:8787/internal/workspaces", { method: "POST",
    headers: { authorization: "Bearer " + s, "content-type": "application/json" },
    body: JSON.stringify({ name: process.argv[1] }) })
    .then(async (r) => { process.stdout.write(await r.text() + "\n"); process.exitCode = r.status === 201 ? 0 : 1; });
' smoke-team >"$WORK/workspace.json"
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[2], JSON.parse(fs.readFileSync(process.argv[1])).data.api_key)' \
  "$WORK/workspace.json" "$WORK/ws.key"
echo "PASS first-run bootstrap created a workspace"

B="http://127.0.0.1:$PORT" STATE="$WORK/state-new.json" WORKSPACE_KEY_FILE="$WORK/ws.key" node "$HERE/smoke.mjs" full

echo "--- restart"
$K rollout restart "deploy/$RELEASE-relaycast" >/dev/null
$K rollout status "deploy/$RELEASE-relaycast" --timeout=300s >/dev/null
forward
smoke new restart
[ -z "$FROM_VERSION" ] || smoke old restart

echo "--- backup + restore"
$K create job --from="cronjob/$RELEASE-relaycast-backup" smoke-backup >/dev/null
$K wait --for=condition=complete job/smoke-backup --timeout=300s >/dev/null
BACKUP=$($K logs job/smoke-backup | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s.trim().split("\n").pop()).backup))')
echo "PASS backup $BACKUP"
KEY=$(cat "$WORK/ws.key")
AT=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).at)' "$WORK/state-new.json")
code=$(status -XPOST -H "authorization: Bearer $AT" -H 'content-type: application/json' \
  -d '{"text":"after-backup-quokka"}' "http://127.0.0.1:$PORT/v1/channels/general/messages")
[ "$code" = 201 ] || { echo "FAIL post-backup message -> $code"; exit 1; }
# search_has <marker>: 0 if found, 1 if absent; a failed request aborts.
search_has() {
  local body
  body=$(curl -sf -H "authorization: Bearer $KEY" "http://127.0.0.1:$PORT/v1/search?q=quokka") \
    || { echo "FAIL search request failed"; exit 1; }
  grep -q '"ok":true' <<<"$body" || { echo "FAIL search response not ok"; exit 1; }
  grep -q "$1" <<<"$body"
}
search_has after-backup-quokka || { echo "FAIL post-backup message is not searchable before the restore"; exit 1; }
echo "PASS post-backup message searchable before restore"
kill "$PF_PID"; PF_PID=
NS="$NS" RELEASE="$RELEASE" BACKUP="$BACKUP" "$HERE/restore.sh" >/dev/null
forward
if search_has after-backup-quokka; then
  echo "FAIL message written after the backup survived the restore"; exit 1
fi
echo "PASS restore rolled back to $BACKUP (post-backup message gone)"
unset KEY AT
smoke new restore
[ -z "$FROM_VERSION" ] || smoke old restore
echo "--- relaycast smoke passed"
