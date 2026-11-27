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
case "${MOCK_ADMIN_SECRET_MODE:-valid}" in
  fail) exit 1 ;;
  empty) printf '{}\n' ;;
  valid) printf '{"username":"dbadmin","password":"admin-secret-material"}\n' ;;
esac
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
    --from-file=run.sh=*)
      cp "${argument#--from-file=run.sh=}" "$MOCK_CAPTURE_DIR/run.sh"
      case " $* " in *" agent-relay-rds-layout-probe-run "*) cp "${argument#--from-file=run.sh=}" "$MOCK_CAPTURE_DIR/probe.sh" ;; esac
      ;;
    --from-file=session-erase-search.sql=*) cp "${argument#--from-file=session-erase-search.sql=}" "$MOCK_CAPTURE_DIR/erase.sql" ;;
  esac
done
case " $* " in
  *" get configmap rds-ca --ignore-not-found -o json "*)
    if [[ "${MOCK_RDS_CA_MANAGED:-0}" == 1 ]]; then
      printf '%s\n' '{"metadata":{"name":"rds-ca","annotations":{"agentworkforce.dev/rds-ca-bundle":"global"}},"data":{"ca.crt":"-----BEGIN CERTIFICATE-----\nmanaged\n-----END CERTIFICATE-----\n"}}'
    fi
    exit 0 ;;
  *" apply -f - "*) cat >/dev/null; exit 0 ;;
  *" create secret generic search-indexer-owner "*)
    touch "$MOCK_CAPTURE_DIR/search-secret-created"
    printf 'apiVersion: v1\nkind: Secret\nmetadata: {name: search-indexer-owner}\n'; exit 0 ;;
  *" create secret generic "*) printf 'apiVersion: v1\nkind: Secret\nmetadata: {name: fixture}\n'; exit 0 ;;
  *" create configmap "*) printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: fixture}\n'; exit 0 ;;
  *" get job agent-relay-rds-layout-probe -o jsonpath="*|*" get job agent-relay-rds-pre -o jsonpath="*|*" get job agent-relay-rds-post -o jsonpath="*) printf '1'; exit 0 ;;
  *" get job sessions-pipeline-worker-migrate-current -o json "*)
    printf '%s\n' '{"metadata":{"name":"sessions-pipeline-worker-migrate-current","labels":{"app.kubernetes.io/instance":"agent-relay","app.kubernetes.io/component":"hoopdb-migrate"}},"status":{"succeeded":1}}'
    exit 0 ;;
  *" get secret agent-relay-secrets -o json "*|*" get secret agent-relay-secrets --ignore-not-found -o json "*)
    printf '%s\n' '{"metadata":{},"data":{"HOOPDB_MIGRATION_URL":"b2xk"}}'; exit 0 ;;
  *" get secret search-indexer-owner -o json "*|*" get secret search-indexer-owner --ignore-not-found -o json "*)
    if [[ "${MOCK_SEARCH_SECRET_ABSENT:-0}" == 1 && ! -e "$MOCK_CAPTURE_DIR/search-secret-created" ]]; then exit 0; fi
    printf '%s\n' '{"metadata":{},"data":{"RELAYHISTORY_PIPELINE_CONSUMER_SECRET":"b2xk"}}'; exit 0 ;;
  *" get externalsecrets.external-secrets.io "*)
    case "${MOCK_ES_MAPPING_STYLE:-none}" in
      template-data)
        printf '%s\n' '{"items":[{"metadata":{"name":"migration"},"spec":{"target":{"name":"agent-relay-secrets","template":{"data":{"HOOPDB_MIGRATION_URL":"{{ .adminUrl }}"}}}}}]}' ;;
      template-from)
        printf '%s\n' '{"items":[{"metadata":{"name":"migration"},"spec":{"target":{"name":"agent-relay-secrets","template":{"templateFrom":[{"configMap":{"name":"outputs"}}]}}}}]}' ;;
      *) printf '%s\n' '{"items":[]}' ;;
    esac
    exit 0 ;;
  *" logs job/agent-relay-rds-layout-probe"*) printf 'HOOPDB_LAYOUT=%s\n' "${MOCK_LAYOUT:-fresh-dedicated}"; exit 0 ;;
  *" logs job/"*) printf 'fixture job completed\n'; exit 0 ;;
esac
exit 0
MOCK

