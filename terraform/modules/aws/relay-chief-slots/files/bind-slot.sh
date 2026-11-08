#!/usr/bin/env bash
# Bind a provisioned Relay Chief slot to one chief. Run as root on the slot host,
# through SSM. Installed at /usr/local/sbin/relay-chief-bind-slot.
#
#   relay-chief-bind-slot --slot-id <id> --config <path|-> [--enable-timer [--dispatch-opt-in]]
#
# Writes /etc/relay-chief/config.json and fetches credentials. --enable-timer
# starts cycles that reserve work and send nothing. --dispatch-opt-in, which needs
# --enable-timer, also installs the drop-in that lets those cycles send real Relay
# assignments. Do not pass it for a customer binding until the execution bridge
# exists. A successful bind without it removes that drop-in.
#
# A slot is single-use: it refuses a ledger or binding record for a different
# chief, and rebinding the same chief is allowed (for example after a host
# replacement, which loses /etc/relay-chief but keeps the data volume).
#
# Exit codes: 0 bound, 1 failure, 2 malformed input, 3 slot already bound or not
# this host's slot, 4 --dispatch-opt-in without --enable-timer. A bind refused
# by its checks changes nothing; one that fails after them leaves the timer off.
set -euo pipefail
umask 077

ROOT="${RELAY_CHIEF_ROOT:-}"
SLOT_ID_PATTERN='^slot-[a-z0-9]{8,32}$'
PLACEMENT_PATTERN='^[a-z0-9][a-z0-9-]{0,39}$'
ETC_DIR="$ROOT/etc/relay-chief"
SLOT_ENV="$ETC_DIR/slot.env"
CONFIG="$ETC_DIR/config.json"
DATA_DIR="$ROOT/var/lib/relay-chief"
LEDGER="$DATA_DIR/chief.db"
MARKER="$DATA_DIR/.slot-binding.json"
CREDS_FILE="$ROOT/run/relay-chief/credentials.env"
NODE="$ROOT/usr/bin/node"
CLI="$ROOT/opt/relay-chief/dist/cli.js"
DISPATCH_DROP_IN="$ROOT/etc/systemd/system/relay-chief.service.d/20-dispatch.conf"
TIMER=relay-chief.timer
SERVICE=relay-chief.service
CREDENTIALS_UNIT=relay-chief-credentials.service

refuse() {
  printf 'relay-chief-bind-slot: refused: %s\n' "$2" >&2
  exit "$1"
}

usage() {
  sed -n '5p' "$0" | sed 's/^# *//' >&2
  exit 2
}

slot_id="" config_source="" enable_timer=0 dispatch_opt_in=0
while [ $# -gt 0 ]; do
  case "$1" in
  --slot-id)
    [ $# -ge 2 ] || usage
    slot_id="$2"
    shift 2
    ;;
  --config)
    [ $# -ge 2 ] || usage
    config_source="$2"
    shift 2
    ;;
  --enable-timer)
    enable_timer=1
    shift
    ;;
  --dispatch-opt-in)
    dispatch_opt_in=1
    shift
    ;;
  *)
    usage
    ;;
  esac
done

[[ "$slot_id" =~ $SLOT_ID_PATTERN ]] || refuse 2 "malformed slot id"
[ -n "$config_source" ] || usage
if [ "$dispatch_opt_in" = "1" ] && [ "$enable_timer" != "1" ]; then
  refuse 4 "--dispatch-opt-in requires --enable-timer"
fi

[ "$(id -u)" = "0" ] || refuse 1 "must run as root"
[ -r "$SLOT_ENV" ] || refuse 3 "this host is not a provisioned slot"
# shellcheck source=/dev/null
. "$SLOT_ENV"
[ "${RELAY_CHIEF_SLOT_ID:-}" = "$slot_id" ] || refuse 3 "this host is not that slot"
[[ "${RELAY_CHIEF_PLACEMENT:-}" =~ $PLACEMENT_PATTERN ]] || refuse 2 "this host has an invalid placement"
case "${RELAY_CHIEF_SIZE_CLASS:-}" in
small | medium | large) ;;
*) refuse 2 "this host has an invalid size class" ;;
esac
mountpoint -q "$DATA_DIR" || refuse 1 "the data volume is not mounted"
if [ ! -x "$NODE" ] || [ ! -f "$CLI" ]; then
  refuse 1 "no relay-chief build is installed under /opt/relay-chief"
fi

# Serializes concurrent binds, so two chiefs cannot both pass the checks below.
exec 9>"$ROOT/run/relay-chief-bind.lock"
flock -n 9 || refuse 1 "another bind is running"

work="$(mktemp -d "$ETC_DIR/.bind.XXXXXX")"
trap 'rm -rf "$work"' EXIT
if [ "$config_source" = "-" ]; then
  cat >"$work/config.json"
else
  [ -f "$config_source" ] || refuse 2 "configuration file not found"
  cat -- "$config_source" >"$work/config.json"
fi

