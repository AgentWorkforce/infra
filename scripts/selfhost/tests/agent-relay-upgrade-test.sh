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
cp "$SELFHOST_DIR/agent-relay-upgrade.sh" "$SELFHOST_DIR/mirror-images-to-ecr.sh" "$SELFHOST_DIR/relaycast-to-actors.sh" "$SELFHOST_DIR/sessions-index-census.mjs" "$root/selfhost/"
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
  if [ "$v" != no-rds-native ]; then : > "$d/pkg/agent-relay/values-eks-rds-native.yaml"; : > "$d/pkg/agent-relay/values-eks-actors.yaml"; fi
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
    if [ -f "$root/rendered-extra.yaml" ]; then echo ---; cat "$root/rendered-extra.yaml"; fi
    # The cutover's target render (the Relaycast-only actors overlay) adds these.
    case "\$*" in *rta-actors-profile.yaml*) [ -f "$root/rendered-target.yaml" ] && { echo ---; cat "$root/rendered-target.yaml"; } ;; esac
    # A capability-gated template, like the charts' VPA check.
    case " \$* " in *" --api-versions autoscaling.k8s.io/v1 "*)
      printf -- '---\nkind: VerticalPodAutoscaler\nmetadata:\n  name: relayfile\n' ;; esac ;;
  *" list "*) if [ -f "$root/exists" ]; then echo '[{"name":"agent-relay","status":"deployed","chart":"agent-relay-0.6.31"}]'; else echo '[]'; fi ;;
  *"get values"*) cat "$root/live-values.yaml" 2>/dev/null || true ;;
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
  rm -f "$root/rekey-fail" "$root/crane-missing" "$root/rendered-extra.yaml" "$root/rendered-target.yaml" "$root/live-manifest.yaml" "$root/patches" "$root/live-values.yaml"; rm -rf "$root/secrets"; touch "$root/exists"
  rm -rf "$root/jobstate"; mkdir -p "$root/jobstate"; rm -f "$root/no-version" "$root/applied.yaml" "$root/census.out" "$root/census-phase"
  printf 'v1\napps/v1\nbatch/v1\npolicy/v1\nautoscaling/v2\n' > "$root/api-versions"
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
  # The Sessions index census: the pod manifest is kept, its phase and logs come from fixtures.
  *" apply -f -"*) cat >> "$root/applied.yaml"; echo --- >> "$root/applied.yaml" ;;
  *"get pod "*"-o json"*) ph=\$(cat "$root/census-phase" 2>/dev/null || echo Succeeded)
    # INT/TERM: signal the upgrader itself mid-census, as an operator's Ctrl-C would.
    case "\$ph" in INT|TERM) kill -"\$ph" "\$(pgrep -o -f "$root/selfhost/agent-relay-upgrade.sh")"; ph=Running ;; esac
    printf '{"status":{"phase":"%s"}}\n' "\$ph" ;;
  *"logs pod/"*"-c census"*) cat "$root/census.out" 2>/dev/null || true ;;
  *jsonpath*) echo "old/relay-control@sha256:old" ;;
  *"version -o json"*) [ -f "$root/no-version" ] || echo '{"serverVersion":{"gitVersion":"v1.31.4-eks-2d5f260"}}' ;;
  *api-versions*) cat "$root/api-versions" ;;
  *"get job "*) # state from $root/jobstate/<name>, one per call; the last state sticks
    prev=""; for a in "\$@"; do [ "\$prev" = job ] && n=\$a; prev=\$a; done
    f="$root/jobstate/\$n"; st=complete
    if [ -s "\$f" ]; then st=\$(head -1 "\$f"); if [ "\$(wc -l < "\$f")" -gt 1 ]; then tail -n +2 "\$f" > "\$f.t"; mv "\$f.t" "\$f"; fi; fi
    case "\$st" in
      complete) echo '{"status":{"succeeded":1,"conditions":[{"type":"Complete","status":"True"}]}}' ;;
      failed) echo '{"status":{"failed":3,"conditions":[{"type":"Failed","status":"True"}]}}' ;;
      notfound) echo "Error from server (NotFound): jobs.batch \"\$n\" not found" >&2; exit 1 ;;
      *) echo '{"status":{"active":1}}' ;;
    esac ;;
  *"logs job/"*) echo "bootstrap: relation sessions.search_documents does not exist" ;;
  *" exec "*relaycast-rekey*) [ -f "$root/rekey-fail" ] && { echo '{"event":"relaycast_rekey.summary","failed":1}'; exit 1; }; echo '{"event":"relaycast_rekey.credential","table":"workspaces","outcome":"rotated"}'; echo '{"event":"relaycast_rekey.summary","run_id":"rekey-run-1","by_column":{}}' ;;
  *"get secret "*"-o json"*) # $root/secrets/<namespace>/<name>.json, else an empty Secret
    ns=""; name=""; prev=""; for a in "\$@"; do [ "\$prev" = -n ] && ns=\$a; [ "\$prev" = secret ] && name=\$a; prev=\$a; done
    cat "$root/secrets/\$ns/\$name.json" 2>/dev/null || echo '{"data":{}}' ;;
  *"-o json"*) echo '{"items":[]}' ;;
  *"get deploy -l"*"-o name"*) echo deployment.apps/agent-relay-read-api ;;
  *"patch secret"*) for a in "\$@"; do case "\$a" in */patch.json) cat "\$a" >> "$root/patches"; echo >> "$root/patches";; esac; done ;;
