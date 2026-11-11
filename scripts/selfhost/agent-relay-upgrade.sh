#!/usr/bin/env bash
# Upgrade a self-hosted Agent Relay install to a published release, pulled by
# the customer. Plan-only by default; nothing changes without --apply.
#
#   scripts/selfhost/agent-relay-upgrade.sh --version 2026.11.1 \
#     --registry <account>.dkr.ecr.<region>.amazonaws.com \
#     --profile eks-native --values <your values.yaml> [--values ...] \
#     [--db-instance <rds-instance-id>] [--context <kube-context>] \
#     [--namespace agent-relay] [--release agent-relay] [--prefix agent-relay] \
#     [--apply]
#
#   --profile P   the chart profile this install uses, so an upgrade never
#                 switches it: eks (values-eks.yaml) or eks-native
#                 (values-eks.yaml + values-eks-native.yaml). Required.
#
# What it does:
#   1. Downloads release agent-relay-<version> from GitHub: the packaged chart
#      (dependencies included), release-manifest.json,
#      release-images.values.yaml and SHA256SUMS. It checks every checksum and
#      verifies the GitHub build attestations (gh attestation verify).
#   2. Renders the chart with your values plus the release image overlay and
#      checks that every image it would deploy is exactly a release image in
#      your mirror, then prints the image changes against what is running.
#   3. Mirrors exactly the release's image digests into your ECR
#      (mirror-images-to-ecr.sh, next to this script).
#   With --apply, after you confirm:
#   4. Takes an RDS snapshot of --db-instance and waits for it.
#   5. Runs helm upgrade, then waits for this release's migration Jobs and
#      Deployments.
#   On a failure it stops and prints the helm rollback command (the last
#   successfully deployed revision) and the snapshot id.
#
# Needs: gh, jq, yq, helm, kubectl, tar, sha256sum or shasum; with --apply
# also aws and crane. Network: github.com, ghcr.io, your AWS account and your
# cluster. Credentials come from your normal AWS/kube/gh environment; this
# script takes none on its command line.
set -euo pipefail

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$0"; }
die() { printf 'agent-relay-upgrade: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="${AGENT_RELAY_INFRA_REPO:-AgentWorkforce/infra}"
version="" registry="" profile="" db_instance="" context="" namespace="agent-relay" release="agent-relay"
prefix="agent-relay" apply=false assume_yes=false values=()
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
    --apply) apply=true; shift ;;
    --yes) assume_yes=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[[ "$version" =~ ^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$ ]] || die "--version must look like 2026.11.1"
[[ "$registry" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com$ ]] || die "--registry must be an ECR registry host"
case "$profile" in
  eks) overlay_profile=eks; profile_files=(values-eks.yaml) ;;
  eks-native) overlay_profile=eks; profile_files=(values-eks.yaml values-eks-native.yaml) ;;
  *) die "--profile must be eks or eks-native (the profile this install already uses)" ;;
esac
[ "${#values[@]}" -gt 0 ] || die "--values must point to your existing values file(s)"
for v in "${values[@]}"; do [ -f "$v" ] || die "values file not found: $v"; done
if $apply && [ -z "$db_instance" ]; then die "--apply needs --db-instance so a snapshot is taken first"; fi
for tool in gh jq yq helm kubectl tar; do command -v "$tool" >/dev/null || die "missing tool: $tool"; done
if $apply; then for tool in aws crane; do command -v "$tool" >/dev/null || die "missing tool: $tool"; done; fi
[ -x "$here/mirror-images-to-ecr.sh" ] || die "mirror-images-to-ecr.sh must sit next to this script"
sha256_of() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }

kube=(kubectl -n "$namespace"); helmx=(helm -n "$namespace")
if [ -n "$context" ]; then kube+=(--context "$context"); helmx+=(--kube-context "$context"); fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
tag="agent-relay-$version"; rel="$work/rel"

say "== 1. Download and verify release $tag"
gh release download "$tag" -R "$repo" -D "$rel" \
  -p release-manifest.json -p release-images.values.yaml -p SHA256SUMS -p '*.tgz' >/dev/null \
  || die "could not download release $tag from $repo"
gh attestation verify "$rel/SHA256SUMS" --repo "$repo" >/dev/null || die "attestation verification failed for SHA256SUMS"
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
  gh attestation verify "$rel/$f" --repo "$repo" >/dev/null || die "attestation verification failed for $f"
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
say "   verified: version $version, infra $commit, chart $chart_version, $(jq '.images|length' "$manifest") images"

