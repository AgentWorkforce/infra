#!/bin/bash
# Root LaunchDaemon loop for one fleet slot on a Mac. Each pass:
#   1. refuses to work unless xcode-parity.sh passes and the data volume is
#      mounted, owned by the slot user and has room (it alerts and waits;
#      it never falls back to the internal disk);
#   2. wipes the slot user's whole home (everything a job touched lives
#      there: runner, _work, _tool, caches, DerivedData, cargo, tmp);
#   3. asks the broker (fleet-runner-jit Worker) for a single-use JIT runner
#      config, authenticating with this Mac's key (never the GitHub App);
#   4. extracts a fresh runner from the pinned tarball into that home and
#      runs it there as the slot user, under caffeinate, with the checked
#      DEVELOPER_DIR and every cache/scratch dir pointed at the home;
#   5. when the runner exits (one job, ephemeral), kills anything the user
#      left behind and goes back to 1. _diag is kept for DIAG_KEEP_DAYS.
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
# Same toolchain settings the parity check uses, so jobs get the checked
# DEVELOPER_DIR and not whatever xcode-select currently points at.
for f in "$libexec/parity.env" "$etc/parity.env"; do
  # shellcheck disable=SC1090 # KEY=value, repo default then per-Mac override
  [ -f "$f" ] && . "$f"
