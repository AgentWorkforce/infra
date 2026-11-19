#!/usr/bin/env bash
# Offline behavioral tests for cloud-sql-setup.sh. Every external GCP and
# Kubernetes command is mocked; no network or cluster access is used.
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${TEST_DIR}/../cloud-sql-setup.sh"
TEST_BASH="${TEST_BASH:-bash}"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"
STATE="$ROOT/state"
LOG="$ROOT/commands.log"
CAPTURE="$ROOT/capture"
SQL_LOG="$ROOT/sql.log"
mkdir -p "$BIN" "$CAPTURE"
: >"$LOG"
: >"$SQL_LOG"

fail() { printf 'not ok - cloud-sql-setup: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - cloud-sql-setup: %s\n' "$*"; }

cat >"$BIN/gcloud" <<'MOCK'
#!/usr/bin/env bash
printf 'gcloud %s\n' "$*" >>"$MOCK_LOG"
case " $* " in
  *" secrets versions access "*)
    case "${MOCK_ADMIN_SECRET_MODE:-valid}" in
      fail) exit 1 ;;
      empty) exit 0 ;;
      valid) printf '%s' 'admin-password' ;;
    esac
    ;;
  *" sql ssl server-ca-certs list "*) printf '[{"cert":"-----BEGIN CERTIFICATE-----\\nMOCK\\n-----END CERTIFICATE-----\\n"}]\n' ;;
  *" sql instances describe "*) printf '{"dnsNames":[{"connectionType":"PRIVATE_SERVICES_ACCESS","name":"db.example.sql-psa.goog."}]}\n' ;;
  *) exit 1 ;;
esac
MOCK

cat >"$BIN/openssl" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == rand && "$2" == -hex ]] || exit 1
printf '%048d' 0
MOCK

cat >"$BIN/psql" <<'MOCK'
#!/usr/bin/env bash
printf 'psql %s\n' "$*" >>"$MOCK_SQL_LOG"
if [[ "${MOCK_PSQL_FAIL_DATABASE:-0}" == 1 && "$*" == *"select 1 from pg_database where datname='hoopdb'"* ]]; then
  exit 1
fi
case "$*" in
  *"select 1 from pg_database where datname='hoopdb'"*) [[ "${MOCK_DB_EXISTS:-1}" == 1 ]] && printf '1\n' ;;
  *"select pg_get_userbyid(datdba) from pg_database where datname='hoopdb'"*) printf '%s\n' "${MOCK_DB_OWNER:-hoopdb_owner}" ;;
  *"select 1 where"*) [[ "${MOCK_PRISTINE:-0}" == 1 ]] && printf '1\n' ;;
  *)
    payload="$(cat)"
    printf 'stdin %s\n' "$payload" >>"$MOCK_SQL_LOG"
    ;;
esac
MOCK

cat >"$BIN/helm" <<'MOCK'
#!/usr/bin/env bash
printf 'helm %s\n' "$*" >>"$MOCK_LOG"
cat <<'YAML'
---
apiVersion: batch/v1
kind: Job
metadata:
  name: agent-relay-worker-migrate-current
  labels:
    app.kubernetes.io/component: hoopdb-migrate
spec:
  template:
    spec:
      containers:
        - name: migrate
YAML
MOCK

cat >"$BIN/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >>"$MOCK_LOG"
for argument in "$@"; do
  case "$argument" in
    --from-file=run.sh=*)
      cp "${argument#--from-file=run.sh=}" "$MOCK_CAPTURE/run.sh"
      case " $* " in *" agent-relay-cloud-sql-probe-run "*) cp "${argument#--from-file=run.sh=}" "$MOCK_CAPTURE/probe.sh" ;; esac
      ;;
    --from-file=*)
      source_path="${argument#--from-file=}"
      if [[ -d "$source_path" && -f "$source_path/MISSING_STATE_NAMES" ]]; then
        cp "$source_path/MISSING_STATE_NAMES" "$MOCK_CAPTURE/MISSING_STATE_NAMES"
      fi
      ;;
  esac
