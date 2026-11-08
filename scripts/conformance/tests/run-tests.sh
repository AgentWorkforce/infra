#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFORMANCE_DIR="$(cd -- "${TEST_DIR}/.." && pwd)"
HARNESS="${CONFORMANCE_DIR}/run.sh"
LIB="${CONFORMANCE_DIR}/lib.sh"
# Run the harness under TEST_BASH (for example /bin/bash 3.2 on macOS) to
# prove compatibility with the oldest supported shell.
TEST_BASH="${TEST_BASH:-bash}"
tmp_root="$(mktemp -d)"
trap 'rm -rf "${tmp_root}"' EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$*"
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  rg -q -- "${pattern}" "${file}" || fail "${file} does not contain ${pattern}"
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  if rg -q -- "${pattern}" "${file}"; then
    fail "${file} unexpectedly contains ${pattern}"
  fi
}

mock_bin="${tmp_root}/bin"
mkdir -p "${mock_bin}"
command_log="${tmp_root}/commands.log"
: >"${command_log}"

fixtures="${tmp_root}/fixtures"
mkdir -p "${fixtures}"

cat >"${mock_bin}/helm" <<'MOCK'
#!/usr/bin/env bash
printf 'helm' >>"${MOCK_COMMAND_LOG}"
printf ' %q' "$@" >>"${MOCK_COMMAND_LOG}"
printf '\n' >>"${MOCK_COMMAND_LOG}"
case " $* " in
  *migration-failure.yaml*|*wrong-database.yaml*)
    exit 1
    ;;
  *" list "*)
    filter=""
    previous=""
    for arg in "$@"; do
      [[ "${previous}" == "--filter" ]] && filter="${arg}"
      previous="${arg}"
    done
    name="${filter#^}"
    name="${name%$}"
    printf '[{"name":"%s","status":"deployed","chart":"%s"}]\n' \
      "${name}" "${MOCK_HELM_CHART:-agent-relay-1.0.0}"
    ;;
esac
exit 0
MOCK

# kubectl returns ${MOCK_FIXTURES}/<namespace>.<resource>.json for JSON gets,
# so scenarios can be driven with specific cluster states.
cat >"${mock_bin}/kubectl" <<'MOCK'
#!/usr/bin/env bash
printf 'kubectl' >>"${MOCK_COMMAND_LOG}"
printf ' %q' "$@" >>"${MOCK_COMMAND_LOG}"
printf '\n' >>"${MOCK_COMMAND_LOG}"
namespace=""
resource=""
previous=""
for arg in "$@"; do
  case "${previous}" in
    --namespace|-n) namespace="${arg}" ;;
    get) resource="${arg}" ;;
  esac
  previous="${arg}"
done
case " $* " in
  *" --output json "*|*" -o json "*)
    fixture="${MOCK_FIXTURES}/${namespace}.${resource}.json"
    if [[ -f "${fixture}" ]]; then
      cat "${fixture}"
    else
      printf '{"items":[]}\n'
    fi
    exit 0
    ;;
esac
case " $* " in
  *" get networkpolicy "*) printf 'networkpolicy.networking.k8s.io/default-deny\n' ;;
esac
exit 0
MOCK

cat >"${mock_bin}/curl" <<'MOCK'
#!/usr/bin/env bash
output_file=""
action=""
while (($#)); do
  case "$1" in
    --output) output_file="$2"; shift 2 ;;
    https://*) action="${1##*/}"; shift ;;
    *) shift ;;
  esac
done
if [[ -n "${output_file}" ]]; then
  printf '{"ok":true,"action":"%s"}\n' "${action}" >"${output_file}"
fi
exit 0
MOCK

cat >"${mock_bin}/getent" <<'MOCK'
#!/usr/bin/env bash
printf '192.0.2.10 STREAM conformance.example.test\n'
MOCK
chmod +x "${mock_bin}/helm" "${mock_bin}/kubectl" "${mock_bin}/curl" "${mock_bin}/getent"

export PATH="${mock_bin}:${PATH}"
export MOCK_COMMAND_LOG="${command_log}"
export MOCK_FIXTURES="${fixtures}"

"${TEST_BASH}" -n "${HARNESS}" "${LIB}" "${CONFORMANCE_DIR}/http-adapter.sh"
pass "shell syntax"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "${HARNESS}" "${LIB}" "${CONFORMANCE_DIR}/http-adapter.sh"
  pass "shellcheck"
fi

CONFORMANCE_BASE_URL=https://conformance.example.test \
  CONFORMANCE_RUN_ID=adapter-test \
  "${CONFORMANCE_DIR}/http-adapter.sh" smoke