esac
exit 0
EOF
  printf '#!/usr/bin/env bash\necho "aws $*" >> "%s/log"\nexit 0\n' "$root" > "$bin/aws"
  # crane: report the pinned digest for any ref, so the mirror's digest check passes
  printf '#!/usr/bin/env bash\necho "crane $*" >> "%s/log"\n[ -f "%s/crane-missing" ] && [ "$1" = digest ] && case "$2" in *relaycast-migration/*) exit 1;; esac\nfor a in "$@"; do case "$a" in *@sha256:*) [ "$1" = digest ] && { echo "${a##*@}"; exit 0; };; *:sha256-*) [ "$1" = digest ] && { d=${a##*:sha256-}; echo "sha256:$d"; exit 0; };; esac; done\nexit 0\n' "$root" "$root" > "$bin/crane"
  chmod +x "$bin"/*
  write_helm
}

# rds-setup.sh state as "pre" leaves it, plus the environment it reads.
make_state() {
  rm -rf "$root/state"; mkdir -p "$root/state/passwords" "$root/state/secret-files/agent-relay-secrets" \
    "$root/state/secret-files/search-indexer-owner"
  for p in bulls96_read_api bulls96_session_ingest search_consumer_runtime; do printf x > "$root/state/passwords/$p"; done
  find "$root/state" -type d -exec chmod 700 {} +; find "$root/state" -type f -exec chmod 600 {} +
}
rds_env=(AWS_REGION=us-east-1 RDS_HOST=db.example.internal RDS_ADMIN_SECRET_ARN=arn:aws:secretsmanager:us-east-1:111111111111:secret:rds STATE_DIR="$root/state")

export AGENT_RELAY_JOB_POLL_SECONDS=0
run() { PATH="$root/bin:$PATH" "$TEST_BASH" "$SCRIPT" "$@"; }
# A normal operator umask (022): state the scripts write must still be owner-only.
run_rds() { ( umask 022; env "${rds_env[@]}" PATH="$root/bin:$PATH" "$TEST_BASH" "$SCRIPT" "$@" ); }
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
before 'helm .* install ' 'kubectl .*get job agent-relay-worker-migrate-0a1b2c3d ' \
  || fail "migration wait must follow helm install"
grep -q '^rds-setup ' "$root/log" && fail "first install without --rds-setup ran rds-setup.sh"
grep -q 'Installed agent-relay at 2026.11.1' <<<"$out" || fail "first install did not report success"
pass "first install: snapshot, helm install --no-hooks, then the migration wait"

# 17. first install with --rds-setup: install -> migration wait -> post -> restart -> rollout status
make_state; setup_mocks "$root/rel-ok" ok; rm -f "$root/exists"; printf '%s\n' "$migrate_job" > "$root/live-manifest.yaml"
out=$(run_rds "${args[@]}" --rds-setup --first-install --apply --db-instance prod-db --yes 2>&1) || fail "rds first install failed: $out"
before 'helm .* install ' 'kubectl .*get job agent-relay-worker-migrate' || fail "install must precede the migration wait"
before 'kubectl .*get job agent-relay-worker-migrate' '^rds-setup post' || fail "post must follow the migration wait"
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

# 23. first install waits for EVERY Job in the release, including one still running after the migration
bootstrap_job='kind: Job
metadata:
  name: agent-relay-search-indexer-bootstrap-9f8e7d6c
  labels: { app.kubernetes.io/component: search-indexer-bootstrap }'
make_state; setup_mocks "$root/rel-ok" ok; rm -f "$root/exists"
printf '%s\n---\n%s\n' "$migrate_job" "$bootstrap_job" > "$root/live-manifest.yaml"
printf 'running\nrunning\ncomplete\n' > "$root/jobstate/agent-relay-search-indexer-bootstrap-9f8e7d6c"
out=$(run_rds "${args[@]}" --rds-setup --first-install --apply --db-instance prod-db --yes 2>&1) || fail "first install with a pending Job failed: $out"
[ "$(grep -c 'kubectl .*get job agent-relay-search-indexer-bootstrap-9f8e7d6c ' "$root/log")" -ge 3 ] \
  || fail "the pending bootstrap Job was not polled to completion"
before '^rds-setup post' 'kubectl .*get job agent-relay-search-indexer-bootstrap' || fail "release Jobs must be awaited after the login barrier"
line_b=$(grep -n 'Job agent-relay-search-indexer-bootstrap-9f8e7d6c completed' <<<"$out" | cut -d: -f1)
line_i=$(grep -n 'Installed agent-relay' <<<"$out" | cut -d: -f1)
[ -n "$line_b" ] && [ -n "$line_i" ] && [ "$line_b" -lt "$line_i" ] || fail "Installed was printed before every Job completed: $out"
pass "first install waits for every release Job before reporting success"

# 24. a failed release Job fails the first install with its name and last logs
make_state; setup_mocks "$root/rel-ok" ok; rm -f "$root/exists"
printf '%s\n---\n%s\n' "$migrate_job" "$bootstrap_job" > "$root/live-manifest.yaml"
printf 'running\nfailed\n' > "$root/jobstate/agent-relay-search-indexer-bootstrap-9f8e7d6c"
out=$(run_rds "${args[@]}" --rds-setup --first-install --apply --db-instance prod-db --yes 2>&1) && fail "a failed Job reported success"
grep -q 'Job agent-relay-search-indexer-bootstrap-9f8e7d6c did not complete (failed)' <<<"$out" || fail "failed Job not named: $out"
grep -q 'relation sessions.search_documents does not exist' <<<"$out" || fail "failed Job logs not shown: $out"
grep -q 'Installed agent-relay' <<<"$out" && fail "Installed printed after a failed Job"
grep -q 'INSTALL FAILED' <<<"$out" || fail "failure hint missing: $out"
pass "a failed release Job fails the first install with its name and logs"

# 25. a Job still running at the deadline fails the first install
make_state; setup_mocks "$root/rel-ok" ok; rm -f "$root/exists"
printf '%s\n' "$migrate_job" > "$root/live-manifest.yaml"; echo running > "$root/jobstate/agent-relay-worker-migrate-0a1b2c3d"
out=$(AGENT_RELAY_JOB_TIMEOUT_SECONDS=0 run_rds "${args[@]}" --rds-setup --first-install --apply --db-instance prod-db --yes 2>&1) \
  && fail "a Job past the deadline reported success"
grep -q 'did not complete (timeout)' <<<"$out" || fail "deadline not reported: $out"
grep -q '^rds-setup post' "$root/log" && fail "post ran without a completed migration"
pass "Job waits are bounded"

# 26. a Job deleted by ttlSecondsAfterFinished after it was seen complete is not awaited again
make_state; setup_mocks "$root/rel-ok" ok; rm -f "$root/exists"
printf '%s\n---\n%s\n' "$migrate_job" "$bootstrap_job" > "$root/live-manifest.yaml"
printf 'complete\nnotfound\n' > "$root/jobstate/agent-relay-worker-migrate-0a1b2c3d"
out=$(AGENT_RELAY_JOB_TIMEOUT_SECONDS=0 run_rds "${args[@]}" --rds-setup --first-install --apply --db-instance prod-db --yes 2>&1) \
  || fail "a completed then TTL-deleted Job failed the install: $out"
[ "$(grep -c 'kubectl .*get job agent-relay-worker-migrate-0a1b2c3d ' "$root/log")" = 1 ] || fail "a completed Job was polled again"
grep -q 'Job agent-relay-worker-migrate-0a1b2c3d already completed' <<<"$out" || fail "completed Job not skipped: $out"
grep -q 'Installed agent-relay' <<<"$out" || fail "install not reported: $out"
pass "a Job seen complete and then deleted counts as complete"

# 27. a Job never found times out with a clear message; one that vanishes unseen-complete fails at once
make_state; setup_mocks "$root/rel-ok" ok; rm -f "$root/exists"
printf '%s\n---\n%s\n' "$migrate_job" "$bootstrap_job" > "$root/live-manifest.yaml"
echo notfound > "$root/jobstate/agent-relay-search-indexer-bootstrap-9f8e7d6c"
out=$(AGENT_RELAY_JOB_TIMEOUT_SECONDS=0 run_rds "${args[@]}" --rds-setup --first-install --apply --db-instance prod-db --yes 2>&1) \
  && fail "a Job that never existed reported success"
grep -q 'agent-relay-search-indexer-bootstrap-9f8e7d6c did not complete (timeout; the Job was never found)' <<<"$out" || fail "never-found Job message unclear: $out"
make_state; setup_mocks "$root/rel-ok" ok; rm -f "$root/exists"
printf '%s\n---\n%s\n' "$migrate_job" "$bootstrap_job" > "$root/live-manifest.yaml"
printf 'running\nnotfound\n' > "$root/jobstate/agent-relay-search-indexer-bootstrap-9f8e7d6c"
out=$(run_rds "${args[@]}" --rds-setup --first-install --apply --db-instance prod-db --yes 2>&1) && fail "a vanished running Job reported success"
grep -q 'did not complete (removed before its outcome was seen)' <<<"$out" || fail "vanished Job message unclear: $out"
pass "a Job never found times out clearly; one removed before completing fails"
# 28. the plan renders with the cluster's version and API versions, so a
# capability-gated resource the cluster has matches the deployed release
vpa='kind: VerticalPodAutoscaler
metadata:
  name: relayfile'
setup_mocks "$root/rel-ok" ok; echo autoscaling.k8s.io/v1 >> "$root/api-versions"; printf '%s\n' "$vpa" > "$root/live-manifest.yaml"
out=$(run "${args[@]}" 2>&1) || fail "plan failed: $out"
tmpl=$(grep 'helm .*template' "$root/log")
grep -q -- '--kube-version v1.31.4-eks-2d5f260' <<<"$tmpl" || fail "plan did not render with the cluster version: $tmpl"
grep -q -- '--api-versions autoscaling.k8s.io/v1' <<<"$tmpl" || fail "plan did not render with the cluster API versions: $tmpl"
grep -q 'plan: changes=false' <<<"$out" || fail "VPA-gated template produced a spurious change: $out"
setup_mocks "$root/rel-ok" ok; printf '%s\n' "$vpa" > "$root/live-manifest.yaml"
out=$(run "${args[@]}" 2>&1) || fail "plan failed: $out"
grep -q -- '- VerticalPodAutoscaler//relayfile' <<<"$out" || fail "capability gate was not driven by the cluster's API versions: $out"
pass "plan renders with the cluster's capabilities (no spurious VPA change)"

# 29. a cluster whose version cannot be read refuses the plan
setup_mocks "$root/rel-ok" ok; touch "$root/no-version"
out=$(run "${args[@]}" 2>&1) && fail "plan without a cluster version was accepted"
grep -q "Kubernetes version" <<<"$out" || fail "missing version refused for the wrong reason: $out"
pass "plan refuses without the cluster's Kubernetes version"

# 30. --rds-setup refuses a STATE_DIR that group or others can read, before contacting anything
make_state; setup_mocks "$root/rel-ok" ok
chmod 644 "$root/state/passwords/bulls96_read_api"
out=$(run_rds "${args[@]}" --rds-setup --apply --db-instance prod-db --yes 2>&1) && fail "an open STATE_DIR was accepted"
grep -q 'readable beyond its owner' <<<"$out" || fail "open STATE_DIR refused for the wrong reason: $out"
[ -s "$root/log" ] && fail "an open STATE_DIR contacted tools"
pass "--rds-setup refuses a STATE_DIR readable beyond its owner"

# 31. --relaycast-actors: opt-in, plan-mode guards that refuse before changing anything
rds_args=(--version 2026.11.1 --registry "$REG" --profile eks-rds-native --values "$vals")
live_pg='relaycast:
  existingSecret: relaycast-secrets
  runtime: { backend: postgres }
  credentials: { format: legacy }
relay-control:
  encryption: { keyId: k1 }'
secret() { mkdir -p "$root/secrets/$1"; printf '%s\n' "$3" > "$root/secrets/$1/$2.json"; }
keyring() { secret agent-relay relaycast-secrets '{"data":{"credential-keyring":"eA==","internal-secret":"aQ==","file-signing-secret":"Zg==","workspace-bootstrap-secret":"Yg=="}}'; }
make_release "$root/rel-ok" ok; setup_mocks "$root/rel-ok" ok
out=$(run "${args[@]}" --relaycast-actors cutover 2>&1) && fail "--relaycast-actors on eks-native was accepted"
grep -q 'needs --profile eks-rds-native' <<<"$out" || fail "wrong-profile migration refused for the wrong reason: $out"
out=$(run "${rds_args[@]}" --relaycast-actors everything 2>&1) && fail "an unknown phase was accepted"
out=$(run "${rds_args[@]}" --actors-values "$vals" 2>&1) && fail "--actors-values without a phase was accepted"
grep -q 'need --relaycast-actors' <<<"$out" || fail "--actors-values alone refused for the wrong reason: $out"
setup_mocks "$root/rel-ok" ok; printf 'relaycast:\n  runtime: { backend: durable-actors }\n' > "$root/live-values.yaml"
out=$(run_rds "${rds_args[@]}" --relaycast-actors credentials 2>&1) && fail "a release already on actors was accepted"
grep -q 'not postgres; nothing to migrate' <<<"$out" || fail "actors backend refused for the wrong reason: $out"
setup_mocks "$root/rel-ok" ok; printf '%s\n' "$live_pg" > "$root/live-values.yaml"
out=$(run_rds "${rds_args[@]}" --relaycast-actors credentials 2>&1) && fail "a Secret without the keyring was accepted"
grep -q 'has no credential-keyring key' <<<"$out" || fail "missing keyring refused for the wrong reason: $out"
keyring
out=$(run_rds "${rds_args[@]}" --relaycast-actors credentials 2>&1) || fail "credentials plan failed: $out"
grep -q 'preconditions hold' <<<"$out" || fail "credentials plan did not report its preconditions: $out"
grep -Eq 'helm .* upgrade |kubectl .*(scale|apply|exec)' "$root/log" && fail "migration plan mode changed the cluster"
pass "--relaycast-actors is opt-in and refuses wrong profile, phase, backend and keyring in plan mode"

# 32. cutover: a Relaycast-only overlay, and every precondition refuses
setup_mocks "$root/rel-ok" ok; printf '%s\n' "$live_pg" > "$root/live-values.yaml"; keyring; make_state
out=$(run_rds "${rds_args[@]}" --relaycast-actors cutover --actors-values "$vals" 2>&1) && fail "cutover on legacy credentials was accepted"
grep -q 'run --relaycast-actors credentials first' <<<"$out" || fail "legacy cutover refused for the wrong reason: $out"
sed -i.bak 's/format: legacy/format: ar/' "$root/live-values.yaml"
out=$(run_rds "${rds_args[@]}" --relaycast-actors cutover 2>&1) && fail "cutover without --actors-values was accepted"
grep -q 'cutover needs --actors-values' <<<"$out" || fail "missing actors values refused for the wrong reason: $out"
out=$(run_rds "${rds_args[@]}" --relaycast-actors cutover --actors-values "$vals" 2>&1) && fail "cutover without a credentials-phase record was accepted"
grep -q 'no record of the credentials phase' <<<"$out" || fail "missing ar-since refused for the wrong reason: $out"
( umask 077; mkdir -p "$root/state/relaycast-actors"; echo 1794500000 > "$root/state/relaycast-actors/agent-relay-agent-relay.ar-since"
  echo k1 > "$root/state/relaycast-actors/agent-relay-agent-relay.control-key" )
target() { # $1: postgres-ca volume on the control plane (yes|no), $2: keyring key, $3: extra image
  cat > "$root/rendered-target.yaml" <<YAML
kind: Deployment
metadata: { name: relaycast, labels: { app.kubernetes.io/name: relaycast } }
spec:
  template:
    spec:
      containers:
        - name: gateway
          image: ${3:-$REG/agent-relay/ghcr.io/agentworkforce/relay-control@$D1}
          env:
            - { name: RELAYCAST_FILE_SIGNING_SECRET, valueFrom: { secretKeyRef: { name: relaycast-secrets, key: file-signing-secret } } }
            - { name: RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET, valueFrom: { secretKeyRef: { name: relaycast-secrets, key: workspace-bootstrap-secret } } }
      volumes: [{ name: secrets, secret: { secretName: relaycast-secrets, items: [{ key: ${2:-credential-keyring}, path: credential-keyring }] } }]
---
kind: Deployment
metadata: { name: agent-relay-durable-actors }
spec: { template: { spec: { volumes: [{ name: tmp }$( [ "$1" = yes ] && echo ', { name: postgres-ca }' )] } } }
---
kind: Role
metadata: { name: agent-relay-durable-actors, namespace: agent-relay-agent-relay }
---
kind: Job
metadata: { name: relaycast-actors-deploy-0a1b2c3d }
spec: { template: { spec: { containers: [{ name: deploy, env: [{ name: DURABLE_ACTORS_SECRET_REFS, value: relaycast-actor-env }] }] } } }
YAML
}
actor_env() { secret agent-relay-agent-relay relaycast-actor-env "{\"data\":{\"RELAYCAST_INTERNAL_SECRET\":\"aQ==\",\"RELAYCAST_FILE_SIGNING_SECRET\":\"Zg==\",\"RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET\":\"${1:-Yg==}\"}}"; }
target no; actor_env
out=$(run_rds "${rds_args[@]}" --relaycast-actors cutover --actors-values "$vals" 2>&1) && fail "a control plane without an RDS CA was accepted"
grep -q 'without a CA bundle' <<<"$out" && grep -q 'agent-relay-durable-actors' <<<"$out" || fail "CA-less control plane refused for the wrong reason: $out"
target yes other-keyring
out=$(run_rds "${rds_args[@]}" --relaycast-actors cutover --actors-values "$vals" 2>&1) && fail "a gateway on another keyring key was accepted"
grep -q 'must read keyring relaycast-secrets/credential-keyring' <<<"$out" || fail "keyring change refused for the wrong reason: $out"
target yes credential-keyring ghcr.io/agentworkforce/relaycast-actors-gateway@$D3
out=$(run_rds "${rds_args[@]}" --relaycast-actors cutover --actors-values "$vals" 2>&1) && fail "an unmirrored cutover image was accepted"
grep -q 'neither release images nor digest-pinned mirrors' <<<"$out" || fail "unmirrored image refused for the wrong reason: $out"
target yes; actor_env Wg==
out=$(run_rds "${rds_args[@]}" --relaycast-actors cutover --actors-values "$vals" 2>&1) && fail "an actor env Secret with other bytes was accepted"
grep -q 'RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET' <<<"$out" || fail "actor secret mismatch refused for the wrong reason: $out"
actor_env; sed -i.bak 's/keyId: k1/keyId: k2/' "$root/live-values.yaml"
out=$(run_rds "${rds_args[@]}" --relaycast-actors cutover --actors-values "$vals" 2>&1) && fail "a changed relay-control encryption key was accepted"
grep -q "encryption key changed" <<<"$out" || fail "encryption key change refused for the wrong reason: $out"
sed -i.bak 's/keyId: k2/keyId: k1/' "$root/live-values.yaml"
out=$(run_rds "${rds_args[@]}" --relaycast-actors cutover --actors-values "$vals" 2>&1) || fail "a complete cutover plan failed: $out"
grep -q 'preconditions hold' <<<"$out" || fail "cutover plan did not report its preconditions: $out"
grep 'helm .*template' "$root/log" | tail -1 | grep -q 'rta-actors-profile.yaml' || fail "cutover did not render the Relaycast-only actors overlay"
grep 'helm .*template' "$root/log" | tail -1 | grep -q 'values-eks-actors.yaml' && fail "cutover layered the whole actors profile (it turns the suite off)"
grep -Eq 'helm .* upgrade |kubectl .*(scale|apply|exec)' "$root/log" && fail "cutover plan mode changed the cluster"
pass "cutover uses a Relaycast-only overlay and refuses CA, keyring, image, actor secret and encryption-key mismatches"

# 33. credentials apply: a retry keeps the first switch time; the rekey run is recorded
setup_mocks "$root/rel-ok" ok; printf '%s\n' "$live_pg" > "$root/live-values.yaml"; keyring; make_state
st="$root/state/relaycast-actors/agent-relay-agent-relay"
( umask 077; mkdir -p "$root/state/relaycast-actors"; echo 1700000000 > "$st.ar-since" )
out=$(run_rds "${rds_args[@]}" --relaycast-actors credentials --apply --db-instance prod-db --yes 2>&1) || fail "credentials apply failed: $out"
[ "$(cat "$st.ar-since")" = 1700000000 ] || fail "a retried credentials phase overwrote the first switch time"
grep -qx rekey-run-1 "$st.rekey-runs" || fail "the relaycast-rekey run id was not recorded"
grep -q 'relaycast_rekey.summary' "$st.rekey-rekey-run-1.jsonl" || fail "the relaycast-rekey report was not kept"
# Under umask 022 the state stays owner-only, so the STATE_DIR guard accepts the next run.
open_perms=$(find "$root/state" \( -perm -0001 -o -perm -0002 -o -perm -0004 -o -perm -0010 -o -perm -0020 -o -perm -0040 \) -print)
[ -z "$open_perms" ] || fail "migration state is readable beyond its owner: $open_perms"
out=$(run_rds "${rds_args[@]}" --relaycast-actors credentials --apply --db-instance prod-db --yes 2>&1) || fail "a retried credentials phase failed: $out"
touch "$root/rekey-fail"
out=$(run_rds "${rds_args[@]}" --relaycast-actors credentials --apply --db-instance prod-db --yes 2>&1) && fail "a failed relaycast-rekey was accepted"
grep -q 'relaycast-rekey failed' <<<"$out" && grep -q 'Relaycast migration (credentials' <<<"$out" && grep -q 'database snapshot:' <<<"$out" \
  || fail "a failed re-key did not print the rollback with the snapshot: $out"
pass "a retried credentials phase keeps the first switch time and records the rekey run"

# 34. cutover apply: a mirrored image missing from the registry refuses before anything stops
setup_mocks "$root/rel-ok" ok; printf '%s\n' "$live_pg" > "$root/live-values.yaml"; keyring; make_state
sed -i.bak 's/format: legacy/format: ar/' "$root/live-values.yaml"
( umask 077; mkdir -p "$root/state/relaycast-actors"; echo 1794500000 > "$st.ar-since"; echo k1 > "$st.control-key" )
target yes credential-keyring "$REG/relaycast-migration/relaycast-actors-gateway@$D3"; actor_env; touch "$root/crane-missing"
out=$(run_rds "${rds_args[@]}" --relaycast-actors cutover --actors-values "$vals" --apply --db-instance prod-db --yes 2>&1) && fail "a missing mirrored image was accepted"
grep -q 'is not in' <<<"$out" || fail "missing mirror refused for the wrong reason: $out"
grep -Eq 'kubectl .*(scale|apply)' "$root/log" && fail "the cutover stopped or created something before the image check"
pass "cutover checks every mirrored image digest before stopping anything"

# 35. once go-live is recorded the rollback hint is forward-only
( umask 077; touch "$st.golive"; echo relaycast-actors-1 > "$st.run" )
grep -q 'GO-LIVE IS RECORDED' "$SELFHOST_DIR/relaycast-to-actors.sh" || fail "no forward-only rollback hint"
pass "go-live is recorded before the first workspace opens and the hint turns forward-only"

# 36-44. Sessions adopt-or-create index steps: a read-only census from the
# deployed migrate Job decides the blocking-build opt-in for this upgrade only.
live_migrate='kind: Job
metadata:
  name: agent-relay-worker-migrate-0a1b2c3d
  labels: { app.kubernetes.io/component: hoopdb-migrate }
spec:
  template:
    metadata:
      labels: { app.kubernetes.io/component: hoopdb-migrate, app.kubernetes.io/instance: agent-relay }
    spec:
      serviceAccountName: agent-relay-worker-migrate
      restartPolicy: Never
      initContainers: [{ name: wait-for-role, image: old/psql@sha256:old }]
      containers:
        - name: migrate
          image: old/sessions-pipeline@sha256:old
          args: [migrate]
          env:
            - { name: HOOPDB_URL, valueFrom: { secretKeyRef: { name: agent-relay-secrets, key: HOOPDB_MIGRATION_URL } } }
            - { name: NODE_EXTRA_CA_CERTS, value: /etc/postgres-ca/ca.crt }
          volumeMounts: [{ name: postgres-ca, mountPath: /etc/postgres-ca, readOnly: true }]
      volumes: [{ name: postgres-ca, configMap: { name: rds-ca } }]'
E58=upstream:20261105058000_operator_user_erase_indexes.sql
PK58=docs/packets/operator-user-erase-index-packet.md
# census STATE ROWS [APPLIED]: 044020 applied; 058000 pending (unless APPLIED=true) with one index
# in STATE on a table of ROWS rows plus one absent index on an empty table.
census() {
  local exact=true; [ "$2" -gt 1000000 ] && exact=false
  printf 'INDEX_CENSUS {"limit":1000000,"steps":[{"step":"upstream:20261105044020_claim_bootstrap_org_indexes.sql","packet":"p","applied":true,"indexes":[]},{"step":"%s","packet":"%s","applied":%s,"indexes":[{"name":"ingest_lazy_ack_decisions_native_key_sha256_idx","table":"sessions.ingest_lazy_ack_decisions","state":"%s","table_exists":true,"rows":%s,"exact":%s,"estimate":%s},{"name":"ingest_receipt_ord_seats_key_sha256_idx","table":"sessions.ingest_receipt_ord_seats","state":"absent","table_exists":true,"rows":0,"exact":true,"estimate":0}]}]}\n' \
    "$E58" "$PK58" "${3:-false}" "$1" "$2" "$exact" "$2" > "$root/census.out"
}
blocking_in() { grep "helm .*$1" "$root/log" | grep -q 'blocking-index.values.yaml'; }
census_setup() { setup_mocks "$root/rel-ok" ok; printf '%s\n' "$live_migrate" > "$root/live-manifest.yaml"; }

# 36. empty tables: no opt-in; the census pod is the deployed migrate container, read-only, and is deleted
census_setup; census absent 0
out=$(run "${args[@]}" 2>&1) || fail "census plan with empty tables failed: $out"
grep -q 'no blocking build' <<<"$out" || fail "empty tables did not report the no-opt-in path: $out"
blocking_in template && fail "empty tables rendered the blocking-build opt-in"
pod=$(yq -o=json 'select(.kind == "Pod")' "$root/applied.yaml")
[ "$(jq -r '.spec.containers | length' <<<"$pod")" = 1 ] || fail "census pod must have exactly one container"
[ "$(jq -r '.spec.containers[0].image' <<<"$pod")" = old/sessions-pipeline@sha256:old ] || fail "census pod must use the deployed migrate image"
[ "$(jq -r '.spec.containers[0].command | join(" ")' <<<"$pod")" = "bun /index-census/sessions-index-census.mjs" ] || fail "census pod runs the wrong command"
jq -e '.spec.initContainers == null and .spec.containers[0].args == null and .spec.restartPolicy == "Never"' <<<"$pod" >/dev/null || fail "census pod kept init containers or args"
jq -e '.spec.serviceAccountName == "agent-relay-worker-migrate" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate"' <<<"$pod" >/dev/null || fail "census pod lost the migrate Job identity or labels"
jq -e '[.spec.containers[0].env[] | select(.name == "HOOPDB_URL") | .valueFrom.secretKeyRef.key] == ["HOOPDB_MIGRATION_URL"]' <<<"$pod" >/dev/null || fail "census pod must read the migrate Job's HOOPDB_URL Secret reference"
jq -e '[.spec.containers[0].env[] | select(.name == "INDEX_CENSUS_LIMIT") | .value] == ["1000000"]' <<<"$pod" >/dev/null || fail "census pod limit"
jq -e '[.spec.containers[0].volumeMounts[].name] == ["postgres-ca", "index-census"]' <<<"$pod" >/dev/null || fail "census pod must keep the CA mount and add the script"
grep -q 'kubectl .*delete pod,configmap,secret agent-relay-index-census-' "$root/log" || fail "census pod and ConfigMap were not deleted"
grep -q 'postgresql://' "$root/applied.yaml" && fail "a connection string reached the census manifest"
pass "census: empty tables need no opt-in; the pod clones the deployed migrate container and is deleted"

# 37. small populated tables: the opt-in for this upgrade only, with rows and lock time in the plan
census_setup; census absent 4000
out=$(run "${args[@]}" 2>&1) || fail "census plan with a small table failed: $out"
grep -q 'path: blocking build for this upgrade. 4000 rows' <<<"$out" || fail "small table did not take the blocking path: $out"
grep -q 'Expected lock: about 1s of SHARE lock on sessions.ingest_lazy_ack_decisions' <<<"$out" || fail "plan did not state the expected lock: $out"
grep -q 'sessions.ingest_lazy_ack_decisions_native_key_sha256_idx on sessions.ingest_lazy_ack_decisions: 4000 rows' <<<"$out" || fail "plan did not name the index and rows: $out"
blocking_in template || fail "the blocking path did not render the opt-in"
census_setup; census absent 4000
out=$(run "${args[@]}" --apply --db-instance prod-db --yes 2>&1) || fail "apply on the blocking path failed: $out"
blocking_in ' upgrade ' || fail "helm upgrade did not carry the opt-in"
grep 'helm .* upgrade ' "$root/log" | grep -o -- '-f [^ ]*' | tail -1 | grep -q blocking-index.values.yaml || fail "the opt-in values must come last"
pass "census: a small populated table gets the blocking-build opt-in for this upgrade only"

# 38. above the limit: refuse in plan and apply, naming the packet; nothing rendered, mirrored or snapshotted
census_setup; census absent 2500000
out=$(run "${args[@]}" 2>&1) && fail "a large table was accepted"
grep -q "refusing: 1 index(es) are absent on populated tables with 2500000 rows to index, above the blocking-build limit of 1000000" <<<"$out" || fail "large table refused for the wrong reason: $out"
grep -q "$PK58" <<<"$out" || fail "the refusal did not name the prebuild packet: $out"
grep -q '(at least; estimate 2500000)' <<<"$out" || fail "an estimated count was not marked: $out"
grep -q 'helm template' "$root/log" && fail "a refused census still rendered"
census_setup; census absent 2500000
run "${args[@]}" --apply --db-instance prod-db --yes >/dev/null 2>&1 && fail "apply accepted a large table"
grep -Eq 'aws rds create-db-snapshot|helm .* upgrade |crane ' "$root/log" && fail "a refused census still snapshotted, mirrored or upgraded"
# A table that gets two absent indexes is named with its rows counted twice.
census_setup; census absent 600000
jq -c '.steps[1].indexes[1] = (.steps[1].indexes[0] | .name = "ingest_lazy_ack_decisions_seat_key_sha256_idx")' <(sed 's/^INDEX_CENSUS //' "$root/census.out") | sed 's/^/INDEX_CENSUS /' > "$root/census.2" && mv "$root/census.2" "$root/census.out"
out=$(run "${args[@]}" 2>&1) && fail "two indexes on a 600000-row table were accepted"
grep -q 'sessions.ingest_lazy_ack_decisions gets 2 indexes: 2 x 600000 = 1200000 rows to index' <<<"$out" || fail "the twice-indexed table was not stated: $out"
grep -q 'with 1200000 rows to index, above the blocking-build limit' <<<"$out" || fail "rows were not counted per absent index: $out"
pass "census: above the limit it refuses before anything changes and names the CONCURRENTLY packet"

# 39. the limit is configurable
census_setup; census absent 4000
AGENT_RELAY_BLOCKING_INDEX_MAX_ROWS=1000 run "${args[@]}" >"$root/out" 2>&1 && fail "rows above a lowered limit were accepted"
grep -q 'above the blocking-build limit of 1000 rows' "$root/out" || fail "a lowered limit was not applied: $(cat "$root/out")"
AGENT_RELAY_BLOCKING_INDEX_MAX_ROWS=lots run "${args[@]}" >"$root/out" 2>&1 && fail "a non-numeric limit was accepted"
pass "census: AGENT_RELAY_BLOCKING_INDEX_MAX_ROWS sets the limit and must be a number"

# 40. prebuilt (adoptable) indexes, or every step applied: nothing to set
census_setup; census adoptable 2500000
out=$(run "${args[@]}" 2>&1) || fail "a prebuilt index on a large table was refused: $out"
grep -q '1 index(es) prebuilt and adopted' <<<"$out" && grep -q 'no blocking build' <<<"$out" || fail "prebuilt index not reported as adopted: $out"
blocking_in template && fail "a prebuilt index rendered the opt-in"
census_setup; census absent 2500000 true
out=$(run "${args[@]}" 2>&1) || fail "applied steps were refused: $out"
grep -q 'already applied: nothing to build' <<<"$out" || fail "applied steps not reported: $out"
pass "census: prebuilt indexes and applied steps need no opt-in"

# 41. an INVALID or drifted index refuses even when small
for st in not_ready mismatch; do
  census_setup; census "$st" 10
  out=$(run "${args[@]}" 2>&1) && fail "a $st index was accepted"
  grep -q 'refusing: an index the Sessions migration would adopt is not usable' <<<"$out" || fail "$st refused for the wrong reason: $out"
done
pass "census: an INVALID or drifted index refuses"

# 42. fail closed: a census error, or a pod that ends without a result, refuses
census_setup; printf 'INDEX_CENSUS_ERROR 42501 permission denied for table ingest_lazy_ack_decisions\n' > "$root/census.out"
out=$(run "${args[@]}" 2>&1) && fail "a census error was accepted"
grep -q 'the index census failed (42501 permission denied' <<<"$out" || fail "census error not reported: $out"
census_setup; echo Failed > "$root/census-phase"
out=$(run "${args[@]}" 2>&1) && fail "a census without a result was accepted"
grep -q 'the index census pod ended Failed without a result' <<<"$out" || fail "missing census result not reported: $out"
grep -q 'kubectl .*delete pod,configmap,secret agent-relay-index-census-' "$root/log" || fail "a failed census pod was not deleted"
pass "census: an error or a missing result refuses (fail closed) and still cleans up"

# 43. the opt-in belongs to the upgrader: site values setting it refuse
census_setup; census absent 0
printf 'sessions-pipeline:\n  worker:\n    migrations:\n      allowBlockingIndexBuild: true\n' > "$root/optin.yaml"
out=$(run --version 2026.11.1 --registry "$REG" --profile eks-native --values "$root/optin.yaml" 2>&1) && fail "site values setting the opt-in were accepted"
grep -q 'sets sessions-pipeline.worker.migrations.allowBlockingIndexBuild: remove it' <<<"$out" || fail "site opt-in refused for the wrong reason: $out"
pass "census: site values may not set the blocking-build opt-in"

# 44. first install and the Relaycast phases never run the census
census_setup; census absent 2500000; rm -f "$root/exists"
run "${args[@]}" --first-install >/dev/null 2>&1 || fail "first install plan failed with a census fixture present"
grep -q 'index-census' "$root/log" && fail "first install ran the index census"
pass "census: first install skips the index census"

# 45. the limit boundary: exactly the limit takes the blocking build, one more row refuses
census_setup; census absent 1000000
out=$(run "${args[@]}" 2>&1) || fail "exactly the limit was refused: $out"
grep -q 'path: blocking build for this upgrade. 1000000 rows' <<<"$out" || fail "exactly the limit did not take the blocking path: $out"
census_setup; census absent 1000001
out=$(run "${args[@]}" 2>&1) && fail "one row over the limit was accepted"
grep -q 'with 1000001 rows to index, above the blocking-build limit of 1000000' <<<"$out" || fail "one row over refused for the wrong reason: $out"
pass "census: exactly the limit builds, one row more refuses"

# 46. a row count that is not a whole number refuses on purpose
for bad in '"lots"' '1.5' '-3' '1e300'; do
  census_setup; census absent 10
  sed -i.bak "s/\"rows\":10,/\"rows\":$bad,/" "$root/census.out"
  out=$(run "${args[@]}" 2>&1) && fail "a row count of $bad was accepted"
  grep -q 'returned a row count that is not a whole number' <<<"$out" || fail "row count $bad refused for the wrong reason: $out"
  blocking_in template && fail "row count $bad rendered the opt-in"
done
pass "census: a non-integer row count refuses (fail closed)"

# 47. Ctrl-C or TERM during the census still deletes the pod and its ConfigMap
for sig in INT TERM; do
  census_setup; census absent 10; echo "$sig" > "$root/census-phase"
  run "${args[@]}" >"$root/out" 2>&1 && fail "an interrupted ($sig) census plan succeeded"
  grep -q 'kubectl .*delete pod,configmap,secret agent-relay-index-census-' "$root/log" || fail "a $sig during the census left the pod and ConfigMap: $(cat "$root/out")"
  grep -q 'helm template' "$root/log" && fail "an interrupted ($sig) census still rendered"
done
pass "census: INT or TERM mid-census deletes the pod and ConfigMap"

# 48. --rds-setup: the census connects with a freshly refreshed admin URL, through a temporary Secret
census_setup; census absent 0; make_state
out=$(run_rds --version 2026.11.1 --registry "$REG" --profile eks-native --values "$vals" --rds-setup 2>&1) || fail "rds-setup census plan failed: $out"
before '^rds-setup refresh-admin' 'kubectl .*create secret generic agent-relay-index-census-' || fail "refresh-admin must run before the census Secret is made"
grep -q 'kubectl .*create secret generic agent-relay-index-census-[0-9]* --from-file=HOOPDB_URL=.*/secret-files/agent-relay-secrets/HOOPDB_MIGRATION_URL' "$root/log" \
  || fail "the census Secret must come from the refreshed state file"
