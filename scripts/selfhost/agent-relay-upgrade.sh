#!/usr/bin/env bash
# Install or upgrade a self-hosted Agent Relay install to a published release,
# pulled by the customer. Plan-only by default; nothing changes without --apply.
#
#   scripts/selfhost/agent-relay-upgrade.sh --version 2026.11.1 \
#     --registry <account>.dkr.ecr.<region>.amazonaws.com \
#     --profile eks-native --values <your values.yaml> [--values ...] \
#     [--db-instance <rds-instance-id>] [--context <kube-context>] \
#     [--namespace agent-relay] [--release agent-relay] [--prefix agent-relay] \
#     [--first-install] [--rds-setup] [--apply]
#
#   --profile P     the chart profile this install uses, so an upgrade never
#                   switches it. Required. One of:
#                     eks             values-eks.yaml
#                     eks-native      values-eks.yaml + values-eks-native.yaml
#                     eks-rds-native  values-eks.yaml + values-eks-rds-native.yaml
#                                     (implies --rds-setup; needs a release
#                                     whose chart ships that file)
#   --first-install the release does not exist yet: run the documented first
#                   install (helm install, then the migration barrier) instead
#                   of helm upgrade. Refused when the release already exists;
#                   a plain upgrade is refused when it does not.
#   --rds-setup     this install's RDS databases are managed with
#                   scripts/selfhost/rds-setup.sh (next to this script). First
#                   install then runs "rds-setup.sh post" after the HoopDb
#                   migration and restarts the read API, ingest edge and search
#                   indexer; an upgrade runs "rds-setup.sh refresh-admin" and
#                   updates the agent-relay-secrets and search-indexer-owner
#                   Secrets from the rewritten files before helm upgrade.
#                   With --apply it needs AWS_REGION, RDS_HOST and
#                   RDS_ADMIN_SECRET_ARN in the environment, and STATE_DIR
#                   (default $HOME/.agent-relay-install) holding the files
#                   "rds-setup.sh pre" wrote.
#
# What it does:
#   1. Downloads release agent-relay-<version> from GitHub: the packaged chart
#      (dependencies included), release-manifest.json,
#      release-images.values.yaml and SHA256SUMS. It checks every checksum and
#      verifies the GitHub build attestations (gh attestation verify), bound to
#      the release workflow and the release tag.
#   2. Renders the chart with your values plus the release image overlay and
#      checks that every image it would deploy is exactly a release image in
#      your mirror, then prints the image changes against what is running and
#      every rendered resource that differs from the deployed release. The
#      last plan line is "plan: changes=true" or "plan: changes=false".
#   3. Mirrors exactly the release's image digests into your ECR
#      (mirror-images-to-ecr.sh, next to this script).
#   With --apply, after you confirm:
#   4. Takes an RDS snapshot of --db-instance and waits for it.
#   5. Upgrade: [--rds-setup: refresh-admin], helm upgrade, then waits for this
#      release's migration Jobs and Deployments.
#      First install: helm install --no-hooks (no --wait), waits for the HoopDb
#      migrate Job, [--rds-setup: rds-setup.sh post and a restart of the read
#      API, ingest edge and search indexer], then waits for the Deployments.
#   On a failure it stops and prints the helm rollback command (the last
#   successfully deployed revision) and the snapshot id.
#
# Needs: gh, jq, yq, helm, kubectl, tar, sha256sum or shasum; with --apply
# also aws and crane (and openssl and curl with --rds-setup). Network:
# github.com, ghcr.io, your AWS account and your cluster. Credentials come
# from your normal AWS/kube/gh environment; this script takes none on its
# command line.
set -euo pipefail

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$0"; }
die() { printf 'agent-relay-upgrade: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="${AGENT_RELAY_INFRA_REPO:-AgentWorkforce/infra}"
# The only workflow that signs release assets (.github/workflows/release-agent-relay.yml).
signer_workflow="$repo/.github/workflows/release-agent-relay.yml"
version="" registry="" profile="" db_instance="" context="" namespace="agent-relay" release="agent-relay"
prefix="agent-relay" apply=false assume_yes=false first_install=false rds_setup=false values=()
while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || die "--version needs a value"; version=$2; shift 2 ;;
    --registry) [ $# -ge 2 ] || die "--registry needs a value"; registry=$2; shift 2 ;;
    --profile) [ $# -ge 2 ] || die "--profile needs a value"; profile=$2; shift 2 ;;
    --values|-f) [ $# -ge 2 ] || die "$1 needs a value"; values+=("$2"); shift 2 ;;
    --db-instance) [ $# -ge 2 ] || die "--db-instance needs a value"; db_instance=$2; shift 2 ;;
    --context) [ $# -ge 2 ] || die "--context needs a value"; context=$2; shift 2 ;;
    --namespace) [ $# -ge 2 ] || die "--namespace needs a value"; namespace=$2; shift 2 ;;
    --release) [ $# -ge 2 ] || die "--release needs a value"; release=$2; shift 2 ;;
    --prefix) [ $# -ge 2 ] || die "--prefix needs a value"; prefix=$2; shift 2 ;;
    --first-install) first_install=true; shift ;;
    --rds-setup) rds_setup=true; shift ;;
    --apply) apply=true; shift ;;
    --yes) assume_yes=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[[ "$version" =~ ^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$ ]] || die "--version must look like 2026.11.1"