cat >"${MOCK_BIN}/psql" <<'MOCK'
#!/usr/bin/env bash
query=""
previous=""
for argument in "$@"; do
  if [[ "$previous" == -c ]]; then query="$argument"; fi
  previous="$argument"
done
case "$query" in
  *"server_version_num"*) printf '%s\n' "${MOCK_SERVER_VERSION:-170000}" ;;
  *"select 1 from pg_database where datname='hoopdb'"*)
    [[ "${MOCK_PSQL_FAIL_DATABASE:-0}" == 0 ]] || exit 1
    if [[ "${MOCK_DB_EXISTS:-1}" == 1 ]]; then printf '1\n'; fi
    ;;
  *"pg_get_userbyid(datdba)"*) printf '%s\n' "${MOCK_DB_OWNER:-dbadmin}" ;;
  *"select 1 where"*)
    if [[ "${MOCK_PRISTINE:-0}" == 1 ]]; then printf '1\n'; fi
    ;;
esac
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

for mode in fail empty; do
  bad_state="${TEST_ROOT}/admin-$mode"
  : >"${COMMAND_LOG}"
  if MOCK_ADMIN_SECRET_MODE="$mode" STATE_DIR="$bad_state" bash "$RDS_SETUP" pre >"${TEST_ROOT}/admin-$mode.log" 2>&1; then
    fail "$mode RDS administrator Secret was accepted"
  fi
  grep -Eq 'could not read|non-empty username and password' "${TEST_ROOT}/admin-$mode.log" \
    || fail "$mode RDS administrator Secret refusal was unclear"
  grep -q '^kubectl' "$COMMAND_LOG" && fail "$mode RDS administrator Secret reached a cluster write"
  [[ ! -e "$bad_state/secret-files/agent-relay-secrets/HOOPDB_MIGRATION_URL" ]] \
    || fail "$mode RDS administrator Secret wrote an owner URL"
done
pass "failed and empty RDS administrator Secret reads stop before cluster or credential writes"

pre_output="$(bash "${RDS_SETUP}" pre 2>&1)"
[[ "${pre_output}" == *"pre done"* ]] || fail "pre mode did not finish"
[[ "${pre_output}" != *"admin-secret-material"* ]] || fail "admin password leaked to output"
[[ "${pre_output}" != *"aaaaaaaaaaaaaaaa"* ]] || fail "generated password leaked to output"
[[ -s "${STATE_DIR}/secret-files/agent-relay-secrets/HOOPDB_URL" ]] || fail "HoopDb runtime credential was not written"
[[ -s "${STATE_DIR}/secret-files/search-indexer-owner/RELAYHISTORY_PIPELINE_CONSUMER_SECRET" ]] || fail "search owner credential was not written"
grep -q 'hoopdb_owner' "${STATE_DIR}/secret-files/agent-relay-secrets/HOOPDB_MIGRATION_URL" || fail "migration credential is not the dedicated owner"
grep -q 'hoopdb_owner' "${STATE_DIR}/secret-files/search-indexer-owner/RELAYHISTORY_PIPELINE_CONSUMER_SECRET" || fail "search bootstrap credential is not the dedicated owner"
[[ "$(<"${STATE_DIR}/hoopdb-layout")" == dedicated-owner ]] || fail "dedicated layout marker was not written"
[[ -s "${STATE_DIR}/hoopdb-target" ]] || fail "RDS target marker was not written"
grep -q 'rdsLayout: separate-database' "${STATE_DIR}/hoopdb-layout-values.yaml" || fail "dedicated layout values are missing"
[[ "$(stat -c '%a' "${STATE_DIR}/passwords/control_owner")" == 600 ]] || fail "password file mode is not 0600"
[[ "$(stat -c '%a' "${STATE_DIR}/secret-files/agent-relay-secrets")" == 700 ]] || fail "secret directory mode is not 0700"
pass "pre mode creates private credential files without leaking secrets"

grep -q ' create configmap rds-ca --from-file=ca.crt=' "${COMMAND_LOG}" || fail "pre did not create rds-ca"
cmp -s "${STATE_DIR}/rds-ca.pem" "${TEST_DIR}/../../../charts/agent-relay/files/rds-ca/us-west-2-bundle.pem" || fail "pre did not use the bundle the chart ships"
! grep -q '^curl .*truststore' "${COMMAND_LOG}" || fail "pre downloaded a bundle the checkout ships"
pass "pre creates rds-ca from the bundle the chart ships"

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

