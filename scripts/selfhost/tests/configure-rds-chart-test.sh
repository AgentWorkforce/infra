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
url="${*: -1}"
printf 'curl %s\n' "$url" >>"$MOCK_LOG"
case "$url" in
  */releases/agent-relay-*/pins.json) printf '{"pins":{}}\n' ;;
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
  *"get namespace"*) echo "Error from server (Forbidden)" >&2; exit 1 ;;
esac
MOCK
for t in aws openssl; do printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/$t"; done
chmod +x "$bin"/*
cat >"$tmp/work/values.yaml" <<'EOF'
services-image: { repository: ghcr.io/agentworkforce/sessions-pipeline, digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000" }
relay-control:
  bootstrap:
    adminEmail: owner@corp.test
EOF

run() { # run configure-rds.sh from $tmp/work with extra env; output in $tmp/out
  : >"$log"
  (cd "$tmp/work" && env PATH="$bin:$PATH" MOCK_LOG="$log" RDS_HOST=db.abc.us-west-2.rds.amazonaws.com \
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

# 5. A values file that is neither local nor in the chart stops early.
if run RELEASE_VERSION=2026.11.19 HELM_CHART=oci://ghcr.io/agentworkforce/charts/agent-relay HELM_EXTRA_VALUES=values-ekss.yaml; then
  fail "missing values: expected failure"
fi
expect_out "values file values-ekss.yaml not found (here or in the chart)" "missing values"
pass "a missing HELM_EXTRA_VALUES file is refused before anything changes"

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
