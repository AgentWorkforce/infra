#!/usr/bin/env bash
# Offline tests for how configure-rds.sh picks the chart: the published OCI chart
# is pulled at the release's chart version (from release-manifest.json), with no
# checkout and no dependency build, and HELM_EXTRA_VALUES names resolve inside it.
# curl, helm and kubectl are mocked; the run stops at the namespace check, before
# anything would change.
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd -- "${TEST_DIR}/.." && pwd)/configure-rds.sh"
TEST_BASH="${TEST_BASH:-bash}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }

bin="$tmp/bin"; log="$tmp/commands.log"
mkdir -p "$bin" "$tmp/work"
: >"$log"

cat >"$bin/curl" <<'MOCK'
#!/usr/bin/env bash
url="" out="" prev=""
for a in "$@"; do [[ "$a" == http* ]] && url="$a"; [[ "$prev" == -o ]] && out="$a"; prev="$a"; done
printf 'curl %s\n' "$url" >>"$MOCK_LOG"
[[ -n "$out" ]] && exec >"$out"
case "$url" in
  */releases/agent-relay-*/pins.json)
    printf '{"pins":{"sessions-pipeline":{"repository":"ghcr.io/agentworkforce/sessions-pipeline","digest":"sha256:%s"}}}\n' \
      1111111111111111111111111111111111111111111111111111111111111111 ;;
  */scripts/selfhost/rds-setup.sh) cat "$MOCK_RDS_SETUP" ;;
  */scripts/selfhost/rds-session-erase-search.sql) echo 'select 1;' ;;
  */releases/download/agent-relay-2026.11.19/release-manifest.json) printf '{"chart":{"path":"charts/agent-relay","version":"0.7.81"}}\n' ;;
  */charts/agent-relay/Chart.yaml) printf 'name: agent-relay\nversion: 0.7.81\n' ;;
  *) echo "curl: (22) 404 $url" >&2; exit 22 ;;
esac
MOCK
# helm pull <ref> --version V --untar --untardir DIR writes a chart with the
# bundled EKS values files (and MOCK_PULLED_VERSION as its version, if set).
cat >"$bin/helm" <<'MOCK'
#!/usr/bin/env bash
printf 'helm %s\n' "$*" >>"$MOCK_LOG"
if [[ "${MOCK_EXEC:-0}" == 1 && "$1" != pull && "$1" != repo && "$1" != dependency ]]; then
  if grep -q "$MOCK_TOKEN" "${KUBECONFIG:-/nonexistent}" 2>/dev/null; then echo 'auth token helm' >>"$MOCK_LOG"; else echo 'auth exec helm' >>"$MOCK_LOG"; fi
fi
[[ "$1" == pull ]] || exit 0
ref="$2" version="" dir=""
shift 2
while [[ $# -gt 0 ]]; do
  case "$1" in --version) version="$2"; shift 2 ;; --untardir) dir="$2"; shift 2 ;; *) shift ;; esac
done
chart="$dir/${ref##*/}"
mkdir -p "$chart/charts"
printf 'apiVersion: v2\nname: %s\nversion: %s\n' "${ref##*/}" "${MOCK_PULLED_VERSION:-$version}" >"$chart/Chart.yaml"
: >"$chart/values-eks.yaml"; : >"$chart/values-eks-native.yaml"
MOCK
cat >"$bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$MOCK_LOG"
if [[ "${MOCK_EXEC:-0}" == 1 && "$*" != *"config "* ]]; then
  if grep -q "$MOCK_TOKEN" "${KUBECONFIG:-/nonexistent}" 2>/dev/null; then echo 'auth token kubectl' >>"$MOCK_LOG"; else echo 'auth exec kubectl' >>"$MOCK_LOG"; fi
