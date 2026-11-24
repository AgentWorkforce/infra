#!/usr/bin/env bash
# Write docs/azure-install/values.yaml with its placeholders filled the way the
# Azure guide's step 5 tells the operator to (CI names, like the placeholder
# hosts of the other render profiles), so CI renders exactly the file an AKS
# customer installs:
#
#   ci/agent-relay/aks-native-site-values.sh <out.yaml>
#
# Render order (docs/azure-install/README.md step 6):
#   -f charts/agent-relay/values-eks.yaml -f <out.yaml>
#   -f charts/agent-relay/ci/aks-native-values.yaml
# __LLM_MODEL__ stays, as the guide says.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=${1:?usage: $0 <out.yaml>}
sed -e 's/__ORG_ID__/ci-org/g' \
    -e 's/__ORG_NAME__/CI Org/g' \
    -e 's/__ADMIN_EMAIL__/admin@ci.company/g' \
    -e 's/__HOST_ROOT__/relay.ci.company/g' \
    -e 's/__HOST_API__/api.ci.company/g' \
    -e 's/__HOST_CAST__/cast.ci.company/g' \
    -e 's/__HOST_HISTORY__/history.ci.company/g' \
    -e 's/__SESSIONS_BUCKET__/ci-agent-relay-sessions/g' \
    -e 's/__POSTGRES_CA_SHA256__/"1111111111111111111111111111111111111111111111111111111111111111"/g' \
    docs/azure-install/values.yaml >"$out"
if grep -v '^[[:space:]]*#' "$out" | grep -o '__[A-Z0-9_]*__' | grep -vx '__LLM_MODEL__' | sort -u | grep .; then
  echo "::error::docs/azure-install/values.yaml has a placeholder $0 does not fill" >&2
  exit 1
fi