: >"${COMMAND_LOG}"
MOCK_RDS_CA_MANAGED=1 MOCK_LAYOUT=dedicated-owner bash "${RDS_SETUP}" pre >"${TEST_ROOT}/managed-ca.log" 2>&1 || fail "pre failed with a chart-managed rds-ca"
grep -q 'managed by the agent-relay chart (global.rdsCa.bundle=global)' "${TEST_ROOT}/managed-ca.log" || fail "pre did not report the chart-managed rds-ca"
! grep -q 'configmap rds-ca --from-file' "${COMMAND_LOG}" || fail "pre rewrote a chart-managed rds-ca"
grep -q managed "${STATE_DIR}/rds-ca.pem" || fail "pre did not keep the chart-managed bundle locally"
pass "pre leaves a chart-managed rds-ca as it is"

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

# A provider-created database is a fresh install only after the probe proves
# it has neither the sessions schema nor any HoopDb role.
: >"${COMMAND_LOG}"
MOCK_LAYOUT=pristine-admin bash "${RDS_SETUP}" pre >/dev/null
grep -q 'agent-relay-rds-pre-run' "${COMMAND_LOG}" || fail "pristine provider-created database was not activated"
[[ "$(<"${STATE_DIR}/hoopdb-layout")" == dedicated-owner ]] || fail "pristine database did not become dedicated-owner"
grep -q "to_regnamespace('sessions') is null" "${RDS_SETUP}" \
  || fail "pristine probe does not reject an existing sessions schema"
grep -q "rolname in ('hoopdb_owner','sessions_pipeline_runtime','search_consumer_runtime','session_directory_search_worker')" "${RDS_SETUP}" \
  || fail "pristine probe does not reject an existing HoopDb role"
pass "RDS activates a classifier-proven pristine provider-created HoopDb"

probe="$MOCK_CAPTURE_DIR/probe.sh"
[[ -s "$probe" ]] || fail "RDS classifier probe was not captured"
probe_out="$(PGUSER=dbadmin MOCK_DB_EXISTS=1 MOCK_DB_OWNER=dbadmin MOCK_PRISTINE=1 sh "$probe")" \
  || fail "pristine RDS probe failed"
[[ "$probe_out" == HOOPDB_LAYOUT=pristine-admin ]] || fail "pristine RDS probe classified as: $probe_out"
probe_out="$(PGUSER=dbadmin MOCK_SERVER_VERSION=150000 MOCK_DB_EXISTS=1 MOCK_DB_OWNER=dbadmin MOCK_PRISTINE=1 sh "$probe")" \
  || fail "PostgreSQL 15 pristine RDS probe failed"
[[ "$probe_out" == HOOPDB_LAYOUT=fresh-legacy ]] \
  || fail "PostgreSQL 15 pristine RDS database bypassed the version refusal: $probe_out"
# Supported majors (16+, 17 and 18 recommended) take the dedicated-owner path;
# there is no upper bound, so a newer major is not refused.
for version in 160000 170012 180000 180003; do
  probe_out="$(PGUSER=dbadmin MOCK_SERVER_VERSION=$version MOCK_DB_EXISTS=1 MOCK_DB_OWNER=dbadmin MOCK_PRISTINE=1 sh "$probe")" \
    || fail "server_version_num $version pristine RDS probe failed"
  [[ "$probe_out" == HOOPDB_LAYOUT=pristine-admin ]] \
    || fail "server_version_num $version pristine RDS database classified as: $probe_out"
  probe_out="$(PGUSER=dbadmin MOCK_SERVER_VERSION=$version MOCK_DB_EXISTS=0 sh "$probe")" \
    || fail "server_version_num $version fresh RDS probe failed"
  [[ "$probe_out" == HOOPDB_LAYOUT=fresh-dedicated ]] \
    || fail "server_version_num $version fresh RDS instance classified as: $probe_out"
done
probe_out="$(PGUSER=dbadmin MOCK_DB_EXISTS=1 MOCK_DB_OWNER=third_party MOCK_PRISTINE=0 sh "$probe")" \
  || fail "third-party RDS probe failed"
[[ "$probe_out" == HOOPDB_LAYOUT=unknown-owner ]] || fail "third-party RDS owner classified as: $probe_out"
: >"${COMMAND_LOG}"
if MOCK_LAYOUT=unknown-owner bash "$RDS_SETUP" pre >"$TEST_ROOT/unknown-owner.log" 2>&1; then
  fail "third-party RDS owner was accepted by the wrapper"