if CONFORMANCE_BASE_URL=http://conformance.example.test \
  CONFORMANCE_RUN_ID=adapter-test \
  "${CONFORMANCE_DIR}/http-adapter.sh" smoke >/dev/null 2>&1; then
  fail "HTTP adapter accepted a non-TLS URL"
fi
pass "reference HTTP adapter validates TLS and success envelopes"

# GKE Ingress as charts/agent-relay renders it: ManagedCertificate and
# FrontendConfig annotations, backend health reported by the GCE controller.
write_gke_fixtures() {
  local namespace="$1"
  local backend_state="${2:-HEALTHY}"
  local cert_state="${3:-Active}"
  jq -n --arg state "${backend_state}" '{items: [{
    metadata: {name: "agent-relay", annotations: {
      "kubernetes.io/ingress.class": "gce",
      "networking.gke.io/managed-certificates": "agent-relay-cert",
      "networking.gke.io/v1beta1.FrontendConfig": "agent-relay-frontend",
      "ingress.kubernetes.io/backends": ({"k8s1-api": "HEALTHY", "k8s1-cast": $state} | tojson)
    }}}]}' >"${fixtures}/${namespace}.ingresses.networking.k8s.io.json"
  jq -n --arg state "${cert_state}" '{items: [{
    metadata: {name: "agent-relay-cert"},
    status: {certificateStatus: $state}}]}' \
    >"${fixtures}/${namespace}.managedcertificates.networking.gke.io.json"
}
write_gke_fixtures production
write_gke_fixtures aw-conformance-test

audit_evidence="${tmp_root}/audit-evidence"
"${TEST_BASH}" "${HARNESS}" \
  --chart ./umbrella \
  --target-namespace production \
  --target-release agentworkforce \
  --evidence-dir "${audit_evidence}" >/dev/null

assert_contains "${command_log}" 'helm upgrade --install'
assert_contains "${command_log}" '--dry-run'
assert_contains "${command_log}" '--hide-secret'
assert_not_contains "${command_log}" 'kubectl (apply|create|delete|edit|label|annotate|patch|replace|rollout|scale|set|exec|run)'
jq -e '.success == true and .mode == "audit"' "${audit_evidence}/summary.json" >/dev/null
jq -e '.scenarios | length == 19' "${audit_evidence}/summary.json" >/dev/null
jq -e '.scenarios[] | select(.scenario == "fresh-install" and .status == "PASS")' \
  "${audit_evidence}/summary.json" >/dev/null
pass "audit mode is dry-run/read-only and emits valid evidence"

for broken in "UNHEALTHY Active" "HEALTHY Provisioning"; do
  read -r backend_state cert_state <<<"${broken}"
  write_gke_fixtures gke-broken "${backend_state}" "${cert_state}"
  "${TEST_BASH}" "${HARNESS}" --target-namespace gke-broken \
    --evidence-dir "${tmp_root}/gke-${backend_state}-${cert_state}" >/dev/null 2>&1 || true
  jq -e '.scenarios[] | select(.scenario == "networkpolicy-gke-backend-health") | .status == "FAIL"' \
    "${tmp_root}/gke-${backend_state}-${cert_state}/summary.json" >/dev/null ||
    fail "GKE health passed with backend=${backend_state} certificate=${cert_state}"
done
assert_not_contains "${command_log}" 'backendconfig'
pass "GKE health checks Ingress backends and ManagedCertificate, not BackendConfig"

: >"${command_log}"
if "${TEST_BASH}" "${HARNESS}" --apply --approval NOPE --chart ./umbrella \
  --evidence-dir "${tmp_root}/rejected" >/dev/null 2>&1; then
  fail "invalid apply approval was accepted"
fi
[[ ! -s "${command_log}" ]] || fail "commands ran before apply approval was rejected"
pass "apply requires literal APPLY approval"

: >"${command_log}"
apply_evidence="${tmp_root}/apply-evidence"
adapter="${tmp_root}/adapter"
hook="${tmp_root}/hook"
migration_values="${tmp_root}/migration-failure.yaml"
wrong_database_values="${tmp_root}/wrong-database.yaml"
: >"${migration_values}"
: >"${wrong_database_values}"
cat >"${adapter}" <<'MOCK'
#!/usr/bin/env bash
printf 'adapter %s\n' "$1" >>"${MOCK_COMMAND_LOG}"
exit 0
MOCK
cat >"${hook}" <<'MOCK'
#!/usr/bin/env bash
printf 'hook %s\n' "$1" >>"${MOCK_COMMAND_LOG}"
exit 0
MOCK
chmod +x "${adapter}" "${hook}"

