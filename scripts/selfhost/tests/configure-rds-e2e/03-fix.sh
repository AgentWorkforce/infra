#!/usr/bin/env bash
# Run configure-rds.sh exactly as the customer would, from their folder.
set -euo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$W/after"
cd "$W/customer"
printf 'RESET\n' | RDS_HOST="$RDS_HOST" RDS_ADMIN_PASSWORD="$MASTER_PW" VALUES="$W/customer/values-poc.yaml" \
  HELM_CHART="$INFRA/charts/agent-relay" \
  HELM_EXTRA_VALUES="$INFRA/charts/agent-relay/values-eks.yaml $INFRA/charts/agent-relay/values-eks-native.yaml" \
  KUBE_CONTEXT="$KCTX" ADMIN_EMAIL=owner@cfgrds.test STATE_DIR="$W/state" \
  bash "$INFRA/scripts/selfhost/configure-rds.sh" --reset-databases 2>&1 | tee "$W/after/configure-rds.log"
