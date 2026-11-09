#!/usr/bin/env bash
# Rendered-chart assertions for the durable-actors S3 deployer artifact store
# (relaycast and relayfile deploy Jobs) and the durable-actors control plane's
# S3 env. Offline. Usage: ci/actors-s3/render.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
err() { echo "::error::$*"; fail=1; }
# job_env <chart> <values> -> NAME=VALUE lines of every Job container's env
job_env() {
  helm template ci "$ROOT/charts/$1" --namespace ci -f "$ROOT/charts/$1/ci/$2" \
    | yq -r 'select(.kind == "Job") | .spec.template.spec.containers[].env[] | select(has("value")) | .name + "=" + (.value | tostring)'
}
expect() { # <label> <env lines> <NAME=VALUE>
  grep -qxF "$3" <<<"$2" || err "$1: expected $3"
}
absent() { # <label> <env lines> <NAME>
  if grep -q "^$3=" <<<"$2"; then err "$1: $3 must not render"; fi
}

rc=$(job_env relaycast durable-actors-s3-values.yaml)
expect "relaycast deployer" "$rc" "DURABLE_ACTORS_ARTIFACT_STORE=s3"
expect "relaycast deployer" "$rc" "DURABLE_ACTORS_S3_REGION=us-west-2"
expect "relaycast deployer" "$rc" "DURABLE_ACTORS_S3_ENDPOINT=https://s3.example.com"
expect "relaycast deployer" "$rc" "DURABLE_ACTORS_S3_FORCE_PATH_STYLE=true"

rf=$(job_env relayfile durable-actors-s3-values.yaml)
expect "relayfile deployer" "$rf" "DURABLE_ACTORS_ARTIFACT_STORE=s3"
expect "relayfile deployer" "$rf" "DURABLE_ACTORS_S3_REGION=us-west-2"
absent "relayfile deployer" "$rf" "DURABLE_ACTORS_S3_ENDPOINT"
# forcePathStyle is honoured without an endpoint too.
expect "relayfile deployer" "$rf" "DURABLE_ACTORS_S3_FORCE_PATH_STYLE=true"

# GCS deployers stay free of S3 variables (the deployer rejects them).
for c in relaycast relayfile; do
  g=$(job_env "$c" durable-actors-values.yaml)
  for name in DURABLE_ACTORS_ARTIFACT_STORE DURABLE_ACTORS_S3_REGION DURABLE_ACTORS_S3_ENDPOINT DURABLE_ACTORS_S3_FORCE_PATH_STYLE; do
    absent "$c gcs deployer" "$g" "$name"
  done
done

# Control plane on S3 (charts/durable-actors/ci/eks-values.yaml).
cp=$(helm template ci "$ROOT/charts/durable-actors" --namespace ci -f "$ROOT/charts/durable-actors/ci/eks-values.yaml" \
  | yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[].env[] | select(has("value")) | .name + "=" + (.value | tostring)')
expect "durable-actors control plane" "$cp" "DURABLE_ACTORS_STORAGE_PROVIDER=s3"
expect "durable-actors control plane" "$cp" "DURABLE_ACTORS_S3_FORCE_PATH_STYLE=false"

# Relayfile gateway blob store on S3 (Deployment env of the same fixture).
gw=$(helm template ci "$ROOT/charts/relayfile" --namespace ci -f "$ROOT/charts/relayfile/ci/durable-actors-s3-values.yaml" \
  | yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[].env[] | select(has("value")) | .name + "=" + (.value | tostring)')
expect "relayfile gateway" "$gw" "RELAYFILE_BLOB_STORE=s3"
expect "relayfile gateway" "$gw" "RELAYFILE_S3_REGION=us-west-2"

[ "$fail" = 0 ] && echo "actors S3 render assertions: OK"
exit "$fail"