CHECK=$(
  cat <<'PY'
import json
import os
import sqlite3
import stat
import sys
from urllib.parse import quote

SCOPE = ("chiefId", "organizationId", "workspaceId", "projectId", "relayCallerId")
mode, slot_id, config_path, ledger, marker = sys.argv[1:6]


def refuse(code, message):
    print("relay-chief-bind-slot: refused: " + message, file=sys.stderr)
    sys.exit(code)


try:
    with open(config_path, encoding="utf-8") as handle:
        config = json.load(handle)
except (OSError, ValueError):
    refuse(2, "the configuration is not valid JSON")
if not isinstance(config, dict):
    refuse(2, "the configuration is not a JSON object")
scope = {}
for key in SCOPE:
    value = config.get(key)
    # The runtime trims identifiers before binding them to a ledger, so a padded
    # value would not compare equal to what a ledger stores.
    if not isinstance(value, str) or not value or value != value.strip() or len(value) > 200:
        refuse(2, "the configuration has an invalid identifier: " + key)
    scope[key] = value


if mode == "setup":
    placement, size_class = sys.argv[6:8]
    with open(sys.argv[8], "w", encoding="utf-8") as handle:
        # The runtime has no validate command. Its side-effect-free plan command
        # applies the real configuration schema to a setup request.
        json.dump({"requestId": "bind-" + slot_id, "config": config,
                   "placement": placement, "sizeClass": size_class}, handle)
    sys.exit(0)


def ledger_scope():
    try:
        info = os.lstat(ledger)
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(info.st_mode):
        refuse(3, "the ledger path is not a regular file")
    connection = None
    try:
        connection = sqlite3.connect("file:" + quote(ledger) + "?mode=ro", uri=True, timeout=5)
        row = connection.execute("SELECT value FROM metadata WHERE key='scope'").fetchone()
    except sqlite3.DatabaseError as error:
        # A ledger that was created but never configured holds no binding yet.
        if "no such table" in str(error):
            return None
        refuse(3, "the existing ledger cannot be read; wipe the volume deliberately or investigate it")
    finally:
        if connection is not None:
            connection.close()
    return None if row is None else row[0]


stored = ledger_scope()
if stored is not None:
    try:
        bound = json.loads(stored)
    except ValueError:
        refuse(3, "the existing ledger has an unreadable binding")
    if bound != scope:
        refuse(3, "this slot already has a ledger bound to a different chief; a slot is single-use unless its volume is wiped")

try:
    with open(marker, encoding="utf-8") as handle:
        previous = json.load(handle)
except FileNotFoundError:
    previous = None
except (OSError, ValueError):
    refuse(3, "the slot binding record cannot be read")
if previous is not None:
    if not isinstance(previous, dict) or previous.get("slotId") != slot_id or previous.get("scope") != scope:
        refuse(3, "this slot is already bound to a different chief; a slot is single-use unless its volume is wiped")

if mode == "write" and previous is None:
    temporary = f"{marker}.{os.getpid()}"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump({"version": 1, "slotId": slot_id, "scope": scope}, handle)
        handle.flush()
        os.fsync(handle.fileno())
    os.rename(temporary, marker)
PY
)

check() {
  python3 -I -c "$CHECK" "$1" "$slot_id" "$work/config.json" "$LEDGER" "$MARKER" "${@:2}"
}

check setup "$RELAY_CHIEF_PLACEMENT" "$RELAY_CHIEF_SIZE_CLASS" "$work/setup.json"
# The CLI opens the path itself as relay-chief, so that user needs real access:
# /dev/stdin would re-open this file, not inherit the descriptor.
chown root:relay-chief "$work" "$work/setup.json"
chmod 0750 "$work"
chmod 0640 "$work/setup.json"
if ! (cd / && runuser -u relay-chief -- "$NODE" "$CLI" plan "$work/setup.json") >/dev/null 2>&1; then
  refuse 2 "the runtime rejected the configuration"
fi

# Read-only, so a refusal never touches a chief that is already running.
check verify

# Stop the cycle before changing anything it reads.
systemctl disable --now "$TIMER" >/dev/null 2>&1 || refuse 1 "could not stop $TIMER"
for _ in $(seq 1 75); do
  state="$(systemctl show -p ActiveState --value "$SERVICE")"
  case "$state" in
  activating | active | deactivating) sleep 2 ;;
  *) state="" && break ;;
  esac
done
[ -z "$state" ] || refuse 1 "$SERVICE did not stop; the timer is disabled"

# Dispatch never carries over from an earlier bind.
if [ -e "$DISPATCH_DROP_IN" ]; then
  rm -f -- "$DISPATCH_DROP_IN"
  systemctl daemon-reload >/dev/null 2>&1 || refuse 1 "could not reload systemd after removing the dispatch drop-in"
fi

# Repeated now that no cycle can create or configure the ledger concurrently.
check write

chown root:relay-chief "$work/config.json"
chmod 0640 "$work/config.json"
mv -f "$work/config.json" "$CONFIG"

systemctl restart "$CREDENTIALS_UNIT" >/dev/null 2>&1 || refuse 1 "credentials could not be fetched; the timer is disabled"
if [ ! -s "$CREDS_FILE" ] || [ "$(stat -c %a "$CREDS_FILE")" != "600" ]; then
  refuse 1 "credentials are missing or not mode 0600; the timer is disabled"
fi

if [ "$dispatch_opt_in" = "1" ]; then
  install -d -m 0755 "$(dirname "$DISPATCH_DROP_IN")"
  printf '[Service]\nEnvironment=RELAY_CHIEF_RUN_FLAGS=--dispatch\n' >"$DISPATCH_DROP_IN"
  chmod 0644 "$DISPATCH_DROP_IN"
  systemctl daemon-reload >/dev/null 2>&1 || refuse 1 "could not reload systemd after adding the dispatch drop-in"
fi
if [ "$enable_timer" = "1" ]; then
  systemctl enable --now "$TIMER" >/dev/null 2>&1 || refuse 1 "could not enable $TIMER"
  if [ "$dispatch_opt_in" = "1" ]; then
    printf 'relay-chief-bind-slot: bound %s; timer enabled, dispatching\n' "$slot_id"
  else
    printf 'relay-chief-bind-slot: bound %s; timer enabled, not dispatching\n' "$slot_id"
  fi
else
  printf 'relay-chief-bind-slot: bound %s; timer left disabled\n' "$slot_id"
fi
