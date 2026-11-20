#!/usr/bin/env bash
# Full end-to-end: fake RDS + customer's broken state + configure-rds.sh + verification.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
source "$D/env.sh"
if [[ "${FRESH:-1}" == 1 ]]; then
  docker rm -f cfgrds-pg >/dev/null 2>&1 || true
  kind delete cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" >/dev/null 2>&1 || true
  rm -rf "$W/state" "$W/secretsmanager" "$W/before" "$W/after" "$W/customer" "$W/certs" "$W/pg"
fi
bash "$D/01-infra.sh" && bash "$D/02-customer-state.sh" && bash "$D/03-fix.sh" && bash "$D/04-verify.sh"
