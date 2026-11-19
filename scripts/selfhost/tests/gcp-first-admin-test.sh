#!/usr/bin/env bash
# Offline behavioral tests for docs/gcp-install/first-admin.sh. gcloud, kubectl
# and curl are mocked; no network, cluster or cloud access is used.
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${TEST_DIR}/../../../docs/gcp-install/first-admin.sh"
TEST_BASH="${TEST_BASH:-bash}"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"
mkdir -p "$BIN"

fail() { printf 'not ok - gcp-first-admin: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - gcp-first-admin: %s\n' "$*"; }

cat >"$BIN/kubectl" <<'MOCK'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$MOCK_LOG"
printf '%s' 'setup-key-value' | base64
MOCK
# "secrets describe" fails (no secret yet) unless MOCK_SECRET_EXISTS is set;
# "secrets create" keeps what it reads on stdin.
cat >"$BIN/gcloud" <<'MOCK'
#!/usr/bin/env bash
printf 'gcloud %s\n' "$*" >>"$MOCK_LOG"
case " $* " in
  *" secrets describe "*) [ -n "${MOCK_SECRET_EXISTS:-}" ] ;;
  *" secrets create "*) cat >"$MOCK_DIR/secret-manager-value" ;;
  *) exit 1 ;;
esac
MOCK
# Keeps the request body, logs the arguments, answers MOCK_HTTP_CODE.
cat >"$BIN/curl" <<'MOCK'
#!/usr/bin/env bash
cat >"$MOCK_DIR/curl-body"
out=""
previous=""
for arg in "$@"; do
  printf 'curl-arg %s\n' "$arg" >>"$MOCK_LOG"
  [ "$previous" = "-o" ] && out="$arg"
  previous="$arg"
done
printf '%s' '{"error":"mock_error","message":"mock message"}' >"$out"
printf '%s' "${MOCK_HTTP_CODE:-200}"
MOCK
chmod +x "$BIN/kubectl" "$BIN/gcloud" "$BIN/curl"

# run <case name> [VAR=value ...] -- <script arguments>: runs the script in a
# fresh case directory; sets DIR, STATUS, and leaves stdout+stderr in $DIR/out.
run() {
  local name="$1"; shift
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  DIR="$ROOT/$name"
  mkdir -p "$DIR"
  : >"$DIR/log"
  STATUS=0
  env PATH="$BIN:$PATH" MOCK_LOG="$DIR/log" MOCK_DIR="$DIR" ${envs[@]+"${envs[@]}"} \
    "$TEST_BASH" "$SCRIPT" "$@" >"$DIR/out" 2>&1 || STATUS=$?
}
posted_password() { jq -r .password "$DIR/curl-body"; }
no_password_in_output() {
  local pw="$1"
  [ "${#pw}" -eq 32 ] || fail "$2: the password is not 32 characters"
  ! grep -qF -- "$pw" "$DIR/out" "$DIR/log" || fail "$2: the password was printed or put on a command line"
  ! grep -qF -- 'setup-key-value' "$DIR/out" "$DIR/log" || fail "$2: the setup key was printed or put on a command line"
}

# 1. Default: api.<app hostname>, Secret Manager.
run default -- relay.example.com example-project
[ "$STATUS" = 0 ] || fail "default run failed: $(cat "$DIR/out")"
grep -qx 'curl-arg https://api.relay.example.com/api/v1/auth/password/setup-key' "$DIR/log" || fail "default API host is not api.<app hostname>"
grep -qx 'curl-arg Origin: https://relay.example.com' "$DIR/log" || fail "Origin is not the app hostname"
grep -q '^gcloud secrets create agent-relay-first-admin-password --project example-project ' "$DIR/log" || fail "the password was not stored in Secret Manager"
[ "$(jq -r .setupKey "$DIR/curl-body")" = setup-key-value ] || fail "the setup key was not posted"
[ "$(posted_password)" = "$(cat "$DIR/secret-manager-value")" ] || fail "the posted password is not the stored one"
no_password_in_output "$(posted_password)" default
grep -q 'kubectl -n agent-relay ' "$DIR/log" || fail "the default namespace is not agent-relay"
pass "default host and Secret Manager are unchanged"

# 2. API_HOST: another API host; the Origin stays the app hostname.
run api-host API_HOST=relay-api.example.com -- relay.example.com example-project relay-ns
[ "$STATUS" = 0 ] || fail "API_HOST run failed: $(cat "$DIR/out")"
grep -qx 'curl-arg https://relay-api.example.com/api/v1/auth/password/setup-key' "$DIR/log" || fail "API_HOST was not called"
! grep -q 'curl-arg https://api\.relay\.example\.com' "$DIR/log" || fail "api.<app hostname> was still called"
grep -qx 'curl-arg Origin: https://relay.example.com' "$DIR/log" || fail "Origin changed with API_HOST"
grep -q 'kubectl -n relay-ns ' "$DIR/log" || fail "the namespace argument was not used"
pass "API_HOST replaces the API host only"

