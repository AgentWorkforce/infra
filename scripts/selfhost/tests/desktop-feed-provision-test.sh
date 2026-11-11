#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROVISIONER="$(cd -- "${TEST_DIR}/.." && pwd)/desktop-feed-provision.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$*"
}

mock_bin="${TEST_ROOT}/bin"
curl_log="${TEST_ROOT}/curl-argv.log"
curl_config_log="${TEST_ROOT}/curl-config.log"
gh_log="${TEST_ROOT}/gh.log"
hdiutil_log="${TEST_ROOT}/hdiutil.log"
mkdir -p "${mock_bin}"
: >"${curl_log}"
: >"${curl_config_log}"
: >"${gh_log}"
: >"${hdiutil_log}"

cat >"${mock_bin}/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${RELAY_ADMIN_TOKEN:-}" ]] || {
  printf 'RELAY_ADMIN_TOKEN leaked into curl environment\n' >&2
  exit 97
}
config="$(cat)"
printf '%s\n' "${config}" >>"${MOCK_CURL_CONFIG_LOG}"
printf 'begin argc=%s\n' "$#" >>"${MOCK_CURL_LOG}"
for argument in "$@"; do
  printf 'arg:%s\n' "${argument}" >>"${MOCK_CURL_LOG}"
done
printf 'end\n' >>"${MOCK_CURL_LOG}"

method=""
url=""
body=""
write_out=""
fail_on_http=0
previous=""
for argument in "$@"; do
  case "${previous}" in
    -X) method="${argument}" ;;
    --data) body="${argument}" ;;
    -w) write_out="${argument}" ;;
  esac
  [[ "${argument}" == "--fail" ]] && fail_on_http=1
  [[ "${argument}" == https://* ]] && url="${argument}"
  previous="${argument}"
done
[[ -n "${method}" && -n "${url}" ]] || exit 98

status=200
response=''
case "${method} ${url}" in
  "GET "*"/profiles/profile1")
    status="${MOCK_PROFILE_STATUS:-200}"
    if [[ "${status}" == "200" ]]; then
      response='{"id":"profile1","signing_key":{"key_id":"fk_profile1_k1","public_key":"fixture-public-key"}}'
    else
      response='{"error":"profile_lookup_failed"}'
    fi
    ;;
  "PUT "*"/profiles/profile1/workspaces/workspace-1")
    response='{}'
    ;;
  "POST "*"/profiles/profile1/publisher-tokens")
    [[ "${body}" == '{"label":"desktop-ci"}' ]] || exit 99
    response='{"token":"sh_dfp_fixture-publisher-token"}'
    ;;
  *)
    response='{"error":"unexpected_request"}'
    status=500
    ;;
esac
printf '%s' "${response}"
if [[ -n "${write_out}" ]]; then
  printf '\n%s' "${status}"
elif [[ "${fail_on_http}" == 1 && "${status}" != 2* ]]; then
  exit 22
fi
MOCK

cat >"${mock_bin}/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${RELAY_ADMIN_TOKEN:-}" ]] || {
  printf 'RELAY_ADMIN_TOKEN leaked into gh environment\n' >&2
  exit 97
}
printf 'begin argc=%s\n' "$#" >>"${MOCK_GH_LOG}"
for argument in "$@"; do
  printf 'arg:%s\n' "${argument}" >>"${MOCK_GH_LOG}"
done
printf 'end\n' >>"${MOCK_GH_LOG}"

case "${1:-} ${2:-}" in
  "run download")
    destination=""
    previous=""
    for argument in "$@"; do
      [[ "${previous}" == "-D" ]] && destination="${argument}"
      previous="${argument}"
    done
    [[ -n "${destination}" ]] || exit 98
    mkdir -p "${destination}"
    : >"${destination}/candidate.dmg"
    ;;
  "secret set")
    value="$(cat)"
    case "${3:-}" in
      DESKTOP_FEED_PUBLIC_KEY)
        [[ "${value}" == "fixture-public-key" ]] || exit 98
        printf 'secret-public-key:ok\n' >>"${MOCK_GH_LOG}"
        ;;
      DESKTOP_FEED_PUBLISHER_TOKEN)
        [[ "${value}" == "sh_dfp_fixture-publisher-token" ]] || exit 98
        printf 'secret-publisher-token:ok\n' >>"${MOCK_GH_LOG}"
        ;;
      *) exit 98 ;;
    esac
    ;;
  "workflow run")
    printf 'workflow-dispatch:ok\n' >>"${MOCK_GH_LOG}"
    ;;
  *) exit 98 ;;
esac
MOCK

cat >"${mock_bin}/hdiutil" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${RELAY_ADMIN_TOKEN:-}" ]] || {
  printf 'RELAY_ADMIN_TOKEN leaked into hdiutil environment\n' >&2
  exit 97
}
case "${1:-}" in
  attach)
    printf 'attach\n' >>"${MOCK_HDIUTIL_LOG}"
    mountpoint=""
    previous=""
    for argument in "$@"; do
      [[ "${previous}" == "-mountpoint" ]] && mountpoint="${argument}"
      previous="${argument}"
    done
    [[ -n "${mountpoint}" ]] || exit 98
    mkdir -p "${mountpoint}"
    printf 'fixture-public-key\n' >"${mountpoint}/embedded-feed-key.txt"
    ;;
  detach)
    printf 'detach\n' >>"${MOCK_HDIUTIL_LOG}"
    [[ "${MOCK_HDIUTIL_DETACH_FAIL:-0}" != 1 ]] || exit 1
    ;;
  *) exit 98 ;;
esac
MOCK

