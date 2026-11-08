#!/usr/bin/env bash
# Mirror the images an environment's chart render pins into that environment's
# ECR. Default off: without --apply this prints the plan and contacts nothing.
#
#   scripts/selfhost/mirror-images-to-ecr.sh \
#     --registry <account>.dkr.ecr.<region>.amazonaws.com \
#     -f <environment-values.yaml> [-f ...] [--out mapping.tsv] [--apply]
#
#   --registry HOST   the target ECR registry (required)
#   -f, --values F    values for `helm template` of charts/agent-relay (repeatable)
#   --chart DIR       chart to render instead of charts/agent-relay
#   --rendered F      already-rendered manifests, instead of rendering
#   --prefix P        ECR repository prefix (default agent-relay)
#   --out F           write the source-to-mirror mapping (TSV) to F
#   --apply           create repositories and copy images
#
# Repositories are named <prefix>/<source host>/<source path>, with immutable
# tags and scan-on-push. A digest-pinned image is copied under the tag
# sha256-<digest> and verified by digest; a tag-pinned image keeps its tag.
# Mutable or unpinned references are refused. Applying needs aws and crane, and
# changes the account: repositories and images, nothing else. After a copy,
# set each chart's image repository and digest to the mapping's mirror; this
# script does not edit values. Private sources need credentials in DOCKER_CONFIG.
set -euo pipefail

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$0"; }
die() { printf 'mirror-images-to-ecr: %s\n' "$*" >&2; exit 1; }

registry="" prefix="agent-relay" chart="" rendered="" out="" apply=false
values=()
while [ $# -gt 0 ]; do
  case "$1" in
    --registry) [ $# -ge 2 ] || die "--registry needs a value"; registry=$2; shift 2 ;;
    -f|--values) [ $# -ge 2 ] || die "$1 needs a value"; values+=("$2"); shift 2 ;;
    --chart) [ $# -ge 2 ] || die "--chart needs a value"; chart=$2; shift 2 ;;
    --rendered) [ $# -ge 2 ] || die "--rendered needs a value"; rendered=$2; shift 2 ;;
    --prefix) [ $# -ge 2 ] || die "--prefix needs a value"; prefix=$2; shift 2 ;;
    --out) [ $# -ge 2 ] || die "--out needs a value"; out=$2; shift 2 ;;
    --apply) apply=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ "$registry" =~ ^[0-9]{12}\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com$ ]] ||
  die "--registry must be <account>.dkr.ecr.<region>.amazonaws.com"
region=${BASH_REMATCH[1]}
[[ "$prefix" =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]] || die "--prefix is not a valid ECR repository prefix"
if [ -n "$rendered" ]; then
  [ -z "$chart" ] && [ "${#values[@]}" -eq 0 ] || die "--rendered replaces --chart and --values"
  [ -f "$rendered" ] || die "--rendered file not found: $rendered"
fi
command -v yq >/dev/null 2>&1 || die "yq is required"

manifests() {
  if [ -n "$rendered" ]; then
    cat "$rendered"
    return
  fi
  command -v helm >/dev/null 2>&1 || die "helm is required"
  local root args=() v
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
  for v in ${values[@]+"${values[@]}"}; do args+=(-f "$v"); done
  helm template agent-relay "${chart:-$root/charts/agent-relay}" ${args[@]+"${args[@]}"}
}

images=$(manifests |
  yq -r '.. | select(tag == "!!map") | select(has("image") or has("imageName")) | (.image // .imageName) | select(tag == "!!str")' |
  sort -u)
[ -n "$images" ] || die "the render contains no images"

plan=$(mktemp)
mapping="" own_docker_config=""
cleanup() {
  rm -f "$plan" ${mapping:+"$mapping"}
  [ -z "$own_docker_config" ] || rm -rf "$own_docker_config"
}
trap cleanup EXIT

# source, destination repository, destination tag, pinned digest (empty for a tag pin)
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  name=$ref digest="" tag=""
  case "$name" in
    *@sha256:*)
      digest=${name##*@}
      name=${name%@*}
      [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || die "malformed digest: $ref"
      ;;
    *@*) die "unsupported digest algorithm: $ref" ;;
  esac
  if [[ ${name##*/} == *:* ]]; then
    tag=${name##*:}
    name=${name%:*}
  fi
  if [ -z "$digest" ] && { [ -z "$tag" ] || [ "$tag" = latest ]; }; then
    die "refusing an unpinned image: $ref"
  fi
  first=${name%%/*}
  if [[ $name == */* && ( $first == *.* || $first == *:* || $first == localhost ) ]]; then
    host=$first path=${name#*/}
  else
    host=docker.io path=$name
    [[ $path == */* ]] || path=library/$path
  fi
  repository="$prefix/$host/$path"
  [[ "$repository" =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]] || die "image does not map to a valid ECR repository name: $ref"
  if [ -n "$digest" ]; then dest_tag=sha256-${digest#sha256:}; else dest_tag=$tag; fi
  printf '%s\t%s\t%s\t%s\n' "$ref" "$repository" "$dest_tag" "$digest" >>"$plan"
done <<<"$images"

if [ "$apply" != true ]; then
  while IFS=$'\t' read -r ref repository dest_tag digest; do
    printf '%s\t%s/%s:%s\n' "$ref" "$registry" "$repository" "$dest_tag"
  done <"$plan"
  printf 'mirror-images-to-ecr: dry run, %s images; re-run with --apply to copy them\n' "$(wc -l <"$plan" | tr -d ' ')" >&2
  exit 0
fi

command -v aws >/dev/null 2>&1 || die "aws is required for --apply"
command -v crane >/dev/null 2>&1 || die "crane is required for --apply"

if [ -z "${DOCKER_CONFIG:-}" ]; then
  own_docker_config=$(mktemp -d)
  export DOCKER_CONFIG=$own_docker_config
fi
aws ecr get-login-password --region "$region" |
  crane auth login "$registry" --username AWS --password-stdin >/dev/null

mapping=$(mktemp)
while IFS=$'\t' read -r ref repository dest_tag digest; do
  if ! aws ecr describe-repositories --region "$region" --repository-names "$repository" >/dev/null 2>&1; then
    aws ecr create-repository --region "$region" --repository-name "$repository" \
      --image-tag-mutability IMMUTABLE \
      --image-scanning-configuration scanOnPush=true >/dev/null
  fi
  source_digest=$(crane digest "$ref")
  [ -z "$digest" ] || [ "$source_digest" = "$digest" ] || die "source digest differs from its pin: $ref"
  dest="$registry/$repository:$dest_tag"
  existing=$(crane digest "$dest" 2>/dev/null || true)
  if [ -z "$existing" ]; then
    crane copy "$ref" "$dest" >/dev/null
  elif [ "$existing" != "$source_digest" ]; then
    die "destination tag already holds a different image: $dest"
  fi
  copied=$(crane digest "$dest")
  [ "$copied" = "$source_digest" ] || die "copy did not preserve the digest: $dest"
  printf '%s\t%s/%s@%s\n' "$ref" "$registry" "$repository" "$copied" | tee -a "$mapping"
done <"$plan"
[ -z "$out" ] || cp "$mapping" "$out"
