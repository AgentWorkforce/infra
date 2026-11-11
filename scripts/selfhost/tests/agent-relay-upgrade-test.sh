#!/usr/bin/env bash
# Offline tests for scripts/selfhost/agent-relay-upgrade.sh. gh, helm,
# kubectl, aws, crane and rds-setup.sh are mocked; nothing contacts GitHub,
# AWS or a cluster.
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SELFHOST_DIR="$(cd -- "${TEST_DIR}/.." && pwd)"
TEST_BASH="${TEST_BASH:-bash}"
command -v jq >/dev/null && command -v yq >/dev/null || { echo "skip - jq and yq are required"; exit 0; }

root="$(mktemp -d)"; trap 'rm -rf "$root"' EXIT
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
line_of() { grep -n -- "$1" "$root/log" | head -1 | cut -d: -f1; }
before() { # $1 pattern, $2 pattern: both logged, $1 first
  local a b; a=$(line_of "$1"); b=$(line_of "$2")
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

# The upgrader runs from a copy so rds-setup.sh next to it is the mock below.
SCRIPT="$root/selfhost/agent-relay-upgrade.sh"
mkdir -p "$root/selfhost"
cp "$SELFHOST_DIR/agent-relay-upgrade.sh" "$SELFHOST_DIR/mirror-images-to-ecr.sh" "$root/selfhost/"
cat > "$root/selfhost/rds-setup.sh" <<EOF
#!/usr/bin/env bash
echo "rds-setup \$1 NAMESPACE=\${NAMESPACE:-} RELEASE=\${RELEASE:-} MIGRATION_JOB=\${MIGRATION_JOB:-} SERVICES_IMAGE=\${SERVICES_IMAGE:-} PSQL_IMAGE=\${PSQL_IMAGE:-} STATE_DIR=\${STATE_DIR:-}" >> "$root/log"
if [ "\$1" = refresh-admin ]; then
  printf 'postgresql://admin:rotated-admin-pw@db/hoopdb' > "\$STATE_DIR/secret-files/agent-relay-secrets/HOOPDB_MIGRATION_URL"
  printf '{"hoopdb_url":"postgresql://admin:rotated-admin-pw@db/hoopdb"}' > "\$STATE_DIR/secret-files/search-indexer-owner/RELAYHISTORY_PIPELINE_CONSUMER_SECRET"
fi
EOF
chmod +x "$root/selfhost/"*.sh

COMMIT=0123456789abcdef0123456789abcdef01234567
REG=111111111111.dkr.ecr.us-east-1.amazonaws.com
D1="sha256:$(printf 'a%.0s' {1..64})"; D2="sha256:$(printf 'b%.0s' {1..64})"
D3="sha256:$(printf 'c%.0s' {1..64})"; D4="sha256:$(printf 'd%.0s' {1..64})"
SIGNER=AgentWorkforce/infra/.github/workflows/release-agent-relay.yml

# $1 dir, $2 variant: ok | unpinned | swapped | chartver | no-rds-native
make_release() {
  local d=$1 v=${2:-ok} cv=0.6.31 o1=$D1 o2=$D2 imgs; rm -rf "$d"; mkdir -p "$d/pkg/agent-relay"
  imgs="[{\"name\":\"relay-control\",\"ref\":\"ghcr.io/agentworkforce/relay-control@$D1\"},{\"name\":\"relay-webapp\",\"ref\":\"ghcr.io/agentworkforce/relay-webapp@$D2\"},{\"name\":\"sessions-pipeline\",\"ref\":\"ghcr.io/agentworkforce/sessions-pipeline@$D3\"},{\"name\":\"sessions-migration-postgresql\",\"ref\":\"ghcr.io/cloudnative-pg/postgresql@$D4\"}]"
  if [ "$v" = unpinned ]; then imgs='[{"name":"relay-control","ref":"ghcr.io/agentworkforce/relay-control:latest"}]'; fi
  if [ "$v" = swapped ]; then o1=$D2; o2=$D1; fi
  printf '{"schema":1,"version":"2026.11.1","infraCommit":"%s","chart":{"path":"charts/agent-relay","version":"%s"},"valuesOverlay":"release-images.values.yaml","valuesOverlayProfile":"eks","images":%s}\n' "$COMMIT" "$cv" "$imgs" > "$d/release-manifest.json"
  printf 'relayControl:\n  image: { repository: __IMAGE_MIRROR_ROOT__/ghcr.io/agentworkforce/relay-control, digest: "%s" }\nrelayWebapp:\n  image: { repository: __IMAGE_MIRROR_ROOT__/ghcr.io/agentworkforce/relay-webapp, digest: "%s" }\n' "$o1" "$o2" > "$d/release-images.values.yaml"
  if [ "$v" = chartver ]; then cv=9.9.9; fi
  printf 'name: agent-relay\nversion: "%s"\n' "$cv" > "$d/pkg/agent-relay/Chart.yaml"
  : > "$d/pkg/agent-relay/values-eks.yaml"; : > "$d/pkg/agent-relay/values-eks-native.yaml"
  if [ "$v" != no-rds-native ]; then : > "$d/pkg/agent-relay/values-eks-rds-native.yaml"; fi
  tar -czf "$d/agent-relay-0.6.31.tgz" -C "$d/pkg" agent-relay; rm -rf "$d/pkg"
  ( cd "$d" && sha release-manifest.json release-images.values.yaml agent-relay-0.6.31.tgz > SHA256SUMS )
}

# helm mock: template renders "<repository>@<digest>" for each image in the
# release overlay, plus $root/rendered-extra.yaml; "get manifest" prints
# $root/live-manifest.yaml; "list" reports the release while $root/exists exists.
# $1: upgrade result (e.g. "exit 1"), $2: install result
write_helm() {
  cat > "$root/bin/helm" <<EOF
#!/usr/bin/env bash
echo "helm \$*" >> "$root/log"
case "\$*" in
  *template*) for a in "\$@"; do case "\$a" in *release-images.values.yaml) ov=\$a;; esac; done
    yq -r '.[] | .image | "---\nimage: " + .repository + "@" + .digest' "\$ov"
    if [ -f "$root/rendered-extra.yaml" ]; then echo ---; cat "$root/rendered-extra.yaml"; fi ;;
  *" list "*) if [ -f "$root/exists" ]; then echo '[{"name":"agent-relay","status":"deployed"}]'; else echo '[]'; fi ;;
  *"get manifest"*) cat "$root/live-manifest.yaml" 2>/dev/null || true ;;
  *"get hooks"*) ;;
  *history*) echo '[{"revision":6,"status":"superseded"},{"revision":7,"status":"deployed"},{"revision":8,"status":"failed"}]' ;;
  *" upgrade "*) ${1:-exit 0} ;;
  *" install "*) ${2:-exit 0} ;;
