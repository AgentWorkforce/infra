#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/logs.sh"

# The match is at the start, followed by output larger than a pipe buffer.
# A producer piped into grep -q can fail here despite finding the match.
large_log() {
  python3 -c 'import sys; sys.stdout.write("wait-for-role: waiting\n" + "x" * 1048576 + "\n")'
}
log_matches -F "wait-for-role: waiting" large_log

# Finding a matching line never hides a failed kubectl/log producer.
failed_log() { printf '%s\n' 'wait-for-role: waiting'; return 23; }
if log_matches -F "wait-for-role: waiting" failed_log; then
  echo "a failed producer was accepted" >&2
  exit 1
else
  [ "$?" -eq 23 ] || { echo "producer exit status was lost" >&2; exit 1; }
fi

if log_matches -F "wait-for-role: waiting" printf '%s\n' "unrelated output"; then
  echo "a missing log message was accepted" >&2
  exit 1
fi
log_matches -xF "bootstrap: exit 0" printf '%s\n' "bootstrap: exit 0"
if log_matches -xF "bootstrap: exit 0" printf '%s\n' "bootstrap: exit 0 trailing"; then
  echo "an inexact bootstrap result was accepted" >&2
  exit 1
fi
echo "log assertions: large early match, producer failure, missing and exact lines pass"
