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
  *" get job agent-relay-rds-layout-probe -o jsonpath="*|*" get job agent-relay-rds-pre -o jsonpath="*|*" get job agent-relay-rds-post -o jsonpath="*) printf '1'; exit 0 ;;
  *" get job sessions-pipeline-worker-migrate-current -o json "*)
    printf '%s\n' '{"metadata":{"name":"sessions-pipeline-worker-migrate-current","labels":{"app.kubernetes.io/instance":"agent-relay","app.kubernetes.io/component":"hoopdb-migrate"}},"status":{"succeeded":1}}'
    exit 0 ;;
  *" logs job/agent-relay-rds-layout-probe"*) printf 'HOOPDB_LAYOUT=%s\n' "${MOCK_LAYOUT:-fresh-dedicated}"; exit 0 ;;
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
grep -q 'hoopdb_owner' "${STATE_DIR}/secret-files/agent-relay-secrets/HOOPDB_MIGRATION_URL" || fail "migration credential is not the dedicated owner"
grep -q 'hoopdb_owner' "${STATE_DIR}/secret-files/search-indexer-owner/RELAYHISTORY_PIPELINE_CONSUMER_SECRET" || fail "search bootstrap credential is not the dedicated owner"
[[ "$(<"${STATE_DIR}/hoopdb-layout")" == dedicated-owner ]] || fail "dedicated layout marker was not written"
grep -q 'rdsLayout: separate-database' "${STATE_DIR}/hoopdb-layout-values.yaml" || fail "dedicated layout values are missing"
[[ "$(stat -c '%a' "${STATE_DIR}/passwords/control_owner")" == 600 ]] || fail "password file mode is not 0600"
[[ "$(stat -c '%a' "${STATE_DIR}/secret-files/agent-relay-secrets")" == 700 ]] || fail "secret directory mode is not 0700"
pass "pre mode creates private credential files without leaking secrets"

# The shipped separate-database preflight requires every role to exist without
# a creator edge before the first migration.
grep -q 'CREATE ROLE agent_relay_hoopdb_role_creator' "${MOCK_CAPTURE_DIR}/run.sh" || fail "pre omitted disposable role creator"
grep -q 'CREATE ROLE search_consumer_runtime LOGIN' "${MOCK_CAPTURE_DIR}/run.sh" || fail "pre omitted search runtime"
grep -q 'DROP ROLE agent_relay_hoopdb_role_creator' "${MOCK_CAPTURE_DIR}/run.sh" || fail "pre did not drop disposable role creator"
diff -u \
  <(tail -n +5 "${TEST_DIR}/../rds-hoopdb-activate.sql" \
    | sed -E "s/^SELECT format\('ALTER DATABASE %I OWNER TO hoopdb_owner'.*/ALTER DATABASE hoopdb OWNER TO hoopdb_owner;/; s/DATABASE :\"DBNAME\"/DATABASE hoopdb/g") \
  <(awk '/-v project_password=.*<<'"'"'SQL'"'"'/{capture=1; next} capture && /^SQL$/{exit} capture{print}' "${MOCK_CAPTURE_DIR}/run.sh") \
  >/dev/null || fail "inline activation SQL drifted from rds-hoopdb-activate.sql"
grep -q 'protected role membership edges:' "${MOCK_CAPTURE_DIR}/run.sh" || fail "pre omitted the protected-role membership census"
pass "pre mode submits the membership-free dedicated-owner role graph"

# These are exact upstream b96e1e1e inputs. Indented role DDL lives inside a
# guarded DO block and is safe after the explicit existence check; only
# top-level role DDL that would execute as hoopdb_owner must refuse.
fixture_dir="${TEST_DIR}/fixtures/rds-post"
[[ "$(sha256sum "$fixture_dir/session_read_api_role.sql" | cut -d' ' -f1)" == 8ab1906b39358947d2f4b6203d5daaf0fb9996bf3c57a4b7a4dba242c40de057 ]] \
  || fail "session_read_api_role.sql fixture drifted from relayhistory-pipeline b96e1e1e"
