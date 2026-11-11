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
