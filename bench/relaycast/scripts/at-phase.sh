#!/usr/bin/env bash
# Runs a command at a point in a producer phase, timed on the producer's
# /status clock, and prints the epoch-ms it fired (for the chaos timeline).
#
#   at-phase.sh <status-url> <phase-label> <seconds-into-phase> -- <command...>
set -euo pipefail
# Scratch never goes to /tmp on shared hosts.
export TMPDIR="${TMPDIR:-$HOME/.agent-tmp}"; mkdir -p "$TMPDIR"
url="$1" phase="$2" at="$3"; shift 3
[[ "${1:-}" == -- ]] && shift
while true; do
  s="$(curl -sf "$url" || true)"
  if [[ -n "$s" ]]; then
    fire="$(node -e '
      const s = JSON.parse(process.argv[1]); const [p, at] = [process.argv[2], Number(process.argv[3])];
      if (s.completed.includes(p)) { console.log("missed"); process.exit(0); }
      console.log(s.phase === p && s.now - s.phaseStartedAt >= at * 1000 ? "yes" : "no");' "$s" "$phase" "$at")"
    [[ "$fire" == missed ]] && { echo "phase $phase already finished" >&2; exit 1; }
    [[ "$fire" == yes ]] && break
  fi
  sleep 0.5
done
date +%s%3N
"$@"
