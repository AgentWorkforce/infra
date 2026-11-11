#!/usr/bin/env bash
# Golden check for the default (subdomain) renders: single-host mode is opt-in
# (global.singleHost.host), so with it off every profile below must render
# exactly what it rendered before single-host mode existed.
#
#   ci/agent-relay/subdomain-golden.sh check        compare with subdomain-golden.sha256
#                                                   (skipped outside CI unless Helm is
#                                                   lint.yml's HELM_VERSION)
#   ci/agent-relay/subdomain-golden.sh update       rewrite subdomain-golden.sha256
#                                                   (needs that Helm version)
#   ci/agent-relay/subdomain-golden.sh diff <ref>   render <ref> in a temporary
#                                                   worktree and diff every profile
#
# Renders are normalized only for the helm.sh/chart label (<chart>-<version>),
# which changes with every chart version bump. Everything else is compared
# byte for byte. A deliberate change to a default render updates the hashes
# (`update`) and says why in the PR; `diff origin/main` shows what moved.
set -euo pipefail
cd "$(dirname "$0")/../.."
here=ci/agent-relay
golden=$here/subdomain-golden.sha256

da_digest() { printf 'sha256:%s' "$(printf "$1%.0s" $(seq 64))"; }
profiles() { # name|helm template args (word-split on spaces)
  local p=charts/agent-relay
  cat <<P
gcp|ar $p -n agent-relay -f $p/values-gcp.yaml
gcp-supported-100|ar $p -n agent-relay -f $p/values-gcp.yaml -f $p/values-gcp-supported-100.yaml
gcp-proof|proof $p -n agent-relay -f $p/values-gcp-proof.yaml -f $p/ci/gcp-proof-values.yaml
gcp-proof-live|proof $p -n agent-relay -f $p/values-gcp-proof.yaml -f $p/values-gcp-proof-live.yaml --set relay-control.image.digest=sha256:2222222222222222222222222222222222222222222222222222222222222222
gcp-proof-flows|proof $p -n agent-relay -f $p/values-gcp-proof.yaml -f $p/ci/gcp-proof-values.yaml -f $p/values-gcp-proof-flows.yaml
gcp-durable-actors|agent-relay $p -n agent-relay -f $p/values-gcp-proof.yaml -f $p/values-gcp-proof-live.yaml -f $p/values-gcp-proof-durable-actors.yaml -f $p/values-gcp-proof-relayfile.yaml --set relaycast.runtime.durableActors.gateway.image.digest=$(da_digest a) --set relaycast.runtime.durableActors.deployer.image.digest=$(da_digest b) --set relayfile.runtime.durableActors.image.digest=$(da_digest c) --set relayfile.runtime.durableActors.workspaceImage.digest=$(da_digest d)
kind-durable-actors|agent-relay $p -n agent-relay -f ci/agent-relay/kind-durable-actors-values.yaml
eks-rds-native|proof $p -n agent-relay-placeholder -f $p/values-eks.yaml -f $p/values-eks-rds-native.yaml
relay-control|ci charts/relay-control -n ci -f charts/relay-control/ci/default-values.yaml
relay-webapp|ci charts/relay-webapp -n ci -f charts/relay-webapp/ci/default-values.yaml
P
}
render_all() { # root outdir
  local root=$1 out=$2 name args previous arg missing
  mkdir -p "$out"
  ( cd "$root"
    helm dependency build charts/sessions-pipeline >/dev/null
    helm dependency build charts/agent-relay >/dev/null
    profiles | while IFS='|' read -r name args; do
      # A profile introduced after the comparison ref has no values file in the
      # detached base worktree. Skip only that base render; diff then reports
      # the profile as a new file while still comparing every older profile.
      previous=""; missing=false
      for arg in $args; do
        if [ "$previous" = -f ] && [ ! -f "$arg" ]; then
          echo "::notice::skipping $name under $root: missing $arg" >&2
          missing=true
          break
        fi
        previous=$arg
      done
      $missing && continue
      # shellcheck disable=SC2086
      helm template $args --no-hooks \
        | sed -E 's/^([[:space:]]*helm\.sh\/chart: "?)([a-z0-9-]+)-[0-9]+\.[0-9]+\.[0-9]+[^"[:space:]]*/\1\2-VERSION/' >"$out/$name.yaml"
    done )
}

# Helm's output differs between releases, so the hashes are tied to the Helm
# version CI pins (lint.yml HELM_VERSION), recorded on the first line.
helm_line="# helm $(helm version --template '{{ .Version }}')"
want_helm=$(sed -n 's/^  HELM_VERSION: *//p' .github/workflows/lint.yml)

mode=${1:-check}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
case $mode in
  check|update)
    if [ "$helm_line" != "# helm $want_helm" ]; then
      msg="hashes are for Helm $want_helm (lint.yml HELM_VERSION), this is ${helm_line#\# helm }"
      [ "$mode" = check ] && [ -z "${CI:-}" ] && { echo "::warning::$msg; skipping (use: $0 diff origin/main)"; exit 0; }
      echo "::error::$msg" >&2; exit 1
    fi
    render_all . "$tmp/head"
    { echo "$helm_line"; ( cd "$tmp/head" && sha256sum -- *.yaml | sort -k2 ); } >"$tmp/head.sha256"
    if [ "$mode" = update ]; then cp "$tmp/head.sha256" "$golden"; echo "wrote $golden"; exit 0; fi
    if ! diff -u "$golden" "$tmp/head.sha256"; then
      echo "::error::a default (subdomain) render changed; if that is intended run $0 update and explain it in the PR ($0 diff origin/main shows the change)"
      exit 1
    fi
    echo "subdomain renders match $golden" ;;
  diff)
    ref=${2:?usage: $0 diff <ref>}
    git worktree add --detach -q "$tmp/base" "$ref"
    trap 'git worktree remove --force "$tmp/base" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
    # Profiles are defined here, so render the base with this script's list.
    render_all "$tmp/base" "$tmp/base-out"
    render_all . "$tmp/head"
    diff -ru "$tmp/base-out" "$tmp/head" && echo "subdomain renders are byte-identical to $ref (helm.sh/chart version normalized)" ;;
  *) echo "usage: $0 check|update|diff <ref>" >&2; exit 2 ;;
esac
