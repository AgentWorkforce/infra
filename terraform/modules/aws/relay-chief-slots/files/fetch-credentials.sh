#!/usr/bin/env bash
# Re-fetch this slot's credentials into tmpfs. relay-chief-credentials.service
# runs this before relay-chief.service, because /run does not survive a reboot.
#
# Fails closed: the previous file is removed first, and any error leaves no
# file, so the service cannot start with stale or partial credentials. Secret
# values are never placed in arguments, logs or error messages.
set -euo pipefail
umask 077

ROOT="${RELAY_CHIEF_ROOT:-}"
SLOT_ENV="$ROOT/etc/relay-chief/slot.env"
CREDS_DIR="$ROOT/run/relay-chief"
CREDS_FILE="$CREDS_DIR/credentials.env"

fail() {
  printf 'relay-chief-fetch-credentials: %s\n' "$1" >&2
  exit 1
}

[ -r "$SLOT_ENV" ] || fail "slot environment file is missing"
# shellcheck source=/dev/null
. "$SLOT_ENV"
[ -n "${RELAY_CHIEF_SECRET_ID:-}" ] || fail "RELAY_CHIEF_SECRET_ID is not set"
[ -n "${RELAY_CHIEF_REGION:-}" ] || fail "RELAY_CHIEF_REGION is not set"

mkdir -p "$CREDS_DIR"
chmod 0700 "$CREDS_DIR"
rm -f "$CREDS_FILE"

# Reads the JSON-encoded SecretString on stdin, then writes systemd
# EnvironmentFile syntax. Only known bindings pass: a free-form secret could
# otherwise inject NODE_OPTIONS or PATH into the service.
RENDER=$(
  cat <<'PY'
import json
import os
import sys

REQUIRED = ("RELAY_AGENT_TOKEN", "TYPESAFE_API_KEY", "CHIEF_CONTROL_PLANE_URL", "CHIEF_CONTROL_PLANE_TOKEN")
OPTIONAL = ("RELAY_BASE_URL",)
target = sys.argv[1]


def fail(message):
    print("relay-chief-fetch-credentials: " + message, file=sys.stderr)
    sys.exit(1)


try:
    secret = json.loads(json.loads(sys.stdin.read()))
except (TypeError, ValueError):
    fail("the secret is not a JSON object")
if not isinstance(secret, dict):
    fail("the secret is not a JSON object")
for key in sorted(set(secret) - set(REQUIRED) - set(OPTIONAL)):
    fail("the secret has an unknown binding: " + key)
for key in REQUIRED:
    if key not in secret:
        fail("the secret is missing a binding: " + key)
lines = []
for key in REQUIRED + OPTIONAL:
    if key not in secret:
        continue
    value = secret[key]
    if not isinstance(value, str) or not value.strip():
        fail("the secret has an empty or non-string binding: " + key)
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        fail("the secret has a control character in binding: " + key)
    escaped = "".join("\\" + c if c in '"\\`$' else c for c in value)
    lines.append(f'{key}="{escaped}"\n')

temporary = f"{target}.{os.getpid()}"
descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.writelines(lines)
        handle.flush()
        os.fsync(handle.fileno())
    os.rename(temporary, target)
except BaseException:
    os.unlink(temporary)
    raise
PY
)

AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=5 aws --region "$RELAY_CHIEF_REGION" \
  secretsmanager get-secret-value \
  --secret-id "$RELAY_CHIEF_SECRET_ID" \
  --query SecretString \
  --output json | python3 -I -c "$RENDER" "$CREDS_FILE" || {
  rm -f "$CREDS_FILE"
  fail "could not fetch the slot credentials"
}
[ -s "$CREDS_FILE" ] || fail "no credentials were written"