esac
exit 0
EOF
  chmod +x "$root/bin/helm"
}

setup_mocks() { # $1 release fixture dir, $2 attestation result (ok|fail)
  local bin="$root/bin"; rm -rf "$bin"; mkdir -p "$bin"; : > "$root/log"
  rm -f "$root/rendered-extra.yaml" "$root/live-manifest.yaml" "$root/patches"; touch "$root/exists"
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
case "\$*" in
  *jsonpath*) echo "old/relay-control@sha256:old" ;;
  *"-o json"*) echo '{"items":[]}' ;;
  *"get deploy -l"*"-o name"*) echo deployment.apps/agent-relay-read-api ;;
  *"patch secret"*) for a in "\$@"; do case "\$a" in */patch.json) cat "\$a" >> "$root/patches"; echo >> "$root/patches";; esac; done ;;
esac
exit 0
EOF
  printf '#!/usr/bin/env bash\necho "aws $*" >> "%s/log"\nexit 0\n' "$root" > "$bin/aws"
  # crane: report the pinned digest for any ref, so the mirror's digest check passes
  printf '#!/usr/bin/env bash\necho "crane $*" >> "%s/log"\nfor a in "$@"; do case "$a" in *@sha256:*) [ "$1" = digest ] && { echo "${a##*@}"; exit 0; };; *:sha256-*) [ "$1" = digest ] && { d=${a##*:sha256-}; echo "sha256:$d"; exit 0; };; esac; done\nexit 0\n' "$root" > "$bin/crane"
  chmod +x "$bin"/*
  write_helm
}

# rds-setup.sh state as "pre" leaves it, plus the environment it reads.
make_state() {
  rm -rf "$root/state"; mkdir -p "$root/state/passwords" "$root/state/secret-files/agent-relay-secrets" \
    "$root/state/secret-files/search-indexer-owner"
  for p in bulls96_read_api bulls96_session_ingest search_consumer_runtime; do printf x > "$root/state/passwords/$p"; done
}
rds_env=(AWS_REGION=us-east-1 RDS_HOST=db.example.internal RDS_ADMIN_SECRET_ARN=arn:aws:secretsmanager:us-east-1:111111111111:secret:rds STATE_DIR="$root/state")

run() { PATH="$root/bin:$PATH" "$TEST_BASH" "$SCRIPT" "$@"; }
run_rds() { env "${rds_env[@]}" PATH="$root/bin:$PATH" "$TEST_BASH" "$SCRIPT" "$@"; }
vals="$root/values.yaml"; : > "$vals"
args=(--version 2026.11.1 --registry "$REG" --profile eks-native --values "$vals")
migrate_job='kind: Job
metadata:
  name: agent-relay-worker-migrate-0a1b2c3d
  labels: { app.kubernetes.io/component: hoopdb-migrate }'

# 1. plan-only verifies, mirrors in plan mode and changes nothing
make_release "$root/rel-ok" ok; setup_mocks "$root/rel-ok" ok
out=$(run "${args[@]}" 2>&1) || fail "plan mode failed: $out"
grep -q 'Plan only' <<<"$out" || fail "plan mode did not stop at the plan"
grep -q 'no image changes' <<<"$out" && fail "plan printed both changes and no changes"
grep -q '^aws ' "$root/log" && fail "plan mode called aws"
grep -q '^crane ' "$root/log" && fail "plan mode copied images"
grep -Eq 'helm .* (upgrade|install) ' "$root/log" && fail "plan mode ran helm upgrade/install"
grep -q 'attestation verify .*SHA256SUMS' "$root/log" || fail "SHA256SUMS attestation not verified"
grep 'helm .*template' "$root/log" | grep -q 'values-eks-native.yaml' || fail "eks-native profile not applied"
grep 'helm .*template' "$root/log" | grep -q -- '--is-upgrade' || fail "upgrade plan did not render as an upgrade"
pass "plan-only verifies the release and changes nothing"

# 2. every attestation is bound to the release workflow, the tag and a hosted runner
n=$(grep -c 'gh attestation verify' "$root/log")
[ "$n" = 3 ] || fail "expected 3 attestation verifications, got $n"
[ "$(grep 'gh attestation verify' "$root/log" | grep -- "--signer-workflow $SIGNER " \
  | grep -- '--source-ref refs/tags/agent-relay-2026.11.1 ' | grep -c -- '--deny-self-hosted-runners')" = 3 ] \
  || fail "attestation verification is not bound to signer workflow and tag: $(grep 'attestation' "$root/log")"
pass "attestations are bound to the release workflow and tag"

# 3. --profile is required and selects only that profile's files
setup_mocks "$root/rel-ok" ok
run --version 2026.11.1 --registry "$REG" --values "$vals" >/dev/null 2>&1 && fail "missing --profile was accepted"
run --version 2026.11.1 --registry "$REG" --profile gcp --values "$vals" >/dev/null 2>&1 && fail "unknown profile was accepted"
out=$(run --version 2026.11.1 --registry "$REG" --profile eks --values "$vals" 2>&1) || fail "eks profile failed: $out"
grep 'helm .*template' "$root/log" | grep -q 'values-eks-native.yaml' && fail "eks profile loaded the native overlay"
pass "--profile is required and is never switched"

# 4. eks-rds-native composes values-eks.yaml then values-eks-rds-native.yaml, then site values, then the overlay
setup_mocks "$root/rel-ok" ok
out=$(run --version 2026.11.1 --registry "$REG" --profile eks-rds-native --values "$vals" 2>&1) || fail "eks-rds-native plan failed: $out"
tmpl=$(grep 'helm .*template' "$root/log")
grep -q 'values-eks-native.yaml' <<<"$tmpl" && fail "eks-rds-native loaded values-eks-native.yaml"
files=$(tr ' ' '\n' <<<"$tmpl" | grep -E 'values-eks.yaml$|values-eks-rds-native.yaml$|/values.yaml$|release-images.values.yaml$' | sed 's#.*/##' | tr '\n' ' ')
[ "$files" = "values-eks.yaml values-eks-rds-native.yaml values.yaml release-images.values.yaml " ] \
  || fail "eks-rds-native file order wrong: $files"
