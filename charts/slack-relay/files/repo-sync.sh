#!/bin/sh
# Keeps read-only copies of GitHub repositories for the slack-relay agents.
#
# Runs in the agent host pod as a sidecar. Every REPOS_REFRESH_MINUTES it
# shallow-fetches each repo in REPOS_LIST into a bare cache (REPOS_CACHE_DIR,
# never mounted into the host) and, when the commit changed, checks it out into
# REPOS_DIR/<owner>/<name>, which the host mounts read-only.
#
# The token (GITHUB_TOKEN) reaches git only through GIT_ASKPASS, which reads it
# from this container's environment. It is never put in a URL, a remote, a git
# config or a log line. The checkouts have no .git directory at all, and the
# cache has no remotes: the URL is given on each fetch's command line.
#
# REPOS_LIST: one repo per line, "owner/name" or "owner/name ref" (a branch,
# tag or commit; default: the repo's default branch). Empty: every repo the
# token can read, listed again on each pass by REPOS_LIST_CMD (repo-list.mts,
# GET /user/repos), so newly granted repos appear on the next pass.
#
# After a pass with a good list, checkouts of repos no longer listed (access
# revoked, or dropped from REPOS_LIST) are removed. A repo that fails to fetch
# keeps its last checkout; a failed listing removes nothing.
set -u

dir=${REPOS_DIR:-/repos}
cache=${REPOS_CACHE_DIR:-/var/cache/repo-sync}
base=${REPOS_BASE_URL:-https://github.com}
base=${base%/}
minutes=${REPOS_REFRESH_MINUTES:-15}
# A stalled fetch or listing must not hold up the whole pass.
limit=${REPOS_TIMEOUT_SECONDS:-600}
once=${REPOS_SYNC_ONCE:-}
here=$(dirname "$0")
list_cmd=${REPOS_LIST_CMD:-node --disable-warning=ExperimentalWarning $here/repo-list.mts --print}

log() { echo "repo-sync: $*"; }

case $minutes in '' | *[!0-9]* | 0) log "REPOS_REFRESH_MINUTES must be a positive integer"; exit 2 ;; esac
case $limit in '' | *[!0-9]* | 0) log "REPOS_TIMEOUT_SECONDS must be a positive integer"; exit 2 ;; esac
[ -n "${GITHUB_TOKEN:-}" ] || { log "GITHUB_TOKEN is not set"; exit 2; }

# Git's own state (HOME, askpass helper) lives in a private temp dir; the
# askpass helper holds no secret, it prints the token from the environment.
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
askpass=$work/askpass
cat >"$askpass" <<'EOF'
#!/bin/sh
case $1 in
  Username*) echo x-access-token ;;
  *) printf '%s\n' "$GITHUB_TOKEN" ;;
esac
EOF
chmod 700 "$askpass"
export HOME="$work" GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
# No credential helper may store what askpass returns.
gitc() { git -c credential.helper= -c core.symlinks=false -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 "$@"; }
# Runs a command under the time limit (coreutils timeout; the image has it).
limited() { if command -v timeout >/dev/null 2>&1; then timeout -k 10 "$limit" "$@"; else "$@"; fi; }

# Git's first fatal/error line (else its last line), with the token masked
# should it ever appear.
redact() {
  awk 'BEGIN { t = ENVIRON["GITHUB_TOKEN"] }
    { if (t != "") while ((i = index($0, t)) > 0) $0 = substr($0, 1, i - 1) "***" substr($0, i + length(t)) }
    first == "" && /^(fatal|error):/ { first = $0 }
    { last = $0 }
    END { print (first != "" ? first : last) }'
}

valid_part() { case $1 in '' | . | .. | *[!A-Za-z0-9._-]*) return 1 ;; esac; }

