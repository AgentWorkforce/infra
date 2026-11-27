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
case "$*" in
  "config current-context") echo test-ctx ;;
  *"get namespace"*) [[ "${MOCK_NS_OK:-0}" == 1 ]] || { echo "Error from server (Forbidden)" >&2; exit 1; } ;;
  *"get secret "*) exit 1 ;;
  *"get job "*"-o json"*) echo '{"status":{"conditions":[{"type":"Complete","status":"True"}]}}' ;;
  *"get jobs "*) echo '{"items":[{"metadata":{"name":"agent-relay-worker-migrate-1","creationTimestamp":"2026-11-26T00:00:00Z"}}]}' ;;
esac
MOCK
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
printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/aws"
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
    HELM_EXTRA_VALUES="values-eks.yaml charts/agent-relay/values-eks-native.yaml" || { cat "$tmp/out" >&2; fail "step 5: run failed"; }
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
