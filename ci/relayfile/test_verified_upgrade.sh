#!/usr/bin/env bash
# CI-only API validation: no Pods start; candidate changes are server dry-run.
set -euo pipefail
[[ "${CI:-}" == true ]] || { echo 'CI=true is required' >&2; exit 1; }
[[ "$(kubectl config current-context)" == kind-ci ]] || { echo 'current-context must be kind-ci' >&2; exit 1; }
chart=charts/relayfile
release=relayfile-upgrade-proof
old=$(helm template "$release" "$chart" -n ci -f "$chart/ci/default-values.yaml" --set replicaCount=0 | yq -o=json 'select(.kind == "Deployment")')
name=$(jq -r .metadata.name <<<"$old")
kubectl create -n ci -f - <<<"$old" >/dev/null
trap 'kubectl delete deployment "$name" -n ci --ignore-not-found --wait=false >/dev/null' EXIT
kubectl get deployment "$name" -n ci -o json | jq -e '.spec.replicas == 0 and .spec.strategy.type == "RollingUpdate" and .spec.strategy.rollingUpdate != null' >/dev/null
# Causal control: keeping the API-defaulted rollingUpdate must be rejected.
if refusal=$(kubectl patch deployment "$name" -n ci --type=strategic --dry-run=server -p '{"spec":{"strategy":{"type":"Recreate"}}}' 2>&1); then
  echo 'Recreate unexpectedly accepted with retained rollingUpdate' >&2
  exit 1
fi
if [[ "$refusal" != *'spec.strategy.rollingUpdate: Forbidden: may not be specified when strategy'* || "$refusal" != *"'Recreate'"* ]]; then
  echo 'negative control did not return the expected rollingUpdate Forbidden validation error' >&2
  exit 1
fi
strategy=$(helm template "$release" "$chart" -n ci -f "$chart/ci/verified-postgres-values.yaml" | yq -o=json 'select(.kind == "Deployment") | .spec.strategy')
patch=$(jq -nc --argjson strategy "$strategy" '{spec:{strategy:$strategy}}')
kubectl patch deployment "$name" -n ci --type=strategic --dry-run=server -p "$patch" -o json | jq -e '.spec.strategy.type == "Recreate" and .spec.strategy.rollingUpdate == null' >/dev/null
echo 'Verified PostgreSQL strategy upgrade server dry-run PASS (zero replicas)'