sync_one() { # owner/name [ref]
  repo=$1 ref=${2:-}
  owner=${repo%%/*} name=${repo#*/}
  if [ "$owner/$name" != "$repo" ] || ! valid_part "$owner" || ! valid_part "$name"; then
    log "$repo: not an owner/name; skipped"
    return 1
  fi
  case $ref in -* | *..* | *[!A-Za-z0-9._/-]*) log "$repo: bad ref; skipped"; return 1 ;; esac
  label=$repo${ref:+@$ref}
  bare=$cache/$owner/$name.git
  [ -d "$bare" ] || gitc init -q --bare "$bare" || { log "$label: cannot create cache"; return 1; }
  if ! err=$(limited git -c credential.helper= -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 -C "$bare" fetch -q --depth 1 --no-tags "$base/$owner/$name.git" "${ref:-HEAD}" 2>&1); then
    log "$label: fetch failed: $(printf '%s\n' "$err" | redact)"
    return 1
  fi
  sha=$(gitc -C "$bare" rev-parse --verify -q 'FETCH_HEAD^{commit}') || { log "$label: fetched no commit"; return 1; }
  # The cache never gets a remote, but scrub anything credential-shaped anyway.
  gitc -C "$bare" config --remove-section remote.origin 2>/dev/null
  gitc -C "$bare" config --unset-all http.extraheader 2>/dev/null
  dest=$dir/$owner/$name
  if [ "$(cat "$cache/$owner/$name.sha" 2>/dev/null)" = "$sha" ] && [ -d "$dest" ]; then
    log "$label $sha unchanged"
    return 0
  fi
  # Check out into $tmp (on the same volume, outside every owner/name), then
  # swap it in with two renames: the path is missing only between them, and
  # the old tree is put back if the new one can't be moved in.
  stage=$tmp/stage old=$tmp/old
  rm -rf "$stage" "$old"
  mkdir -p "$stage" "$dir/$owner" || return 1
  if ! err=$(GIT_INDEX_FILE=$work/index gitc --git-dir="$bare" --work-tree="$stage" read-tree "$sha" 2>&1 &&
    GIT_INDEX_FILE=$work/index gitc --git-dir="$bare" --work-tree="$stage" checkout-index -a -f 2>&1); then
    log "$label: checkout failed: $(printf '%s\n' "$err" | redact)"
    rm -rf "$stage" "$work/index"
    return 1
  fi
  rm -f "$work/index"
  if [ -e "$dest" ] && ! mv "$dest" "$old"; then
    log "$label: cannot move the old checkout aside"
    rm -rf "$stage"
    return 1
  fi
  if ! mv "$stage" "$dest"; then
    log "$label: cannot publish the new checkout; keeping the old one"
    [ -e "$old" ] && mv "$old" "$dest"
    rm -rf "$stage"
    return 1
  fi
  rm -rf "$old"
  printf '%s\n' "$sha" >"$cache/$owner/$name.sha"
  # Shallow fetches pile up objects; keep the cache to the latest commit.
  gitc -C "$bare" update-ref refs/sync/head "$sha"
  gitc -C "$bare" reflog expire --expire=now --all 2>/dev/null
  gitc -C "$bare" gc -q --prune=now 2>/dev/null
  log "$label $sha updated"
}

# Removes checkouts (and their caches) of repos not in $1 (owner/name lines).
prune() {
  # Repo names may start with a dot (.github); owners never do, so the
  # staging dir ($tmp) is never taken for an owner.
  for d in "$dir"/*/* "$dir"/*/.[!.]* "$dir"/*/..?*; do
    [ -d "$d" ] || continue
    rel=${d#"$dir"/}
    printf '%s\n' "$1" | grep -qxF "$rel" && continue
    rm -rf "$d" "$cache/$rel.git" "$cache/$rel.sha"
    log "$rel removed (no longer listed)"
  done
  for o in "$dir"/*/; do rmdir "$o" 2>/dev/null; done
  return 0
}

# Staging for checkouts: on the checkout volume so renames are atomic, under a
# name no GitHub owner can have (owners never start with a dot).
tmp=$dir/.repo-sync
mkdir -p "$dir" "$cache" || exit 1
rm -rf "$tmp"
if [ -n "${REPOS_LIST:-}" ]; then
  log "syncing $(printf '%s\n' "$REPOS_LIST" | grep -c '[^[:space:]]') listed repo(s) from $base every $minutes min"
else
  log "syncing every repo the token can read from $base every $minutes min"
fi
while :; do
  ok=0 failed=0
  # shellcheck disable=SC2086 # list_cmd is a command line, split on purpose
  if [ -n "${REPOS_LIST:-}" ]; then
    list=$REPOS_LIST listed=1
  elif list=$(limited $list_cmd 2>"$work/list.err"); then
    listed=1
    log "token can read $(printf '%s\n' "$list" | grep -c '[^[:space:]]') repo(s)"
  else
    listed=
    log "listing repos failed, keeping current checkouts: $(redact <"$work/list.err")"
    failed=1
  fi
  if [ -n "$listed" ]; then
    # A here-document, not a pipe, so the counters survive the loop.
    while read -r repo ref _; do
      [ -n "$repo" ] || continue
      if sync_one "$repo" "$ref"; then ok=$((ok + 1)); else failed=$((failed + 1)); fi
    done <<EOF
$list
EOF
    prune "$(printf '%s\n' "$list" | awk 'NF { print $1 }')"
  fi
  log "pass done: $ok ok, $failed failed"
  if [ -n "$once" ]; then [ "$failed" -eq 0 ]; exit; fi
  sleep $((minutes * 60))
done