fi
grep -q 'owned by neither the RDS administrator nor hoopdb_owner' "$TEST_ROOT/unknown-owner.log" \
  || fail "third-party RDS owner refusal was unclear"
! grep -q 'agent-relay-rds-pre-run' "$COMMAND_LOG" || fail "third-party RDS owner reached the mutating Job"
if PGUSER=dbadmin MOCK_PSQL_FAIL_DATABASE=1 sh "$probe" >"$TEST_ROOT/probe-fail.log" 2>&1; then
  fail "failed RDS pg_database query took a layout path"
fi
grep -q 'could not inspect the HoopDb database' "$TEST_ROOT/probe-fail.log" \
  || fail "failed RDS pg_database query had no clear refusal"
pass "RDS classifier executes pristine, PG16/17/18, third-party-owner and query-failure branches fail closed"

# The RDS owner handoff is one transaction. A marker cannot convert an
# administrator-owned non-pristine database; dedicated-owner convergence
# removes a marker left after the commit.
cp "${STATE_DIR}/hoopdb-target" "${STATE_DIR}/.pending-hoopdb-activation"
: >"${COMMAND_LOG}"
MOCK_LAYOUT=legacy-admin bash "${RDS_SETUP}" pre >/dev/null
! grep -q 'agent-relay-rds-pre-run' "${COMMAND_LOG}" || fail "marker converted a legacy RDS database"
[[ ! -e "${STATE_DIR}/.pending-hoopdb-activation" ]] || fail "legacy classification retained a stale pending marker"
cp "${STATE_DIR}/hoopdb-target" "${STATE_DIR}/.pending-hoopdb-activation"
: >"${COMMAND_LOG}"
MOCK_LAYOUT=dedicated-owner bash "${RDS_SETUP}" pre >/dev/null
[[ ! -e "${STATE_DIR}/.pending-hoopdb-activation" ]] || fail "dedicated-owner rerun retained its activation marker"
pass "RDS marker never converts legacy and is cleared after committed ownership"

printf 'old-preview-marker\n' >"${STATE_DIR}/.pending-hoopdb-activation"
if MOCK_LAYOUT=fresh-dedicated bash "${RDS_SETUP}" pre >"$TEST_ROOT/old-marker.log" 2>&1; then
  fail "old-format RDS activation marker was accepted"
fi
grep -q 'unreleased preview wrote an old-format marker' "$TEST_ROOT/old-marker.log" \
  || fail "old-format RDS activation marker refusal omitted recovery guidance"
rm -f "${STATE_DIR}/.pending-hoopdb-activation"
pass "old-format RDS activation marker refusal explains safe recovery"

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

: >"${COMMAND_LOG}"
set +e
prepare_rollback_output="$(env -u SERVICES_IMAGE bash "$RDS_SETUP" prepare-rollback-admin-keys 2>&1)"
prepare_rollback_rc=$?
set -e
[[ "$prepare_rollback_rc" == 0 ]] || fail "rollback-key preparation failed: $prepare_rollback_output"
[[ "$prepare_rollback_output" == *"temporarily restored"* ]] || fail "rollback-key preparation did not finish"
grep -q 'patch secret agent-relay-secrets --type=merge --patch-file' "$COMMAND_LOG" \
  || fail "rollback-key preparation did not restore the migration key from a private patch file"
grep -q 'patch secret search-indexer-owner --type=merge --patch-file' "$COMMAND_LOG" \
  || fail "rollback-key preparation did not restore the search key from a private patch file"
[[ "$prepare_rollback_output" != *"admin-secret-material"* ]] || fail "rollback-key preparation printed the administrator password"
: >"${COMMAND_LOG}"
remove_rollback_output="$(env -u SERVICES_IMAGE bash "$RDS_SETUP" remove-rollback-admin-keys 2>&1)"
[[ "$remove_rollback_output" == *"rollback administrator keys removed"* ]] || fail "rollback-key removal did not finish"
[[ "$remove_rollback_output" == *"only after the rollback revision that reads these keys has been replaced or removed"* ]] \
  || fail "rollback-key removal omitted the active-revision warning"
grep -q 'patch secret agent-relay-secrets --type=json --patch-file' "$COMMAND_LOG" \
  || fail "rollback-key removal did not remove the migration key"