say "== 2. Render and check images"
overlay="$work/release-images.values.yaml"
# Overlay repositories are __IMAGE_MIRROR_ROOT__/<source host>/<source path>, exactly where
# mirror-images-to-ecr.sh copies each image.
sed "s#__IMAGE_MIRROR_ROOT__#${registry}/${prefix}#g" "$rel/release-images.values.yaml" > "$overlay"
if grep -q '__IMAGE_' "$overlay"; then die "overlay still has an unreplaced placeholder"; fi
base=()
for f in "${profile_files[@]}"; do [ -f "$chart/$f" ] || die "release chart is missing $f"; base+=(-f "$chart/$f"); done
for v in "${values[@]}"; do base+=(-f "$v"); done
base+=(-f "$overlay")
helm template "$release" "$chart" -n "$namespace" "${base[@]}" > "$work/new.yaml"
yq -N -r '.. | select(tag == "!!map") | select(has("image") or has("imageName")) | (.image // .imageName) | select(tag == "!!str")' \
  "$work/new.yaml" | sort -u > "$work/new-images.txt"
jq -r --arg root "${registry}/${prefix}" '.images[].ref | "\($root)/\(.)"' "$manifest" | sort -u > "$work/expected-images.txt"
unexpected=$(comm -23 "$work/new-images.txt" "$work/expected-images.txt")
[ -z "$unexpected" ] || die "the render would deploy images that are not this release's mirrored images:
$unexpected"
[ -s "$work/new-images.txt" ] || die "the render contains no images"
release_selector="app.kubernetes.io/instance=$release"
"${kube[@]}" get deploy,statefulset,job,cronjob -l "$release_selector" -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{range .spec.jobTemplate.spec.template.spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null \
  | sort -u > "$work/live-images.txt" || true
say "   images added (+) / removed (-) against what is running:"
changes=$(diff "$work/live-images.txt" "$work/new-images.txt" | grep -E '^[<>]' | sed 's/^</   -/;s/^>/   +/' || true)
if [ -n "$changes" ]; then say "$changes"; else say "   (no image changes)"; fi
current_rev=$("${helmx[@]}" history "$release" -o json 2>/dev/null | jq -r '[.[]|select(.status=="deployed")]|last.revision // empty' || true)

say "== 3. Mirror release images into $registry"
jq -r '.images[].ref | "---\nimage: \(.)"' "$manifest" > "$work/release-images.rendered.yaml"
mirror=("$here/mirror-images-to-ecr.sh" --registry "$registry" --prefix "$prefix" \
  --rendered "$work/release-images.rendered.yaml" --out "$work/mirror.tsv")
if $apply; then "${mirror[@]}" --apply; else "${mirror[@]}"; fi

if ! $apply; then
  say ""; say "Plan only. Re-run with --apply --db-instance <id> to snapshot and upgrade."
  exit 0
fi
if ! $assume_yes; then
  printf 'Upgrade release %s in %s to %s? Type the version to continue: ' "$release" "$namespace" "$version"
  read -r answer; [ "$answer" = "$version" ] || die "not confirmed; nothing changed"
fi

say "== 4. RDS snapshot of $db_instance"
snapshot="agent-relay-pre-${version//./-}-$(date -u +%Y%m%d%H%M%S)"
aws rds create-db-snapshot --db-instance-identifier "$db_instance" --db-snapshot-identifier "$snapshot" >/dev/null
aws rds wait db-snapshot-available --db-snapshot-identifier "$snapshot"
say "   snapshot $snapshot is available"

rollback_hint() {
  say ""; say "UPGRADE FAILED. Nothing further was changed."
  if [ -n "$current_rev" ]; then
    say "   roll back the release:  helm -n $namespace ${context:+--kube-context $context }rollback $release $current_rev"
  fi
  say "   database snapshot:      $snapshot (restore only if a migration damaged data)"
  exit 1
}
trap 'rollback_hint' ERR

say "== 5. helm upgrade $release to $version"
"${helmx[@]}" upgrade "$release" "$chart" "${base[@]}" --wait --wait-for-jobs --timeout 15m
"${kube[@]}" get deploy -l "$release_selector" -o name | while read -r d; do "${kube[@]}" rollout status "$d" --timeout 5m; done
failed=$("${kube[@]}" get jobs -l "$release_selector" -o json | jq -r '[.items[]|select((.status.failed // 0) > 0 and (.status.succeeded // 0) == 0)|.metadata.name]|join(",")')
[ -z "$failed" ] || { say "   failed Jobs: $failed"; false; }
trap - ERR
say ""; say "Upgraded $release to $version (infra $commit, chart $chart_version). Snapshot kept: $snapshot"