[[ "$registry" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com$ ]] || die "--registry must be an ECR registry host"
[[ "$release" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "--release must be a DNS-1123 label"
case "$profile" in
  eks) overlay_profile=eks; profile_files=(values-eks.yaml) ;;
  eks-native) overlay_profile=eks; profile_files=(values-eks.yaml values-eks-native.yaml) ;;
  # values-eks-rds-native.yaml layers on values-eks.yaml and replaces
  # values-eks-native.yaml; its databases are bootstrapped by rds-setup.sh.
  eks-rds-native) overlay_profile=eks; profile_files=(values-eks.yaml values-eks-rds-native.yaml); rds_setup=true ;;
  *) die "--profile must be eks, eks-native or eks-rds-native (the profile this install already uses)" ;;
esac
[ "${#values[@]}" -gt 0 ] || die "--values must point to your existing values file(s)"
for v in "${values[@]}"; do [ -f "$v" ] || die "values file not found: $v"; done
if $apply && [ -z "$db_instance" ]; then die "--apply needs --db-instance so a snapshot is taken first"; fi
for tool in gh jq yq helm kubectl tar; do command -v "$tool" >/dev/null || die "missing tool: $tool"; done
if $apply; then for tool in aws crane; do command -v "$tool" >/dev/null || die "missing tool: $tool"; done; fi
[ -x "$here/mirror-images-to-ecr.sh" ] || die "mirror-images-to-ecr.sh must sit next to this script"
state_dir="${STATE_DIR:-${HOME:-}/.agent-relay-install}"
if $apply && $rds_setup; then
  [ -x "$here/rds-setup.sh" ] || die "rds-setup.sh must sit next to this script (--rds-setup)"
  for tool in openssl curl; do command -v "$tool" >/dev/null || die "missing tool: $tool"; done
  for var in AWS_REGION RDS_HOST RDS_ADMIN_SECRET_ARN; do
    [ -n "${!var:-}" ] || die "--rds-setup needs $var in the environment (see rds-setup.sh)"
  done
  if $first_install; then
    for p in bulls96_read_api bulls96_session_ingest search_consumer_runtime; do
      [ -s "$state_dir/passwords/$p" ] || die "no rds-setup state under $state_dir: run 'rds-setup.sh pre' first (or set STATE_DIR)"
    done
  else
    for s in agent-relay-secrets search-indexer-owner; do
      [ -d "$state_dir/secret-files/$s" ] || die "no rds-setup credential files under $state_dir/secret-files: set STATE_DIR to the directory 'rds-setup.sh pre' used"
    done
  fi
fi
sha256_of() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }

kube=(kubectl -n "$namespace"); helmx=(helm -n "$namespace")
if [ -n "$context" ]; then kube+=(--context "$context"); helmx+=(--kube-context "$context"); fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
tag="agent-relay-$version"; rel="$work/rel"
verify_attestation() {
  gh attestation verify "$1" --repo "$repo" --signer-workflow "$signer_workflow" \
    --source-ref "refs/tags/$tag" --deny-self-hosted-runners >/dev/null
}

say "== 1. Download and verify release $tag"
gh release download "$tag" -R "$repo" -D "$rel" \
  -p release-manifest.json -p release-images.values.yaml -p SHA256SUMS -p '*.tgz' >/dev/null \
  || die "could not download release $tag from $repo"
