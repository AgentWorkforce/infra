#!/usr/bin/env bash
# PostgreSQL 15: configure-rds.sh --reset-databases must stop before dropping anything.
set -uo pipefail
source "$(dirname "$0")/env.sh"
export PG_MAJOR=15
docker rm -f cfgrds-pg >/dev/null 2>&1; rm -rf "$W/pg"
bash "$(dirname "$0")/01-infra.sh" >/dev/null 2>&1 || { echo "FAIL infra"; exit 1; }
for db in relaycontrol relaycast hoopdb; do docker exec cfgrds-pg psql -U postgres -d postgres -qc "CREATE DATABASE $db" >/dev/null 2>&1; done
cd "$W/customer"
out="$(printf 'RESET\n' | RDS_HOST="$RDS_HOST" RDS_ADMIN_PASSWORD="$MASTER_PW" VALUES="$W/customer/values-poc.yaml" \
  HELM_CHART="$INFRA/charts/agent-relay" KUBE_CONTEXT="$KCTX" ADMIN_EMAIL=owner@cfgrds.test STATE_DIR="$W/state15" \
  bash "$INFRA/scripts/selfhost/configure-rds.sh" --reset-databases 2>&1)"; rc=$?
echo "$out" | grep -E 'ERROR|PostgreSQL' | cut -c1-250
left="$(docker exec cfgrds-pg psql -U rdsadmin -d postgres -Atc "select count(*) from pg_database where datname in ('relaycontrol','relaycast','hoopdb')")"
[[ $rc != 0 ]] && echo "PASS script stopped (exit $rc)" || echo "FAIL script did not stop"
grep -q 'needs PostgreSQL 16 or later. Nothing was dropped' <<<"$out" && echo "PASS clear PG15 message" || echo "FAIL message"
[[ "$left" == 3 ]] && echo "PASS all 3 databases still exist" || echo "FAIL databases dropped ($left left)"