pass "eks-rds-native layers values-eks.yaml + values-eks-rds-native.yaml, site values, overlay last"

# 5. a release whose chart lacks values-eks-rds-native.yaml refuses eks-rds-native before rendering
make_release "$root/rel-old" no-rds-native; setup_mocks "$root/rel-old" ok
out=$(run --version 2026.11.1 --registry "$REG" --profile eks-rds-native --values "$vals" 2>&1) && fail "missing profile file was accepted"
grep -q 'does not ship values-eks-rds-native.yaml' <<<"$out" || fail "missing profile file refused for the wrong reason: $out"
grep -q 'helm .*template' "$root/log" && fail "rendered without the profile file"
out=$(run "${args[@]}" 2>&1) || fail "eks-native failed on a release without the rds-native file: $out"
pass "eks-rds-native refuses a release chart that does not ship its values file"

# 6. an overlay for a different cloud profile refuses before rendering
make_release "$root/rel-wrong-profile" ok
jq '.valuesOverlayProfile = "gcp"' "$root/rel-wrong-profile/release-manifest.json" \
  > "$root/rel-wrong-profile/manifest.tmp"
mv "$root/rel-wrong-profile/manifest.tmp" "$root/rel-wrong-profile/release-manifest.json"
( cd "$root/rel-wrong-profile" && sha release-manifest.json release-images.values.yaml agent-relay-0.6.31.tgz > SHA256SUMS )
setup_mocks "$root/rel-wrong-profile" ok
out=$(run "${args[@]}" 2>&1) && fail "wrong-profile overlay was accepted"
grep -q 'not for the selected profile' <<<"$out" || fail "wrong-profile overlay refused for the wrong reason: $out"
pass "release overlay profile must match the selected install profile"

