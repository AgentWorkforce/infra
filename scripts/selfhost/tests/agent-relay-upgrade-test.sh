#!/usr/bin/env bash
# Offline tests for scripts/selfhost/agent-relay-upgrade.sh. gh, helm,
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
REG=111111111111.dkr.ecr.us-east-1.amazonaws.com
D1="sha256:$(printf 'a%.0s' {1..64})"; D2="sha256:$(printf 'b%.0s' {1..64})"

# $1 dir, $2 variant: ok | unpinned | swapped | chartver
make_release() {
  local d=$1 v=${2:-ok} cv=0.6.31 o1=$D1 o2=$D2 imgs; rm -rf "$d"; mkdir -p "$d/pkg/agent-relay"
  imgs="[{\"name\":\"relay-control\",\"ref\":\"ghcr.io/agentworkforce/relay-control@$D1\"},{\"name\":\"relay-webapp\",\"ref\":\"ghcr.io/agentworkforce/relay-webapp@$D2\"}]"
  if [ "$v" = unpinned ]; then imgs='[{"name":"relay-control","ref":"ghcr.io/agentworkforce/relay-control:latest"}]'; fi
  if [ "$v" = swapped ]; then o1=$D2; o2=$D1; fi
  printf '{"schema":1,"version":"2026.11.1","infraCommit":"%s","chart":{"path":"charts/agent-relay","version":"%s"},"valuesOverlay":"release-images.values.yaml","valuesOverlayProfile":"eks","images":%s}\n' "$COMMIT" "$cv" "$imgs" > "$d/release-manifest.json"
  printf 'relayControl:\n  image: { repository: __IMAGE_MIRROR_ROOT__/ghcr.io/agentworkforce/relay-control, digest: "%s" }\nrelayWebapp:\n  image: { repository: __IMAGE_MIRROR_ROOT__/ghcr.io/agentworkforce/relay-webapp, digest: "%s" }\n' "$o1" "$o2" > "$d/release-images.values.yaml"
  if [ "$v" = chartver ]; then cv=9.9.9; fi
  printf 'name: agent-relay\nversion: "%s"\n' "$cv" > "$d/pkg/agent-relay/Chart.yaml"
  : > "$d/pkg/agent-relay/values-eks.yaml"; : > "$d/pkg/agent-relay/values-eks-native.yaml"
  tar -czf "$d/agent-relay-0.6.31.tgz" -C "$d/pkg" agent-relay; rm -rf "$d/pkg"
  ( cd "$d" && sha release-manifest.json release-images.values.yaml agent-relay-0.6.31.tgz > SHA256SUMS )
}

# helm mock: template renders "<repository>@<digest>" for each image in the release overlay.
# $1: extra case arm for upgrade (e.g. "exit 1")
write_helm() {
  cat > "$root/bin/helm" <<EOF
#!/usr/bin/env bash
echo "helm \$*" >> "$root/log"
case "\$*" in
  *template*) for a in "\$@"; do case "\$a" in *release-images.values.yaml) ov=\$a;; esac; done
    yq -r '.[] | .image | "---\nimage: " + .repository + "@" + .digest' "\$ov" ;;
  *history*) echo '[{"revision":6,"status":"superseded"},{"revision":7,"status":"deployed"},{"revision":8,"status":"failed"}]' ;;
  *upgrade*) ${1:-exit 0} ;;
esac
exit 0
EOF
  chmod +x "$root/bin/helm"
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
  write_helm
}

run() { PATH="$root/bin:$PATH" "$TEST_BASH" "$SCRIPT" "$@"; }
vals="$root/values.yaml"; : > "$vals"
args=(--version 2026.11.1 --registry "$REG" --profile eks-native --values "$vals")

# 1. plan-only verifies, mirrors in plan mode and changes nothing
make_release "$root/rel-ok" ok; setup_mocks "$root/rel-ok" ok
out=$(run "${args[@]}" 2>&1) || fail "plan mode failed: $out"
grep -q 'Plan only' <<<"$out" || fail "plan mode did not stop at the plan"
grep -q 'no image changes' <<<"$out" && fail "plan printed both changes and no changes"
grep -q '^aws ' "$root/log" && fail "plan mode called aws"
grep -q '^crane ' "$root/log" && fail "plan mode copied images"
grep -q 'helm .*upgrade' "$root/log" && fail "plan mode ran helm upgrade"
grep -q 'attestation verify .*SHA256SUMS' "$root/log" || fail "SHA256SUMS attestation not verified"
grep 'helm .*template' "$root/log" | grep -q 'values-eks-native.yaml' || fail "eks-native profile not applied"
pass "plan-only verifies the release and changes nothing"