grep -q 'patch secret search-indexer-owner --type=json --patch-file' "$COMMAND_LOG" \
  || fail "rollback-key removal did not remove the search key"
pass "legacy rollback restores only the target revision's keys and removes them afterward"

rm -f "$MOCK_CAPTURE_DIR/search-secret-created"
: >"${COMMAND_LOG}"
absent_search_output="$(MOCK_SEARCH_SECRET_ABSENT=1 env -u SERVICES_IMAGE bash "$RDS_SETUP" prepare-rollback-admin-keys 2>&1)"
[[ "$absent_search_output" == *"recreated absent unmanaged rollback Secret search-indexer-owner"* ]] \
  || fail "rollback preparation did not reconstruct an absent unmanaged bootstrap Secret"
grep -q 'create secret generic search-indexer-owner --from-file=RELAYHISTORY_PIPELINE_CONSUMER_SECRET=' "$COMMAND_LOG" \
  || fail "absent bootstrap Secret was not reconstructed from the private rollback value"
pass "rollback preparation reconstructs an absent unmanaged bootstrap Secret"

: >"${COMMAND_LOG}"
if MOCK_ES_MAPPING_STYLE=template-data env -u SERVICES_IMAGE bash "$RDS_SETUP" prepare-rollback-admin-keys >"$TEST_ROOT/rollback-template-map.log" 2>&1; then
  fail "rollback preparation patched an existing Secret with an ExternalSecret template output"
fi
grep -q 'supplied by External Secrets' "$TEST_ROOT/rollback-template-map.log" \
  || fail "template-output rollback refusal was unclear"
! grep -q 'patch secret' "$COMMAND_LOG" || fail "template-output rollback refusal reached a patch"
: >"${COMMAND_LOG}"
if MOCK_ES_MAPPING_STYLE=template-from env -u SERVICES_IMAGE bash "$RDS_SETUP" remove-rollback-admin-keys >"$TEST_ROOT/remove-template-map.log" 2>&1; then
  fail "rollback removal accepted an uninspectable ExternalSecret templateFrom"
fi
grep -q 'External Secrets still maps' "$TEST_ROOT/remove-template-map.log" \
  || fail "templateFrom rollback refusal was unclear"
! grep -q 'patch secret' "$COMMAND_LOG" || fail "templateFrom rollback refusal reached a patch"
pass "rollback preparation and removal refuse explicit and uninspectable ExternalSecret templates"

: >"${COMMAND_LOG}"
if RDS_HOST=other-db.example.invalid env -u SERVICES_IMAGE bash "$RDS_SETUP" remove-rollback-admin-keys >"$TEST_ROOT/rollback-target-mismatch.log" 2>&1; then
  fail "rollback-key removal accepted state from another RDS target"
fi
grep -q 'STATE_DIR belongs to a different' "$TEST_ROOT/rollback-target-mismatch.log" \
  || fail "rollback target mismatch refusal was unclear"
! grep -q 'get secret' "$COMMAND_LOG" || fail "rollback target mismatch read a live Secret"
! grep -q 'patch secret' "$COMMAND_LOG" || fail "rollback target mismatch patched a live Secret"
pass "rollback-key removal binds state to the Kubernetes and RDS target"

printf '%s\n' dedicated-owner >"${STATE_DIR}/hoopdb-layout"
: >"${COMMAND_LOG}"
set +e
dedicated_remove_output="$(env -u SERVICES_IMAGE bash "$RDS_SETUP" remove-rollback-admin-keys 2>&1)"
dedicated_remove_rc=$?
set -e
[[ "$dedicated_remove_rc" != 0 && "$dedicated_remove_output" == *"only for an existing administrator-owned install"* ]] \
  || fail "dedicated-owner install did not refuse rollback-key removal"
! grep -q 'patch secret' "$COMMAND_LOG" || fail "dedicated-owner rollback-key refusal patched a live Secret"
printf '%s\n' legacy-admin >"${STATE_DIR}/hoopdb-layout"
pass "rollback-key removal is restricted to validated legacy layouts"

set +e
nostate_output="$(STATE_DIR="$(mktemp -d)" bash "${RDS_SETUP}" refresh-admin 2>&1)"
nostate_rc=$?
set -e
[[ "${nostate_rc}" != 0 && "${nostate_output}" == *"run '"*"pre' first"* ]] || fail "refresh-admin without state must refuse"
pass "refresh-admin refuses without pre state"
