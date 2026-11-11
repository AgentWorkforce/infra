#!/usr/bin/env bash
# Offline tests for scripts/selfhost/agent-relay-upgrade.sh. gh, git, helm,
# kubectl, aws and crane are mocked; nothing contacts GitHub, AWS or a cluster.
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SELFHOST_DIR="$(cd -- "${TEST_DIR}/.." && pwd)"
SCRIPT="${SELFHOST_DIR}/agent-relay-upgrade.sh"
TEST_BASH="${TEST_BASH:-bash}"
command -v jq >/dev/null && command -v yq >/dev/null || { echo "skip - jq and yq are required"; exit 0; }

root="$(mktemp -d)"; trap 'rm -rf "$root"' EXIT
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

COMMIT=0123456789abcdef0123456789abcdef01234567
D1="sha256:$(printf 'a%.0s' {1..64})"; D2="sha256:$(printf 'b%.0s' {1..64})"

make_release() { # $1 dir, $2 manifest-variant
  local d=$1; mkdir -p "$d"
  case "${2:-ok}" in
    ok) imgs="[{\"name\":\"relay-control\",\"ref\":\"ghcr.io/agentworkforce/relay-control@$D1\"},{\"name\":\"relay-webapp\",\"ref\":\"ghcr.io/agentworkforce/relay-webapp@$D2\"}]" ;;
    unpinned) imgs='[{"name":"relay-control","ref":"ghcr.io/agentworkforce/relay-control:latest"}]' ;;
  esac
  printf '{"schema":1,"version":"2026.11.1","infraCommit":"%s","chart":{"path":"charts/agent-relay","version":"0.6.31"},"valuesOverlay":"release-images.values.yaml","images":%s}\n' "$COMMIT" "$imgs" > "$d/release-manifest.json"
  printf 'relayControl:\n  image: { repository: __IMAGE_REPO_PREFIX__/relay-control, digest: "%s" }\n' "$D1" > "$d/release-images.values.yaml"
  ( cd "$d" && sha release-manifest.json release-images.values.yaml > SHA256SUMS )
}

setup_mocks() { # $1 release fixture dir, $2 attestation result (ok|fail)
  local bin="$root/bin"; rm -rf "$bin"; mkdir -p "$bin"; : > "$root/log"
  cat > "$bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$root/log"
case "\$1 \$2" in
  "release download") while [ \$# -gt 0 ]; do [ "\$1" = -D ] && { mkdir -p "\$2"; cp "$1"/* "\$2"/; }; shift; done ;;
  "attestation verify") [ "$2" = ok ] ;;
esac
EOF
  cat > "$bin/git" <<EOF
#!/usr/bin/env bash
echo "git \$*" >> "$root/log"
if [ "\$1" = clone ]; then mkdir -p "\${@: -1}"; exit 0; fi
if [ "\$3" = worktree ] && [ "\$4" = add ]; then
  t="\${@: -2:1}"; mkdir -p "\$t/charts/agent-relay" "\$t/scripts/selfhost"
  : > "\$t/charts/agent-relay/values-eks.yaml"; : > "\$t/charts/agent-relay/values-eks-native.yaml"
  cp "$SELFHOST_DIR/mirror-images-to-ecr.sh" "\$t/scripts/selfhost/"
fi
exit 0
EOF
  cat > "$bin/helm" <<EOF
#!/usr/bin/env bash
echo "helm \$*" >> "$root/log"
case "\$*" in
  *template*) echo "image: 111111111111.dkr.ecr.us-east-1.amazonaws.com/agent-relay/ghcr.io/agentworkforce/relay-control@$D1" ;;
  *history*) echo '[{"revision":7}]' ;;
esac
exit 0
EOF
  cat > "$bin/kubectl" <<EOF
#!/usr/bin/env bash
echo "kubectl \$*" >> "$root/log"
case "\$*" in *jsonpath*) echo "old/relay-control@sha256:old" ;; *"-o json"*) echo '{"items":[]}' ;; esac
exit 0
EOF
  printf '#!/usr/bin/env bash\necho "aws $*" >> "%s/log"\nexit 0\n' "$root" > "$bin/aws"
  # crane: report the pinned digest for any ref, so the mirror's digest check passes
  printf '#!/usr/bin/env bash\necho "crane $*" >> "%s/log"\nfor a in "$@"; do case "$a" in *@sha256:*) [ "$1" = digest ] && { echo "${a##*@}"; exit 0; };; *:sha256-*) [ "$1" = digest ] && { d=${a##*:sha256-}; echo "sha256:$d"; exit 0; };; esac; done\nexit 0\n' "$root" > "$bin/crane"
  chmod +x "$bin"/*
}

run() { PATH="$root/bin:$PATH" "$TEST_BASH" "$SCRIPT" "$@"; }
vals="$root/values.yaml"; : > "$vals"
args=(--version 2026.11.1 --registry 111111111111.dkr.ecr.us-east-1.amazonaws.com --values "$vals")

# 1. plan-only verifies, mirrors in plan mode and changes nothing
make_release "$root/rel-ok" ok; setup_mocks "$root/rel-ok" ok
out=$(run "${args[@]}" 2>&1) || fail "plan mode failed: $out"
grep -q 'Plan only' <<<"$out" || fail "plan mode did not stop at the plan"
grep -q 'no image changes' <<<"$out" && fail "plan printed both changes and no changes"
grep -q '^aws ' "$root/log" && fail "plan mode called aws"
grep -q '^crane ' "$root/log" && fail "plan mode copied images"
grep -q 'helm .*upgrade' "$root/log" && fail "plan mode ran helm upgrade"
grep -q 'attestation verify' "$root/log" || fail "attestation not verified"
pass "plan-only verifies the release and changes nothing"

# 2. a tampered manifest fails the checksum
make_release "$root/rel-bad" ok; echo ' ' >> "$root/rel-bad/release-manifest.json"; setup_mocks "$root/rel-bad" ok
run "${args[@]}" >/dev/null 2>&1 && fail "tampered manifest was accepted"
pass "checksum mismatch refuses"

# 3. a failed attestation refuses
setup_mocks "$root/rel-ok" fail
run "${args[@]}" >/dev/null 2>&1 && fail "failed attestation was accepted"
pass "failed attestation refuses"

# 4. an unpinned image refuses
make_release "$root/rel-unpinned" unpinned; setup_mocks "$root/rel-unpinned" ok
run "${args[@]}" >/dev/null 2>&1 && fail "unpinned image was accepted"
pass "unpinned image refuses"

# 5. --apply without --db-instance refuses before contacting anything
setup_mocks "$root/rel-ok" ok
run "${args[@]}" --apply >/dev/null 2>&1 && fail "apply without a snapshot target was accepted"
[ -s "$root/log" ] && fail "apply without --db-instance contacted tools"
pass "--apply requires --db-instance"

# 6. --apply snapshots before upgrading, then upgrades with the overlay last
setup_mocks "$root/rel-ok" ok
out=$(run "${args[@]}" --apply --db-instance prod-db --yes 2>&1) || fail "apply failed: $out"
snap=$(grep -n 'aws rds create-db-snapshot' "$root/log" | cut -d: -f1); up=$(grep -n 'helm .*upgrade' "$root/log" | cut -d: -f1)
[ -n "$snap" ] && [ -n "$up" ] && [ "$snap" -lt "$up" ] || fail "snapshot must precede helm upgrade"
grep 'helm .*upgrade' "$root/log" | grep -q 'release-images.values.yaml' || fail "upgrade did not use the release overlay"
pass "apply snapshots first, then upgrades with the release overlay"