done
case " $* " in
  *" create configmap "*" --dry-run=client "*)
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: mock\n'
    ;;
  *" apply -f - "*)
    payload="$(cat)"
    if jq -e '.kind == "Job"' >/dev/null 2>&1 <<<"$payload"; then
      name="$(jq -r '.metadata.name' <<<"$payload")"
      printf '%s\n' "$payload" >"$MOCK_CAPTURE/job-$name.json"
    fi
    ;;
  *" create secret generic "*) ;;
  *" get secret hoopdb-admin-jobs -o name "*) printf 'secret/hoopdb-admin-jobs\n' ;;
  *" get secret agent-relay-secrets -o json "*|*" get secret search-indexer-owner -o json "*)
    case "${MOCK_SECRET_READ_MODE:-ok}" in
      notfound) echo 'Error from server (NotFound): secrets not found' >&2; exit 1 ;;
      error) echo 'transport is unavailable' >&2; exit 1 ;;
    esac
    name=agent-relay-secrets; key=HOOPDB_MIGRATION_URL
    [[ " $* " == *" search-indexer-owner "* ]] && { name=search-indexer-owner; key=RELAYHISTORY_PIPELINE_CONSUMER_SECRET; }
    if [[ "${MOCK_SECRET_KEY_ABSENT:-0}" == 1 && "${MOCK_EXTERNAL_SECRET_MODE:-none}" == owner ]]; then
      printf '{"metadata":{"ownerReferences":[{"kind":"ExternalSecret","name":"%s"}]},"data":{}}\n' "$name"
    elif [[ "${MOCK_SECRET_KEY_ABSENT:-0}" == 1 && "${MOCK_EXTERNAL_SECRET_MODE:-none}" == label ]]; then
      printf '{"metadata":{"labels":{"reconcile.external-secrets.io/managed":"true"}},"data":{}}\n'
    elif [[ "${MOCK_EXTERNAL_SECRET_MODE:-none}" == owner ]]; then
      printf '{"metadata":{"ownerReferences":[{"kind":"ExternalSecret","name":"%s"}]},"data":{"%s":"b2xk"}}\n' "$name" "$key"
    elif [[ "${MOCK_EXTERNAL_SECRET_MODE:-none}" == label ]]; then
      printf '{"metadata":{"labels":{"reconcile.external-secrets.io/managed":"true"}},"data":{"%s":"b2xk"}}\n' "$key"
    else
      printf '{"metadata":{},"data":{"%s":"b2xk"}}\n' "$key"
    fi
    ;;
  *" patch secret "*) ;;
  *" get namespace "*) ;;
  *" create namespace "*) ;;
  *" delete "*) ;;
  *" logs job/agent-relay-cloud-sql-pre"*)
    if [[ "${MOCK_DEDICATED_MISSING:-false}" == true ]]; then
      printf 'setup output without credentials\nHOOPDB_STATE=dedicated-owner-missing\n'
    else
      printf 'setup output without credentials\nHOOPDB_LAYOUT=%s\n' "${MOCK_PRE_LAYOUT:-${MOCK_LAYOUT:-fresh-dedicated}}"
    fi
    ;;
  *" logs job/agent-relay-cloud-sql-probe"*)
    printf 'HOOPDB_LAYOUT=%s\n' "${MOCK_LAYOUT:-fresh-dedicated}"
    ;;
  *" logs job/"*) printf 'setup output without credentials\n' ;;
  *" get job agent-relay-worker-migrate-current -o json "*)
    if [[ "${MOCK_MIGRATION_STATUS:-complete}" == failed ]]; then
      printf '{"status":{"failed":1,"conditions":[{"type":"Failed","status":"True"}]}}\n'
    else
      printf '{"status":{"succeeded":1,"conditions":[{"type":"Complete","status":"True"}]}}\n'
    fi
    ;;
  *" get job agent-relay-cloud-sql-probe "*"jsonpath={.status.succeeded}"*) printf '1' ;;
  *" get job agent-relay-cloud-sql-probe "*"jsonpath={.status.failed}"*) ;;
  *" get job agent-relay-cloud-sql-"*"jsonpath={.status.succeeded}"*)
    [[ "${MOCK_SETUP_JOB_FAILED:-false}" == true ]] || printf '1'
    ;;
  *" get job agent-relay-cloud-sql-"*"jsonpath={.status.failed}"*)
    [[ "${MOCK_SETUP_JOB_FAILED:-false}" == true ]] && printf '1'
    ;;
  *) ;;