fi
case "$*" in
  "config current-context") echo test-ctx ;;
  *"create namespace"*) exit 0 ;;
  *"get namespace"*) [[ "${MOCK_NS_OK:-0}" == 1 ]] && exit 0
    [[ "${MOCK_NS_MISSING:-0}" == 1 ]] && { echo 'Error from server (NotFound): namespaces "agent-relay" not found' >&2; exit 1; }
    echo "Error from server (Forbidden)" >&2; exit 1 ;;
  *"get serviceaccounts default"*) echo '{"kind":"ServiceAccount"}' ;;
  *"config view --minify"*) [[ "${MOCK_EXEC:-0}" == 1 ]] && { printf '{"clusters":[{"name":"arn:aws:eks:us-west-2:123456789012:cluster/demo","cluster":{"server":"https://127.0.0.1:1"}}],"contexts":[{"name":"test-ctx","context":{"cluster":"arn:aws:eks:us-west-2:123456789012:cluster/demo","user":"u"}}],"current-context":"test-ctx","users":[{"name":"u","user":{"exec":{"apiVersion":"client.authentication.k8s.io/v1beta1","command":"%s","args":["eks","get-token","--cluster-name","demo","--region","us-west-2"]}}}]}\n' "$(dirname "$0")/fake-get-token"; exit 0; }
    [[ "${MOCK_EKS:-0}" == 1 ]] && echo '{"clusters":[{"name":"arn:aws:eks:us-west-2:123456789012:cluster/demo"}],"users":[]}' ;;
  *"get secret agent-relay-secrets -o json") [[ "${MOCK_SECRET_OK:-0}" == 1 ]] && echo '{"kind":"Secret"}' || exit 1 ;;
  *"get secret "*) exit 1 ;;
  *"create -f - -o name"*) cat >/dev/null; echo job.batch/probe ;;
  *"get job "*"-o json"*) echo '{"status":{"succeeded":1,"conditions":[{"type":"Complete","status":"True"}]}}' ;;
  *"logs job/agent-relay-diagnose-os-"*) printf 'AR\tOS\t%s\nAR\tDONE\n' "${MOCK_OS_RESULT:-}" ;;
  *"get deployments"*) none='{"items":[]}'; echo "${MOCK_DEPLOYMENTS:-$none}" ;;
  *"get statefulsets"*|*"get cronjobs"*|*"get persistentvolumeclaims"*) echo '{"items":[]}' ;;
  *"get pods"*) echo '{"items":[]}' ;;
  *"get jobs "*) echo '{"items":[{"metadata":{"name":"agent-relay-worker-migrate-1","creationTimestamp":"2026-11-26T00:00:00Z"}}]}' ;;
esac
MOCK
# A slow exec credential plugin (aws eks get-token behind a slow credential_process).
cat >"$bin/fake-get-token" <<'MOCK'
#!/usr/bin/env bash
echo 'exec-plugin run' >>"$MOCK_LOG"
sleep "${MOCK_PLUGIN_DELAY:-2}"
# MOCK_PLUGIN_FAIL_AFTER=N: the (N+1)th run fails, like a credential_process that stops working.
if [[ -n "${MOCK_PLUGIN_FAIL_AFTER:-}" ]] && (( $(grep -c '^exec-plugin run' "$MOCK_LOG") > MOCK_PLUGIN_FAIL_AFTER )); then
  echo 'exec-plugin failed' >>"$MOCK_LOG"; exit 1
