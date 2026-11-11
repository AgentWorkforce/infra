#!/usr/bin/env bash
# Upgrade a self-hosted Agent Relay install to a published release, pulled by
# the customer. Plan-only by default; nothing changes without --apply.
#
#   scripts/selfhost/agent-relay-upgrade.sh --version 2026.11.1 \
#     --registry <account>.dkr.ecr.<region>.amazonaws.com \
#     --values <path to your values.yaml> \
#     [--db-instance <rds-instance-id>] [--context <kube-context>] \
#     [--namespace agent-relay] [--release agent-relay] [--prefix agent-relay/ghcr.io/agentworkforce] \
#     [--apply]
#
# What it does:
#   1. Downloads release agent-relay-<version> from GitHub (release-manifest.json,
#      release-images.values.yaml, SHA256SUMS), checks the checksums and verifies
#      the GitHub build attestation (gh attestation verify).
#   2. Checks out the release's infra commit in a temporary worktree.
#   3. Mirrors exactly the release's image digests into your ECR
#      (scripts/selfhost/mirror-images-to-ecr.sh) and prints the image changes
#      against the running release.
#   With --apply, after you confirm:
#   4. Takes an RDS snapshot of --db-instance and waits for it.
#   5. Runs helm upgrade with your values plus the release's image overlay,
#      waits for the migration Jobs and every Deployment rollout.
#   On a failure it stops and prints the helm rollback command and snapshot id.
#
# Needs: gh, jq, yq, git, helm, kubectl, aws, crane, sha256sum or shasum.
# Credentials come from your normal AWS/kube/gh environment; this script takes
# none on its command line. It only reaches github.com, ghcr.io, your AWS
# account and your cluster.
set -euo pipefail

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$0"; }
die() { printf 'agent-relay-upgrade: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

repo="${AGENT_RELAY_INFRA_REPO:-AgentWorkforce/infra}"
version="" registry="" values="" db_instance="" context="" namespace="agent-relay" release="agent-relay"
prefix="agent-relay/ghcr.io/agentworkforce" apply=false assume_yes=false
while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || die "--version needs a value"; version=$2; shift 2 ;;
    --registry) [ $# -ge 2 ] || die "--registry needs a value"; registry=$2; shift 2 ;;
    --values) [ $# -ge 2 ] || die "--values needs a value"; values=$2; shift 2 ;;
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
[ -n "$registry" ] || die "--registry is required"
[[ "$registry" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com$ ]] || die "--registry must be an ECR registry host"
[ -n "$values" ] && [ -f "$values" ] || die "--values must point to your existing values.yaml"
if $apply && [ -z "$db_instance" ]; then die "--apply needs --db-instance so a snapshot is taken first"; fi
for tool in gh jq yq git helm kubectl; do command -v "$tool" >/dev/null || die "missing tool: $tool"; done
$apply && for tool in aws crane; do command -v "$tool" >/dev/null || die "missing tool: $tool"; done
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

kube=(kubectl -n "$namespace"); helmx=(helm -n "$namespace")
[ -n "$context" ] && { kube+=(--context "$context"); helmx+=(--kube-context "$context"); }

work=$(mktemp -d); trap 'git -C "$work/src" worktree remove --force "$work/tree" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
tag="agent-relay-$version"

say "== 1. Download and verify release $tag"
gh release download "$tag" -R "$repo" -D "$work/rel" \
  -p release-manifest.json -p release-images.values.yaml -p SHA256SUMS >/dev/null \
  || die "could not download release $tag from $repo"
( cd "$work/rel" && sha256 -c SHA256SUMS --ignore-missing >/dev/null ) || die "checksum mismatch in $tag"
for f in release-manifest.json release-images.values.yaml; do
  awk -v f="$f" '{n=$2; sub(/^\*/,"",n)} n==f {found=1} END {exit !found}' "$work/rel/SHA256SUMS" || die "$f is not covered by SHA256SUMS"
  gh attestation verify "$work/rel/$f" --repo "$repo" >/dev/null || die "attestation verification failed for $f"
done
manifest="$work/rel/release-manifest.json"
[ "$(jq -r .schema "$manifest")" = 1 ] || die "unsupported manifest schema"
[ "$(jq -r .version "$manifest")" = "$version" ] || die "manifest version does not match $version"
commit=$(jq -r .infraCommit "$manifest"); [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "manifest infraCommit invalid"
chart_path=$(jq -r .chart.path "$manifest"); [[ "$chart_path" =~ ^charts/[a-z0-9-]+$ ]] || die "manifest chart path invalid"
jq -e '.images|length>0 and all(.[]; (.ref|test("^[a-z0-9.-]+/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$")))' "$manifest" >/dev/null \
  || die "manifest images must all be pinned by digest"
say "   verified: version $version, infra $commit, $(jq '.images|length' "$manifest") images"

say "== 2. Check out infra $commit"
git clone --quiet --filter=blob:none --no-checkout "https://github.com/$repo.git" "$work/src"
git -C "$work/src" worktree add --quiet --detach "$work/tree" "$commit"
chart="$work/tree/$chart_path"
helm dependency build "$chart" >/dev/null
for dep in "$work"/tree/charts/*/; do [ -f "$dep/Chart.lock" ] && helm dependency build "$dep" >/dev/null 2>&1 || true; done

overlay="$work/release-images.values.yaml"
sed "s#__IMAGE_REPO_PREFIX__#${registry}/${prefix}#g" "$work/rel/release-images.values.yaml" > "$overlay"
grep -q '__IMAGE_REPO_PREFIX__' "$overlay" && die "overlay still has an unreplaced prefix"
base=(-f "$chart/values-eks.yaml" -f "$chart/values-eks-native.yaml" -f "$values" -f "$overlay")
for f in "$chart/values-eks.yaml" "$chart/values-eks-native.yaml"; do [ -f "$f" ] || die "release chart is missing ${f#"$work/tree/"}"; done

say "== 3. Mirror release images into $registry and compare"
jq -r '.images[].ref | "---\nimage: \(.)"' "$manifest" > "$work/release-images.rendered.yaml"
mirror=("$work/tree/scripts/selfhost/mirror-images-to-ecr.sh" --registry "$registry" --prefix "${prefix%%/*}" \
  --rendered "$work/release-images.rendered.yaml" --out "$work/mirror.tsv")
if $apply; then "${mirror[@]}" --apply; else "${mirror[@]}"; fi
helm template "$release" "$chart" -n "$namespace" "${base[@]}" > "$work/new.yaml"
grep -oE 'image: *"?[^" ]+' "$work/new.yaml" | sed 's/image: *"\{0,1\}//' | sort -u > "$work/new-images.txt"
"${kube[@]}" get deploy,statefulset,job,cronjob -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{range .spec.jobTemplate.spec.template.spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null \
  | sort -u > "$work/live-images.txt" || true
say "   images added (+) / removed (-) against what is running:"
changes=$(diff "$work/live-images.txt" "$work/new-images.txt" | grep -E '^[<>]' | sed 's/^</   -/;s/^>/   +/' || true)
if [ -n "$changes" ]; then say "$changes"; else say "   (no image changes)"; fi
current_rev=$("${helmx[@]}" history "$release" --max 1 -o json 2>/dev/null | jq -r '.[-1].revision // empty')

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
  [ -n "$current_rev" ] && say "   roll back the release:  helm -n $namespace ${context:+--kube-context $context }rollback $release $current_rev"
  say "   database snapshot:      $snapshot (restore only if a migration damaged data)"
  exit 1
}
trap 'rollback_hint' ERR

say "== 5. helm upgrade $release to $version"
"${helmx[@]}" upgrade "$release" "$chart" "${base[@]}" --wait --wait-for-jobs --timeout 15m
"${kube[@]}" get deploy -o name | while read -r d; do "${kube[@]}" rollout status "$d" --timeout 5m; done
failed=$("${kube[@]}" get jobs -o json | jq -r '[.items[]|select((.status.failed // 0) > 0 and (.status.succeeded // 0) == 0)|.metadata.name]|join(",")')
[ -z "$failed" ] || { say "   failed Jobs: $failed"; false; }
trap - ERR
say ""; say "Upgraded $release to $version (infra $commit). Snapshot kept: $snapshot"