# 7. a tampered manifest fails the checksum
make_release "$root/rel-bad" ok; echo ' ' >> "$root/rel-bad/release-manifest.json"; setup_mocks "$root/rel-bad" ok
run "${args[@]}" >/dev/null 2>&1 && fail "tampered manifest was accepted"
pass "checksum mismatch refuses"

# 8. a failed attestation refuses
setup_mocks "$root/rel-ok" fail
run "${args[@]}" >/dev/null 2>&1 && fail "failed attestation was accepted"
pass "failed attestation refuses"

# 9. an unpinned image refuses
make_release "$root/rel-unpinned" unpinned; setup_mocks "$root/rel-unpinned" ok
run "${args[@]}" >/dev/null 2>&1 && fail "unpinned image was accepted"
pass "unpinned image refuses"

# 10. a packaged chart whose version differs from the release refuses
make_release "$root/rel-chartver" chartver; setup_mocks "$root/rel-chartver" ok
run "${args[@]}" >/dev/null 2>&1 && fail "mismatched chart version was accepted"
pass "chart version mismatch refuses"

# 11. an overlay that swaps digests between images refuses
make_release "$root/rel-swap" swapped; setup_mocks "$root/rel-swap" ok
out=$(run "${args[@]}" 2>&1) && fail "swapped digests were accepted"
grep -q 'not this release' <<<"$out" || fail "swapped digests refused for the wrong reason: $out"
pass "overlay with swapped image digests refuses"

