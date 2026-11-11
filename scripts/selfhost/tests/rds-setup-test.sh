#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RDS_SETUP="$(cd -- "${TEST_DIR}/.." && pwd)/rds-setup.sh"
TMP_BASE="${AGENT_TMP_DIR:-${HOME}/.agent-tmp}"
mkdir -p "${TMP_BASE}"
TEST_ROOT="$(mktemp -d "${TMP_BASE}/rds-setup-test.XXXXXX")"
trap 'rm -rf "${TEST_ROOT}"' EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$*"
}

MOCK_BIN="${TEST_ROOT}/bin"
STATE_DIR="${TEST_ROOT}/state"
COMMAND_LOG="${TEST_ROOT}/commands.log"
mkdir -p "${MOCK_BIN}"
: >"${COMMAND_LOG}"

# Capture actual submitted scripts and helper SQL before the setup cleans up.
export MOCK_CAPTURE_DIR="${TEST_ROOT}/capture"
mkdir -p "$MOCK_CAPTURE_DIR"
cat >"${MOCK_BIN}/aws" <<'MOCK'
#!/usr/bin/env bash
printf 'aws' >>"${MOCK_COMMAND_LOG}"
printf ' %s' "$@" >>"${MOCK_COMMAND_LOG}"
printf '\n' >>"${MOCK_COMMAND_LOG}"
printf '{"username":"dbadmin","password":"admin-secret-material"}\n'
MOCK

cat >"${MOCK_BIN}/curl" <<'MOCK'
#!/usr/bin/env bash
printf 'curl' >>"${MOCK_COMMAND_LOG}"
printf ' %s' "$@" >>"${MOCK_COMMAND_LOG}"
printf '\n' >>"${MOCK_COMMAND_LOG}"
output=""
previous=""
for argument in "$@"; do
  if [[ "${previous}" == "-o" ]]; then output="${argument}"; fi
  previous="${argument}"
done
[[ -n "${output}" ]] || exit 2
printf '%s\n' '-----BEGIN CERTIFICATE-----' 'fixture' '-----END CERTIFICATE-----' >"${output}"
MOCK

cat >"${MOCK_BIN}/openssl" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "rand" ]]; then
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  exit 0
fi
exit 2
MOCK

cat >"${MOCK_BIN}/kubectl" <<'MOCK'
#!/usr/bin/env bash
printf 'kubectl' >>"${MOCK_COMMAND_LOG}"
printf ' %s' "$@" >>"${MOCK_COMMAND_LOG}"
printf '\n' >>"${MOCK_COMMAND_LOG}"
for argument in "$@"; do
  case "$argument" in
    --from-file=run.sh=*) cp "${argument#--from-file=run.sh=}" "$MOCK_CAPTURE_DIR/run.sh" ;;
    --from-file=session-erase-search.sql=*) cp "${argument#--from-file=session-erase-search.sql=}" "$MOCK_CAPTURE_DIR/erase.sql" ;;
  esac
done
case " $* " in
  *" apply -f - "*) cat >/dev/null; exit 0 ;;
  *" create secret generic "*) printf 'apiVersion: v1\nkind: Secret\nmetadata: {name: fixture}\n'; exit 0 ;;
  *" create configmap "*) printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: fixture}\n'; exit 0 ;;
  *" get job agent-relay-rds-pre -o jsonpath="*|*" get job agent-relay-rds-post -o jsonpath="*) printf '1'; exit 0 ;;
  *" get job sessions-pipeline-worker-migrate-current -o json "*)
    printf '%s\n' '{"metadata":{"name":"sessions-pipeline-worker-migrate-current","labels":{"app.kubernetes.io/instance":"agent-relay","app.kubernetes.io/component":"hoopdb-migrate"}},"status":{"succeeded":1}}'
    exit 0 ;;
  *" logs job/"*) printf 'fixture job completed\n'; exit 0 ;;
esac
exit 0
MOCK

