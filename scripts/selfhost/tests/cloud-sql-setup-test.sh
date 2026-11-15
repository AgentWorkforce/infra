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
mkdir -p "$BIN" "$CAPTURE"
: >"$LOG"

fail() { printf 'not ok - cloud-sql-setup: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - cloud-sql-setup: %s\n' "$*"; }

cat >"$BIN/gcloud" <<'MOCK'
#!/usr/bin/env bash
printf 'gcloud %s\n' "$*" >>"$MOCK_LOG"
case " $* " in
  *" secrets versions access "*) printf '%s' 'admin-password' ;;
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
  *" get namespace "*) ;;
  *" create namespace "*) ;;
  *" delete "*) ;;
  *" logs job/"*) printf 'setup output without credentials\n' ;;
  *" get job agent-relay-worker-migrate-current -o json "*)
    if [[ "${MOCK_MIGRATION_STATUS:-complete}" == failed ]]; then
      printf '{"status":{"failed":1,"conditions":[{"type":"Failed","status":"True"}]}}\n'
    else
      printf '{"status":{"succeeded":1,"conditions":[{"type":"Complete","status":"True"}]}}\n'
    fi
    ;;
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
export GCP_PROJECT_ID=example
export CLOUD_SQL_INSTANCE=agent-relay-pg
export CLOUD_SQL_HOST=db.example.sql-psa.goog.
export CLOUD_SQL_ADMIN_USER=cloud-admin
export CLOUD_SQL_ADMIN_SECRET_ID=agent-relay-pg-admin
export SERVICES_IMAGE=ghcr.io/agentworkforce/sessions-pipeline@sha256:dc95d94202c49573749f99cc548638ed185f782dc3b88691f551d7f1f700f769
export STATE_DIR="$STATE"
export JOB_TIMEOUT_SECONDS=5

"$TEST_BASH" "$SCRIPT" pre >/dev/null
grep -F 'ALTER DATABASE relaycast OWNER TO CURRENT_USER' "$SCRIPT" >/dev/null || fail "Relaycast database owner boundary is missing"
if grep -Fq 'ALTER DATABASE relaycast OWNER TO relaycast_owner' "$SCRIPT"; then
  fail "Relaycast role incorrectly owns the database"
fi
grep -F 'session_consumer_roles.sql' "$SCRIPT" >/dev/null || fail "pre-migration consumer role bootstrap is missing"
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
grep -F 'sessions_pipeline_runtime:' "$STATE/secret-files/agent-relay-secrets/HOOPDB_URL" >/dev/null || fail "runtime URL uses the wrong role"
grep -F 'sslmode=verify-full' "$STATE/secret-files/agent-relay-secrets/HOOPDB_URL" >/dev/null || fail "runtime URL does not verify Cloud SQL TLS"
[[ "$(stat -c %a "$STATE/secret-files/agent-relay-secrets/HOOPDB_URL")" == 600 ]] || fail "credential file mode is not 0600"
pass "pre creates hardened Job, create-only temporary Secret and credential files"

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