fi
printf '{"kind":"ExecCredential","apiVersion":"client.authentication.k8s.io/v1beta1","status":{"token":"%s","expirationTimestamp":"%s"}}\n' "$MOCK_TOKEN" "${MOCK_TOKEN_EXPIRES:-2099-01-01T00:00:00Z}"
MOCK
chmod +x "$bin/fake-get-token"
# The pinned rds-setup.sh, as the stub the mocked download serves: pre writes
# one credential file and the HoopDb layout overlay.
cat >"$tmp/rds-setup-stub.sh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == pre ]]; then
  mkdir -p "$STATE_DIR/secret-files/agent-relay-secrets"
  printf 'postgresql://u:p@db/x?sslmode=verify-full' >"$STATE_DIR/secret-files/agent-relay-secrets/database-url"
  # The layout overlay exactly as rds-setup.sh pre writes it.
  printf '%s\n' 'sessions-pipeline:' '  worker:' '    migrations:' '      hoopdb:' '        existingSecret: agent-relay-secrets' \
    '        key: HOOPDB_MIGRATION_URL' '      rdsLayout: separate-database' '  searchIndexer:' '    bootstrap:' \
    '      existingSecret: search-indexer-owner' '      key: RELAYHISTORY_PIPELINE_CONSUMER_SECRET' >"$STATE_DIR/hoopdb-layout-values.yaml"
fi
STUB
# sha256sum: report the pinned checksum, so the stub passes as the pinned script.
printf '#!/usr/bin/env bash\nprintf "%%s  %%s\\n" %s "$1"\n' "$(sed -n 's/^RDS_SETUP_SHA256=\([0-9a-f]*\).*/\1/p' "$SCRIPT")" >"$bin/sha256sum"
# aws: Secrets Manager calls succeed; EKS Pod Identity answers from MOCK_ASSOCIATIONS
# (a JSON list of ServiceAccounts) or MOCK_AWS_ERROR, and records creates.
cat >"$bin/aws" <<'MOCK'
#!/usr/bin/env bash
printf 'aws %s\n' "$*" >>"$MOCK_LOG"
case "$*" in
  *"eks list-pod-identity-associations"*)
    [[ -n "${MOCK_AWS_ERROR:-}" ]] && { echo "$MOCK_AWS_ERROR" >&2; exit 253; }
    python3 -c 'import json,os;print(json.dumps({"associations":[{"serviceAccount":s,"associationId":"a-"+str(i).zfill(10),"namespace":"agent-relay"} for i,s in enumerate(json.loads(os.environ.get("MOCK_ASSOCIATIONS","[]")))]}))' ;;
  *"eks describe-pod-identity-association"*) echo '{"association":{"roleArn":"arn:aws:iam::123456789012:role/sessions"}}' ;;
  *"eks create-pod-identity-association"*) echo '{"association":{"associationId":"a-new0000000"}}' ;;
  *"iam simulate-principal-policy"*)
    acts=(); on=0; for a in "$@"; do [[ "$a" == --resource-arns ]] && on=0; [[ "$on" == 1 ]] && acts+=("$a"); [[ "$a" == --action-names ]] && on=1; done
    python3 -c 'import json,sys;print(json.dumps({"EvaluationResults":[{"EvalActionName":a,"EvalDecision":"allowed"} for a in sys.argv[1:]]}))' "${acts[@]}" ;;