chmod +x "${mock_bin}"/*
export PATH="${mock_bin}:${PATH}"
export MOCK_CURL_LOG="${curl_log}"
export MOCK_CURL_CONFIG_LOG="${curl_config_log}"
export MOCK_GH_LOG="${gh_log}"
export MOCK_HDIUTIL_LOG="${hdiutil_log}"

admin_token="test-admin-token-never-in-argv"
common_args=(
  --site https://api.customer.invalid
  --org org-1
  --profile profile1
  --workspace workspace-1
  --asset-prefix Desktop-profile1
  --candidate-run 42903809516
  --version 2026.11.5
)

plan_output="$(
  RELAY_ADMIN_TOKEN="${admin_token}" DESKTOP_REPO=AgentWorkforce/relay-desktop \
    bash "${PROVISIONER}" "${common_args[@]}"
)"
[[ "${plan_output}" == *"plan-only"* ]] || fail "plan did not identify itself"
[[ "${plan_output}" == *"candidate 42903809516 embeds this site's feed key: OK"* ]] || fail "plan did not verify the candidate key"
grep -Fxq 'detach' "${hdiutil_log}" || fail "plan did not detach the candidate volume"
if grep -Fxq 'arg:secret' "${gh_log}" || grep -Fxq 'arg:workflow' "${gh_log}"; then
  fail "plan invoked a mutating GitHub command"
fi
pass "plan verifies the candidate without mutations"

: >"${curl_log}"
: >"${curl_config_log}"
: >"${gh_log}"
: >"${hdiutil_log}"
apply_output="$(
  RELAY_ADMIN_TOKEN="${admin_token}" DESKTOP_REPO=AgentWorkforce/relay-desktop \
    bash "${PROVISIONER}" "${common_args[@]}" --apply
)"
[[ "${apply_output}" == *"publisher token minted and stored"* ]] || fail "apply did not store the publisher token"
[[ "${apply_output}" == *"Desktop Promote dispatched"* ]] || fail "apply did not dispatch Promote"
[[ "${apply_output}" != *"sh_dfp_fixture-publisher-token"* ]] || fail "publisher token leaked to output"

grep -Fxq 'arg:--data' "${curl_log}" || fail "POST did not pass --data as its own curl argument"
grep -Fxq 'arg:{"label":"desktop-ci"}' "${curl_log}" || fail "POST body was not a distinct curl argument"
if grep -Fxq 'arg:-o' "${curl_log}"; then
  fail "API response was written to a temporary file"
fi
if grep -Fq -- "${admin_token}" "${curl_log}"; then
  fail "admin token appeared in curl argv"
fi
grep -Fq -- "Authorization: Bearer ${admin_token}" "${curl_config_log}" || fail "curl did not receive the bearer through stdin config"
grep -Fxq 'secret-public-key:ok' "${gh_log}" || fail "public key secret was not set from stdin"
grep -Fxq 'secret-publisher-token:ok' "${gh_log}" || fail "publisher token secret was not set from stdin"
grep -Fxq 'workflow-dispatch:ok' "${gh_log}" || fail "Promote workflow was not dispatched"
grep -Fxq 'detach' "${hdiutil_log}" || fail "apply did not detach the candidate volume"
pass "apply streams secrets, keeps the bearer out of argv, and detaches the candidate"

set +e
lookup_output="$(
  RELAY_ADMIN_TOKEN="${admin_token}" MOCK_PROFILE_STATUS=500 DESKTOP_REPO=AgentWorkforce/relay-desktop \
    bash "${PROVISIONER}" "${common_args[@]}" 2>&1
)"
lookup_rc=$?
set -e
[[ "${lookup_rc}" == 1 ]] || fail "profile lookup HTTP 500 was not fatal"
[[ "${lookup_output}" == *"HTTP 500"* ]] || fail "profile lookup failure omitted its HTTP status"
[[ "${lookup_output}" != *"would register profile"* ]] || fail "profile lookup failure was treated as absence"
pass "profile lookup failures are not treated as a missing profile"

missing_output="$(
  RELAY_ADMIN_TOKEN="${admin_token}" MOCK_PROFILE_STATUS=404 DESKTOP_REPO=AgentWorkforce/relay-desktop \
    bash "${PROVISIONER}" "${common_args[@]}" 2>&1
)"
[[ "${missing_output}" == *"would register profile"* ]] || fail "profile HTTP 404 was not treated as absence"
pass "only profile HTTP 404 is treated as absence"

set +e
detach_output="$(
  RELAY_ADMIN_TOKEN="${admin_token}" MOCK_HDIUTIL_DETACH_FAIL=1 DESKTOP_REPO=AgentWorkforce/relay-desktop \
    bash "${PROVISIONER}" "${common_args[@]}" 2>&1
)"
detach_rc=$?
set -e
[[ "${detach_rc}" == 1 ]] || fail "candidate detach failure was ignored"
[[ "${detach_output}" == *"failed to detach candidate volume"* ]] || fail "candidate detach failure was not reported"
pass "candidate detach failures are fatal and reported"

set +e
invalid_output="$(
  RELAY_ADMIN_TOKEN='invalid bearer with spaces' DESKTOP_REPO=AgentWorkforce/relay-desktop \
    bash "${PROVISIONER}" "${common_args[@]}" 2>&1
)"
invalid_rc=$?
set -e
[[ "${invalid_rc}" == 2 ]] || fail "unsafe bearer characters were accepted"
[[ "${invalid_output}" == *"unsupported bearer-token characters"* ]] || fail "unsafe bearer refusal was unclear"
pass "unsafe bearer characters are rejected before child processes"