chmod +x "${MOCK_BIN}"/*
export PATH="${MOCK_BIN}:${PATH}"
export MOCK_COMMAND_LOG="${COMMAND_LOG}"
export AWS_REGION="us-west-2"
export RDS_HOST="customer-db.example.invalid"
export RDS_ADMIN_SECRET_ARN="arn:aws:secretsmanager:us-west-2:111122223333:secret:fixture"
export SERVICES_IMAGE="ghcr.io/agentworkforce/sessions-pipeline@sha256:1111111111111111111111111111111111111111111111111111111111111111"
export NAMESPACE="agent-relay"
export KUBE_CONTEXT="customer-context"
export RELEASE="agent-relay"
export MIGRATION_JOB="sessions-pipeline-worker-migrate-current"
export STATE_DIR

set +e
usage_output="$(bash "${RDS_SETUP}" 2>&1)"
usage_rc=$?
set -e
[[ "${usage_rc}" == 2 ]] || fail "missing mode must exit 2"
[[ "${usage_output}" == *"usage:"* ]] || fail "missing mode must print usage"
pass "mode is required"

set +e
mutable_output="$(SERVICES_IMAGE=ghcr.io/agentworkforce/sessions-pipeline:main bash "${RDS_SETUP}" pre 2>&1)"
mutable_rc=$?
set -e
[[ "${mutable_rc}" != 0 ]] || fail "mutable services image was accepted"
[[ "${mutable_output}" == *"must be pinned by digest"* ]] || fail "mutable image error was unclear"
pass "mutable services image is rejected"

pre_output="$(bash "${RDS_SETUP}" pre 2>&1)"
[[ "${pre_output}" == *"pre done"* ]] || fail "pre mode did not finish"
[[ "${pre_output}" != *"admin-secret-material"* ]] || fail "admin password leaked to output"
[[ "${pre_output}" != *"aaaaaaaaaaaaaaaa"* ]] || fail "generated password leaked to output"
[[ -s "${STATE_DIR}/secret-files/agent-relay-secrets/HOOPDB_URL" ]] || fail "HoopDb runtime credential was not written"
[[ -s "${STATE_DIR}/secret-files/search-indexer-owner/RELAYHISTORY_PIPELINE_CONSUMER_SECRET" ]] || fail "search owner credential was not written"
[[ "$(stat -c '%a' "${STATE_DIR}/passwords/control_owner")" == 600 ]] || fail "password file mode is not 0600"
[[ "$(stat -c '%a' "${STATE_DIR}/secret-files/agent-relay-secrets")" == 700 ]] || fail "secret directory mode is not 0700"
pass "pre mode creates private credential files without leaking secrets"

# HoopDb migration 20261105043900 refuses to run unless search_consumer_runtime
# already exists, so pre (not post) must provision it on a fresh database.
grep -Eq '^for f in .*session_consumer_roles.*; do$' "${RDS_SETUP}" || fail "pre mode does not provision search_consumer_runtime before migrate"
pass "pre mode provisions the consumer role the migrations require"

set +e
wrong_release_output="$(RELEASE=another-release bash "${RDS_SETUP}" post 2>&1)"
wrong_release_rc=$?
set -e
[[ "${wrong_release_rc}" != 0 ]] || fail "post mode accepted migration evidence from another release"
[[ "${wrong_release_output}" == *"has not succeeded for release another-release"* ]] || fail "wrong-release refusal was unclear"
pass "post mode refuses migration evidence from another release"

post_output="$(bash "${RDS_SETUP}" post 2>&1)"
[[ "${post_output}" == *"post done"* ]] || fail "post mode did not finish"
[[ "${post_output}" != *"admin-secret-material"* ]] || fail "admin password leaked in post mode"
grep -q -- '--context customer-context -n agent-relay get job sessions-pipeline-worker-migrate-current -o json' "${COMMAND_LOG}" || fail "post mode did not verify the exact current migration Job in the selected context"
grep -q 'agent-relay-rds-post' "${COMMAND_LOG}" || fail "post bootstrap Job was not applied"
pass "post mode requires migration evidence and activates runtime roles"

[[ -s "$STATE_DIR/passwords/bulls96_session_erase_search" ]] || fail "erase search password missing"
[[ -s "$STATE_DIR/secret-files/session-erase-search-runtime/SESSION_ERASE_SEARCH_POSTGRES_URL" ]] || fail "dedicated erase search input missing"
[[ "$(stat -c '%a' "$STATE_DIR/secret-files/session-erase-search-runtime/SESSION_ERASE_SEARCH_POSTGRES_URL")" == 600 ]] || fail "erase input is not private"
grep -q '^provision_erase_search_login=0$' "$MOCK_CAPTURE_DIR/run.sh" || fail "erase login enabled by default"
[[ "$post_output" != *"aaaaaaaaaaaaaaaa"* ]] || fail "erase password leaked"
pass "eraser credentials are separate and login activation defaults off"

cp "$STATE_DIR/passwords/bulls96_session_erase_search" "$TEST_ROOT/original-password"
bash "$RDS_SETUP" pre >/dev/null
cmp "$STATE_DIR/passwords/bulls96_session_erase_search" "$TEST_ROOT/original-password" || fail "rerun rotated erase password"
grep -q '\-v post=false -f /run-script/session-erase-search.sql' "$MOCK_CAPTURE_DIR/run.sh" || fail "pre does not create dormant role"
cmp "$MOCK_CAPTURE_DIR/erase.sql" "${TEST_DIR}/../rds-session-erase-search.sql" || fail "Job did not receive exact reviewed SQL"
pass "pre reuses eraser credentials and ships reviewed role SQL"

PROVISION_ERASE_SEARCH_LOGIN=1 bash "$RDS_SETUP" post >/dev/null
grep -q '^provision_erase_search_login=1$' "$MOCK_CAPTURE_DIR/run.sh" || fail "post lost explicit activation request"
grep -q '\-v post=true -v p1="$bulls96_session_erase_search"' "$MOCK_CAPTURE_DIR/run.sh" || fail "post omitted dedicated eraser credential"
pass "post carries explicit optional provisioning and dedicated credentials"

mv "$STATE_DIR/passwords/bulls96_session_erase_search" "$TEST_ROOT/saved-password"
rm "$STATE_DIR/secret-files/session-erase-search-runtime/SESSION_ERASE_SEARCH_POSTGRES_URL"
bash "$RDS_SETUP" post >/dev/null
[[ ! -e "$STATE_DIR/passwords/bulls96_session_erase_search" ]] || fail "default post provisioned an optional credential"
[[ ! -e "$STATE_DIR/secret-files/session-erase-search-runtime/SESSION_ERASE_SEARCH_POSTGRES_URL" ]] || fail "default post rewrote optional input"
pass "ordinary post upgrades do not require or provision the optional eraser credential"
PROVISION_ERASE_SEARCH_LOGIN=1 bash "$RDS_SETUP" post >/dev/null
[[ -s "$STATE_DIR/passwords/bulls96_session_erase_search" ]] || fail "explicit post upgrade did not create optional credential"
[[ -s "$STATE_DIR/secret-files/session-erase-search-runtime/SESSION_ERASE_SEARCH_POSTGRES_URL" ]] || fail "explicit post upgrade did not create optional input"
pass "explicit optional provisioning upgrades an existing install without repeating pre"

: > "${COMMAND_LOG}"
rm -f "${STATE_DIR}/secret-files/agent-relay-secrets/HOOPDB_MIGRATION_URL" "${STATE_DIR}/secret-files/search-indexer-owner/RELAYHISTORY_PIPELINE_CONSUMER_SECRET"
cp "$STATE_DIR/secret-files/session-erase-search-runtime/SESSION_ERASE_SEARCH_POSTGRES_URL" "$TEST_ROOT/eraser-input-before-refresh"
refresh_output="$(PROVISION_ERASE_SEARCH_LOGIN=1 env -u SERVICES_IMAGE bash "${RDS_SETUP}" refresh-admin 2>&1)"
[[ "${refresh_output}" == *"admin credential files refreshed"* ]] || fail "refresh-admin did not finish"
[[ "${refresh_output}" != *"admin-secret-material"* ]] || fail "admin password leaked in refresh-admin"
[[ -s "${STATE_DIR}/secret-files/agent-relay-secrets/HOOPDB_MIGRATION_URL" ]] || fail "refresh-admin did not rewrite HOOPDB_MIGRATION_URL"
[[ -s "${STATE_DIR}/secret-files/search-indexer-owner/RELAYHISTORY_PIPELINE_CONSUMER_SECRET" ]] || fail "refresh-admin did not rewrite the search owner secret"
! grep -q 'agent-relay-rds-' "${COMMAND_LOG}" || fail "refresh-admin must not run a database Job"
cmp "$STATE_DIR/secret-files/session-erase-search-runtime/SESSION_ERASE_SEARCH_POSTGRES_URL" "$TEST_ROOT/eraser-input-before-refresh" || fail "refresh-admin changed the optional eraser input"
pass "refresh-admin rewrites only the admin-derived files, without SERVICES_IMAGE or a database Job"

set +e
nostate_output="$(STATE_DIR="$(mktemp -d)" bash "${RDS_SETUP}" refresh-admin 2>&1)"
nostate_rc=$?
set -e
[[ "${nostate_rc}" != 0 && "${nostate_output}" == *"run '"*"pre' first"* ]] || fail "refresh-admin without state must refuse"
pass "refresh-admin refuses without pre state"