esac
exit 0
MOCK
# configure-rds.sh generates the application keys with openssl rand -hex 32.
printf '#!/usr/bin/env bash\n[[ "$1 $2" == "rand -hex" ]] && { printf %%0*d "$(( $3 * 2 ))" 0; echo; }\nexit 0\n' >"$bin/openssl"
chmod +x "$bin"/*
reset_values() { cp "$tmp/values.orig" "$tmp/work/values.yaml"; rm -f "$tmp/work"/values.yaml.bak-*; }
cat >"$tmp/values.orig" <<'EOF'
services-image: { repository: ghcr.io/agentworkforce/sessions-pipeline, digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000" }
relay-control:
  bootstrap:
    adminEmail: owner@corp.test
EOF
cp "$tmp/values.orig" "$tmp/work/values.yaml"

run() { # run configure-rds.sh from $tmp/work with extra env; output in $tmp/out
  : >"$log"
  (cd "$tmp/work" && env PATH="$bin:$PATH" MOCK_LOG="$log" MOCK_RDS_SETUP="$tmp/rds-setup-stub.sh" RDS_HOST=db.abc.us-west-2.rds.amazonaws.com \
    KUBE_CONTEXT=test-ctx STATE_DIR="$tmp/state" "$@" "$TEST_BASH" "$SCRIPT" </dev/null) >"$tmp/out" 2>&1
}
expect_out() { grep -qF -- "$1" "$tmp/out" || { cat "$tmp/out" >&2; fail "$2: output lacks: $1"; }; }

# 1. OCI chart: pulled at the release's chart version, bundled values resolved,
#    reaches the namespace check (the first step that needs the cluster).
if run RELEASE_VERSION=2026.11.19 HELM_CHART=oci://ghcr.io/agentworkforce/charts/agent-relay \
       HELM_EXTRA_VALUES="values-eks.yaml charts/agent-relay/values-eks-native.yaml"; then
  fail "oci: expected to stop at the namespace check"
fi
expect_out "chart: agent-relay 0.7.81 (release 2026.11.19), pulled from the OCI registry" "oci"
expect_out "cannot reach namespace agent-relay" "oci"
grep -qE '^helm pull oci://ghcr.io/agentworkforce/charts/agent-relay --version 0\.7\.81 --untar --untardir ' "$log" \
  || fail "oci: helm pull did not pin --version 0.7.81"
grep -q 'releases/download/agent-relay-2026.11.19/release-manifest.json' "$log" || fail "oci: release manifest not read"
grep -q '^helm dependency' "$log" && fail "oci: ran helm dependency build"
pass "OCI chart is pulled at the release manifest's chart version; bundled values files resolve"

# 2. A HELM_CHART_VERSION that disagrees with the release stops before any pull.
if run RELEASE_VERSION=2026.11.19 HELM_CHART=oci://ghcr.io/agentworkforce/charts/agent-relay HELM_CHART_VERSION=0.7.80; then
  fail "version mismatch: expected failure"
fi
expect_out "HELM_CHART_VERSION is 0.7.80 but release 2026.11.19 ships chart 0.7.81" "version mismatch"
grep -q '^helm pull' "$log" && fail "version mismatch: pulled anyway"
pass "HELM_CHART_VERSION must match the release"

# 3. A tag in the OCI ref is refused: RELEASE_VERSION picks the version.
if run RELEASE_VERSION=2026.11.19 HELM_CHART=oci://ghcr.io/agentworkforce/charts/agent-relay:0.7.80; then
  fail "tagged ref: expected failure"
fi
expect_out "set HELM_CHART without a tag or digest" "tagged ref"
pass "a tagged OCI ref is refused"

# 4. A release with no published manifest stops with the URL it tried.
if run RELEASE_VERSION=2099.1.1 HELM_CHART=oci://ghcr.io/agentworkforce/charts/agent-relay; then
  fail "no manifest: expected failure"
fi
expect_out "could not read the chart version of release 2099.1.1" "no manifest"
pass "a release without release-manifest.json is refused"

# 5. A values file that is neither local nor in the chart stops before the
#    release pins rewrite values.yaml (the pins above would change its digest).
reset_values
if run RELEASE_VERSION=2026.11.19 HELM_CHART=oci://ghcr.io/agentworkforce/charts/agent-relay HELM_EXTRA_VALUES=values-ekss.yaml; then
  fail "missing values: expected failure"
fi
expect_out "values file values-ekss.yaml not found (here or in the chart)" "missing values"
cmp -s "$tmp/work/values.yaml" "$tmp/values.orig" || fail "missing values: values.yaml was rewritten"
compgen -G "$tmp/work/values.yaml.bak-*" >/dev/null && fail "missing values: a pin backup was made"
pass "a missing HELM_EXTRA_VALUES file is refused before values.yaml is touched"

# 6. A pulled chart whose Chart.yaml disagrees is refused.
if run RELEASE_VERSION=2026.11.19 HELM_CHART=oci://ghcr.io/agentworkforce/charts/agent-relay MOCK_PULLED_VERSION=0.7.79; then
  fail "pulled mismatch: expected failure"
fi
expect_out "pulled chart is version 0.7.79, expected 0.7.81" "pulled mismatch"
pass "the pulled chart's own version is checked"

# 7. A local chart directory of another version still points at the OCI chart or the tag.
mkdir -p "$tmp/work/charts/agent-relay"; printf 'name: agent-relay\nversion: 0.7.70\n' >"$tmp/work/charts/agent-relay/Chart.yaml"
if run RELEASE_VERSION=2026.11.19 HELM_CHART=charts/agent-relay; then fail "local mismatch: expected failure"; fi
expect_out "install from oci://ghcr.io/agentworkforce/charts/agent-relay, or in your infra clone run" "local mismatch"
pass "a local chart of the wrong version names both fixes"

# 8. --help prints the whole header, through the last environment variable.
"$TEST_BASH" "$SCRIPT" --help >"$tmp/out"
expect_out "ADMIN_EMAIL" "help"; expect_out "HELM_CHART_VERSION" "help"
grep -q '^set -euo' "$tmp/out" && fail "help: printed code"
pass "--help prints the full header"

# 9. Through step 5: helm upgrade gets the pulled chart, the bundled values files
#    in order, then values.yaml, which now holds the HoopDb layout and first admin
#    (no hidden overlay a later plain upgrade would drop); no dependency build.
reset_values
run RELEASE_VERSION=2026.11.19 HELM_CHART=oci://ghcr.io/agentworkforce/charts/agent-relay MOCK_NS_OK=1 \
    RDS_ADMIN_SECRET_ARN=arn:aws:secretsmanager:us-west-2:111122223333:secret:x \
    HELM_EXTRA_VALUES="values-eks.yaml charts/agent-relay/values-eks-native.yaml" || true
expect_out "==> Result" "step 5: the run did not reach the verdict"
upgrade="$(grep '^helm .*upgrade --install' "$log")" || { cat "$tmp/out" >&2; fail "step 5: no helm upgrade"; }
chart="$(sed -nE 's/^helm pull .* --untardir ([^ ]+).*/\1/p' "$log")/agent-relay"
want="upgrade --install agent-relay $chart -n agent-relay -f $chart/values-eks.yaml -f $chart/values-eks-native.yaml -f values.yaml"
[[ "$upgrade" == *"$want" ]] || fail "step 5: helm got: $upgrade"
[[ "$upgrade" != *hoopdb-layout-values* && "$upgrade" != *--set* ]] || fail "step 5: a hidden overlay is still passed: $upgrade"
for want_line in '      rdsLayout: separate-database' '        key: HOOPDB_MIGRATION_URL' '      existingSecret: search-indexer-owner' 'adminEmail: "owner@corp.test"'; do
  grep -qF -- "$want_line" "$tmp/work/values.yaml" || { cat "$tmp/work/values.yaml" >&2; fail "step 5: values.yaml lacks: $want_line"; }
