#!/usr/bin/env bash
# List the installation's workspaces (ID and name), for turning on titles and
# summaries ("Turn on titles and summaries" in 0-START-HERE.md).
#
#   bash workspace-ids.sh <app hostname> [namespace]
#
# Run after the first sign-in, with kubectl access to the install. It reads the
# install's bootstrap token from the agent-relay-secrets Secret and sends it
# only in a request header on stdin (never on a command line or in output),
# then prints one line per workspace: its ID, then its name. Needs kubectl,
# curl and jq.
set -euo pipefail
DOMAIN="${1:?usage: bash workspace-ids.sh <app hostname> [namespace]}"
NS="${2:-${NAMESPACE:-agent-relay}}"
API="https://api.$DOMAIN"

auth() {
  printf 'Authorization: Bearer '
  kubectl -n "$NS" get secret agent-relay-secrets -o jsonpath='{.data.selfhost-bootstrap-token}' | base64 -d
  printf '\n'
}

ORG="$(auth | curl -fsS -H @- "$API/api/v1/organizations" | jq -r '.organizations[0].id // empty')"
[ -n "$ORG" ] || { echo "could not read the organization (is the bootstrap token right?)" >&2; exit 1; }
auth | curl -fsS -H @- "$API/api/v1/organizations/$ORG/workspaces" | jq -r '.workspaces[] | "\(.id)\t\(.name)"'
