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
# Mint failures back off 30 s -> 10 min, and so does a runner that exits
# within RUNNER_MIN_LIFETIME seconds of starting (a bad config, a GitHub
# rejection or a broken runner would otherwise mint a new config every few
# seconds). Nothing from the mint response is ever logged. The JIT config
# reaches the runner only as ACTIONS_RUNNER_INPUT_JITCONFIG in its own
# environment, which the runner strips before starting any job; never on the
# command line, which every local user can read with ps.
# Usage: fleet-runner-supervisor.sh <slot>
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
: "${RUNNER_MIN_LIFETIME:=60}" "${FAST_EXIT_ALERT_AFTER:=3}"
: "${DATA_MAX_GB:=0}" "${DATA_MIN_FREE_GB:=40}" "${ALERT_URL:=}"
[ -f "$RUNNER_TARBALL" ] || { log "missing runner tarball $RUNNER_TARBALL"; exit 64; }
id "$RUNNER_USER" >/dev/null 2>&1 || { log "no such user $RUNNER_USER"; exit 64; }
case "$RUNNER_HOME" in /Volumes/*/gh-runner/"$slot"|/Users/"$RUNNER_USER") ;; *) log "refusing unexpected RUNNER_HOME $RUNNER_HOME"; exit 64 ;; esac

mkdir -p "$log_dir" "$run_dir"
chmod 700 "$run_dir"
runner_dir=$RUNNER_HOME/runner
runner_pid=""
backoff=30
provenance_warned=0
exit_backoff=30
fast_exits=0

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

ensure_home() {
  # This daemon, never setup-mac.sh, makes the home's parent and the home.
  # A directory created from an admin's Terminal carries
  # com.apple.provenance, and macOS then denies a launchd-started runner
  # readdir on it (and root, from here, unlink inside it) while the admin's
  # own shell sees nothing wrong. The parent stays root-owned so the slot
  # user can never replace its home with a link; the home is 0700, the user's.
  parent=$(dirname "$RUNNER_HOME")
  if [ ! -e "$parent" ]; then
    install -d -o root -g wheel -m 755 "$parent" || return 1
    log "created $parent"
  fi
  if [ ! -e "$RUNNER_HOME" ]; then
    install -d -o "$RUNNER_USER" -g staff -m 700 "$RUNNER_HOME" || return 1
    tmutil addexclusion -p "$RUNNER_HOME" >/dev/null 2>&1 || true
    log "created $RUNNER_HOME"
  fi
  # A tagged tree is reported once per start, not refused: whether macOS
  # enforces the block depends on its version, and a Mac that still works
  # should keep working until the admin migrates it (README: Operations).
  if [ "$provenance_warned" = 0 ]; then
    for p in "$parent" "$RUNNER_HOME"; do
      if xattr -p com.apple.provenance "$p" >/dev/null 2>&1; then
        alert "$p carries com.apple.provenance (made from an admin shell, not by this daemon); if runners exit at once, from Terminal: sudo rm -rf $parent, then kickstart this slot (README: Operations)"
        provenance_warned=1
        break
      fi
    done
  fi
  return 0
}

volume_ok() {
  # The data volume must be a mounted filesystem other than the root one,
  # the home must be sane and there must be room. Anything else: refuse.
  if [ "$DATA_VOLUME" != /Users ]; then
    if [ ! -d "$DATA_VOLUME" ] || [ "$(dev_of "$DATA_VOLUME")" = "$(dev_of /)" ]; then
      alert "data volume $DATA_VOLUME is not mounted; not taking jobs"; return 1
    fi
  fi
  ensure_home || return 1
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
  # The group opens the file here, before the fork, so deleting the name
  # right after cannot race the child's open. The shell hands the config to
  # the runner as ACTIONS_RUNNER_INPUT_JITCONFIG (the runner's documented
  # env form of --jitconfig; Runner.Listener reads it, masks it and removes
  # it from its environment before any job starts), not as an argument:
  # argv is visible to every local user through ps, the environment of a
  # process is not.
  # caffeinate keeps the Mac from sleeping while a job runs.
  started=$(date +%s)
  log_mark=$(stat -f %z "$log_dir/runner.log" 2>/dev/null || echo 0)
  {
    # shellcheck disable=SC2016 # $1 is the inner bash's positional arg
    as_user env -i HOME="$RUNNER_HOME" USER="$RUNNER_USER" LOGNAME="$RUNNER_USER" TMPDIR="$RUNNER_HOME/tmp" \
      PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin DEVELOPER_DIR="$DEVELOPER_DIR" \
      bash -c 'cd "$1" || exit 70; c=$(cat); [ -n "$c" ] || exit 71; ACTIONS_RUNNER_INPUT_JITCONFIG=$c exec caffeinate -i ./run.sh </dev/null' _ "$runner_dir" \
      <&3 >>"$log_dir/runner.log" 2>&1 &
    runner_pid=$!
  } 3<"$cfg"
  rm -f "$cfg"
  wait "$runner_pid"; rc=$?
  runner_pid=""
  lived=$(( $(date +%s) - started ))
  # The runner prints "Running job: <name>" when it takes one; a job that
  # finishes in under a minute is a normal short run, not a failed start.
  ran_job=$(tail -c "+$(( log_mark + 1 ))" "$log_dir/runner.log" 2>/dev/null | grep -c 'Running job:' || true)
  log "runner $runner_name exited rc=$rc after ${lived}s (jobs: $ran_job)"
  if [ "$lived" -lt "$RUNNER_MIN_LIFETIME" ] && [ "$ran_job" -eq 0 ]; then
    # A runner that dies this fast without a job never waited for one: the
    # config was rejected, the runner cannot start or read its home, or
    # GitHub turned it away. Each pass mints a config and registers a runner,
    # so slow down instead of looping, and copy the runner's last lines next
    # to this log so the cause is in one place. The runner masks its own
    # secrets in that output.
    fast_exits=$(( fast_exits + 1 ))
    tail -c "+$(( log_mark + 1 ))" "$log_dir/runner.log" 2>/dev/null | tail -n 15 | while IFS= read -r l; do log "  runner: $l"; done
    state "fast-exit runner=$runner_name rc=$rc lived=${lived}s backoff=${exit_backoff}s"
    if [ "$fast_exits" -eq "$FAST_EXIT_ALERT_AFTER" ]; then
      alert "runner exited $fast_exits times within ${RUNNER_MIN_LIFETIME}s of starting (last rc=$rc); see $log_dir/runner.log"
    fi
    # Nothing it left behind runs through the wait: kill and wipe first.
    cleanup_user
    sleep "$exit_backoff"
    exit_backoff=$(( exit_backoff * 2 )); [ "$exit_backoff" -gt "$MINT_BACKOFF_MAX" ] && exit_backoff=$MINT_BACKOFF_MAX
    continue
  fi
  exit_backoff=30
  fast_exits=0
  state "finished runner=$runner_name rc=$rc lived=${lived}s"
done
