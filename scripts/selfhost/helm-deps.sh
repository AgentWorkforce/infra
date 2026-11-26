#!/usr/bin/env bash
# Build the locked chart dependencies a git checkout needs before
# `helm upgrade --install ... charts/agent-relay`, with no `helm repo add`.
#
#   scripts/selfhost/helm-deps.sh
#
# Runs `helm dependency build` for charts/sessions-pipeline, then
# charts/agent-relay (Helm does not vendor the children of a file://
# dependency, so the order matters). Versions come from the Chart.lock files.
#
# Third-party charts come from OCI registries where the project publishes one
# (CloudNativePG cluster, OpenTelemetry collector), which Helm pulls without a
# repository entry. The MinIO chart is published only at https://charts.min.io/,
# and `helm dependency build` resolves an https repository only when one is
# registered. This script registers it in a throwaway repository config and
# cache, so your own Helm repositories are neither read nor changed.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
command -v helm >/dev/null || { echo "helm-deps: helm not found on PATH" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HELM_REPOSITORY_CONFIG="$tmp/repositories.yaml"
export HELM_REPOSITORY_CACHE="$tmp/repository"
: >"$HELM_REPOSITORY_CONFIG"

# Every https repository either lock file names (today only MinIO's).
locks=("$root/charts/sessions-pipeline/Chart.lock" "$root/charts/agent-relay/Chart.lock")
while read -r repo; do
  helm repo add "dep-$(printf %s "$repo" | cksum | cut -d' ' -f1)" "$repo" >/dev/null
done < <(sed -n 's/^ *repository: *\(https:.*\)/\1/p' "${locks[@]}" | sort -u)

helm dependency build "$root/charts/sessions-pipeline"
helm dependency build "$root/charts/agent-relay"