# 12. --apply without --db-instance refuses before contacting anything
setup_mocks "$root/rel-ok" ok
run "${args[@]}" --apply >/dev/null 2>&1 && fail "apply without a snapshot target was accepted"
[ -s "$root/log" ] && fail "apply without --db-instance contacted tools"
pass "--apply requires --db-instance"

# 13. --apply snapshots first, upgrades with the overlay, scopes checks to the release
setup_mocks "$root/rel-ok" ok
out=$(run "${args[@]}" --apply --db-instance prod-db --yes 2>&1) || fail "apply failed: $out"
before 'aws rds create-db-snapshot' 'helm .* upgrade ' || fail "snapshot must precede helm upgrade"
grep 'helm .* upgrade ' "$root/log" | grep -q 'release-images.values.yaml' || fail "upgrade did not use the release overlay"
grep 'helm .* upgrade ' "$root/log" | grep -q -- '--install' && fail "upgrade added --install"
grep -q 'helm .* install ' "$root/log" && fail "upgrade ran helm install"
grep -q '^rds-setup ' "$root/log" && fail "upgrade without --rds-setup ran rds-setup.sh"
grep 'kubectl .*get jobs' "$root/log" | grep -q 'app.kubernetes.io/instance=agent-relay' || fail "job check not scoped to the release"
pass "apply snapshots first, upgrades with the overlay, checks only this release"

# 14. a failed upgrade prints the last DEPLOYED revision, not the latest one
setup_mocks "$root/rel-ok" ok; write_helm "exit 1"
out=$(run "${args[@]}" --apply --db-instance prod-db --yes 2>&1) && fail "failed upgrade reported success"
grep -q 'rollback agent-relay 7' <<<"$out" || fail "rollback did not point at the last deployed revision: $out"
pass "failed upgrade prints rollback to the last deployed revision"

# 15. plain upgrade refuses a missing release; --first-install refuses an existing one
setup_mocks "$root/rel-ok" ok; rm -f "$root/exists"
out=$(run "${args[@]}" 2>&1) && fail "upgrade of a missing release was accepted"
grep -q 'use --first-install' <<<"$out" || fail "missing release refused for the wrong reason: $out"
setup_mocks "$root/rel-ok" ok
out=$(run "${args[@]}" --first-install --apply --db-instance prod-db --yes 2>&1) && fail "first install over an existing release was accepted"
grep -q 'already exists' <<<"$out" || fail "existing release refused for the wrong reason: $out"
grep -Eq '^aws |helm .* (upgrade|install) |^crane ' "$root/log" && fail "a refused mode changed something"
pass "first install and upgrade each refuse the other's release state"

# 16. first install (no --rds-setup): snapshot, helm install --no-hooks without --wait, migration wait
setup_mocks "$root/rel-ok" ok; rm -f "$root/exists"; printf '%s\n' "$migrate_job" > "$root/live-manifest.yaml"
out=$(run "${args[@]}" --first-install 2>&1) || fail "first-install plan failed: $out"
grep -q 'plan: changes=true' <<<"$out" || fail "first-install plan did not report changes"
grep 'helm .*template' "$root/log" | grep -q -- '--is-upgrade' && fail "first-install rendered as an upgrade"
setup_mocks "$root/rel-ok" ok; rm -f "$root/exists"; printf '%s\n' "$migrate_job" > "$root/live-manifest.yaml"
out=$(run "${args[@]}" --first-install --apply --db-instance prod-db --yes 2>&1) || fail "first install failed: $out"
inst=$(grep 'helm .* install ' "$root/log") || fail "first install did not run helm install"
grep -q -- '--no-hooks' <<<"$inst" || fail "first install lacks --no-hooks"
grep -q -- '--wait' <<<"$inst" && fail "first install waited on Deployments before the migration barrier"
grep -q 'release-images.values.yaml' <<<"$inst" || fail "first install did not use the release overlay"
grep -q 'helm .* upgrade ' "$root/log" && fail "first install ran helm upgrade"
before 'aws rds create-db-snapshot' 'helm .* install ' || fail "snapshot must precede helm install"
before 'helm .* install ' 'kubectl .*wait --for=condition=complete job/agent-relay-worker-migrate-0a1b2c3d' \
  || fail "migration wait must follow helm install"
