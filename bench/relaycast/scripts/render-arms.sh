#!/usr/bin/env bash
#
# Generates the values files for both benchmark arms and renders them.
#
#   bench/relaycast/scripts/render-arms.sh <out-dir> [--check]
#
# Arms (same chart, same node pool; only Relaycast's backend differs):
#   pg      values-eks.yaml + values-eks-rds-native.yaml       (+ bench-common)
#   actors  pg + values-eks-actors.yaml + arm-actors-suite.yaml (+ bench-actors)
#
# The two chart profiles are used as shipped, with these string substitutions
# only (printed as a diff into <out-dir>/profile-substitutions.diff):
#   placeholder.company            -> ${BENCH_DOMAIN}
#   10.0.0.0/16 (ipBlocks)         -> ${VPC_CIDR}
#   example-agent-relay-sessions   -> ${BUCKET}
#   example-agent-relay-secrets    -> agent-relay-secrets (the Secret rds-setup.sh writes)
#   example-org                    -> bench
#   64 zeros (RDS CA SHA-256)      -> ${RDS_CA_SHA256}
#   agent-relay-placeholder (ns)   -> ${NS}
#   search backend: opensearch     -> postgres (no OpenSearch domain in the bench)
#
# Env (defaults are render-only stand-ins): BENCH_DOMAIN, VPC_CIDR, BUCKET,
# RDS_CA_SHA256, NS_PG, NS_ACTORS, REGION, ACTOR_ZONE, ACTOR_ROLE_ARN.
# --check also runs helm template for both arms and kubeconform when present.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${1:?out dir}"; CHECK="${2:-}"
C="$ROOT/charts/agent-relay"
V="$ROOT/bench/relaycast/values"
: "${BENCH_DOMAIN:=relaycast-bench.agentrelay.com}" "${VPC_CIDR:=10.91.0.0/16}" "${BUCKET:=relaycast-actors-bench-805532413586}"
: "${RDS_CA_SHA256:=1111111111111111111111111111111111111111111111111111111111111111}"
: "${NS_PG:=arm-pg}" "${NS_ACTORS:=arm-actors}" "${REGION:=us-west-2}" "${ACTOR_ZONE:=us-west-2a}"
: "${ACTOR_ROLE_ARN:=arn:aws:iam::805532413586:role/relaycast-actors-bench/relaycast-actors-bench-storage}"
export BENCH_DOMAIN VPC_CIDR BUCKET RDS_CA_SHA256 REGION ACTOR_ZONE ACTOR_ROLE_ARN
mkdir -p "$OUT"

subst() { # file ns
  sed -e "s/placeholder\.company/${BENCH_DOMAIN}/g" \
      -e "s#10\.0\.0\.0/16#${VPC_CIDR}#g" \
      -e "s/example-agent-relay-sessions/${BUCKET}/g" \
      -e "s/example-agent-relay-secrets/agent-relay-secrets/g" \
      -e "s/example-org/bench/g" \
      -e "s/0\{64\}/${RDS_CA_SHA256}/g" \
      -e "s/agent-relay-placeholder/$2/g" \
      -e "s/backend: opensearch/backend: postgres/g" "$1"
}

: >"$OUT/profile-substitutions.diff"
for arm in pg actors; do
  ns="$NS_PG"; [[ "$arm" == actors ]] && ns="$NS_ACTORS"
  d="$OUT/$arm"; mkdir -p "$d"
  subst "$C/values-eks.yaml" "$ns" >"$d/values-eks.yaml"
  subst "$C/values-eks-rds-native.yaml" "$ns" >"$d/values-eks-rds-native.yaml"
  files=(-f "$d/values-eks.yaml" -f "$d/values-eks-rds-native.yaml")
  if [[ "$arm" == actors ]]; then
    cp "$C/values-eks-actors.yaml" "$d/values-eks-actors.yaml"
    envsubst '${BENCH_DOMAIN} ${BUCKET} ${REGION} ${ACTOR_ZONE} ${ACTOR_ROLE_ARN}' <"$V/bench-actors.yaml.tmpl" >"$d/bench-actors.yaml"
    cp "$V/arm-actors-suite.yaml" "$d/arm-actors-suite.yaml"
    files+=(-f "$d/values-eks-actors.yaml" -f "$d/bench-actors.yaml" -f "$d/arm-actors-suite.yaml")
  fi
  # The mailbox depth cap is a Helm value on the postgres backend; on
  # durable-actors the chart refuses mailbox.* and install-arm.sh puts the same
  # RELAYCAST_MAILBOX_DEPTH_CAP into the relaycast-actor-env Secret instead.
  if [[ "$arm" == pg ]]; then cp "$V/bench-common.yaml" "$d/bench-common.yaml"; files+=(-f "$d/bench-common.yaml"); fi
  cp "$V/bench-suite.yaml" "$d/bench-suite.yaml"; files+=(-f "$d/bench-suite.yaml")
  printf '%s\n' "${files[@]}" | paste -sd' ' >"$d/helm-args"
  if [[ "$arm" == pg ]]; then
    { diff -u "$C/values-eks.yaml" "$d/values-eks.yaml" || true; diff -u "$C/values-eks-rds-native.yaml" "$d/values-eks-rds-native.yaml" || true; } \
      | sed -e "s#$ROOT/##g" -e "s#$OUT/##g" >>"$OUT/profile-substitutions.diff"
  fi
  if [[ "$CHECK" == --check ]]; then
    helm template agent-relay "$C" -n "$ns" "${files[@]}" >"$d/rendered.yaml"
    printf '%s: %s resources\n' "$arm" "$(grep -c '^kind:' "$d/rendered.yaml")"
    if command -v kubeconform >/dev/null; then
      kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version 1.34.0 "$d/rendered.yaml"
    fi
  fi
done