done
grep -q '^helm dependency' "$log" && fail "step 5: ran helm dependency build"
grep -q 'sha256:1111111111111111111111111111111111111111111111111111111111111111' "$tmp/work/values.yaml" || fail "step 5: pins not applied"
[[ ! -e "$chart" ]] || fail "step 5: the pulled chart was not cleaned up"
pass "helm upgrade installs the pulled chart with its bundled values files in order, the layout written into values.yaml, no dependency build"

# A release's workloads, as kubectl get deployments returns them: the worker
# (S3) and the search indexer (S3 + OpenSearch, SigV4).
DEPLOYMENTS='{"items":[
 {"metadata":{"name":"agent-relay-worker-session-summary-worker"},"spec":{"template":{"spec":{"serviceAccountName":"agent-relay-worker","containers":[{"name":"w","image":"img@sha256:'"$(printf 1%.0s {1..64})"'","env":[{"name":"LOCKER_BUCKET","value":"acme-sessions"}]}]}}}},
 {"metadata":{"name":"agent-relay-search-indexer"},"spec":{"template":{"spec":{"serviceAccountName":"agent-relay-search-indexer","containers":[{"name":"s","image":"img@sha256:'"$(printf 1%.0s {1..64})"'","env":[{"name":"LOCKER_BUCKET","value":"acme-sessions"},{"name":"SEARCH_INDEX_OPENSEARCH_AUTH","value":"sigv4"},{"name":"SEARCH_INDEX_OPENSEARCH_URL","value":"https://vpc-relay-search-abcdefghijklmnopqrstuvwxyz.us-west-2.es.amazonaws.com"},{"name":"SEARCH_INDEX_OPENSEARCH_AWS_REGION","value":"us-west-2"}]}]}}}}]}'
