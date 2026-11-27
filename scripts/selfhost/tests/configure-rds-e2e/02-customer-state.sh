#!/usr/bin/env bash
# Recreate the customer's state from the 2026-11-19 call and screenshots:
# - shared PG15 RDS, databases created by the master user (agentrelaypoc, relaycontrol, relaycast, hoopdb)
# - every database URL in the install Secrets uses the master user "postgres"
# - search-indexer-runtime holds a bare URL, not the {"hoopdb_url":...} JSON (malformed-url-or-json)
# - rds-ca ConfigMap present, values copied from examples/aws/values.yaml (admin@example.com left in)
# - helm install with values-eks.yaml + values-eks-native.yaml + values-poc.yaml (examples/aws/README.md)
set -euo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$W/customer" "$W/before"
cd "$W/customer"

for db in agentrelaypoc relaycontrol relaycast hoopdb; do
  docker exec cfgrds-pg psql -U postgres -d postgres -qc "CREATE DATABASE $db" 2>&1 | grep -v 'already exists' || true
done

kubectl --context "$KCTX" create namespace agent-relay --dry-run=client -o yaml | kubectl --context "$KCTX" apply -f - >/dev/null
k create configmap rds-ca --from-file=ca.crt="$TEST_CA" --dry-run=client -o yaml | k apply -f - >/dev/null

rm -rf secrets; cp -R "$INFRA/examples/aws/secrets" secrets
python3 - secrets "$MASTER_PW" "$RDS_HOST" <<'PY'
import pathlib, re, sys
root, pw, host = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
url = re.compile(r'postgres(?:ql)?://[^:@/\s]+:[^@\s]+@[^:/\s]+:5432/([A-Za-z0-9_]+)')
for f in root.glob('*.yaml'):
    s = url.sub(lambda m: f'postgresql://postgres:{pw}@{host}:5432/{m.group(1)}', f.read_text())
    if f.name.startswith('04-'):
        # Customer's search-indexer-runtime held a bare URL (diagnostic: malformed-url-or-json).
        s = re.sub(r"'\{\"hoopdb_url\":\"([^\"]+)\"\}'", r"'\1'", s)
    f.write_text(s)
PY
for f in secrets/0[1-5]-*.yaml; do k apply -f "$f" >/dev/null; done
echo "secrets applied:"; k get secrets -o name | grep -v helm | sed 's/^/  /'

CA_SHA="$(shasum -a 256 "$TEST_CA" | cut -d' ' -f1)"
sed "s/9f2c4e1ab7d03586e2f1c9a47b0d6e3851fa2c94d7e60b13a8c5f27e4d91b06a/$CA_SHA/g" "$INFRA/examples/aws/values.yaml" > values-poc.yaml

cd "$INFRA"
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo add minio https://charts.min.io/ >/dev/null 2>&1 || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
rm -rf charts/agent-relay/charts charts/sessions-pipeline/charts   # as a fresh clone, then examples/aws/README.md
helm dependency build charts/sessions-pipeline >/dev/null && helm dependency build charts/agent-relay >/dev/null
# Since databaseGuard (chart 0.7.84) this install is refused before anything is
# applied, with one message naming every Secret key that logs in as the master.
if helm --kube-context "$KCTX" upgrade --install agent-relay charts/agent-relay -n agent-relay \
  -f charts/agent-relay/values-eks.yaml -f charts/agent-relay/values-eks-native.yaml -f "$W/customer/values-poc.yaml" \
  --timeout 2m >"$W/before/helm.txt" 2>&1; then
  echo "FAIL: helm installed the customer's master-login Secrets" >&2; exit 1
fi
sed -n '/AR_DB_LOGIN/,$p' "$W/before/helm.txt"
grep -q 'logs in as "postgres" (the RDS master user)' "$W/before/helm.txt" || { cat "$W/before/helm.txt" >&2; echo "FAIL: no master-login refusal" >&2; exit 1; }
grep -q 'search-indexer-runtime: RELAYHISTORY_PIPELINE_CONSUMER_SECRET holds a bare URL' "$W/before/helm.txt" || { echo "FAIL: bare URL in 04 not reported" >&2; exit 1; }
[[ -z "$(k get deploy -o name 2>/dev/null)" ]] || { echo "FAIL: workloads exist after a refused install" >&2; exit 1; }
echo "PASS databaseGuard refused the customer's install before anything was applied"
k get jobs -o wide > "$W/before/jobs.txt" 2>&1 || true
k get pods > "$W/before/pods.txt" 2>&1 || true
k get deploy > "$W/before/deploy.txt" 2>&1 || true
for j in $(k get jobs -o name); do echo "== $j"; k logs "$j" --all-containers --tail=25 2>&1 | grep -v -i -E 'password|postgres(ql)?://' | cut -c1-220; done > "$W/before/job-logs.txt" 2>&1 || true
for p in $(k get pods -o name); do st="$(k get "$p" -o jsonpath='{.status.phase}')"; [[ "$st" == Running ]] && k get "$p" -o jsonpath='{.status.containerStatuses[*].ready}' | grep -q false || [[ "$st" != Running ]] || continue; echo "== $p ($st)"; k logs "$p" --all-containers --tail=15 2>&1 | grep -v -i -E 'password|postgres(ql)?://' | cut -c1-220; done > "$W/before/pod-logs.txt" 2>&1 || true
cd "$W/customer" && python3 "$INFRA/scripts/support/diagnose-install.py" --context "$KCTX" --scope cluster --values values-poc.yaml \
  --output "$W/before/diagnostic-cluster.json" > "$W/before/diagnostic-cluster.txt" 2>&1 || true
echo "== before: jobs"; cat "$W/before/jobs.txt"; echo "== before: deployments"; cat "$W/before/deploy.txt"
echo "== before: diagnostic"; sed -n '/Likely problems/,$p' "$W/before/diagnostic-cluster.txt" | cut -c1-200
