#!/usr/bin/env bash
#
# Arm 5 (AgentWorkforce/relaycast#717) on top of an installed actors arm:
#   SQLITE_IMAGE=<repo@sha256:…> EXPRESS_BUCKET=<directory bucket> bench/relaycast/infra/sqlite-arm.sh up|down
# up: copies relaycast-actor-env from the sandbox namespace, installs the SQLite
# hosts and router (infra/sqlite-arm.yaml.tmpl), then re-runs install-arm.sh
# actors install with EXTRA_VALUES=values/sqlite-arm.yaml so the gateway calls the router.
# The hosts' ServiceAccount needs a Pod Identity association with S3 Express
# access to EXPRESS_BUCKET (operator step: cluster.sh assoc arm-actors sqlite-host <role>).
set -euo pipefail
export TMPDIR="${TMPDIR:-$HOME/.agent-tmp}"; mkdir -p "$TMPDIR"
HERE="$(cd "$(dirname "$0")" && pwd)"
export NS=arm-actors AWS_REGION="${AWS_REGION:-us-west-2}"
export SQLITE_HOSTS="${SQLITE_HOSTS:-2}" SQLITE_DURABILITY="${SQLITE_DURABILITY:-sync}"
export KUBECONFIG="${BENCH_KUBECONFIG:-$HOME/.agent-tmp/relaycast-actors-bench.kubeconfig}"
SANDBOX_NS="${NS}-agent-relay"
case "${1:?up|down}" in
  up)
    : "${SQLITE_IMAGE:?}" "${EXPRESS_BUCKET:?}"
    hosts=(); for ((i = 0; i < SQLITE_HOSTS; i++)); do hosts+=("sqlite-host-$i=http://sqlite-host-$i.sqlite-host.$NS.svc.cluster.local:8080"); done
    export SQLITE_ROUTER_HOSTS; SQLITE_ROUTER_HOSTS="$(IFS=,; echo "${hosts[*]}")"
    kubectl -n "$SANDBOX_NS" get secret relaycast-actor-env -o json \
      | node -e 'const s=JSON.parse(require("fs").readFileSync(0));process.stdout.write(JSON.stringify({apiVersion:"v1",kind:"Secret",metadata:{name:s.metadata.name,namespace:process.argv[1]},data:s.data}))' "$NS" \
      | kubectl apply -f - >/dev/null
    envsubst <"$HERE/sqlite-arm.yaml.tmpl" | kubectl apply -f -
    kubectl -n "$NS" rollout status statefulset/sqlite-host --timeout=300s
    kubectl -n "$NS" rollout status deployment/sqlite-router --timeout=300s
    EXTRA_VALUES="$HERE/../values/sqlite-arm.yaml" "$HERE/install-arm.sh" actors install ;;
  down)
    envsubst <"$HERE/sqlite-arm.yaml.tmpl" | kubectl delete --ignore-not-found -f - >/dev/null
    kubectl -n "$NS" delete secret relaycast-actor-env --ignore-not-found >/dev/null ;;
  *) echo "up|down" >&2; exit 2 ;;
esac