# 2. --profile is required and selects only that profile's files
setup_mocks "$root/rel-ok" ok
run --version 2026.11.1 --registry "$REG" --values "$vals" >/dev/null 2>&1 && fail "missing --profile was accepted"
out=$(run --version 2026.11.1 --registry "$REG" --profile eks --values "$vals" 2>&1) || fail "eks profile failed: $out"
grep 'helm .*template' "$root/log" | grep -q 'values-eks-native.yaml' && fail "eks profile loaded the native overlay"
pass "--profile is required and is never switched"

# 3. an overlay for a different cloud profile refuses before rendering
make_release "$root/rel-wrong-profile" ok
jq '.valuesOverlayProfile = "gcp"' "$root/rel-wrong-profile/release-manifest.json" \
  > "$root/rel-wrong-profile/manifest.tmp"
mv "$root/rel-wrong-profile/manifest.tmp" "$root/rel-wrong-profile/release-manifest.json"
( cd "$root/rel-wrong-profile" && sha release-manifest.json release-images.values.yaml agent-relay-0.6.31.tgz > SHA256SUMS )
setup_mocks "$root/rel-wrong-profile" ok
out=$(run "${args[@]}" 2>&1) && fail "wrong-profile overlay was accepted"
grep -q 'not for the selected profile' <<<"$out" || fail "wrong-profile overlay refused for the wrong reason: $out"
pass "release overlay profile must match the selected install profile"

# 4. a tampered manifest fails the checksum
make_release "$root/rel-bad" ok; echo ' ' >> "$root/rel-bad/release-manifest.json"; setup_mocks "$root/rel-bad" ok
run "${args[@]}" >/dev/null 2>&1 && fail "tampered manifest was accepted"
pass "checksum mismatch refuses"

# 5. a failed attestation refuses
setup_mocks "$root/rel-ok" fail
run "${args[@]}" >/dev/null 2>&1 && fail "failed attestation was accepted"
pass "failed attestation refuses"

# 6. an unpinned image refuses
make_release "$root/rel-unpinned" unpinned; setup_mocks "$root/rel-unpinned" ok
run "${args[@]}" >/dev/null 2>&1 && fail "unpinned image was accepted"
pass "unpinned image refuses"

# 7. a packaged chart whose version differs from the release refuses
make_release "$root/rel-chartver" chartver; setup_mocks "$root/rel-chartver" ok
run "${args[@]}" >/dev/null 2>&1 && fail "mismatched chart version was accepted"
pass "chart version mismatch refuses"

# 8. an overlay that swaps digests between images refuses
make_release "$root/rel-swap" swapped; setup_mocks "$root/rel-swap" ok
out=$(run "${args[@]}" 2>&1) && fail "swapped digests were accepted"
grep -q 'not this release' <<<"$out" || fail "swapped digests refused for the wrong reason: $out"
pass "overlay with swapped image digests refuses"

# 9. --apply without --db-instance refuses before contacting anything
setup_mocks "$root/rel-ok" ok
run "${args[@]}" --apply >/dev/null 2>&1 && fail "apply without a snapshot target was accepted"
[ -s "$root/log" ] && fail "apply without --db-instance contacted tools"
pass "--apply requires --db-instance"

# 10. --apply snapshots first, upgrades with the overlay, scopes checks to the release
setup_mocks "$root/rel-ok" ok
out=$(run "${args[@]}" --apply --db-instance prod-db --yes 2>&1) || fail "apply failed: $out"
snap=$(grep -n 'aws rds create-db-snapshot' "$root/log" | cut -d: -f1); up=$(grep -n 'helm .*upgrade' "$root/log" | cut -d: -f1)
[ -n "$snap" ] && [ -n "$up" ] && [ "$snap" -lt "$up" ] || fail "snapshot must precede helm upgrade"
grep 'helm .*upgrade' "$root/log" | grep -q 'release-images.values.yaml' || fail "upgrade did not use the release overlay"
grep 'kubectl .*get jobs' "$root/log" | grep -q 'app.kubernetes.io/instance=agent-relay' || fail "job check not scoped to the release"
pass "apply snapshots first, upgrades with the overlay, checks only this release"

# 11. a failed upgrade prints the last DEPLOYED revision, not the latest one
setup_mocks "$root/rel-ok" ok; write_helm "exit 1"
out=$(run "${args[@]}" --apply --db-instance prod-db --yes 2>&1) && fail "failed upgrade reported success"
grep -q 'rollback agent-relay 7' <<<"$out" || fail "rollback did not point at the last deployed revision: $out"
pass "failed upgrade prints rollback to the last deployed revision"