[[ "$(sha256sum "$fixture_dir/session_ingest_role.sql" | cut -d' ' -f1)" == b944c30a609fd8ad63d6c86424180c67a23fd8978d949b6e0340bb7b0a9e41a9 ]] \
  || fail "session_ingest_role.sql fixture drifted from relayhistory-pipeline b96e1e1e"
filter_role_fixture() {
  local input=$1 role=$2 output=$3
  sed "/^ALTER ROLE $role /d" "$input" >"$output"
  ! grep -Eq '^(ALTER|CREATE)[[:space:]]+ROLE([[:space:]]|$)' "$output"
}
filter_role_fixture "$fixture_dir/session_read_api_role.sql" bulls96_read_api "$TEST_ROOT/read-filtered.sql" \
  || fail "real read-role SQL was rejected because of guarded indented DDL"
filter_role_fixture "$fixture_dir/session_ingest_role.sql" bulls96_session_ingest "$TEST_ROOT/ingest-filtered.sql" \
  || fail "real ingest-role SQL was rejected"
if filter_role_fixture "$fixture_dir/top-level-multiline-alter-role.sql" bulls96_read_api "$TEST_ROOT/bad-filtered.sql"; then
  fail "top-level multi-line ALTER ROLE passed the owner filter"
fi
pass "post role filters accept guarded upstream SQL and reject executable top-level DDL"

: >"${COMMAND_LOG}"
MOCK_LAYOUT=dedicated-owner bash "${RDS_SETUP}" pre >/dev/null
! grep -q 'agent-relay-rds-pre-run' "${COMMAND_LOG}" || fail "dedicated-owner rerun changed the role graph"
grep -q 'agent-relay-rds-layout-probe' "${COMMAND_LOG}" || fail "dedicated-owner rerun skipped classification"
pass "dedicated-owner pre rerun leaves the database and role graph unchanged"

: >"${COMMAND_LOG}"
set +e
pg15_output="$(MOCK_LAYOUT=fresh-legacy bash "${RDS_SETUP}" pre 2>&1)"
pg15_rc=$?
set -e
[[ "$pg15_rc" != 0 && "$pg15_output" == *"PostgreSQL 16 or later is required"* ]] || fail "fresh PostgreSQL 15 did not fail clearly"
! grep -q 'agent-relay-rds-pre-run' "${COMMAND_LOG}" || fail "fresh PostgreSQL 15 changed database roles"
pass "fresh PostgreSQL 15 refuses before database changes"

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
grep -q "filtered session_read_api_role.sql still contains ALTER ROLE or CREATE ROLE" "${MOCK_CAPTURE_DIR}/run.sh" \
  || fail "post does not fail closed if the read-role filter misses role DDL"
grep -q "filtered session_ingest_role.sql still contains ALTER ROLE or CREATE ROLE" "${MOCK_CAPTURE_DIR}/run.sh" \
  || fail "post does not fail closed if the ingest-role filter misses role DDL"
read_exists_line="$(grep -n "rolname='bulls96_read_api'" "${MOCK_CAPTURE_DIR}/run.sh" | head -1 | cut -d: -f1)"
read_filter_line="$(grep -n 'sed .*session_read_api_role.sql' "${MOCK_CAPTURE_DIR}/run.sh" | head -1 | cut -d: -f1)"
ingest_exists_line="$(grep -n "rolname='bulls96_session_ingest'" "${MOCK_CAPTURE_DIR}/run.sh" | head -1 | cut -d: -f1)"
ingest_filter_line="$(grep -n 'sed .*session_ingest_role.sql' "${MOCK_CAPTURE_DIR}/run.sh" | head -1 | cut -d: -f1)"
[[ -n "$read_exists_line" && -n "$read_filter_line" && "$read_exists_line" -lt "$read_filter_line" ]] \
  || fail "read role is not proven to exist before its filtered SQL runs"
