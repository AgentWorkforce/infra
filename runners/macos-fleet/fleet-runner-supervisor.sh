#!/bin/bash
# Root LaunchDaemon loop for one fleet slot on a Mac. Each pass:
#   1. refuses to work unless xcode-parity.sh passes;
#   2. asks the broker (fleet-runner-jit Worker) for a single-use JIT runner
#      config, authenticating with this Mac's key (never the GitHub App);
#   3. extracts a fresh runner from the pinned tarball into the slot's
#      unprivileged user's home and runs it there, under caffeinate;
#   4. when the runner exits (one job, ephemeral), kills anything the user
#      left behind, wipes the work dir and caches, keeps _diag for 7 days.
# Mint failures back off 30 s -> 10 min. Nothing from the mint response is
# ever logged. Usage: fleet-runner-supervisor.sh <slot>
set -uo pipefail

slot=${1:?usage: fleet-runner-supervisor.sh <slot>}
etc=/etc/fleet-runner
libexec=/usr/local/libexec/fleet-runner
env_file=$etc/$slot.env
auth_file=$etc/$slot.auth
log_dir=/var/log/fleet-runner/$slot
run_dir=/var/run/fleet-runner
state_file=$run_dir/$slot.state

log() { printf '%s fleet-runner[%s] %s\n' "$(date -u +%FT%TZ)" "$slot" "$*"; }
state() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >"$state_file"; }

[ "$(id -u)" = 0 ] || { log "must run as root"; exit 64; }
[ -r "$env_file" ] || { log "missing $env_file"; exit 64; }
[ -r "$auth_file" ] || { log "missing $auth_file"; exit 64; }
# shellcheck disable=SC1090 # KEY=value file written by setup-mac.sh
. "$env_file"
: "${BROKER_URL:?$env_file must set BROKER_URL}"
: "${RUNNER_USER:?$env_file must set RUNNER_USER}"
: "${RUNNER_HOME:?$env_file must set RUNNER_HOME}"
: "${RUNNER_TARBALL:?$env_file must set RUNNER_TARBALL}"
: "${PARITY_RETRY_SECONDS:=300}" "${MINT_BACKOFF_MAX:=600}" "${DIAG_KEEP_DAYS:=7}"
[ -f "$RUNNER_TARBALL" ] || { log "missing runner tarball $RUNNER_TARBALL"; exit 64; }
id "$RUNNER_USER" >/dev/null 2>&1 || { log "no such user $RUNNER_USER"; exit 64; }

mkdir -p "$log_dir" "$run_dir"
chmod 700 "$run_dir"
runner_dir=$RUNNER_HOME/runner
runner_pid=""
backoff=30

as_user() { sudo -n -u "$RUNNER_USER" -H "$@"; }

stop_runner() {
  if [ -n "$runner_pid" ] && kill -0 "$runner_pid" 2>/dev/null; then
    log "stopping runner pid $runner_pid"
    kill -TERM "$runner_pid" 2>/dev/null || true
    for _ in $(seq 1 30); do kill -0 "$runner_pid" 2>/dev/null || break; sleep 1; done
  fi
}