pi_run() { reset_values; run RELEASE_VERSION=2026.11.19 HELM_CHART=oci://ghcr.io/agentworkforce/charts/agent-relay MOCK_NS_OK=1 \
  MOCK_SECRET_OK=1 MOCK_EKS=1 MOCK_DEPLOYMENTS="$DEPLOYMENTS" RDS_ADMIN_SECRET_ARN=arn:aws:secretsmanager:us-west-2:111122223333:secret:x \
  HELM_EXTRA_VALUES="values-eks.yaml values-eks-native.yaml" "$@"; }

# 10. A missing association stops the run before anything changes (no Secrets
#     Manager write, no rds-setup.sh, no helm), with the exact create line.
if pi_run MOCK_ASSOCIATIONS='["agent-relay-search-indexer"]'; then fail "missing association: the run went on"; fi
expect_out "Pod Identity associations are missing (before any change). Nothing has been changed yet." "missing association"
expect_out "aws eks create-pod-identity-association --cluster-name demo --region us-west-2 --namespace agent-relay --service-account agent-relay-worker" "missing association"
! grep -qE '^aws secretsmanager|^helm .*upgrade' "$log" || fail "missing association: something changed before the stop"
! grep -q '1/8' "$tmp/out" || fail "missing association: reached step 1"
pass "a missing Pod Identity association stops the run before any change, with the exact create line"

# 11. POD_IDENTITY_ROLES creates it (opt-in) and the run goes on.
pi_run MOCK_ASSOCIATIONS='["agent-relay-search-indexer"]' POD_IDENTITY_ROLES="agent-relay-worker=arn:aws:iam::123456789012:role/sessions" || true
grep -q '^aws eks create-pod-identity-association .*--service-account agent-relay-worker --role-arn arn:aws:iam::123456789012:role/sessions' "$log" \
  || { cat "$tmp/out" >&2; fail "POD_IDENTITY_ROLES: no create call"; }
expect_out "created the Pod Identity association for agent-relay-worker" "POD_IDENTITY_ROLES"
expect_out "==> 1/8" "POD_IDENTITY_ROLES: the run did not go on"
pass "POD_IDENTITY_ROLES creates the missing association and the run goes on"

# 12. No AWS credentials: UNKNOWN with the manual command, the run goes on;
#     POD_IDENTITY_STRICT=1 stops it.
pi_run MOCK_AWS_ERROR='Unable to locate credentials.' || true
expect_out "Pod Identity: could not be checked (before any change)" "no credentials"
expect_out "==> 1/8" "no credentials: the run did not go on"
if pi_run MOCK_AWS_ERROR='Unable to locate credentials.' POD_IDENTITY_STRICT=1; then fail "POD_IDENTITY_STRICT: went on"; fi
expect_out "POD_IDENTITY_STRICT=1" "POD_IDENTITY_STRICT"
pass "unverifiable Pod Identity is reported and only stops the run with POD_IDENTITY_STRICT=1"