[[ -n "$ingest_exists_line" && -n "$ingest_filter_line" && "$ingest_exists_line" -lt "$ingest_filter_line" ]] \
  || fail "ingest role is not proven to exist before its filtered SQL runs"
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
grep -q 'CREATE ROLE bulls96_session_erase_search NOLOGIN' "$MOCK_CAPTURE_DIR/run.sh" || fail "pre does not create the dormant role"
cmp "$MOCK_CAPTURE_DIR/erase.sql" "${TEST_DIR}/../rds-session-erase-search.sql" || fail "Job did not receive exact reviewed SQL"
pass "pre reuses eraser credentials and creates the dormant identity"

set +e
erase_output="$(PROVISION_ERASE_SEARCH_LOGIN=1 bash "$RDS_SETUP" post 2>&1)"
erase_rc=$?
set -e
[[ "$erase_rc" != 0 && "$erase_output" == *"dedicated-owner RDS layout leaves bulls96_session_erase_search NOLOGIN"* ]] \
  || fail "dedicated owner did not refuse the unreviewed eraser activation"
pass "dedicated-owner post refuses legacy-only optional eraser activation"

mv "$STATE_DIR/passwords/bulls96_session_erase_search" "$TEST_ROOT/saved-password"
rm "$STATE_DIR/secret-files/session-erase-search-runtime/SESSION_ERASE_SEARCH_POSTGRES_URL"
bash "$RDS_SETUP" post >/dev/null
[[ ! -e "$STATE_DIR/passwords/bulls96_session_erase_search" ]] || fail "default post provisioned an optional credential"
[[ ! -e "$STATE_DIR/secret-files/session-erase-search-runtime/SESSION_ERASE_SEARCH_POSTGRES_URL" ]] || fail "default post rewrote optional input"
pass "ordinary post upgrades do not require or provision the optional eraser credential"
pass "ordinary dedicated-owner upgrades do not require the optional eraser credential"

: > "${COMMAND_LOG}"
printf '%s\n' legacy-admin >"${STATE_DIR}/hoopdb-layout"
rm -f "${STATE_DIR}/secret-files/agent-relay-secrets/HOOPDB_MIGRATION_URL" "${STATE_DIR}/secret-files/search-indexer-owner/RELAYHISTORY_PIPELINE_CONSUMER_SECRET"
refresh_output="$(PROVISION_ERASE_SEARCH_LOGIN=1 env -u SERVICES_IMAGE bash "${RDS_SETUP}" refresh-admin 2>&1)"
[[ "${refresh_output}" == *"administrator Job credential files refreshed"* ]] || fail "refresh-admin did not finish"
[[ "${refresh_output}" != *"admin-secret-material"* ]] || fail "admin password leaked in refresh-admin"
[[ -s "${STATE_DIR}/secret-files/hoopdb-admin-jobs/HOOPDB_MIGRATION_URL" ]] || fail "refresh-admin did not write the temporary migration input"
[[ -s "${STATE_DIR}/secret-files/hoopdb-admin-jobs/RELAYHISTORY_PIPELINE_CONSUMER_SECRET" ]] || fail "refresh-admin did not write the temporary search input"
[[ ! -e "${STATE_DIR}/secret-files/agent-relay-secrets/HOOPDB_MIGRATION_URL" ]] || fail "refresh-admin restored the long-lived administrator key"
[[ ! -e "${STATE_DIR}/secret-files/search-indexer-owner/RELAYHISTORY_PIPELINE_CONSUMER_SECRET" ]] || fail "refresh-admin restored the long-lived search administrator key"
! grep -q 'agent-relay-rds-' "${COMMAND_LOG}" || fail "refresh-admin must not run a database Job"
[[ ! -e "$STATE_DIR/secret-files/session-erase-search-runtime/SESSION_ERASE_SEARCH_POSTGRES_URL" ]] || fail "refresh-admin recreated the optional eraser input"
pass "refresh-admin writes only the short-lived Job inputs, without SERVICES_IMAGE or a database Job"

set +e
nostate_output="$(STATE_DIR="$(mktemp -d)" bash "${RDS_SETUP}" refresh-admin 2>&1)"
nostate_rc=$?
set -e
[[ "${nostate_rc}" != 0 && "${nostate_output}" == *"run '"*"pre' first"* ]] || fail "refresh-admin without state must refuse"
pass "refresh-admin refuses without pre state"
