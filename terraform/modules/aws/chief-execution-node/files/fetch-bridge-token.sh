#!/bin/bash
# Runs as root (ExecStartPre=+). Reads the bridge's Relay token with the instance
# role, which the service user cannot reach, into a root-only environment file.
# Never prints the value.
set -euo pipefail
umask 077

# shellcheck source=/dev/null
. /etc/chief-bridge/token-source

dir=/run/chief-bridge-secrets
install -d -m 0700 -o root -g root "$dir"

token="$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET_ARN" --query SecretString --output text)"
case "$token" in
  "" | None | *[!A-Za-z0-9_.-]*)
    echo "chief-bridge-fetch-token: the secret is empty or has an unexpected format" >&2
    exit 1
    ;;
esac

tmp="$(mktemp -p "$dir")"
printf 'CHIEF_BRIDGE_RELAY_TOKEN=%s\n' "$token" >"$tmp"
mv -f "$tmp" "$dir/relay-token.env"
