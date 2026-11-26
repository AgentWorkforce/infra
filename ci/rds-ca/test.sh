#!/usr/bin/env bash
# Render assertions for the chart-managed RDS CA (global.rdsCa). Offline.
#
#   ci/rds-ca/test.sh
#
# Cases: off by default; a region bundle; the global bundle; a component that
# keeps its own CA; contradictions that must fail; values written before
# global.rdsCa (explicit rds-ca ConfigMap and hashes) rendering unchanged; the
# shared helper copies, the bundle files and the Helm release size.
set -euo pipefail
cd "$(dirname "$0")/../.."

fail=0; n=0
err() { echo "::error::$*"; fail=1; }
ok() { n=$((n + 1)); }
p=charts/agent-relay
example=(-f $p/values-eks.yaml -f $p/values-eks-native.yaml -f examples/aws/values.yaml)
render() { helm template agent-relay $p -n agent-relay --no-hooks "$@"; }
expect_fail() { # label expected-error helm-args...
  local label=$1 want=$2 out; shift 2
  if out=$(render "$@" 2>&1); then err "$label: rendered"; return; fi
  grep -Fq -- "$want" <<<"$out" && ok || err "$label: wrong error: $(tail -c 600 <<<"$out")"
}
sha_file() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
table() { yq ".global.rdsCa.bundleSha256[\"$1\"]" $p/values.yaml; }
# The exact bytes of a rendered ConfigMap's ca.crt (yq would add a newline).
ca_bytes() { yq -o=json "$1" | python3 -Ic 'import json, sys; sys.stdout.write(json.load(sys.stdin))'; }