# Wrong database: the app container started but never became ready.
cat >"${fixtures}/aw-conformance-test-wrong-db.pods.json" <<'JSON'
{"items":[{"metadata":{"name":"api-1"},"status":{"phase":"Running",
  "conditions":[{"type":"PodScheduled","status":"True"}],
  "containerStatuses":[{"name":"api","ready":false,"state":{"running":{}}}]}}]}
JSON
# Migration failure: the migration Job ended Failed=True.
cat >"${fixtures}/aw-conformance-test-migration.jobs.batch.json" <<'JSON'
{"items":[{"metadata":{"name":"relay-control-migrate-abc123"},
  "spec":{"template":{"metadata":{"labels":{"app.kubernetes.io/component":"migration"}}}},
  "status":{"failed":3,"conditions":[{"type":"Failed","status":"True"}]}}]}
JSON

if ! "${TEST_BASH}" "${HARNESS}" \
  --apply --approval APPLY --cleanup \
  --chart ./umbrella \
  --current-version 2.0.0 \
  --previous-version 1.0.0 \
  --namespace aw-conformance-test \
  --release aw-conformance-test \
  --migration-failure-values "${migration_values}" \
  --wrong-database-values "${wrong_database_values}" \
  --adapter "${adapter}" \
  --base-url https://conformance.example.test \
  --dns-name conformance.example.test \
  --db-outage-hook "${hook}" \
  --backup-hook "${hook}" \
  --restore-hook "${hook}" \
  --rollback-base-url https://rollback.example.test \
  --evidence-dir "${apply_evidence}" >/dev/null; then
  jq . "${apply_evidence}/summary.json" >&2
  fail "full mocked apply run failed"
fi

assert_contains "${command_log}" 'kubectl create namespace aw-conformance-test'
assert_contains "${command_log}" 'helm upgrade --install aw-conformance-test'
assert_contains "${command_log}" '--hide-secret'
assert_contains "${command_log}" 'kubectl delete namespace aw-conformance-test'
if rg 'helm upgrade --install' "${command_log}" | rg -v -- '--dry-run' | rg -qv -- '--wait-for-jobs'; then
  fail "an apply-mode install did not wait for Jobs"
fi
jq -e '
  .success == true
  and .mode == "apply"
  and (.scenarios | length == 19)
  and (.counts.pass == 19)
  and (.counts.fail == 0)
  and (.counts.skip == 0)
  and (.counts.plan == 0)
' "${apply_evidence}/summary.json" >/dev/null
pass "approved apply mode exercises all scenarios with isolated mocks"
assert_contains "${command_log}" 'helm rollback aw-conformance-test-migration'
if rg 'upgrade --install aw-conformance-test-(wrong-db|migration) .*(wrong-database|migration-failure)\.yaml' \
  "${command_log}" | rg -q -- '--atomic'; then
  fail "negative scenarios must keep failed resources for inspection"
fi

# Negative scenarios must not PASS when the failure has an unrelated cause.
: >"${command_log}"
cat >"${fixtures}/aw-neg-wrong-db.pods.json" <<'JSON'
{"items":[{"metadata":{"name":"api-1"},"status":{"phase":"Pending",
  "containerStatuses":[{"name":"api","ready":false,
    "state":{"waiting":{"reason":"ImagePullBackOff"}}}]}}]}
JSON
# No migration Job failed: the upgrade failed for another reason.
cat >"${fixtures}/aw-neg-migration.jobs.batch.json" <<'JSON'
{"items":[{"metadata":{"name":"relay-control-migrate-abc123"},
  "status":{"succeeded":1,"conditions":[{"type":"Complete","status":"True"}]}}]}
JSON
negative_evidence="${tmp_root}/negative-evidence"
"${TEST_BASH}" "${HARNESS}" --apply --approval APPLY \
  --chart ./umbrella --current-version 2.0.0 --previous-version 1.0.0 \
  --namespace aw-neg --release aw-neg \
  --migration-failure-values "${migration_values}" \
  --wrong-database-values "${wrong_database_values}" \
  --evidence-dir "${negative_evidence}" >/dev/null 2>&1 || true
jq -e '
  [.scenarios[] | select(.scenario == "wrong-database" or .scenario == "migration-failure") | .status]
  == ["FAIL", "FAIL"]
' "${negative_evidence}/summary.json" >/dev/null ||
  fail "negative scenarios passed without a fixture-specific failure signal"
pass "negative scenarios assert the specific expected failure"