# 13-15. The final table classifies the in-cluster OpenSearch probe, and the run
#        exits non-zero unless every row passes.
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
ALL='["agent-relay-worker","agent-relay-search-indexer"]'
if pi_run MOCK_ASSOCIATIONS="$ALL" MOCK_OS_RESULT="$(b64 '{"kind":"http","status":403,"body":"{\"error\":{\"type\":\"security_exception\",\"reason\":\"no permissions for [cluster:monitor/health]\"}}","who":{"user":"arn:aws:sts::123456789012:assumed-role/sessions/x"}}')"; then
  fail "FGAC 403: exit 0"; fi
grep -E '^    OpenSearch auth +FAIL +.*fine-grained access control' "$tmp/out" >/dev/null || { cat "$tmp/out" >&2; fail "FGAC 403: no table row"; }
expect_out 'PUT _plugins/_security/api/rolesmapping/relayhistory_indexer {"backend_roles":["arn:aws:iam::123456789012:role/sessions"]}' "FGAC 403"
pass "an FGAC 403 is a FAIL row with the exact rolesmapping body, and a non-zero exit"
if pi_run MOCK_ASSOCIATIONS="$ALL" MOCK_OS_RESULT="$(b64 '{"kind":"network","detail":"ENOTFOUND"}')"; then fail "unreachable: exit 0"; fi
grep -E '^    OpenSearch auth +FAIL +.*unreachable from the cluster \(ENOTFOUND\)' "$tmp/out" >/dev/null || { cat "$tmp/out" >&2; fail "unreachable: no table row"; }
pass "an unreachable OpenSearch is a FAIL row"
pi_run MOCK_ASSOCIATIONS="$ALL" MOCK_OS_RESULT="$(b64 '{"kind":"http","status":200,"body":"{}"}')" || true
grep -E '^    OpenSearch auth +PASS ' "$tmp/out" >/dev/null || { cat "$tmp/out" >&2; fail "success: no PASS row"; }
grep -E '^    Pod Identity +PASS ' "$tmp/out" >/dev/null || { cat "$tmp/out" >&2; fail "success: Pod Identity not PASS"; }
pass "a signed request that OpenSearch accepts is a PASS row"

# 16. A fresh install: the cluster answers but the namespace doesn't exist yet.
reset_values
run RELEASE_VERSION=2026.11.19 HELM_CHART=oci://ghcr.io/agentworkforce/charts/agent-relay MOCK_NS_MISSING=1 MOCK_SECRET_OK=1 \
  RDS_ADMIN_SECRET_ARN=arn:aws:secretsmanager:us-west-2:111122223333:secret:x HELM_EXTRA_VALUES="values-eks.yaml values-eks-native.yaml" || true
grep -q '^kubectl --context test-ctx create namespace agent-relay' "$log" || { cat "$tmp/out" >&2; fail "fresh namespace: not created"; }
expect_out "created namespace agent-relay" "fresh namespace"
pass "a fresh install creates the namespace instead of stopping"

# 17. Partial POD_IDENTITY_ROLES: what was created is restarted before the stop,
#     and the message says what changed.
if pi_run MOCK_ASSOCIATIONS='[]' POD_IDENTITY_ROLES="agent-relay-search-indexer=arn:aws:iam::123456789012:role/indexer"; then fail "partial roles: went on"; fi
grep -q 'rollout restart deployment/agent-relay-search-indexer' "$log" || { cat "$tmp/out" >&2; fail "partial roles: created association's pods not restarted"; }
expect_out "Only Pod Identity associations have been created so far: agent-relay-search-indexer." "partial roles"
! grep -q "Nothing has been changed yet" "$tmp/out" || fail "partial roles: claims nothing changed after creating an association"
pass "a partial POD_IDENTITY_ROLES restarts what it created, then stops naming it"