cleanup_user() {
  # Kill whatever the job left running, then wipe its state. Each pass starts
  # from the pinned tarball again, so nothing a job wrote survives it.
  pkill -TERM -u "$RUNNER_USER" 2>/dev/null || true
  sleep 3
  pkill -KILL -u "$RUNNER_USER" 2>/dev/null || true
  if [ -d "$runner_dir/_diag" ]; then
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "$log_dir/diag-$stamp"
    cp -R "$runner_dir/_diag/." "$log_dir/diag-$stamp/" 2>/dev/null || true
  fi
  rm -rf "$runner_dir"
  for d in Library/Caches Library/Developer/Xcode/DerivedData Library/Developer/Xcode/iOS\ DeviceSupport \
           .npm .cache .swiftpm .gradle .cargo/registry Library/org.swift.swiftpm; do
    rm -rf "${RUNNER_HOME:?}/$d"
  done
  for v in DARWIN_USER_TEMP_DIR DARWIN_USER_CACHE_DIR; do
    p=$(as_user getconf "$v" 2>/dev/null || true)
    case "$p" in /private/var/folders/*|/var/folders/*) rm -rf "${p:?}"/* 2>/dev/null || true ;; esac
  done
  find /private/tmp -maxdepth 1 -user "$RUNNER_USER" -exec rm -rf {} + 2>/dev/null || true
  find "$log_dir" -maxdepth 1 -name 'diag-*' -type d -mtime +"$DIAG_KEEP_DAYS" -exec rm -rf {} + 2>/dev/null || true
}

on_term() { log "SIGTERM"; stop_runner; cleanup_user; state "stopped"; exit 0; }
trap on_term TERM INT

mint() {
  # Returns 0 and prints nothing; the config lands in $cfg (0600, root) and
  # the runner name in $runner_name. The broker answers text/plain with the
  # encoded JIT config as the body and the runner name in a header.
  cfg=$run_dir/$slot.jitconfig
  hdr=$run_dir/$slot.headers
  rm -f "$cfg" "$hdr"
  ( umask 077; : >"$cfg"; : >"$hdr" )
  body=$(printf '{"slot":"%s","host":"%s"}' "$slot" "$(scutil --get LocalHostName 2>/dev/null || hostname -s)")
  code=$(curl -sS --max-time 40 -o "$cfg" -D "$hdr" -w '%{http_code}' \
    -H "@$auth_file" -H 'Content-Type: application/json' \
    -X POST --data "$body" "$BROKER_URL/mint" 2>>"$log_dir/curl.err") || code=000
  if [ "$code" != 200 ] || [ ! -s "$cfg" ]; then
    log "mint failed (http $code); see $log_dir/curl.err"
    rm -f "$cfg" "$hdr"
    return 1
  fi
  runner_name=$(awk 'tolower($1)=="x-fleet-runner-name:"{sub(/\r$/,"",$2); print $2}' "$hdr")
  rm -f "$hdr"
  [ -n "$runner_name" ] || runner_name="(unnamed)"
  return 0
}

log "supervisor start (user $RUNNER_USER, home $RUNNER_HOME)"
while :; do
  if ! parity_out=$("$libexec/xcode-parity.sh" 2>&1); then
    log "parity FAILED, not taking jobs; retry in ${PARITY_RETRY_SECONDS}s"
    printf '%s\n' "$parity_out" | grep -v '^ok ' | while read -r l; do log "  $l"; done
    state "parity-failed"
    sleep "$PARITY_RETRY_SECONDS"
    continue
  fi

  cleanup_user
  if ! mint; then
    state "mint-failed backoff=${backoff}s"
    sleep "$backoff"
    backoff=$(( backoff * 2 )); [ "$backoff" -gt "$MINT_BACKOFF_MAX" ] && backoff=$MINT_BACKOFF_MAX
    continue
  fi
  backoff=30

  mkdir -p "$runner_dir"
  if ! tar -xzf "$RUNNER_TARBALL" -C "$runner_dir"; then
    log "runner tarball extract failed"; rm -f "$cfg"; sleep 60; continue
  fi
  chown -R "$RUNNER_USER" "$runner_dir"
  chown "$RUNNER_USER" "$cfg"

  log "runner $runner_name waiting for a job"
  state "running runner=$runner_name"
  # The runner reads the single-use config from the file and deletes it
  # first thing; caffeinate keeps the Mac from sleeping while a job runs.
  # shellcheck disable=SC2016 # $1/$2 are the inner bash's positional args
  as_user env -i HOME="$RUNNER_HOME" USER="$RUNNER_USER" LOGNAME="$RUNNER_USER" \
    PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin DEVELOPER_DIR="${DEVELOPER_DIR:-}" \
    bash -c 'cd "$1" || exit 70; c=$(cat "$2"); rm -f "$2"; exec caffeinate -i ./run.sh --jitconfig "$c"' _ "$runner_dir" "$cfg" \
    >>"$log_dir/runner.log" 2>&1 &
  runner_pid=$!
  wait "$runner_pid"; rc=$?
  runner_pid=""
  rm -f "$cfg"
  log "runner $runner_name exited rc=$rc"
  state "finished runner=$runner_name rc=$rc"
done