grep -q '^rds-setup ' "$root/log" && fail "first install without --rds-setup ran rds-setup.sh"
grep -q 'Installed agent-relay at 2026.11.1' <<<"$out" || fail "first install did not report success"
pass "first install: snapshot, helm install --no-hooks, then the migration wait"

# 17. first install with --rds-setup: install -> migration wait -> post -> restart -> rollout status
make_state; setup_mocks "$root/rel-ok" ok; rm -f "$root/exists"; printf '%s\n' "$migrate_job" > "$root/live-manifest.yaml"
out=$(run_rds "${args[@]}" --rds-setup --first-install --apply --db-instance prod-db --yes 2>&1) || fail "rds first install failed: $out"
before 'helm .* install ' 'kubectl .*wait --for=condition=complete' || fail "install must precede the migration wait"
before 'kubectl .*wait --for=condition=complete' '^rds-setup post' || fail "post must follow the migration wait"
before '^rds-setup post' 'kubectl .*rollout restart' || fail "restart must follow post"
before 'kubectl .*rollout restart' 'kubectl .*rollout status' || fail "rollout status must follow the restart"
post=$(grep '^rds-setup post' "$root/log")
grep -q 'RELEASE=agent-relay ' <<<"$post" || fail "post did not get RELEASE: $post"
grep -q 'MIGRATION_JOB=agent-relay-worker-migrate-0a1b2c3d ' <<<"$post" || fail "post did not get MIGRATION_JOB: $post"
grep -q "SERVICES_IMAGE=$REG/agent-relay/ghcr.io/agentworkforce/sessions-pipeline@$D3 " <<<"$post" || fail "post did not get the mirrored services image: $post"
grep -q "PSQL_IMAGE=$REG/agent-relay/ghcr.io/cloudnative-pg/postgresql@$D4 " <<<"$post" || fail "post did not get the mirrored psql image: $post"
grep -q 'NAMESPACE=agent-relay ' <<<"$post" || fail "post did not get NAMESPACE: $post"
grep 'kubectl .*rollout restart' "$root/log" | grep -q 'deployment/agent-relay-read-api deployment/agent-relay-ingest-edge deployment/agent-relay-search-indexer' \
  || fail "restart did not target read API, ingest edge and search indexer"
grep -q '^rds-setup refresh-admin' "$root/log" && fail "first install ran refresh-admin"
pass "first install --rds-setup: install, migration wait, post, restart, in order"

# 18. --rds-setup apply refuses before contacting anything without its environment or state
make_state; setup_mocks "$root/rel-ok" ok; rm -f "$root/exists"
out=$(env -u RDS_HOST PATH="$root/bin:$PATH" AWS_REGION=x RDS_ADMIN_SECRET_ARN=y STATE_DIR="$root/state" \
  "$TEST_BASH" "$SCRIPT" "${args[@]}" --rds-setup --first-install --apply --db-instance prod-db --yes 2>&1) \
  && fail "--rds-setup without RDS_HOST was accepted"
grep -q 'RDS_HOST' <<<"$out" || fail "missing RDS_HOST refused for the wrong reason: $out"
rm -f "$root/state/passwords/bulls96_read_api"
out=$(run_rds "${args[@]}" --rds-setup --first-install --apply --db-instance prod-db --yes 2>&1) && fail "first install without pre state was accepted"
grep -q "rds-setup.sh pre" <<<"$out" || fail "missing pre state refused for the wrong reason: $out"
[ -s "$root/log" ] && fail "a refused --rds-setup apply contacted tools"
pass "--rds-setup apply checks its environment and pre state first"

# 19. eks-rds-native upgrade: snapshot -> refresh-admin -> Secret patches -> helm upgrade; values never in argv
make_state; setup_mocks "$root/rel-ok" ok
out=$(run_rds --version 2026.11.1 --registry "$REG" --profile eks-rds-native --values "$vals" \
  --apply --db-instance prod-db --yes 2>&1) || fail "rds-native upgrade failed: $out"
