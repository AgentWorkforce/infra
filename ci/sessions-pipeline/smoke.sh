#!/usr/bin/env bash
# kind smoke test for the Sessions Pipeline charts, installed the way Alchemy's
# Kubernetes.HelmChart does it: `helm template --no-hooks` + server-side apply.
# No Helm release, no hooks. Usage: ci/sessions-pipeline/smoke.sh [image]
# Dependencies come from deps/ (CloudNativePG, MinIO, OpenTelemetry).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CLUSTER=${CLUSTER:-sessions-pipeline-smoke}
NS=${NS:-sessions-pipeline}
IMAGE=${1:-ghcr.io/agentworkforce/96bulls-services:kind}
K="kubectl --context kind-$CLUSTER -n $NS"
apply() { # release chart [helm args...]
  local rel=$1 chart=$2; shift 2
  helm template "$rel" "$chart" --namespace "$NS" --no-hooks --include-crds "$@" \
    | kubectl --context "kind-$CLUSTER" -n "$NS" apply --server-side --field-manager=smoke -f -
}

kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --wait 120s
kind load docker-image "$IMAGE" --name "$CLUSTER"
kubectl --context "kind-$CLUSTER" create namespace "$NS" --dry-run=client -o yaml | kubectl --context "kind-$CLUSTER" apply -f -

# Dependencies and their pins live in deps/ (see deps/PINS.md).
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo add minio https://charts.min.io >/dev/null 2>&1 || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update cnpg minio open-telemetry >/dev/null
DEPS="$ROOT/deps"
# pin <name> -> "<chart> --version <v> -f <values>" from deps/pins.txt
pin() {
  awk -v n="$1" -v d="$DEPS" '$1==n {print $2, "--version", $3, "-f", d"/"$4; f=1} END {exit !f}' "$DEPS/pins.txt" \
    || { echo "smoke: $1 not in deps/pins.txt" >&2; exit 1; }
}

# HoopDb: the CloudNativePG operator (its own release, CRDs first), then the
# Cluster. The operator runs in cnpg-system.
kubectl --context "kind-$CLUSTER" create namespace cnpg-system --dry-run=client -o yaml | kubectl --context "kind-$CLUSTER" apply -f -
helm template cnpg $(pin cnpg-operator) --namespace cnpg-system --no-hooks --include-crds \
  | kubectl --context "kind-$CLUSTER" -n cnpg-system apply --server-side --force-conflicts --field-manager=smoke -f -
kubectl --context "kind-$CLUSTER" -n cnpg-system rollout status deploy --timeout=300s
apply hoopdb $(pin hoopdb)
$K wait cluster.postgresql.cnpg.io/hoopdb --for=condition=Ready --timeout=600s

# Secrets (kind-only throwaway values). HOOPDB_URL comes from the app-user
# Secret that CNPG generates.
HOOPDB_URL=$($K get secret hoopdb-app -o jsonpath='{.data.uri}' | base64 -d)
summary_secret=$($K get secret sessions-pipeline --ignore-not-found -o name)
if [ -n "$summary_secret" ]; then
  summary_key_b64=$($K get secret sessions-pipeline -o jsonpath='{.data.SUMMARY_MASTER_KEYS}')
  if [ -n "$summary_key_b64" ]; then
    SUMMARY_MASTER_KEYS=$(printf %s "$summary_key_b64" | base64 -d)
  else
    SUMMARY_MASTER_KEYS="kind1:$(openssl rand -hex 32)"
  fi
else
  SUMMARY_MASTER_KEYS="kind1:$(openssl rand -hex 32)"
fi
$K create secret generic locker-root --from-literal=rootUser=locker --from-literal=rootPassword=locker-kind-only \
  --dry-run=client -o yaml | $K apply -f -
printf %s "$SUMMARY_MASTER_KEYS" | $K create secret generic sessions-pipeline \
  --from-literal=HOOPDB_URL="$HOOPDB_URL" \
  --from-literal=LOCKER_ACCESS_KEY_ID=locker --from-literal=LOCKER_SECRET_ACCESS_KEY=locker-kind-only \
  --from-file=SUMMARY_MASTER_KEYS=/dev/stdin \
  --from-literal=JWKS_JSON='{"keys":[]}' --dry-run=client -o yaml | $K apply -f -
unset HOOPDB_URL SUMMARY_MASTER_KEYS summary_key_b64 summary_secret

apply locker $(pin locker)
apply otel $(pin otel)

# Charts under test, all at once: workloads must tolerate any apply order.
# The image under test (argument 1) overrides the values file.
IMG_REPO=${IMAGE%:*} IMG_TAG=${IMAGE##*:}
IMG_ARGS=(--set global.imageRegistry= --set "image.repository=$IMG_REPO" --set "image.tag=$IMG_TAG" --set image.digest=)
apply bulls "$ROOT/charts/sessions-pipeline-worker" -f "$ROOT/ci/sessions-pipeline/values.yaml" "${IMG_ARGS[@]}"
apply oop "$ROOT/charts/session-ingest-api" -f "$ROOT/ci/sessions-pipeline/values.yaml" "${IMG_ARGS[@]}"

$K wait --for=condition=complete job -l app.kubernetes.io/component=hoopdb-migrate --timeout=300s
$K wait --for=condition=complete job -l app.kubernetes.io/component=locker-init --timeout=300s
$K rollout status deploy --timeout=300s
$K get jobs,deploy,pods -o wide
echo "smoke: OK"
