#!/usr/bin/env bash
# Copies ci/rds-ca/_rds-ca.tpl (the chart-managed RDS CA helpers) into every
# chart that consumes global.rdsCa, under that chart's template prefix.
#   ci/rds-ca/sync.sh          write the copies
#   ci/rds-ca/sync.sh --check  fail when a copy differs (CI)
set -euo pipefail
cd "$(dirname "$0")/../.."
check=false; [ "${1:-}" = --check ] && check=true
fail=0
# chart:template-prefix
for pair in agent-relay:agent-relay relaycast:relaycast relay-control:relay-control session-read-api:session-read-api \
  sessions-pipeline-worker:sessions-pipeline-worker session-ingest-api:alleyoop sessions-pipeline:sessions-pipeline; do
  chart=${pair%%:*} prefix=${pair#*:}
  dest=charts/$chart/templates/_rds-ca.tpl
  want=$(sed "s/CHART/$prefix/g" ci/rds-ca/_rds-ca.tpl)
  if $check; then
    [ "$(cat "$dest" 2>/dev/null)" = "$want" ] || { echo "::error::$dest differs from ci/rds-ca/_rds-ca.tpl; run ci/rds-ca/sync.sh"; fail=1; }
  else
    printf '%s\n' "$want" > "$dest"
  fi
done
exit $fail