esac
MOCK
chmod +x "$BIN"/*

export PATH="$BIN:$PATH"
export MOCK_LOG="$LOG"
export MOCK_CAPTURE="$CAPTURE"
export MOCK_SQL_LOG="$SQL_LOG"
export GCP_PROJECT_ID=example
export CLOUD_SQL_INSTANCE=agent-relay-pg
export CLOUD_SQL_HOST=db.example.sql-psa.goog.
export CLOUD_SQL_ADMIN_USER=cloud-admin
export CLOUD_SQL_ADMIN_SECRET_ID=agent-relay-pg-admin
export SERVICES_IMAGE=ghcr.io/agentworkforce/sessions-pipeline@sha256:dc95d94202c49573749f99cc548638ed185f782dc3b88691f551d7f1f700f769
export STATE_DIR="$STATE"
export JOB_TIMEOUT_SECONDS=5

for mode in fail empty; do
  bad_state="$ROOT/admin-$mode"
  : >"$LOG"
  if MOCK_ADMIN_SECRET_MODE="$mode" STATE_DIR="$bad_state" "$TEST_BASH" "$SCRIPT" pre >"$ROOT/admin-$mode.log" 2>&1; then
    fail "$mode Cloud SQL administrator Secret was accepted"
  fi
  grep -Eq 'could not read|password is empty' "$ROOT/admin-$mode.log" \
    || fail "$mode Cloud SQL administrator Secret refusal was unclear"
  grep -q '^kubectl' "$LOG" && fail "$mode Cloud SQL administrator Secret reached a cluster write"
  [[ ! -e "$bad_state/secret-files/agent-relay-secrets/HOOPDB_MIGRATION_URL" ]] \
    || fail "$mode Cloud SQL administrator Secret wrote an owner URL"
done
pass "failed and empty Cloud SQL administrator Secret reads stop before cluster or credential writes"

"$TEST_BASH" "$SCRIPT" pre >/dev/null
grep -F 'ALTER DATABASE relaycast OWNER TO CURRENT_USER' "$SCRIPT" >/dev/null || fail "Relaycast database owner boundary is missing"
if grep -Fq 'ALTER DATABASE relaycast OWNER TO relaycast_owner' "$SCRIPT"; then
  fail "Relaycast role incorrectly owns the database"
fi
grep -F 'CREATE ROLE agent_relay_hoopdb_role_creator' "$SCRIPT" >/dev/null || fail "disposable owner/runtime role executor is missing"
grep -F 'DROP ROLE agent_relay_hoopdb_role_creator' "$SCRIPT" >/dev/null || fail "disposable role executor is not removed"
[[ -s "$CAPTURE/job-agent-relay-cloud-sql-pre.json" ]] || fail "pre Job manifest was not submitted"
jq -e '.spec.template.spec.automountServiceAccountToken == false and
  any(.spec.template.spec.volumes[]; .name == "ca") and
  .spec.template.spec.initContainers[0].image == env.SERVICES_IMAGE' \
  "$CAPTURE/job-agent-relay-cloud-sql-pre.json" >/dev/null || fail "pre Job is missing its hardened CA/image contract"
grep -F 'create secret generic agent-relay-cloud-sql-pre-secret' "$LOG" >/dev/null || fail "temporary Secret was not created"
if grep -F 'create secret generic agent-relay-cloud-sql-pre-secret' "$LOG" | grep -q -- '--dry-run'; then
  fail "temporary Secret used apply-style last-applied annotations"
fi
grep -F 'delete secret agent-relay-cloud-sql-pre-secret --ignore-not-found' "$LOG" >/dev/null || fail "temporary Secret was not cleaned up"
[[ -s "$STATE/secret-files/agent-relay-secrets/HOOPDB_URL" ]] || fail "runtime credential file was not generated"
grep -F 'hoopdb_owner:' "$STATE/secret-files/agent-relay-secrets/HOOPDB_MIGRATION_URL" >/dev/null || fail "migration URL does not use hoopdb_owner"
grep -F 'hoopdb_owner:' "$STATE/secret-files/search-indexer-owner/RELAYHISTORY_PIPELINE_CONSUMER_SECRET" >/dev/null || fail "search bootstrap URL does not use hoopdb_owner"
[[ "$(cat "$STATE/hoopdb-layout")" == dedicated-owner ]] || fail "dedicated-owner layout marker is missing"
grep -F 'sessions_pipeline_runtime:' "$STATE/secret-files/agent-relay-secrets/HOOPDB_URL" >/dev/null || fail "runtime URL uses the wrong role"
grep -F 'sslmode=verify-full' "$STATE/secret-files/agent-relay-secrets/HOOPDB_URL" >/dev/null || fail "runtime URL does not verify Cloud SQL TLS"
grep -F 'sslrootcert=/etc/postgres-ca/ca.crt' "$STATE/secret-files/agent-relay-secrets/HOOPDB_URL" >/dev/null \
  || fail "runtime URL does not name the mounted CA for native brief workers"
[[ "$(stat -c %a "$STATE/secret-files/agent-relay-secrets/HOOPDB_URL")" == 600 ]] || fail "credential file mode is not 0600"
pass "pre creates hardened Job, create-only temporary Secret and credential files"

: >"$LOG"
MOCK_LAYOUT=dedicated-owner "$TEST_BASH" "$SCRIPT" pre >/dev/null
grep -F 'create secret generic agent-relay-cloud-sql-pre-secret' "$LOG" >/dev/null || fail "dedicated rerun did not classify the database"
grep -F 'hoopdb_owner:' "$STATE/secret-files/agent-relay-secrets/HOOPDB_MIGRATION_URL" >/dev/null || fail "dedicated rerun changed the owner URL"
grep -F 'dedicated HoopDb ownership already committed; finishing prerequisites' "$CAPTURE/run.sh" >/dev/null \
  || fail "dedicated rerun exits instead of finishing interrupted prerequisites"
grep -F 'for f in session_directory_search_worker session_token_verifier session_ingest_roles session_read_api_roles' "$CAPTURE/run.sh" >/dev/null \
  || fail "dedicated rerun omits the role prerequisites after an interrupted pre"
grep -F 'protected role membership edges:' "$CAPTURE/run.sh" >/dev/null \
  || fail "dedicated rerun omits the protected-role membership census"
pass "dedicated-owner pre rerun finishes an interrupted pre and reuses saved passwords"

secret_hashes_before="$(find "$STATE/secret-files" -type f -print0 | sort -z | xargs -0 sha256sum)"
rm "$STATE/passwords/relaycast_runtime"
: >"$LOG"
rm -f "$CAPTURE/job-agent-relay-cloud-sql-pre.json"
if MOCK_LAYOUT=dedicated-owner \
    "$TEST_BASH" "$SCRIPT" pre >"$ROOT/pre-dedicated-missing.log" 2>&1; then
  fail "dedicated-owner rerun accepted missing saved credential state"
fi
grep -F 'STATE_DIR lacked trusted saved passwords for: relaycast_runtime' "$ROOT/pre-dedicated-missing.log" >/dev/null \
  || fail "missing saved credential state diagnostic is absent"
[[ ! -e "$CAPTURE/job-agent-relay-cloud-sql-pre.json" ]] \
  || fail "dedicated-owner missing-state refusal started the mutating setup Job"
[[ ! -e "$STATE/passwords/relaycast_runtime" ]] \
  || fail "dedicated-owner refusal retained the newly generated password"
[[ "$(find "$STATE/secret-files" -type f -print0 | sort -z | xargs -0 sha256sum)" == "$secret_hashes_before" ]] \
  || fail "dedicated-owner refusal rewrote a long-lived Secret file"
if grep -Fq 'patch secret ' "$LOG"; then
  fail "dedicated-owner refusal patched a live Kubernetes Secret"
fi
password_for_repair="$STATE/passwords/relaycast_runtime"
printf '%048d' 0 >"$password_for_repair"; chmod 600 "$password_for_repair"
pass "dedicated-owner rerun refuses missing saved state before database or Secret writes"

printf 'relaycast_runtime\n' >"$STATE/.pending-hoopdb-passwords"
printf 'fresh activation in progress\n' >"$STATE/.pending-hoopdb-activation"
: >"$LOG"
MOCK_LAYOUT=dedicated-owner "$TEST_BASH" "$SCRIPT" pre >/dev/null \
  || fail "an interrupted fresh activation could not resume"
[[ -s "$STATE/passwords/relaycast_runtime" ]] || fail "resumed activation deleted a committed password"
[[ ! -e "$STATE/.pending-hoopdb-passwords" && ! -e "$STATE/.pending-hoopdb-activation" ]] \
  || fail "successful resumed activation retained pending-state markers"
grep -F 'create secret generic agent-relay-cloud-sql-pre-secret' "$LOG" >/dev/null \
  || fail "resumed activation did not finish the setup prerequisites"
pass "post-commit interruption reuses the committed password files"

# Terraform may pre-create an empty hoopdb. The catalog proof, not a wrapper
# flag, distinguishes it from an existing administrator-owned install.
: >"$LOG"
MOCK_LAYOUT=pristine-admin MOCK_PRE_LAYOUT=fresh-dedicated \
  "$TEST_BASH" "$SCRIPT" pre >/dev/null
grep -F 'create secret generic agent-relay-cloud-sql-pre-secret' "$LOG" >/dev/null \
  || fail "pristine Cloud SQL database did not start activation"
[[ "$(cat "$STATE/hoopdb-layout")" == dedicated-owner ]] || fail "pristine Cloud SQL database did not become dedicated-owner"
grep -F "to_regnamespace('sessions') is null" "$SCRIPT" >/dev/null \
  || fail "Cloud SQL pristine probe does not reject an existing sessions schema"
grep -F "rolname in ('hoopdb_owner','sessions_pipeline_runtime','search_consumer_runtime','session_directory_search_worker')" "$SCRIPT" >/dev/null \
  || fail "Cloud SQL pristine probe does not reject an existing HoopDb role"
pass "Cloud SQL activates a classifier-proven pristine provider-created HoopDb"

probe="$CAPTURE/probe.sh"
[[ -s "$probe" ]] || fail "Cloud SQL classifier probe was not captured"
probe_out="$(PGUSER=cloud-admin MOCK_DB_EXISTS=1 MOCK_DB_OWNER=cloud-admin MOCK_PRISTINE=1 sh "$probe")" \
  || fail "pristine Cloud SQL probe failed"
[[ "$probe_out" == HOOPDB_LAYOUT=pristine-admin ]] || fail "pristine Cloud SQL probe classified as: $probe_out"
if PGUSER=cloud-admin MOCK_PSQL_FAIL_DATABASE=1 sh "$probe" >"$ROOT/probe-fail.log" 2>&1; then
  fail "failed Cloud SQL pg_database query took a layout path"
fi
grep -q 'could not inspect the HoopDb database' "$ROOT/probe-fail.log" \
  || fail "failed Cloud SQL pg_database query had no clear refusal"
pass "Cloud SQL classifier executes the pristine and query-failure branches fail closed"

printf 'fresh activation in progress\n' >"$STATE/.pending-hoopdb-activation"
: >"$LOG"
MOCK_LAYOUT=pristine-admin MOCK_PRE_LAYOUT=fresh-dedicated "$TEST_BASH" "$SCRIPT" pre >/dev/null \
  || fail "a marked pristine Cloud SQL activation could not resume"
grep -F 'create secret generic agent-relay-cloud-sql-pre-secret' "$LOG" >/dev/null \
  || fail "marked pristine Cloud SQL activation did not resume the setup Job"
[[ ! -e "$STATE/.pending-hoopdb-activation" ]] || fail "marked pristine Cloud SQL retry retained its pending marker"
pass "Cloud SQL resumes a marked pristine activation without a second approval flag"

printf 'hoopdb_owner\n' >"$STATE/.pending-hoopdb-passwords"
printf 'fresh activation in progress\n' >"$STATE/.pending-hoopdb-activation"
rm -f "$STATE/passwords/hoopdb_owner" "$CAPTURE/job-agent-relay-cloud-sql-pre.json"
: >"$LOG"
if MOCK_LAYOUT=dedicated-owner "$TEST_BASH" "$SCRIPT" pre >"$ROOT/pre-marked-missing.log" 2>&1; then
  fail "marked Cloud SQL retry regenerated a missing live password"
fi
grep -F 'interrupted activation lacks saved passwords for: hoopdb_owner' "$ROOT/pre-marked-missing.log" >/dev/null \
  || fail "marked Cloud SQL missing-password refusal was unclear"
[[ ! -e "$STATE/passwords/hoopdb_owner" ]] || fail "marked Cloud SQL refusal retained its generated replacement"
[[ -e "$STATE/.pending-hoopdb-activation" ]] || fail "marked Cloud SQL refusal discarded recovery state"
[[ ! -e "$CAPTURE/job-agent-relay-cloud-sql-pre.json" ]] || fail "marked Cloud SQL refusal started the mutating Job"
printf '%048d' 0 >"$STATE/passwords/hoopdb_owner"; chmod 600 "$STATE/passwords/hoopdb_owner"
rm -f "$STATE/.pending-hoopdb-activation" "$STATE/.pending-hoopdb-passwords"
pass "marked Cloud SQL retry refuses an absent committed password before writes"

: >"$LOG"
MOCK_LAYOUT=legacy-admin "$TEST_BASH" "$SCRIPT" pre >/dev/null
"$TEST_BASH" "$SCRIPT" prepare-admin-jobs >/dev/null
grep -F 'create secret generic hoopdb-admin-jobs' "$LOG" >/dev/null || fail "legacy prepare did not create the temporary Secret"
if grep -Fq 'patch secret agent-relay-secrets' "$LOG" || grep -Fq 'patch secret search-indexer-owner' "$LOG"; then
  fail "legacy prepare removed rollback credentials before Helm succeeded"
fi
"$TEST_BASH" "$SCRIPT" remove-legacy-secret-keys >/dev/null
before_migration=$(grep -n 'patch secret agent-relay-secrets' "$LOG" | head -1 | cut -d: -f1)
before_search=$(grep -n 'patch secret search-indexer-owner' "$LOG" | head -1 | cut -d: -f1)
[[ -n "$before_migration" && -n "$before_search" ]] || fail "post-success cleanup did not remove both live administrator keys"
pass "legacy keys remain through Helm and are removed only by post-success cleanup"

: >"$LOG"
MOCK_SECRET_READ_MODE=notfound "$TEST_BASH" "$SCRIPT" remove-legacy-secret-keys >/dev/null \
  || fail "NotFound Secret was not treated as already absent"
grep -Fq 'patch secret' "$LOG" && fail "NotFound cleanup attempted a patch"
if MOCK_SECRET_READ_MODE=error "$TEST_BASH" "$SCRIPT" remove-legacy-secret-keys >"$ROOT/remove-api-error.log" 2>&1; then
  fail "Secret read API error was treated as absence"
fi
grep -F 'could not read Secret agent-relay-secrets' "$ROOT/remove-api-error.log" >/dev/null \
  || fail "Secret read API error refusal was unclear"
for managed in owner label; do
  : >"$LOG"
  if MOCK_EXTERNAL_SECRET_MODE="$managed" "$TEST_BASH" "$SCRIPT" remove-legacy-secret-keys >"$ROOT/remove-external-$managed.log" 2>&1; then
    fail "$managed-managed External Secret was patched"
  fi
  grep -F 'HOOPDB_MIGRATION_URL mapping' "$ROOT/remove-external-$managed.log" >/dev/null \
    || fail "$managed-managed External Secret refusal did not name the mapping"
  grep -F 'backing-store value' "$ROOT/remove-external-$managed.log" >/dev/null \
    || fail "$managed-managed External Secret refusal did not name the store action"
  grep -Fq 'patch secret' "$LOG" && fail "$managed-managed External Secret reached a patch"
  : >"$LOG"
  MOCK_EXTERNAL_SECRET_MODE="$managed" MOCK_SECRET_KEY_ABSENT=1 \
    "$TEST_BASH" "$SCRIPT" remove-legacy-secret-keys >/dev/null \
    || fail "$managed-managed cleanup did not finish after the mapped key disappeared"
  grep -Fq 'patch secret' "$LOG" && fail "$managed-managed absent key reached a patch"
done
pass "legacy cleanup distinguishes NotFound, API errors and External Secrets key ownership"

# Terraform's chart_values pin sha256(server_ca_cert): the PEM with exactly one
# trailing newline. The bundle written for the ConfigMap must be those bytes.
expected_ca_sha="$(printf -- '-----BEGIN CERTIFICATE-----\nMOCK\n-----END CERTIFICATE-----\n' | sha256sum | cut -d' ' -f1)"
[[ "$(sha256sum "$STATE/cloud-sql-ca.pem" | cut -d' ' -f1)" == "$expected_ca_sha" ]] || fail "CA bundle bytes differ from Terraform's server_ca_cert"
[[ "$(cat "$STATE/cloud-sql-ca.sha256")" == "$expected_ca_sha" ]] || fail "recorded CA sha256 differs from Terraform's pin"
pass "CA bundle matches the Terraform caSha256 pin"

: >"$LOG"
CLOUD_SQL_ADMIN_SECRET_ID=projects/secret-project/secrets/agent-relay-pg-admin \
  CLOUD_SQL_CA_SHA256="$expected_ca_sha" "$TEST_BASH" "$SCRIPT" pre >/dev/null
grep -F 'gcloud secrets versions access latest --project secret-project --secret agent-relay-pg-admin' "$LOG" >/dev/null \
  || fail "full Secret Manager resource name was not split into project and id"
pass "pre accepts the Terraform admin_password_secret_id resource name"

: >"$LOG"
if CLOUD_SQL_CA_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
    "$TEST_BASH" "$SCRIPT" pre >"$ROOT/pre-ca-mismatch.log" 2>&1; then
  fail "pre accepted a CA bundle that differs from CLOUD_SQL_CA_SHA256"
fi
grep -F 'differs from CLOUD_SQL_CA_SHA256' "$ROOT/pre-ca-mismatch.log" >/dev/null || fail "CA pin mismatch diagnostic is missing"
if grep -Fq 'create secret generic agent-relay-cloud-sql-pre-secret' "$LOG"; then
  fail "pre ran database setup after a CA pin mismatch"
fi
pass "pre stops when the CA bundle differs from the chart pin"

: >"$LOG"
MOCK_MIGRATION_STATUS=complete "$TEST_BASH" "$SCRIPT" post >/dev/null
grep -F 'helm -n agent-relay get manifest agent-relay' "$LOG" >/dev/null || fail "post did not inspect the current Helm manifest"
grep -F 'get job agent-relay-worker-migrate-current -o json' "$LOG" >/dev/null || fail "post did not gate on the exact current migration Job"
[[ -s "$CAPTURE/job-agent-relay-cloud-sql-post.json" ]] || fail "post Job manifest was not submitted"
pass "post gates activation on the exact current migration Job"

: >"$LOG"
if MOCK_MIGRATION_STATUS=failed "$TEST_BASH" "$SCRIPT" post >"$ROOT/post-failed.log" 2>&1; then
  fail "post accepted a failed current migration Job"
fi
grep -F 'current HoopDb migrate Job agent-relay-worker-migrate-current failed' "$ROOT/post-failed.log" >/dev/null || fail "failed migration diagnostic is missing"
if grep -Fq 'create secret generic agent-relay-cloud-sql-post-secret' "$LOG"; then
  fail "post created bootstrap credentials after a failed migration"
fi
pass "post rejects a failed current migration even if older Jobs exist"

FAIL_STATE="$ROOT/failure-state"
: >"$LOG"
if MOCK_SETUP_JOB_FAILED=true STATE_DIR="$FAIL_STATE" "$TEST_BASH" "$SCRIPT" pre >"$ROOT/pre-failed.log" 2>&1; then
  fail "pre accepted a failed setup Job"
fi
grep -F 'delete secret agent-relay-cloud-sql-pre-secret --ignore-not-found' "$LOG" >/dev/null || fail "failed pre did not clean up its temporary Secret"
pass "failed setup cleans up temporary credentials"