done
: "${BROKER_URL:?$env_file must set BROKER_URL}"
: "${RUNNER_USER:?$env_file must set RUNNER_USER}"
: "${RUNNER_HOME:?$env_file must set RUNNER_HOME}"
: "${RUNNER_TARBALL:?$env_file must set RUNNER_TARBALL}"
: "${DATA_VOLUME:?$env_file must set DATA_VOLUME}"
: "${DEVELOPER_DIR:?$libexec/parity.env must set DEVELOPER_DIR}"
: "${PARITY_RETRY_SECONDS:=300}" "${MINT_BACKOFF_MAX:=600}" "${DIAG_KEEP_DAYS:=7}"
: "${DATA_MAX_GB:=0}" "${DATA_MIN_FREE_GB:=40}" "${ALERT_URL:=}"
[ -f "$RUNNER_TARBALL" ] || { log "missing runner tarball $RUNNER_TARBALL"; exit 64; }
id "$RUNNER_USER" >/dev/null 2>&1 || { log "no such user $RUNNER_USER"; exit 64; }
case "$RUNNER_HOME" in /Volumes/*/gh-runner/"$slot"|/Users/"$RUNNER_USER") ;; *) log "refusing unexpected RUNNER_HOME $RUNNER_HOME"; exit 64 ;; esac

mkdir -p "$log_dir" "$run_dir"
chmod 700 "$run_dir"
runner_dir=$RUNNER_HOME/runner
runner_pid=""
backoff=30

as_user() { sudo -n -u "$RUNNER_USER" -H "$@"; }

alert() {
  # Loud path for problems a human must fix: unified log + optional webhook.
  log "ALERT $*"
  logger -p user.err -t "fleet-runner[$slot]" "$*" 2>/dev/null || true
  if [ -n "$ALERT_URL" ]; then
    curl -sS --max-time 10 -X POST -H 'Content-Type: text/plain' \
      --data "fleet-runner $slot on $(scutil --get LocalHostName 2>/dev/null || hostname -s): $*" "$ALERT_URL" >/dev/null 2>&1 || true
  fi
}

dev_of() { df -P "$1" 2>/dev/null | awk 'NR==2{print $1}'; }

home_ok() {
  # RUNNER_HOME must be a real directory (not a link) owned by the slot user,
  # inside a root-owned parent so the job cannot swap it for something else.
  # Root only ever deletes through this path once these hold.
  parent=$(dirname "$RUNNER_HOME")
  [ ! -L "$RUNNER_HOME" ] && [ -d "$RUNNER_HOME" ] && [ ! -L "$parent" ] \
    && [ "$(stat -f %u "$parent")" = 0 ] && [ "$(stat -f %Su "$RUNNER_HOME")" = "$RUNNER_USER" ]
}

volume_ok() {
  # The data volume must be a mounted filesystem other than the root one,
  # the home must be sane and there must be room. Anything else: refuse.
  if [ "$DATA_VOLUME" != /Users ]; then
    if [ ! -d "$DATA_VOLUME" ] || [ "$(dev_of "$DATA_VOLUME")" = "$(dev_of /)" ]; then
      alert "data volume $DATA_VOLUME is not mounted; not taking jobs"; return 1
    fi
  fi
  if ! home_ok; then
    alert "$RUNNER_HOME missing, a link, or not owned by $RUNNER_USER inside a root-owned dir; not taking jobs"; return 1
  fi
  free_gb=$(df -Pg "$RUNNER_HOME" | awk 'NR==2{print $4}')
  if [ "${free_gb:-0}" -lt "$DATA_MIN_FREE_GB" ]; then
    alert "only ${free_gb}GB free on $DATA_VOLUME (min $DATA_MIN_FREE_GB); not taking jobs"; return 1
  fi
  if [ "$DATA_MAX_GB" -gt 0 ]; then
    used_gb=$(( $(du -sk "$RUNNER_HOME" 2>/dev/null | awk '{print $1}') / 1048576 ))
    if [ "$used_gb" -gt "$DATA_MAX_GB" ]; then
      alert "$RUNNER_HOME uses ${used_gb}GB (max $DATA_MAX_GB) after cleanup; not taking jobs"; return 1
    fi
  fi
  return 0
}

stop_runner() {
  if [ -n "$runner_pid" ] && kill -0 "$runner_pid" 2>/dev/null; then
    log "stopping runner pid $runner_pid"
    kill -TERM "$runner_pid" 2>/dev/null || true
    for _ in $(seq 1 30); do kill -0 "$runner_pid" 2>/dev/null || break; sleep 1; done
  fi
}

cleanup_user() {
  # Kill whatever the job left running, then reset the whole home: no
  # .gitconfig, .npmrc, .ssh, cargo config or cache survives into the next
  # job. Only done when home_ok holds, so root never follows a job-made
  # link; the per-user /var/folders and /tmp leftovers are removed as the
  # user, who can only reach its own files.
  pkill -TERM -u "$RUNNER_USER" 2>/dev/null || true
  sleep 3
  pkill -KILL -u "$RUNNER_USER" 2>/dev/null || true
  if home_ok; then
    if [ -d "$runner_dir/_diag" ]; then
      stamp=$(date -u +%Y%m%dT%H%M%SZ)
      mkdir -p "$log_dir/diag-$stamp"
      # Read as the user (tar cannot reach what the user cannot), unpack as root.
      as_user tar -C "$runner_dir" -cf - _diag 2>/dev/null | tar -C "$log_dir/diag-$stamp" -xf - --no-same-owner --no-same-permissions 2>/dev/null || true
    fi
    chflags -R nouchg,nouappnd "$RUNNER_HOME" 2>/dev/null || true
    rm -rf "${RUNNER_HOME:?}"
    mkdir -m 700 "$RUNNER_HOME" && chown "$RUNNER_USER:staff" "$RUNNER_HOME"
  fi
  for v in DARWIN_USER_TEMP_DIR DARWIN_USER_CACHE_DIR; do
    p=$(as_user getconf "$v" 2>/dev/null || true)
    case "$p" in /private/var/folders/*|/var/folders/*) as_user rm -rf "${p:?}" 2>/dev/null || true ;; esac
  done
  as_user find /private/tmp -maxdepth 1 -user "$RUNNER_USER" -exec rm -rf {} + 2>/dev/null || true
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

log "supervisor start (user $RUNNER_USER, home $RUNNER_HOME, developer_dir $DEVELOPER_DIR)"
while :; do
  if ! parity_out=$("$libexec/xcode-parity.sh" 2>&1); then
    log "parity FAILED, not taking jobs; retry in ${PARITY_RETRY_SECONDS}s"
    printf '%s\n' "$parity_out" | grep -v '^ok ' | while read -r l; do log "  $l"; done
    state "parity-failed"
    sleep "$PARITY_RETRY_SECONDS"
    continue
  fi

  cleanup_user
  if ! volume_ok; then
    state "volume-unavailable"
    sleep "$PARITY_RETRY_SECONDS"
    continue
  fi
  if ! mint; then
    state "mint-failed backoff=${backoff}s"
    sleep "$backoff"
    backoff=$(( backoff * 2 )); [ "$backoff" -gt "$MINT_BACKOFF_MAX" ] && backoff=$MINT_BACKOFF_MAX
    continue
  fi
  backoff=30

  mkdir -p "$runner_dir" "$RUNNER_HOME/tmp" "$RUNNER_HOME/cache"
  if ! tar -xzf "$RUNNER_TARBALL" -C "$runner_dir"; then
    log "runner tarball extract failed"; rm -f "$cfg"; sleep 60; continue
  fi
  # Job-visible env (the runner reads .env in its root): every cache and
  # scratch dir stays on the data volume, not in /var/folders or /Users.
  # Xcode's DerivedData default (~/Library/Developer/Xcode/DerivedData) is
  # already under this home.
  cat >"$runner_dir/.env" <<ENV
TMPDIR=$RUNNER_HOME/tmp
DEVELOPER_DIR=$DEVELOPER_DIR
CARGO_HOME=$RUNNER_HOME/cache/cargo
CARGO_TARGET_DIR=$RUNNER_HOME/cache/cargo-target
npm_config_cache=$RUNNER_HOME/cache/npm
XDG_CACHE_HOME=$RUNNER_HOME/cache
HOMEBREW_CACHE=$RUNNER_HOME/cache/homebrew
ENV
  chown -R "$RUNNER_USER:staff" "$runner_dir" "$RUNNER_HOME/tmp" "$RUNNER_HOME/cache"

  log "runner $runner_name waiting for a job"
  state "running runner=$runner_name"
  # The single-use config stays in root's 0700 run dir; the runner's shell
  # gets it as an already-open stdin and refuses to start on an empty read.
  # caffeinate keeps the Mac from sleeping while a job runs.
  # shellcheck disable=SC2016 # $1 is the inner bash's positional arg
  as_user env -i HOME="$RUNNER_HOME" USER="$RUNNER_USER" LOGNAME="$RUNNER_USER" TMPDIR="$RUNNER_HOME/tmp" \
    PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin DEVELOPER_DIR="$DEVELOPER_DIR" \
    bash -c 'cd "$1" || exit 70; c=$(cat); [ -n "$c" ] || exit 71; exec caffeinate -i ./run.sh --jitconfig "$c" </dev/null' _ "$runner_dir" \
    <"$cfg" >>"$log_dir/runner.log" 2>&1 &
  runner_pid=$!
  rm -f "$cfg"
  wait "$runner_pid"; rc=$?
  runner_pid=""
  log "runner $runner_name exited rc=$rc"
  state "finished runner=$runner_name rc=$rc"
done