# Every Postgres CA reference in a render, one line per workload:
#   <kind>/<name> <volume ConfigMap> <SESSION_POSTGRES_CA_SHA256 or NATIVE_BRIEF_CA_SHA256 or ->
ca_refs() {
  yq -N '
    select(.kind == "Deployment" or .kind == "Job" or .kind == "CronJob") |
    (.spec.jobTemplate.spec.template.spec // .spec.template.spec) as $s |
    ([$s.volumes[]? | select(.name == "postgres-ca" or .name == "session-analysis-ca") | .configMap.name // .secret.secretName] | join(",")) as $v |
    ([$s.containers[]?.env[]? | select(.name == "SESSION_POSTGRES_CA_SHA256" or .name == "NATIVE_BRIEF_CA_SHA256") | .value] | unique | join(",")) as $h |
    select($v != "" or $h != "") |
    .kind + "/" + .metadata.name + " " + ($v // "-") + " " + (($h | select(. != "")) // "-")' <<<"$1"
}

# 1. Off by default: nothing rendered, and the shipped AWS example without
#    global.rdsCa still renders (its consumers then need their own CA).
out=$(render -f $p/values-gcp-proof.yaml -f $p/ci/gcp-proof-values.yaml)
[ -z "$(yq 'select(.kind == "ConfigMap" and .metadata.labels["app.kubernetes.io/component"] == "rds-ca") | .metadata.name' <<<"$out")" ] && ok || err "default render has an rds-ca ConfigMap"

# 2. Region: the simple AWS example (global.rdsCa.bundle us-east-1, no hashes).
out=$(render "${example[@]}")
cm=$(yq 'select(.kind == "ConfigMap" and .metadata.name == "rds-ca")' <<<"$out")
[ -n "$cm" ] && ok || err "region: no rds-ca ConfigMap"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ca_bytes '.data["ca.crt"]' <<<"$cm" > "$tmp/ca.crt"
want=$(table us-east-1)
[ "$(sha_file "$tmp/ca.crt")" = "$want" ] && ok || err "region: ca.crt is not the shipped us-east-1 bundle"
cmp -s "$tmp/ca.crt" $p/files/rds-ca/us-east-1-bundle.pem && ok || err "region: ca.crt bytes differ from files/rds-ca/us-east-1-bundle.pem"
[ "$(yq '.metadata.annotations["agentworkforce.dev/rds-ca-sha256"]' <<<"$cm")" = "$want" ] && ok || err "region: annotation hash"
refs=$(ca_refs "$out")
for w in Deployment/relaycast Deployment/relay-control Deployment/agent-relay-read-api Deployment/agent-relay-ingest-edge Deployment/agent-relay-search-indexer; do
  grep -q "^$w rds-ca" <<<"$refs" && ok || err "region: $w does not mount rds-ca: $(grep "^$w " <<<"$refs" || echo none)"
done
for w in Deployment/agent-relay-read-api Deployment/agent-relay-ingest-edge Deployment/agent-relay-search-indexer; do
  grep -q "^$w rds-ca $want\$" <<<"$refs" && ok || err "region: $w does not pin $want: $(grep "^$w " <<<"$refs" || echo none)"
done
bad=$(awk -v w="$want" '$3 != "-" && $3 != w' <<<"$refs")
[ -z "$bad" ] && ok || err "region: a workload pins another hash: $bad"
bad=$(awk '$2 != "rds-ca"' <<<"$refs")
[ -z "$bad" ] && ok || err "region: a workload mounts another CA: $bad"
# The legacy worker, alleyoop and migrate Jobs get NODE_EXTRA_CA_CERTS from it.
nodes=$(yq -N 'select(.kind == "Deployment" or .kind == "Job" or .kind == "CronJob") | (.spec.jobTemplate.spec.template.spec // .spec.template.spec) as $s | select([$s.containers[]?.env[]? | select(.name == "NODE_EXTRA_CA_CERTS")] | length > 0) | .metadata.name' <<<"$out")
for w in relaycast relay-control; do grep -qx "$w" <<<"$nodes" && ok || err "region: $w has no NODE_EXTRA_CA_CERTS"; done
grep -q "worker" <<<"$nodes" && ok || err "region: no worker workload has NODE_EXTRA_CA_CERTS"

# NODE_EXTRA_CA_CERTS is read at start: those Deployments roll on a new bundle.
ann=$(yq -N 'select(.kind == "Deployment") | select(.spec.template.metadata.annotations["agentworkforce.dev/rds-ca-sha256"] == "'"$(table us-east-1)"'") | .metadata.name' <<<"$out")
for w in relaycast relay-control agent-relay-worker-session-summary-worker; do grep -qx "$w" <<<"$ann" && ok || err "region: $w has no rds-ca-sha256 pod annotation"; done

# Native brief pins the same hash.
out=$(render "${example[@]}" --set sessions-pipeline.worker.nativeBrief.enabled=true --set-json 'sessions-pipeline.worker.nativeBrief.workspaceIds=["ws_1"]' --set sessions-pipeline.worker.components.session-brief.enabled=true)
grep -q "NATIVE_BRIEF_CA_SHA256, value: \"$want\"" <<<"$out" && ok || err "region: nativeBrief does not pin $want"

# 3. Global bundle.
out=$(render "${example[@]}" --set global.rdsCa.bundle=global)
want=$(table global)
[ "$(yq 'select(.kind == "ConfigMap" and .metadata.name == "rds-ca") | .metadata.annotations["agentworkforce.dev/rds-ca-sha256"]' <<<"$out")" = "$want" ] && ok || err "global: annotation"
ca_bytes 'select(.kind == "ConfigMap" and .metadata.name == "rds-ca") | .data["ca.crt"]' <<<"$out" > "$tmp/global.crt"
cmp -s "$tmp/global.crt" $p/files/rds-ca/global-bundle.pem && ok || err "global: ca.crt bytes differ from the shipped global bundle"
bad=$(ca_refs "$out" | awk -v w="$want" '$3 != "-" && $3 != w')
[ -z "$bad" ] && ok || err "global: a workload pins another hash: $bad"

# 4. Override: the read API keeps a private CA; everything else stays managed.
own=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
out=$(render "${example[@]}" --set sessions-pipeline.sessionReadApi.postgresCa.enabled=true \
  --set sessions-pipeline.sessionReadApi.postgresCa.configMap=private-ca --set sessions-pipeline.sessionReadApi.postgresCa.sha256=$own)
refs=$(ca_refs "$out")
grep -q "^Deployment/agent-relay-read-api private-ca $own\$" <<<"$refs" && ok || err "override: read API: $(grep read-api <<<"$refs")"
grep -q "^Deployment/agent-relay-ingest-edge rds-ca $(table us-east-1)\$" <<<"$refs" && ok || err "override: ingest edge left the managed CA"
# A Secret source is kept too.
out=$(render "${example[@]}" --set relay-control.postgresCa.enabled=true --set relay-control.postgresCa.secret=pg-ca)
grep -q "^Deployment/relay-control pg-ca" <<<"$(ca_refs "$out")" && ok || err "override: relay-control Secret source"
# A hand-set hash equal to the bundle's is accepted; so is the all-zero placeholder.
render "${example[@]}" --set sessions-pipeline.ingestEdge.postgres.caSha256="$(table us-east-1)" >/dev/null && ok || err "matching hand-set hash refused"
out=$(render -f $p/values-eks.yaml -f $p/values-eks-rds-native.yaml --set global.rdsCa.bundle=us-west-2) && ok || err "values-eks-rds-native.yaml with global.rdsCa did not render"
bad=$(ca_refs "$out" | awk -v w="$(table us-west-2)" '$3 != "-" && $3 != w')
[ -z "$bad" ] && ok || err "values-eks-rds-native.yaml: placeholder hash kept: $bad"

# 5. Contradictions fail.
bad1=1111111111111111111111111111111111111111111111111111111111111111
expect_fail "read API hash mismatch" "sessionReadApi" "${example[@]}" --set sessions-pipeline.sessionReadApi.postgresCa.sha256=$bad1
expect_fail "read API hash mismatch message" "does not match the chart-managed RDS CA" "${example[@]}" --set sessions-pipeline.sessionReadApi.postgresCa.sha256=$bad1
expect_fail "ingest edge hash mismatch" "ingestEdge.postgres.caSha256=$bad1 does not match the chart-managed RDS CA" "${example[@]}" --set sessions-pipeline.ingestEdge.postgres.caSha256=$bad1
expect_fail "search indexer hash mismatch" "searchIndexer.postgres.caSha256=$bad1 does not match" "${example[@]}" --set sessions-pipeline.searchIndexer.postgres.caSha256=$bad1
expect_fail "worker hash mismatch" "postgresCa.sha256=$bad1 does not match" "${example[@]}" --set sessions-pipeline.worker.postgresCa.sha256=$bad1
expect_fail "named managed ConfigMap with a wrong hash" "does not match the chart-managed RDS CA" "${example[@]}" \
  --set sessions-pipeline.sessionReadApi.postgresCa.configMap=rds-ca --set sessions-pipeline.sessionReadApi.postgresCa.sha256=$bad1
expect_fail "key mismatch" "contradicts the chart-managed RDS CA" "${example[@]}" --set relay-control.postgresCa.key=rds.pem
expect_fail "tampered hash table" "does not match the us-east-1 bundle this chart ships" "${example[@]}" --set global.rdsCa.bundleSha256.us-east-1=$bad1
expect_fail "unknown region" 'global.rdsCa.bundle="xx-nowhere-9"' "${example[@]}" --set global.rdsCa.bundle=xx-nowhere-9
expect_fail "malformed bundle" 'global.rdsCa.bundle="../etc"' "${example[@]}" --set global.rdsCa.bundle=../etc
expect_fail "BYO without a hash names global.rdsCa" "global.rdsCa.bundle" "${example[@]}" --set global.rdsCa.bundle=
# Without the umbrella the subcharts cannot resolve a bundle.
if out=$(helm template t charts/sessions-pipeline -f charts/sessions-pipeline/ci/search-indexer-values.yaml --set global.rdsCa.bundle=us-east-1 2>&1); then
  err "standalone sessions-pipeline rendered global.rdsCa without the umbrella"
else
  grep -Fq "is not an RDS CA bundle the agent-relay chart ships" <<<"$out" && ok || err "standalone: wrong error: $(tail -c 400 <<<"$out")"
fi
# The SQLite Relaycast backend takes no CA.
render "${example[@]}" --set relaycast.runtime.backend=sqlite --set relaycast.retention.messageTtlDays=30 >/dev/null 2>"$tmp/e" \
  && ok || { grep -q "postgresCa" "$tmp/e" && err "sqlite relaycast got the managed CA: $(cat "$tmp/e")" || ok; }

# 6. Values written before global.rdsCa render as they did: the explicit rds-ca
#    references and hashes, no ConfigMap. With global.rdsCa they keep working
#    when the hashes are the bundle's.
out=$(render "${example[@]}" -f ci/rds-ca/legacy-values.yaml)
[ -z "$(yq 'select(.kind == "ConfigMap" and .metadata.name == "rds-ca") | .metadata.name' <<<"$out")" ] && ok || err "legacy: renders an rds-ca ConfigMap"
refs=$(ca_refs "$out")
bad=$(awk '$2 != "rds-ca" || ($3 != "-" && $3 != "9f2c4e1ab7d03586e2f1c9a47b0d6e3851fa2c94d7e60b13a8c5f27e4d91b06a")' <<<"$refs")
[ -z "$bad" ] && [ -n "$refs" ] && ok || err "legacy: CA references changed: $bad"
[ -z "$(yq 'select(.spec.template.metadata.annotations["agentworkforce.dev/rds-ca-sha256"]) | .metadata.name' <<<"$out")" ] && ok || err "legacy: a pod has the rds-ca-sha256 annotation"
out=$(render -f $p/values-eks.yaml -f $p/values-eks-rds-native.yaml -f ci/agent-relay/eks-rds-native-site-values.yaml)
bad=$(ca_refs "$out" | awk '$2 != "rds-ca" || ($3 != "-" && $3 != "1111111111111111111111111111111111111111111111111111111111111111")')
[ -z "$bad" ] && ok || err "legacy profile: CA references changed: $bad"
legacy_matching=$(sed "s/9f2c4e1ab7d03586e2f1c9a47b0d6e3851fa2c94d7e60b13a8c5f27e4d91b06a/$(table us-east-1)/" ci/rds-ca/legacy-values.yaml | grep -v '^global:\|^  rdsCa:\|^    bundle:')
out=$(render "${example[@]}" -f <(printf '%s\n' "$legacy_matching") --set global.rdsCa.bundle=us-east-1)
bad=$(ca_refs "$out" | awk -v w="$(table us-east-1)" '$2 != "rds-ca" || ($3 != "-" && $3 != w)')
[ -z "$bad" ] && ok || err "legacy values with the bundle's hashes under global.rdsCa: $bad"
expect_fail "legacy values with an example hash under global.rdsCa" "does not match the chart-managed RDS CA" "${example[@]}" -f ci/rds-ca/legacy-values.yaml --set global.rdsCa.bundle=us-east-1

# 7. Generated files agree; release size.
ci/rds-ca/sync.sh --check && ok || err "a chart's _rds-ca.tpl differs from ci/rds-ca/_rds-ca.tpl"
scripts/selfhost/refresh-rds-ca-bundles.sh --verify >/dev/null && ok || err "bundles, manifest and values table disagree"
helm package $p -d "$tmp" >/dev/null
render "${example[@]}" --set global.rdsCa.bundle=global > "$tmp/manifest.yaml"
size=$(python3 -I ci/rds-ca/release-size.py "$tmp"/agent-relay-*.tgz "$tmp/manifest.yaml")
echo "release Secret estimate (chart + global-bundle manifest): $size bytes"
[ "$size" -lt 943718 ] && ok || err "the Helm release Secret estimate $size is over 0.9 MiB (the limit is 1 MiB)"

echo "rds-ca: $n checks passed"
exit $fail