before 'aws rds create-db-snapshot' '^rds-setup refresh-admin' || fail "refresh-admin must follow the snapshot"
before '^rds-setup refresh-admin' 'kubectl .*patch secret agent-relay-secrets' || fail "Secret update must follow refresh-admin"
before 'kubectl .*patch secret search-indexer-owner' 'helm .* upgrade ' || fail "Secret updates must precede helm upgrade"
grep 'kubectl .*patch secret' "$root/log" | grep -qv -- '--patch-file' && fail "Secret patched without a patch file"
grep -q 'rotated-admin-pw' "$root/log" && fail "a credential appeared on a command line"
grep -q 'rotated-admin-pw' <<<"$out" && fail "a credential was printed"
want=$(printf 'postgresql://admin:rotated-admin-pw@db/hoopdb' | base64 | tr -d '\n')
grep -q "{\"data\":{\"HOOPDB_MIGRATION_URL\":\"$want\"}}" "$root/patches" || fail "agent-relay-secrets patch is wrong: $(cat "$root/patches")"
grep -q '"RELAYHISTORY_PIPELINE_CONSUMER_SECRET"' "$root/patches" || fail "search-indexer-owner was not patched"
grep -q '^rds-setup post' "$root/log" && fail "upgrade ran post"
pass "rds-native upgrade runs refresh-admin and updates both Secrets before helm upgrade"

# 20. eks-native upgrade with --rds-setup runs refresh-admin; without it, never
make_state; setup_mocks "$root/rel-ok" ok
out=$(run_rds "${args[@]}" --rds-setup --apply --db-instance prod-db --yes 2>&1) || fail "eks-native --rds-setup upgrade failed: $out"
grep -q '^rds-setup refresh-admin' "$root/log" || fail "--rds-setup upgrade did not refresh admin credentials"
setup_mocks "$root/rel-ok" ok
out=$(run_rds "${args[@]}" --apply --db-instance prod-db --yes 2>&1) || fail "eks-native upgrade failed: $out"
grep -q '^rds-setup ' "$root/log" && fail "eks-native upgrade without --rds-setup ran rds-setup.sh"
pass "refresh-admin runs only when the install uses rds-setup"

# 21. the plan reports any rendered change, not only image changes
cfg() { printf 'kind: ConfigMap\nmetadata:\n  name: settings\ndata:\n  mode: "%s"\n' "$1"; }
setup_mocks "$root/rel-ok" ok; cfg one > "$root/rendered-extra.yaml"; cfg one > "$root/live-manifest.yaml"
out=$(run "${args[@]}" 2>&1) || fail "plan failed: $out"
grep -q 'plan: changes=false' <<<"$out" || fail "identical render reported changes: $out"
grep -q '(no manifest changes)' <<<"$out" || fail "identical render did not say so: $out"
setup_mocks "$root/rel-ok" ok; cfg two > "$root/rendered-extra.yaml"; cfg one > "$root/live-manifest.yaml"
out=$(run "${args[@]}" 2>&1) || fail "plan failed: $out"
grep -q 'plan: changes=true' <<<"$out" || fail "values-only change was not reported: $out"
grep -q '~ ConfigMap//settings' <<<"$out" || fail "changed resource not listed: $out"
setup_mocks "$root/rel-ok" ok; cfg one > "$root/rendered-extra.yaml"; : > "$root/live-manifest.yaml"
out=$(run "${args[@]}" 2>&1) || fail "plan failed: $out"
grep -q '+ ConfigMap//settings' <<<"$out" || fail "added resource not listed: $out"
pass "plan detects manifest changes beyond images"

# 22. values selecting databaseMode rds without --rds-setup get a note, not a guess
setup_mocks "$root/rel-ok" ok
printf 'sessions-pipeline:\n  worker:\n    migrations:\n      databaseMode: rds\n' > "$root/rds-values.yaml"
out=$(run --version 2026.11.1 --registry "$REG" --profile eks-native --values "$root/rds-values.yaml" 2>&1) || fail "plan failed: $out"
grep -q 'add --rds-setup' <<<"$out" || fail "rds values without --rds-setup were not flagged: $out"
pass "rds values without --rds-setup are flagged in the plan"
