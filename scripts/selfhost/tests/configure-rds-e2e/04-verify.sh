#!/usr/bin/env bash
# Check every failure seen on the customer's install is gone.
set -uo pipefail
source "$(dirname "$0")/env.sh"
cd "$W/after"
fail=0; check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
k get jobs > jobs.txt; k get deploy > deploy.txt; k get pods > pods.txt
cat jobs.txt deploy.txt
failed_jobs="$(k get jobs -o json | jq -r '.items[] | select(.status.failed>0 and (.status.succeeded//0)==0) | .metadata.name')"
check "no failed Jobs (relaycast/control/worker migrate, search bootstrap)" '[[ -z "$failed_jobs" ]]'
for d in relaycast relay-control read-api ingest-edge search-indexer webapp; do
  n="$(k get deploy -o json | jq -r --arg d "$d" '[.items[]|select(.metadata.name|test($d))][0]|"\(.status.readyReplicas//0)/\(.spec.replicas)"')"
  check "deployment *$d* ready ($n)" '[[ "${n%/*}" -ge 1 && "${n%/*}" == "${n#*/}" ]]'
done
logs="$(for p in $(k get pods -o name); do k logs "$p" --all-containers --tail=200 2>/dev/null; done)"
check "no relaycast identity refusal (exit 65)" '! grep -q -E "not a correctly scoped|refusing: the session" <<<"$logs"'
check "no session_user / wrong-login refusals" '! grep -q -E "reader_role_session_user|login .* refused|runtime_role_unsafe" <<<"$logs"'
python3 "$INFRA/scripts/support/diagnose-install.py" --context "$KCTX" --scope cluster --values "$W/customer/values-poc.yaml" \
  --output "$W/after/diagnostic-cluster-$(date +%s).json" > diag-cluster.txt 2>&1; rc=$?
sed -n '/Likely problems/,$p' diag-cluster.txt | cut -c1-200
check "diagnostic credential checks all PASS" '! grep -q "^FAIL credential" diag-cluster.txt'
check "diagnostic cluster scope exit 0" '[[ $rc == 0 ]]'
# Database scope from inside the kind network, against the deployed Secrets (kubectl JSON).
rm -rf dbsecrets; mkdir -m 700 dbsecrets
for s in agent-relay-secrets agent-relay-read-api agent-relay-ingest-edge-runtime search-indexer-runtime search-indexer-owner; do
  k get secret "$s" -o json > "dbsecrets/$s.json" 2>/dev/null && chmod 600 "dbsecrets/$s.json"; done
PG_IP="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' cfgrds-pg)"
docker run --rm --network kind --add-host "$RDS_HOST:$PG_IP" -v "$INFRA/scripts/support:/s:ro" -v "$W/after/dbsecrets:/secrets:ro" \
  -v "$TEST_CA:/ca.pem:ro" pgvector/pgvector:pg${PG_MAJOR} bash -c 'apt-get -qq update >/dev/null && apt-get -qq install -y python3 >/dev/null 2>&1;
  cd /tmp && python3 /s/diagnose-install.py --scope database --secret-manifests /secrets --ca-file /ca.pem --values \
  --control-database relaycontrol --cast-database relaycast --hoop-database hoopdb' > diag-db.txt 2>&1; rc=$?
grep -E '^(FAIL|UNKNOWN)' diag-db.txt | cut -c1-200; tail -2 diag-db.txt
check "diagnostic database scope exit 0 (logins, roles, grants)" '[[ $rc == 0 ]]'
rm -rf dbsecrets
grep -q '^Agent Relay install status' configure-rds.log 2>/dev/null || cp "$W/after/configure-rds.log" . 2>/dev/null
check "helm test status table printed" 'grep -q "^Agent Relay install status" configure-rds.log'
check "helm test: every database login ok" '! grep -E "^  database  " configure-rds.log | grep -qv " ok  "'
check "helm test: every migration Job ok" '! grep -E "^  migrations  " configure-rds.log | grep -qv " ok  "'
check "a plain verdict and Next steps end the run" 'grep -qE "^    (HEALTHY|UNHEALTHY|INCOMPLETE): " configure-rds.log && grep -q "^    Next:" configure-rds.log'
layout="$(helm template agent-relay "$INFRA/charts/agent-relay" -n agent-relay -f "$INFRA/charts/agent-relay/values-eks.yaml" \
  -f "$INFRA/charts/agent-relay/values-eks-native.yaml" -f "$W/customer/values-poc.yaml" 2>/dev/null \
  | yq -N 'select(.kind == "Job" and (.metadata.name | test("worker-migrate"))) | .spec.template.spec.containers[0].env[] | select(.name == "HOOPDB_RDS_LAYOUT") | .value')"
check "a plain helm upgrade (documented -f files only) keeps rdsLayout ($layout)" '[[ "$layout" == separate-database ]]'
check "the guide generated the application keys" 'k get secret agent-relay-secrets -o jsonpath="{.data.selfhost-encryption-key}" | grep -q .'
check "first sign-in: fresh setup key minted" 'grep -q "Setup key (single use" configure-rds.log'
exit $fail