: >"${command_log}"
baseline_evidence="${tmp_root}/no-baseline-evidence"
# A fresh install that fails (the mock rejects this values file) gives no
# baseline, so the wrong-database scenario cannot attribute a failure.
"${TEST_BASH}" "${HARNESS}" --apply --approval APPLY \
  --chart ./umbrella --namespace aw-nobase --release aw-nobase \
  --values "${wrong_database_values}" \
  --wrong-database-values "${wrong_database_values}" \
  --evidence-dir "${baseline_evidence}" >/dev/null 2>&1 || true
jq -e '.scenarios[] | select(.scenario == "wrong-database") | .status == "SKIP"' \
  "${baseline_evidence}/summary.json" >/dev/null ||
  fail "wrong-database ran without a passing baseline install"
pass "wrong-database requires a passing baseline install"

: >"${command_log}"
set +e
(
  # shellcheck source=../lib.sh
  source "${LIB}"
  MODE=audit
  safe_kubectl get secrets --namespace production --output=yaml
) >/dev/null 2>&1
secret_rc=$?
set -e
[[ "${secret_rc}" -eq 96 ]] || fail "Secret read was not rejected with safety code"
[[ ! -s "${command_log}" ]] || fail "blocked Secret read reached kubectl"
pass "Kubernetes Secret reads are blocked before execution"

: >"${command_log}"
set +e
(
  # shellcheck source=../lib.sh
  source "${LIB}"
  MODE=apply
  safe_helm upgrade release ./chart
) >/dev/null 2>&1
helm_rc=$?
set -e
[[ "${helm_rc}" -eq 96 ]] || fail "Helm output without --hide-secret was not rejected"
[[ ! -s "${command_log}" ]] || fail "unsafe Helm command reached helm"
pass "Helm install/upgrade requires Secret redaction"

: >"${command_log}"
if "${TEST_BASH}" "${HARNESS}" --apply --approval APPLY --chart ./umbrella \
  --target-namespace production --adapter "${adapter}" \
  --evidence-dir "${tmp_root}/target-rejected" >/dev/null 2>&1; then
  fail "apply mode accepted --target-namespace"
fi
if CONFORMANCE_TARGET_RELEASE=agentworkforce "${TEST_BASH}" "${HARNESS}" \
  --apply --approval APPLY --chart ./umbrella \
  --evidence-dir "${tmp_root}/target-release-rejected" >/dev/null 2>&1; then
  fail "apply mode accepted CONFORMANCE_TARGET_RELEASE"
fi
[[ ! -s "${command_log}" ]] || fail "commands ran before target override was rejected"
pass "apply mode rejects existing-release targets"

: >"${command_log}"
no_chart_evidence="${tmp_root}/apply-no-chart"
"${TEST_BASH}" "${HARNESS}" --apply --approval APPLY \
  --namespace aw-conformance-nochart --release aw-conformance-nochart \
  --adapter "${adapter}" --db-outage-hook "${hook}" \
  --backup-hook "${hook}" --restore-hook "${hook}" \
  --evidence-dir "${no_chart_evidence}" >/dev/null 2>&1 || true
assert_not_contains "${command_log}" 'rollout restart'
assert_not_contains "${command_log}" '^hook '
assert_not_contains "${command_log}" '^adapter '
jq -e '
  [.scenarios[] | select(.scenario == "db-outage-readiness"
    or .scenario == "restart-outbox-recovery"
    or .scenario == "two-agent-ping-reply"
    or .scenario == "backup"
    or .scenario == "networkpolicy-gke-backend-health") | .status]
  | length == 5 and all(. == "SKIP")
' "${no_chart_evidence}/summary.json" >/dev/null ||
  fail "mutating scenarios ran without an isolated fresh install"
pass "mutating scenarios require the isolated fresh install"

: >"${command_log}"
failing_begin_hook="${tmp_root}/failing-begin-hook"
cat >"${failing_begin_hook}" <<'MOCK'
#!/usr/bin/env bash
printf 'hook %s\n' "$1" >>"${MOCK_COMMAND_LOG}"
[[ "$1" != "begin" ]]
MOCK
chmod +x "${failing_begin_hook}"
"${TEST_BASH}" "${HARNESS}" --apply --approval APPLY --chart ./umbrella \
  --namespace aw-outage --release aw-outage \
  --db-outage-hook "${failing_begin_hook}" \
  --evidence-dir "${tmp_root}/outage-begin-fails" >/dev/null 2>&1 || true
