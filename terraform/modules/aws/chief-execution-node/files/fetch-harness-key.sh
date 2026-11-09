#!/bin/bash
# Runs as root (ExecStartPre=+). Reads the harness API key with the instance
# role, which the service user cannot reach, into a root-only environment file
# that systemd hands to the node unit. Spawned harnesses inherit it from there,
# by design. Until the secret has a value the node starts without one. Never
# prints the value.
set -euo pipefail
umask 077

# shellcheck source=/dev/null
. /etc/chief-node/harness-key-source

dir=/run/chief-node-secrets
env_file="$dir/harness.env"
install -d -m 0700 -o root -g root "$dir"
rm -f "$env_file"

errors="$(mktemp -p "$dir")"
trap 'rm -f "$errors"' EXIT
if ! key="$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET_ARN" --query SecretString --output text 2>"$errors")"; then
  if grep -q ResourceNotFoundException "$errors"; then
    echo "chief-node-fetch-harness-key: the secret has no value yet; starting without one" >&2
    exit 0
  fi
  echo "chief-node-fetch-harness-key: could not read the secret" >&2
  exit 1
fi

case "$key" in
  "" | None | *[!A-Za-z0-9_.-]*)
    echo "chief-node-fetch-harness-key: the secret is empty or has an unexpected format" >&2
    exit 1
    ;;
esac

tmp="$(mktemp -p "$dir")"
printf '%s=%s\n' "$KEY_NAME" "$key" >"$tmp"
mv -f "$tmp" "$env_file"