# 3. API_HOST is validated like the app hostname, before anything runs.
for bad in 'https://relay-api.example.com' 'relay-api.example.com/path' 'a b' 'x;id'; do
  run bad-api-host "API_HOST=$bad" -- relay.example.com example-project
  [ "$STATUS" = 2 ] || fail "API_HOST '$bad' was accepted"
  [ ! -s "$DIR/log" ] || fail "a command ran with API_HOST '$bad'"
done
run bad-app-host -- 'https://relay.example.com' example-project
[ "$STATUS" = 2 ] && [ ! -s "$DIR/log" ] || fail "a bad app hostname was accepted"
pass "host names are validated before any command"

# 4. PASSWORD_FILE: a new 0600 file, no gcloud.
run password-file "PASSWORD_FILE=$ROOT/password-file/pw" -- relay.example.com -
[ "$STATUS" = 0 ] || fail "PASSWORD_FILE run failed: $(cat "$DIR/out")"
! grep -q '^gcloud ' "$DIR/log" || fail "gcloud ran with PASSWORD_FILE"
[ "$(ls -l "$DIR/pw" | cut -c1-10)" = '-rw-------' ] || fail "the password file is not mode 0600"
[ "$(cat "$DIR/pw")" = "$(posted_password)" ] || fail "the posted password is not the one in the file"
no_password_in_output "$(posted_password)" PASSWORD_FILE
grep -q "password in the file $DIR/pw" "$DIR/out" || fail "the result does not name the password file"
pass "PASSWORD_FILE keeps the password in a 0600 file without gcloud"

# 5. PASSWORD_FILE without gcloud installed at all.
NOGCLOUD="$ROOT/nogcloud-bin"
mkdir -p "$NOGCLOUD"
for tool in kubectl curl; do cp "$BIN/$tool" "$NOGCLOUD/$tool"; done
for tool in bash env jq openssl base64 cat grep tr cut mktemp chmod rm; do
  ln -s "$(command -v "$tool")" "$NOGCLOUD/$tool"
done
DIR="$ROOT/no-gcloud"; mkdir -p "$DIR"; : >"$DIR/log"
env PATH="$NOGCLOUD" MOCK_LOG="$DIR/log" MOCK_DIR="$DIR" PASSWORD_FILE="$DIR/pw" \
  "$NOGCLOUD/bash" "$SCRIPT" relay.example.com - >"$DIR/out" 2>&1 || fail "PASSWORD_FILE still needs gcloud: $(cat "$DIR/out")"
STATUS=0
env PATH="$NOGCLOUD" MOCK_LOG="$DIR/log" MOCK_DIR="$DIR" \
  "$NOGCLOUD/bash" "$SCRIPT" relay.example.com example-project >"$DIR/out" 2>&1 || STATUS=$?
[ "$STATUS" = 2 ] && grep -q 'gcloud is required' "$DIR/out" || fail "the default mode did not ask for gcloud"
pass "gcloud is required only for Secret Manager"

# 6. An existing password is never replaced, in either store.
printf 'earlier\n' >"$ROOT/existing-pw"
run existing-file "PASSWORD_FILE=$ROOT/existing-pw" -- relay.example.com -
[ "$STATUS" = 1 ] || fail "an existing password file was accepted"
[ "$(cat "$ROOT/existing-pw")" = earlier ] || fail "an existing password file was replaced"
! grep -q '^curl-arg ' "$DIR/log" || fail "the setup key was sent although the password file existed"
run existing-secret MOCK_SECRET_EXISTS=1 -- relay.example.com example-project
[ "$STATUS" = 1 ] || fail "an existing Secret Manager secret was accepted"
! grep -q 'secrets create\|^curl-arg ' "$DIR/log" || fail "the secret was replaced or the setup key sent"
pass "an existing password stops the run"

# 7. A refused sign-in names the API host and where the password is.
run refused MOCK_HTTP_CODE=401 "PASSWORD_FILE=$ROOT/refused/pw" API_HOST=relay-api.example.com -- relay.example.com -
[ "$STATUS" = 1 ] || fail "a 401 did not fail the run"
grep -q 'HTTP 401 {"error":"mock_error","message":"mock message"}' "$DIR/out" || fail "the error body was not reported"
grep -q "https://relay-api.example.com.*delete the file $DIR/pw" "$DIR/out" || fail "the failure does not name the API host and the file"
no_password_in_output "$(cat "$DIR/pw")" refused
pass "a refused sign-in reports the host and the stored password's place"

printf 'All gcp-first-admin tests passed.\n'