assert_contains "${command_log}" '^hook begin'
assert_contains "${command_log}" '^hook end'
jq -e '.scenarios[] | select(.scenario == "db-outage-readiness") | .status == "FAIL"' \
  "${tmp_root}/outage-begin-fails/summary.json" >/dev/null ||
  fail "failed outage begin was not reported"
pass "database outage end runs even when begin fails"

# The full apply run above used the default DB-dependent selector.
: >"${command_log}"
"${TEST_BASH}" "${HARNESS}" --apply --approval APPLY --chart ./umbrella \
  --namespace aw-select --release aw-select --db-outage-hook "${hook}" \
  --evidence-dir "${tmp_root}/outage-select" >/dev/null 2>&1 || true
assert_contains "${command_log}" 'Ready=false pod .*instance=aw-select\\?,app.kubernetes.io/component\\? in\\? \\\(api\\?,history\\\)\\?,\\?!job-name'
assert_contains "${command_log}" 'condition=Ready pod .*\\?,\\?!job-name'
: >"${command_log}"
"${TEST_BASH}" "${HARNESS}" --apply --approval APPLY --chart ./umbrella \
  --namespace aw-select --release aw-select --db-outage-hook "${hook}" \
  --db-dependent-selector 'app.kubernetes.io/name=relay-control' \
  --evidence-dir "${tmp_root}/outage-select-custom" >/dev/null 2>&1 || true
assert_contains "${command_log}" 'Ready=false pod .*name=relay-control\\?,\\?!job-name'
pass "DB outage waits only on PostgreSQL-dependent, non-Job pods"

# expect_wrapper RC MODE COMMAND... runs a wrapper in an isolated subshell
# under TEST_BASH and asserts both the exit code and that a blocked command
# never reached the mocked binary.
expect_wrapper() {
  local expected_rc="$1"
  local mode="$2"
  shift 2
  local rc
  : >"${command_log}"
  set +e
  MODE="${mode}" "${TEST_BASH}" -c 'set -u; source "$1"; shift; "$@"' \
    wrapper "${LIB}" "$@" >/dev/null 2>&1
  rc=$?
  set -e
  [[ "${rc}" -eq "${expected_rc}" ]] ||
    fail "expected rc ${expected_rc} for MODE=${mode} $*, got ${rc}"
  if [[ "${expected_rc}" -ne 0 && -s "${command_log}" ]]; then
    fail "blocked command reached the binary: $*"
  fi
  if [[ "${expected_rc}" -eq 0 && ! -s "${command_log}" ]]; then
    fail "allowed command did not run: $*"
  fi
}

# Global option values must not be mistaken for the verb.
expect_wrapper 97 audit safe_kubectl -n foo delete pod x
expect_wrapper 97 audit safe_kubectl --namespace foo delete pod x
expect_wrapper 97 audit safe_kubectl --context prod -n foo rollout restart deployment
expect_wrapper 96 audit safe_kubectl -n get get secrets
expect_wrapper 96 audit safe_kubectl --namespace=foo get secret/x
expect_wrapper 0 audit safe_kubectl -n foo get pods
expect_wrapper 0 audit safe_kubectl --context prod rollout status deployment
expect_wrapper 98 audit safe_kubectl --unknown-flag foo delete pod x
expect_wrapper 98 audit safe_kubectl -n
expect_wrapper 97 audit safe_helm --namespace foo uninstall rel
expect_wrapper 96 audit safe_helm -n foo get values rel
expect_wrapper 96 audit safe_helm --kube-context prod template rel ./chart
expect_wrapper 98 audit safe_helm --bogus x list
expect_wrapper 0 audit safe_helm -n foo list --output json
pass "wrappers skip global options before choosing the verb"

# Unlisted verbs are denied (default deny), including in apply mode.
expect_wrapper 97 audit safe_kubectl autoscale deploy x --max=3
expect_wrapper 97 audit safe_kubectl debug pod/x
expect_wrapper 97 apply safe_kubectl debug pod/x
expect_wrapper 97 apply safe_kubectl port-forward svc/x 8080:80
expect_wrapper 97 apply safe_kubectl proxy
expect_wrapper 97 apply safe_kubectl certificate approve csr-1
expect_wrapper 97 audit safe_kubectl exec --dry-run=client pod/x -- true
expect_wrapper 0 audit safe_kubectl create namespace x --dry-run=client
expect_wrapper 0 apply safe_kubectl autoscale deploy x --max=3
expect_wrapper 97 apply safe_helm plugin install x
expect_wrapper 97 audit safe_helm rollback rel 1
pass "wrappers default-deny unknown or mutating verbs in audit mode"

printf 'All conformance harness tests passed.\n'
