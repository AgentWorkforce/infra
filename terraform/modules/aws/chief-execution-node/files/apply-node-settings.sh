#!/bin/bash
# Applies the core settings the bridge requires, through the node's own local
# socket as the service user. Idempotent; reruns after a node restart are safe.
set -euo pipefail

params='{"accept_spawns":true,"spawn_full_access_claude":false,"spawn_full_access_codex":false,"spawn_requester_approvals":false}'
socket=/var/lib/chief-node/.agentworkforce/desktop/core.sock

for _ in $(seq 1 60); do
  if [ -S "$socket" ]; then break; fi
  sleep 2
done
[ -S "$socket" ] || { echo "chief-node-apply-settings: the node socket did not appear" >&2; exit 1; }

exec runuser -u chief-node -- env -i HOME=/var/lib/chief-node PATH=/usr/local/bin:/usr/bin:/bin \
  /usr/local/bin/agent-relay-node call settings.set --socket "$socket" --params "$params"