# 18. A restart that failed is retried on the next run (kept in STATE_DIR) and
#     fails the table until it succeeds.
mkdir -p "$tmp/state"; printf ' agent-relay-worker-session-summary-worker\n' >"$tmp/state/pending-pod-identity-restarts"
pi_run MOCK_ASSOCIATIONS='["agent-relay-worker","agent-relay-search-indexer"]' MOCK_OS_RESULT="$(b64 '{"kind":"http","status":200,"body":"{}"}')" || true
grep -q 'rollout restart deployment/agent-relay-worker-session-summary-worker' "$log" || { cat "$tmp/out" >&2; fail "pending restart: not retried"; }
[[ ! -e "$tmp/state/pending-pod-identity-restarts" ]] || fail "pending restart: not cleared after it succeeded"
pass "a pending restart from an earlier run is retried and cleared once it succeeds"


# 19. An exec credential plugin runs once for the script's own kubectl/helm calls
#     (each diagnostic run fetches its own): every call uses the cached token,
#     and the token is never printed.
pi_run MOCK_EXEC=1 MOCK_TOKEN=k8s-aws-v1.SECRET-TOKEN-VALUE MOCK_ASSOCIATIONS="$ALL" \
  MOCK_OS_RESULT="$(b64 '{"kind":"http","status":200,"body":"{}"}')" || true
# Only the long waits (rollout status, helm test) keep the exec plugin.
short_exec="$(grep -B1 '^auth exec' "$log" | grep -E '^(kubectl|helm) ' | grep -vE 'rollout status| test ' || true)"
[[ -z "$short_exec" ]] || { printf '%s\n' "$short_exec" >&2; fail "token cache: a short kubectl/helm call ran the exec plugin"; }
grep -q '^auth token helm' "$log" || fail "token cache: helm did not use the cached token"
grep -q '^auth token kubectl' "$log" || fail "token cache: kubectl did not use the cached token"
! grep -q 'SECRET-TOKEN-VALUE' "$tmp/out" || fail "token cache: the token was printed"
! grep -q 'SECRET-TOKEN-VALUE' "$log" || fail "token cache: the token reached a command line"
expect_out "using one cached cluster token for kubectl and helm (exec credential plugin)" "token cache"
runs=$(grep -c '^exec-plugin run' "$log"); calls=$(grep -c '^auth token' "$log")
(( runs < calls / 4 )) || fail "token cache: $runs plugin runs for $calls calls"
grep -A1 -E '^kubectl .*rollout status|^helm .* test ' "$log" | grep -q '^auth token' && fail "token cache: a long wait (rollout status / helm test) used the cached token"
pass "an exec credential plugin runs once per process, not once per kubectl call ($runs runs, $calls calls), and the token is never printed"

# 20. A refresh that fails (here inside a $(...) subshell, with a token that is
#     always due) falls back to kubectl's own auth for every later call: no call
#     keeps using the stale cached token.
pi_run MOCK_EXEC=1 MOCK_TOKEN=k8s-aws-v1.SECRET-TOKEN-VALUE MOCK_PLUGIN_DELAY=0 MOCK_PLUGIN_FAIL_AFTER=1 \
  MOCK_TOKEN_EXPIRES=2000-01-01T00:00:00Z MOCK_ASSOCIATIONS="$ALL" MOCK_OS_RESULT="$(b64 '{"kind":"http","status":200,"body":"{}"}')" || true
grep -q '^exec-plugin failed' "$log" || fail "refresh failure: the plugin never failed"
first_fail=$(grep -n '^exec-plugin failed' "$log" | head -n1 | cut -d: -f1)
! tail -n +"$first_fail" "$log" | grep -q '^auth token' || { tail -n +"$first_fail" "$log" | grep -n '^auth token' -B1 | head >&2; fail "refresh failure: a later call still used the cached token"; }
tail -n +"$first_fail" "$log" | grep -q '^auth exec' || fail "refresh failure: no later call ran"
pass "a failed token refresh falls back to kubectl's own auth for every later call"
