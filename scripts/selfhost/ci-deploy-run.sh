#!/usr/bin/env bash
# GitHub side of the CI deploy (.github/workflows/selfhost-ci-deploy.yml): build the deploy bundle, hand it to
# the environment's CodeBuild project, stream its log and fetch its report. AWS credentials are the GitHub OIDC
# role of that project (terraform/modules/aws/ci-deploy).
#
#   ci-deploy-run.sh bundle <charts checkout> <tools checkout> <environment dir> <out.tgz>   prints the sha256
#     charts/ comes from the environment's infra commit, scripts/selfhost/ from the deploy tooling's commit.
#   ci-deploy-run.sh start  <project> <bucket> <bundle key> <out.tgz> <report dir> [NAME=VALUE ...]
#
# start uploads the bundle, starts the build with BUNDLE_KEY, BUNDLE_SHA256, RUN_ID and the extra variables,
# prints the build's log until it ends, downloads s3://<bucket>/runs/<RUN_ID>/<plan|apply>/ into <report dir>
# and exits 0 only if the build succeeded. RUN_ID and LOG_GROUP come from the environment.
set -euo pipefail
sha256(){ if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

case "${1:-}" in
  bundle)
    infra=${2:?charts checkout}; tools=${3:?tools checkout}; envdir=${4:?environment dir}; out=${5:?out.tgz}
    [ -f "$envdir/deploy.json" ] || { echo "missing $envdir/deploy.json" >&2; exit 2; }
    stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
    mkdir -p "$stage/infra/scripts"
    cp -R "$infra/charts" "$stage/infra/charts"
    cp -R "$tools/scripts/selfhost" "$stage/infra/scripts/selfhost"
    cp -R "$envdir" "$stage/env"
    find "$stage" \( -name .git -o -name '*.tgz' -path '*/charts/*/charts/*' \) -prune -exec rm -rf {} + 2>/dev/null || true
    # Deterministic: the apply job rebuilds the bundle and must get the digest the plan reviewed.
    tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner --format=gnu -C "$stage" -cf - infra env | gzip -n > "$out"
    sha256 "$out" ;;
  start)
    project=${2:?project}; bucket=${3:?bucket}; key=${4:?bundle key}; bundle=${5:?bundle}; report=${6:?report dir}
    shift 6
    : "${RUN_ID:?RUN_ID}" "${LOG_GROUP:?LOG_GROUP}"
    digest=$(sha256 "$bundle")
    # No --sse: the bucket's default (customer) key applies; naming aws:kms alone would pick aws/s3.
    aws s3 cp --only-show-errors "$bundle" "s3://$bucket/$key"
    vars=$(jq -n --arg k "$key" --arg d "$digest" --arg r "$RUN_ID" \
      '[{name: "BUNDLE_KEY", value: $k}, {name: "BUNDLE_SHA256", value: $d}, {name: "RUN_ID", value: $r}]')
    for kv in "$@"; do
      [[ "$kv" =~ ^[A-Z_][A-Z0-9_]*= ]] || { echo "bad variable $kv" >&2; exit 2; }
      vars=$(jq --arg n "${kv%%=*}" --arg v "${kv#*=}" '. + [{name: $n, value: $v}]' <<<"$vars")
    done
    build=$(aws codebuild start-build --project-name "$project" --environment-variables-override "$vars" \
      --query build.id --output text)
    echo "build $build"
    # A cancelled GitHub job must not leave the deploy running unseen.
    trap 'echo "cancelled: stopping $build" >&2; aws codebuild stop-build --id "$build" >/dev/null; exit 130' INT TERM
    stream=""; token=""; status=IN_PROGRESS
    while :; do
      read -r status stream_now < <(aws codebuild batch-get-builds --ids "$build" \
        --query 'builds[0].[buildStatus, logs.streamName]' --output text)
      [ "$stream_now" != None ] && stream=$stream_now
      if [ -n "$stream" ]; then
        while :; do
          args=(--log-group-name "$LOG_GROUP" --log-stream-name "$stream" --start-from-head --output json)
          [ -n "$token" ] && args+=(--next-token "$token")
          page=$(aws logs get-log-events "${args[@]}" 2>/dev/null) || break
          jq -r '.events[].message' <<<"$page" | sed 's/[[:space:]]*$//'
          next=$(jq -r .nextForwardToken <<<"$page")
          [ "$next" = "$token" ] && break
          token=$next
        done
      fi
      [ "$status" != IN_PROGRESS ] && break
      sleep 15 & wait $!   # wait returns at once on a signal, so the trap runs promptly
    done
    mode=$(aws codebuild batch-get-builds --ids "$build" \
      --query "builds[0].environment.environmentVariables[?name=='CI_DEPLOY_PROJECT_MODE'].value | [0]" --output text)
    trap - INT TERM
    mkdir -p "$report"
    fetched=1
    aws s3 cp --only-show-errors --recursive "s3://$bucket/runs/$RUN_ID/$mode/" "$report/" || fetched=0
    echo "build $build: $status"
    [ "$status" = SUCCEEDED ] || exit 1
    # A successful build always writes its report: without it the outputs (changes, revisions) are unknown.
    [ $fetched = 1 ] && [ -f "$report/log.txt" ] || { echo "build succeeded but its report is missing" >&2; exit 1; } ;;
  *) sed -n '2,12p' "$0" >&2; exit 2 ;;
esac