verify_attestation "$rel/SHA256SUMS" || die "attestation verification failed for SHA256SUMS"
manifest="$rel/release-manifest.json"
chart_version=$(jq -r '.chart.version // empty' "$manifest" 2>/dev/null || true)
[[ "$chart_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || die "manifest chart version invalid"
package="agent-relay-${chart_version}.tgz"
for f in release-manifest.json release-images.values.yaml "$package"; do
  [ -f "$rel/$f" ] || die "release is missing $f"
  want=$(awk -v f="$f" '{n=$2; sub(/^\*/,"",n)} n==f {print $1; exit}' "$rel/SHA256SUMS")
  [ -n "$want" ] || die "$f is not covered by SHA256SUMS"
  [ "$(sha256_of "$rel/$f")" = "$want" ] || die "checksum mismatch for $f"
done
for f in release-manifest.json release-images.values.yaml; do
  verify_attestation "$rel/$f" || die "attestation verification failed for $f"
done
[ "$(jq -r .schema "$manifest")" = 1 ] || die "unsupported manifest schema"
[ "$(jq -r .version "$manifest")" = "$version" ] || die "manifest version does not match $version"
[ "$(jq -r '.valuesOverlayProfile // empty' "$manifest")" = "$overlay_profile" ] \
  || die "release image overlay is not for the selected profile"
commit=$(jq -r .infraCommit "$manifest"); [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "manifest infraCommit invalid"
jq -e '.images|length>0 and all(.[]; (.ref|test("^[a-z0-9.-]+/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$")))' "$manifest" >/dev/null \
  || die "manifest images must all be pinned by digest"
mkdir "$work/chart"; tar -xzf "$rel/$package" -C "$work/chart"
chart="$work/chart/agent-relay"
[ -f "$chart/Chart.yaml" ] || die "release chart package has no agent-relay chart"
[ "$(yq -r .version "$chart/Chart.yaml")" = "$chart_version" ] || die "packaged chart version does not match the release ($chart_version)"
for f in "${profile_files[@]}"; do
  [ -f "$chart/$f" ] || die "release $version (chart $chart_version) does not ship $f, so it cannot serve --profile $profile; choose a release that includes it"
done
say "   verified: version $version, infra $commit, chart $chart_version, $(jq '.images|length' "$manifest") images"

say "== 2. Render and check images"
release_selector="app.kubernetes.io/instance=$release"
releases=$("${helmx[@]}" list --all --filter "^${release}\$" -o json) \
  || die "could not list Helm releases in $namespace, so whether $release exists is unknown"
existing=$(jq -r --arg r "$release" '[.[]? | select(.name == $r) | .status] | first // empty' <<<"${releases:-[]}")
if $first_install && [ -n "$existing" ]; then
  die "release $release already exists in $namespace (status $existing); --first-install is only for a new install"
fi
if ! $first_install && [ -z "$existing" ]; then
  die "release $release does not exist in $namespace; use --first-install for a new install"
fi
overlay="$work/release-images.values.yaml"
# Overlay repositories are __IMAGE_MIRROR_ROOT__/<source host>/<source path>, exactly where
# mirror-images-to-ecr.sh copies each image.
sed "s#__IMAGE_MIRROR_ROOT__#${registry}/${prefix}#g" "$rel/release-images.values.yaml" > "$overlay"
if grep -q '__IMAGE_' "$overlay"; then die "overlay still has an unreplaced placeholder"; fi
base=()
for f in "${profile_files[@]}"; do base+=(-f "$chart/$f"); done
for v in "${values[@]}"; do base+=(-f "$v"); done
base+=(-f "$overlay")
render=(helm template "$release" "$chart" -n "$namespace")
if ! $first_install; then render+=(--is-upgrade); fi
"${render[@]}" "${base[@]}" > "$work/new.yaml"
yq -N -r '.. | select(tag == "!!map") | select(has("image") or has("imageName")) | (.image // .imageName) | select(tag == "!!str")' \
  "$work/new.yaml" | sort -u > "$work/new-images.txt"
jq -r --arg root "${registry}/${prefix}" '.images[].ref | "\($root)/\(.)"' "$manifest" | sort -u > "$work/expected-images.txt"
unexpected=$(comm -23 "$work/new-images.txt" "$work/expected-images.txt")
[ -z "$unexpected" ] || die "the render would deploy images that are not this release's mirrored images:
$unexpected"
[ -s "$work/new-images.txt" ] || die "the render contains no images"
if ! $rds_setup; then
  db_mode=""
  for f in "${profile_files[@]/#/$chart/}" "${values[@]}"; do
    m=$(yq -r '.["sessions-pipeline"].worker.migrations.databaseMode // ""' "$f" 2>/dev/null || true)
    [ -z "$m" ] || db_mode=$m
  done
  if [ "$db_mode" = rds ]; then
    say "   NOTE: these values select databaseMode rds. If the databases were bootstrapped with"
    say "         rds-setup.sh, add --rds-setup (post on first install, refresh-admin on upgrade)."
  fi
fi
"${kube[@]}" get deploy,statefulset,job,cronjob -l "$release_selector" -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{range .spec.jobTemplate.spec.template.spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null \
  | sort -u > "$work/live-images.txt" || true
say "   images added (+) / removed (-) against what is running:"
changes=$(diff "$work/live-images.txt" "$work/new-images.txt" | grep -E '^[<>]' | sed 's/^</   -/;s/^>/   +/' || true)
if [ -n "$changes" ]; then say "$changes"; else say "   (no image changes)"; fi
current_rev=$("${helmx[@]}" history "$release" -o json 2>/dev/null | jq -r '[.[]|select(.status=="deployed")]|last.revision // empty' || true)

# One line per rendered resource: "<kind>/<namespace>/<name><TAB><canonical JSON>".
normalize() {
  yq -o=json -I=0 'sort_keys(..)' "$1" \
    | jq -r 'select(type == "object" and .kind != null) | "\(.kind)/\(.metadata.namespace // "")/\(.metadata.name)\t\(tojson)"' \
    | LC_ALL=C sort
}
if $first_install; then
  say "   first install: every rendered resource is new"
  plan_changes=true
else
  { "${helmx[@]}" get manifest "$release"; printf '\n---\n'; "${helmx[@]}" get hooks "$release"; } > "$work/live.yaml" \
    || die "could not read the deployed manifest of $release"
  normalize "$work/live.yaml" > "$work/live.tsv"; normalize "$work/new.yaml" > "$work/new.tsv"
  cut -f1 "$work/live.tsv" > "$work/live.keys"; cut -f1 "$work/new.tsv" > "$work/new.keys"
  LC_ALL=C comm -3 "$work/live.tsv" "$work/new.tsv" | awk -F'\t' '{print ($1 == "" ? $2 : $1)}' \
    | LC_ALL=C sort -u > "$work/diff.keys"
  say "   rendered resources changed (~) / added (+) / removed (-) against the deployed release:"
  if [ -s "$work/diff.keys" ]; then
    awk 'FILENAME == ARGV[1] {l[$0] = 1; next} FILENAME == ARGV[2] {n[$0] = 1; next}
         {print (($0 in l) && ($0 in n) ? "   ~ " : ($0 in n) ? "   + " : "   - ") $0}' \
      "$work/live.keys" "$work/new.keys" "$work/diff.keys"
    plan_changes=true
  else
    say "   (no manifest changes)"
    plan_changes=false
  fi
fi
say "plan: changes=$plan_changes"

say "== 3. Mirror release images into $registry"
jq -r '.images[].ref | "---\nimage: \(.)"' "$manifest" > "$work/release-images.rendered.yaml"
mirror=("$here/mirror-images-to-ecr.sh" --registry "$registry" --prefix "$prefix" \
  --rendered "$work/release-images.rendered.yaml" --out "$work/mirror.tsv")
if $apply; then "${mirror[@]}" --apply; else "${mirror[@]}"; fi

if ! $apply; then
  say ""; say "Plan only. Re-run with --apply --db-instance <id> to snapshot and $($first_install && echo install || echo upgrade)."
  exit 0
fi
if $first_install; then action="Install new release"; else action="Upgrade release"; fi
if ! $assume_yes; then
  printf '%s %s in %s to %s? Type the version to continue: ' "$action" "$release" "$namespace" "$version"
  read -r answer; [ "$answer" = "$version" ] || die "not confirmed; nothing changed"
fi
if $rds_setup && ! $first_install; then
  "${kube[@]}" get secret agent-relay-secrets search-indexer-owner -o name >/dev/null \
    || die "--rds-setup upgrade needs the agent-relay-secrets and search-indexer-owner Secrets in $namespace; nothing changed"
fi

say "== 4. RDS snapshot of $db_instance"
snapshot="agent-relay-pre-${version//./-}-$(date -u +%Y%m%d%H%M%S)"
aws rds create-db-snapshot --db-instance-identifier "$db_instance" --db-snapshot-identifier "$snapshot" >/dev/null
aws rds wait db-snapshot-available --db-snapshot-identifier "$snapshot"
say "   snapshot $snapshot is available"

rollback_hint() {
  say ""; say "$($first_install && echo INSTALL || echo UPGRADE) FAILED. Nothing further was changed."
  if [ -n "$current_rev" ]; then
    say "   roll back the release:  helm -n $namespace ${context:+--kube-context $context }rollback $release $current_rev"
  elif $first_install; then
    say "   the new release has no earlier revision; inspect its Jobs and Pods before retrying"
  fi
  say "   database snapshot:      $snapshot (restore only if a migration damaged data)"
  exit 1
}
trap 'rollback_hint' ERR

# rds-setup.sh reads its inputs from the environment (never argv).
rds_env=(env NAMESPACE="$namespace" KUBE_CONTEXT="$context" STATE_DIR="$state_dir")
mirrored_ref() { jq -r --arg n "$1" --arg root "${registry}/${prefix}" '[.images[] | select(.name == $n) | "\($root)/\(.ref)"] | first // empty' "$manifest"; }

if $first_install; then
  say "== 5. helm install $release at $version"
  "${helmx[@]}" install "$release" "$chart" "${base[@]}" --create-namespace --no-hooks --timeout 20m
  migration_job=$("${helmx[@]}" get manifest "$release" \
    | yq -N -r 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate") | .metadata.name')
  if [ -n "$migration_job" ]; then
    [[ "$migration_job" != *$'\n'* ]] || { say "   expected exactly one current HoopDb migrate Job"; false; }
    say "   waiting for HoopDb migrate Job $migration_job"
    "${kube[@]}" wait --for=condition=complete "job/$migration_job" --timeout=20m
  elif $rds_setup; then
    say "   the release renders no HoopDb migrate Job, so rds-setup.sh post has no migration evidence"; false
  fi
  if $rds_setup; then
    say "== 6. rds-setup.sh post, then restart the read API, ingest edge and search indexer"
    services_image=$(mirrored_ref sessions-pipeline)
    [ -n "$services_image" ] || { say "   the release manifest has no sessions-pipeline image"; false; }
    psql_image=$(mirrored_ref sessions-migration-postgresql)
    rds_env+=(RELEASE="$release" MIGRATION_JOB="$migration_job" SERVICES_IMAGE="$services_image")
    if [ -n "$psql_image" ]; then rds_env+=(PSQL_IMAGE="$psql_image"); fi
    "${rds_env[@]}" "$here/rds-setup.sh" post
    "${kube[@]}" rollout restart "deployment/$release-read-api" "deployment/$release-ingest-edge" \
      "deployment/$release-search-indexer"
  fi
else
  if $rds_setup; then
    say "== 5. rds-setup.sh refresh-admin, then update the admin-derived Secret keys"
    "${rds_env[@]}" "$here/rds-setup.sh" refresh-admin
    for pair in agent-relay-secrets:HOOPDB_MIGRATION_URL search-indexer-owner:RELAYHISTORY_PIPELINE_CONSUMER_SECRET; do
      s=${pair%%:*}; k=${pair#*:}; src="$state_dir/secret-files/$s/$k"
      [ -s "$src" ] || { say "   refresh-admin did not write $s/$k"; false; }
      # A merge patch replaces only this key; the value goes through a 0600 file, never argv.
      ( umask 077; printf '{"data":{"%s":"%s"}}' "$k" "$(base64 < "$src" | tr -d '\n')" > "$work/patch.json" )
      "${kube[@]}" patch secret "$s" --type merge --patch-file "$work/patch.json" >/dev/null
      rm -f "$work/patch.json"
      say "   updated Secret $s key $k"
    done
  fi
  say "== $($rds_setup && echo 6 || echo 5). helm upgrade $release to $version"
  "${helmx[@]}" upgrade "$release" "$chart" "${base[@]}" --wait --wait-for-jobs --timeout 15m
fi
"${kube[@]}" get deploy -l "$release_selector" -o name | while read -r d; do "${kube[@]}" rollout status "$d" --timeout 20m; done
failed=$("${kube[@]}" get jobs -l "$release_selector" -o json | jq -r '[.items[]|select((.status.failed // 0) > 0 and (.status.succeeded // 0) == 0)|.metadata.name]|join(",")')
[ -z "$failed" ] || { say "   failed Jobs: $failed"; false; }
trap - ERR
if $first_install; then
  say ""; say "Installed $release at $version (infra $commit, chart $chart_version). Snapshot kept: $snapshot"
else
  say ""; say "Upgraded $release to $version (infra $commit, chart $chart_version). Snapshot kept: $snapshot"
fi
