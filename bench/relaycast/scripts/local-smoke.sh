#!/usr/bin/env bash
# Runs the harness end to end against a local relaycast-self-host container
# (SQLite backend): provision, sink, producer phases from a plan, an
# offline/online backlog cycle, an optional container restart mid-load, and
# the report. It proves the harness, not Relaycast performance.
#
#   bench/relaycast/scripts/local-smoke.sh [plan.json] [--restart-at <s>]
#
# Scratch goes to ${TMPDIR:-$HOME/.agent-tmp}/rcb-local; generated secrets
# stay in files there (0600) and never reach argv or logs.
set -euo pipefail
cd "$(dirname "$0")/../../.."
PLAN="${1:-bench/relaycast/plans/local-smoke.json}"
RESTART_AT=""
[[ "${2:-}" == --restart-at ]] && RESTART_AT="$3"
IMAGE="${RCB_IMAGE:-ghcr.io/agentworkforce/relaycast-self-host@sha256:ab9dd6781e68f09d5e2e686a17088f9ad533978ef13d974a47d6c212d8eedbde}"
ROOT="${TMPDIR:-$HOME/.agent-tmp}/rcb-local"
OUT="$ROOT/run-$(date +%Y%m%d%H%M%S)"
PORT="${RCB_LOCAL_PORT:-18787}"
mkdir -p "$ROOT/sec" "$ROOT/data" "$OUT"
umask 077
[[ -s "$ROOT/sec/internal" ]] || head -c 32 /dev/urandom | base64 | tr -d '\n' >"$ROOT/sec/internal"
[[ -s "$ROOT/sec/boot" ]] || head -c 32 /dev/urandom | base64 | tr -d '\n' >"$ROOT/sec/boot"
chmod 644 "$ROOT/sec/"*; chmod 777 "$ROOT/data"

if ! curl -sf "127.0.0.1:${PORT}/health" >/dev/null; then
  docker rm -f rcb-local >/dev/null 2>&1 || true
  docker run -d --name rcb-local -p "127.0.0.1:${PORT}:8787" -v "$ROOT/data:/data" -v "$ROOT/sec:/sec:ro" \
    -e PORT=8787 -e RELAYCAST_DB_PATH=/data/relaycast.db -e RELAYCAST_INTERNAL_SECRET_FILE=/sec/internal \
    -e RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET_FILE=/sec/boot -e RELAYCAST_PUBLIC_WORKSPACE_CREATE=false \
    -e RELAYCAST_MAILBOX_DEPTH_CAP=20000 "$IMAGE" --base-url https://cast.bench.invalid >/dev/null
  for _ in $(seq 1 30); do curl -sf "127.0.0.1:${PORT}/health" >/dev/null && break; sleep 1; done
fi

RCB_RUN="local$(date +%H%M%S)"
export RCB_BASE_URL="http://127.0.0.1:${PORT}" RCB_INTERNAL_SECRET_FILE="$ROOT/sec/internal" RCB_RUN RCB_FIXTURE="$OUT/fixture.json"
RCB_WORKSPACES=2 RCB_PRODUCERS=4 RCB_RECEIVERS=20 RCB_AGENTS_PER_NODE=2 RCB_CHANNELS=2 RCB_CHANNEL_MEMBERS=5 \
  RCB_FANOUT_MEMBERS=15 RCB_BACKLOG_RECEIVERS=2 RCB_SINK_SHARDS=1 RCB_OUT="$OUT/provision.json" \
  node bench/relaycast/harness/provision.mjs 2>"$OUT/provision.log"

RCB_SHARD=0 RCB_PORT=19090 RCB_OUT="$OUT/sink-0.json" node bench/relaycast/harness/sink.mjs 2>"$OUT/sink-0.log" &
SINK=$!
trap 'kill -TERM $SINK 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do [[ "$(curl -s -o /dev/null -w '%{http_code}' 127.0.0.1:19090/ready)" == 200 ]] && break; sleep 1; done

# Chaos: restart the container RESTART_AT seconds into the "s-chaos" phase.
if [[ -n "$RESTART_AT" ]]; then
  (bench/relaycast/scripts/at-phase.sh http://127.0.0.1:19190/ s-chaos "$RESTART_AT" -- ${RCB_CHAOS_CMD:-docker restart rcb-local} >"$OUT/restart.txt" 2>&1 || true) &
fi

RCB_SINK_URLS=http://127.0.0.1:19090 RCB_STATUS_PORT=19190 RCB_PLAN="$PLAN" RCB_SHARD=0 RCB_SHARDS=1 RCB_OUT="$OUT/producer-0.json" node bench/relaycast/harness/producer.mjs 2>"$OUT/producer-0.log"
sleep 10
kill -TERM "$SINK"; wait "$SINK" 2>/dev/null || true
trap - EXIT
node bench/relaycast/harness/report.mjs "$OUT" --arm local >/dev/null
echo "$OUT"
column -s, -t <"$OUT/integrity.csv"
column -s, -t <"$OUT/delivery.csv"