pod=$(yq -o=json 'select(.kind == "Pod")' "$root/applied.yaml")
jq -e '[.spec.containers[0].env[] | select(.name == "HOOPDB_URL") | .valueFrom.secretKeyRef] == [{"name": .metadata.name, "key": "HOOPDB_URL"}]' <<<"$pod" >/dev/null \
  || fail "the census pod must read HOOPDB_URL from its own refreshed Secret: $(jq -c '.spec.containers[0].env' <<<"$pod")"
grep -q 'rotated-admin-pw' "$root/log" && fail "the refreshed credential reached argv or the log"
grep -q 'kubectl .*delete pod,configmap,secret agent-relay-index-census-' "$root/log" || fail "the census Secret was not deleted"
census_setup; census absent 0
out=$(run "${args[@]}" 2>&1) || fail "census plan without --rds-setup failed: $out"
grep -q 'create secret generic agent-relay-index-census' "$root/log" && fail "a census without --rds-setup made a credential Secret"
pass "census: --rds-setup refreshes the admin URL first and hands it over in a temporary Secret"

# 49. a login failure names the admin-credential refresh
census_setup; printf 'INDEX_CENSUS_ERROR 28P01 password authentication failed for user "admin"\n' > "$root/census.out"
out=$(run "${args[@]}" 2>&1) && fail "a census login failure was accepted"
grep -q 'If the RDS admin password rotated, refresh the admin inputs first' <<<"$out" || fail "a login failure did not name the refresh: $out"
pass "census: a login failure points at refreshing the admin inputs"

# 50. an upgrade that adds a migrate Job the deployed release lacked says no census ran
setup_mocks "$root/rel-ok" ok; printf '%s\n' "$migrate_job" > "$root/rendered-extra.yaml"
out=$(run "${args[@]}" 2>&1) || fail "plan adding a migrate Job failed: $out"
grep -q 'NOTE: this upgrade adds a HoopDb migrate Job that the deployed release did not have' <<<"$out" || fail "no note for a newly added migrate Job: $out"
setup_mocks "$root/rel-ok" ok
out=$(run "${args[@]}" 2>&1) || fail "plain plan failed: $out"
grep -q 'NOTE: this upgrade adds a HoopDb migrate Job' <<<"$out" && fail "the note printed without a new migrate Job"
pass "census: a newly added migrate Job is called out when no census could run"
