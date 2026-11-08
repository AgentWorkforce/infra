#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

# Helm does not recursively vendor file:// dependency children.
helm dependency build charts/sessions-pipeline >/dev/null
helm dependency build charts/agent-relay >/dev/null
out=$(helm template proof charts/agent-relay -n agent-relay --no-hooks \
  -f charts/agent-relay/values-gcp-proof.yaml \
  -f charts/agent-relay/ci/gcp-proof-values.yaml)

if grep -Eq 'app.kubernetes.io/name: (relayflows|relayfile)' <<<"$out"; then
  echo "proof render emits a relayflows/relayfile manifest" >&2
  exit 1
fi
if yq 'select(.kind == "Secret") | .metadata.name' <<<"$out" | grep -q .; then
  echo "proof render emits a Secret manifest" >&2
  exit 1
fi
if grep -Eq 'helm\.sh/hook:' <<<"$out"; then
  echo "proof render emits a Helm hook annotation" >&2
  exit 1
fi
test "$(yq 'select(.kind == "Ingress") | .metadata.name' <<<"$out" | grep -c .)" = 1
test "$(yq 'select(.kind == "ManagedCertificate") | .metadata.name' <<<"$out")" = agent-relay-gcp-proof
test "$(yq 'select(.kind == "FrontendConfig") | .spec.redirectToHttps.enabled' <<<"$out")" = true
test "$(yq 'select(.kind == "Ingress") | .metadata.annotations["kubernetes.io/ingress.global-static-ip-name"]' <<<"$out")" = agent-relay-gcp-proof-ingress

root_api=$(yq 'select(.kind == "Ingress" and .metadata.name == "agent-relay-gcp-proof") |
  .spec.rules[] | select(.host == "gcp-proof.agentrelay.com") |
  .http.paths[] | select(.path == "/cloud/api") | .backend.service.name' <<<"$out")
test "$root_api" = relay-cloud-api

root_login=$(yq 'select(.kind == "Ingress" and .metadata.name == "agent-relay-gcp-proof") |
  .spec.rules[] | select(.host == "gcp-proof.agentrelay.com") |
  .http.paths[] | select(.path == "/login") | .backend.service.name' <<<"$out")
test "$root_login" = relay-cloud-api

api_backend=$(yq 'select(.kind == "Ingress" and .metadata.name == "agent-relay-gcp-proof") |
  .spec.rules[] | select(.host == "api.gcp-proof.agentrelay.com") |
  .http.paths[] | select(.path == "/") | .backend.service.name' <<<"$out")
test "$api_backend" = relay-cloud-api

for host in gcp-proof.agentrelay.com api.gcp-proof.agentrelay.com \
  cast.gcp-proof.agentrelay.com history.gcp-proof.agentrelay.com; do
  grep -Eq "host: [\"']?${host}[\"']?$" <<<"$out"
done

for image in \
  us-central1-docker.pkg.dev/agentrelay-96bulls-soc2-2610/awf-conformance-images/selfhost-api \
  us-central1-docker.pkg.dev/agentrelay-96bulls-soc2-2610/awf-conformance-images/relay-dashboard \
  us-central1-docker.pkg.dev/agentrelay-96bulls-soc2-2610/awf-conformance-images/relayhistory; do
  grep -Eq "image: [\"']?${image}@sha256:[a-f0-9]{64}" <<<"$out"
done

for service in relaycast relayhistory relay-cloud-api relay-dashboard; do
  test "$(yq "select(.kind == \"Service\" and .metadata.name == \"$service\") |
    .metadata.annotations[\"cloud.google.com/neg\"]" <<<"$out")" = '{"ingress": true}'
done

api_history_url=$(yq 'select(.kind == "Deployment" and .metadata.name == "relay-cloud-api") |
  .spec.template.spec.containers[0].env[] | select(.name == "RELAYHISTORY_URL") | .value' <<<"$out")
api_history_public_url=$(yq 'select(.kind == "Deployment" and .metadata.name == "relay-cloud-api") |
  .spec.template.spec.containers[0].env[] | select(.name == "RELAYHISTORY_PUBLIC_URL") | .value' <<<"$out")
api_cast_public_url=$(yq 'select(.kind == "Deployment" and .metadata.name == "relay-cloud-api") |
  .spec.template.spec.containers[0].env[] | select(.name == "RELAYCAST_PUBLIC_URL") | .value' <<<"$out")
history_audience=$(yq 'select(.kind == "ConfigMap" and .metadata.name == "relayhistory") |
  .data.RELAYAUTH_AUDIENCE' <<<"$out")
test "$api_history_url" = http://relayhistory:8080
test "$api_history_public_url" = https://history.gcp-proof.agentrelay.com
test "$api_history_public_url" = "$history_audience"
test "$api_cast_public_url" = https://cast.gcp-proof.agentrelay.com

# /internal on the api host is denied at the edge, like the cast host.
api_internal=$(yq 'select(.kind == "Ingress" and .metadata.name == "agent-relay-gcp-proof") |
  .spec.rules[] | select(.host == "api.gcp-proof.agentrelay.com") |
  .http.paths[] | select(.path == "/internal") | .backend.service.name + " " + .pathType' <<<"$out")
test "$api_internal" = "agent-relay-gcp-proof-cast-edge-deny Prefix" \
  || { echo "api host does not deny /internal at the edge ($api_internal)" >&2; exit 1; }
cast_internal=$(yq 'select(.kind == "Ingress" and .metadata.name == "agent-relay-gcp-proof") |
  .spec.rules[] | select(.host == "cast.gcp-proof.agentrelay.com") |
  .http.paths[] | select(.path == "/internal") | .backend.service.name' <<<"$out")
test "$cast_internal" = agent-relay-gcp-proof-cast-edge-deny
# The edge-deny Service must never select pods.
test "$(yq 'select(.kind == "Service" and .metadata.name == "agent-relay-gcp-proof-cast-edge-deny") | .spec.selector' <<<"$out")" = null

# The api backend gets a BackendConfig timeout above GCE's 30s default for
# the flows worker queue SSE stream, bound through the api Service.
test "$(yq 'select(.kind == "BackendConfig" and .metadata.name == "agent-relay-gcp-proof-api") | .spec.timeoutSec' <<<"$out")" -ge 60
test "$(yq 'select(.kind == "Service" and .metadata.name == "relay-cloud-api") |
  .metadata.annotations["cloud.google.com/backend-config"]' <<<"$out")" = '{"default":"agent-relay-gcp-proof-api"}'
expect_umbrella_failure() { # expected-error helm-args...
  local expected=$1 output; shift
  if output=$(helm template proof charts/agent-relay -n agent-relay --no-hooks \
    -f charts/agent-relay/values-gcp-proof.yaml -f charts/agent-relay/ci/gcp-proof-values.yaml "$@" 2>&1); then
    echo "agent-relay: rendered despite expected failure: $expected" >&2
    exit 1
  fi
  grep -Fq "$expected" <<<"$output" \
    || { echo "agent-relay: failed without expected error: $expected" >&2; echo "$output" >&2; exit 1; }
}
expect_umbrella_failure "gkeIngress.backends.api.timeoutSec must be at least 60" --set gkeIngress.backends.api.timeoutSec=30
expect_umbrella_failure "gkeIngress.backends.cast.timeoutSec must be at least 60" --set gkeIngress.backends.cast.timeoutSec=30
expect_umbrella_failure "relaycast.service.backendConfig=agent-relay-gcp-proof-cast" --set relaycast.service.backendConfig=null
expect_umbrella_failure "relaycast.service.backendConfig=agent-relay-gcp-proof-cast" --set relaycast.service.backendConfig=other-cast
# The relaycast Service carries the cast BackendConfig (WebSocket timeout).
cast_out=$(helm template proof charts/agent-relay -n agent-relay --no-hooks \
  -f charts/agent-relay/values-gcp-proof.yaml -f charts/agent-relay/ci/gcp-proof-values.yaml)
test "$(yq 'select(.kind == "BackendConfig" and .metadata.name == "agent-relay-gcp-proof-cast") | .spec.timeoutSec' <<<"$cast_out")" = 3600 \
  || { echo "cast BackendConfig missing or timeout not 3600" >&2; exit 1; }
test "$(yq 'select(.kind == "Service" and .metadata.name == "relaycast") | .metadata.annotations["cloud.google.com/backend-config"]' <<<"$cast_out")" = '{"default":"agent-relay-gcp-proof-cast"}' \
  || { echo "relaycast Service is not bound to the cast BackendConfig" >&2; exit 1; }
expect_umbrella_failure "relay-cloud-api.service.backendConfig=agent-relay-gcp-proof-api" \
  --set relay-cloud-api.service.backendConfig=null
expect_umbrella_failure "relay-cloud-api.service.backendConfig=agent-relay-gcp-proof-api" \
  --set relay-cloud-api.service.backendConfig=other-api
# Long names keep the -api suffix: truncate to 59, then append.
long_name=$(printf 'n%.0s' $(seq 70))
long_bc="$(printf 'n%.0s' $(seq 59))-api"
long_cast="$(printf 'n%.0s' $(seq 58))-cast"
long_out=$(helm template proof charts/agent-relay -n agent-relay --no-hooks \
  -f charts/agent-relay/values-gcp-proof.yaml -f charts/agent-relay/ci/gcp-proof-values.yaml \
  --set "gkeIngress.name=$long_name" --set "relay-cloud-api.service.backendConfig=$long_bc" \
  --set "relaycast.service.backendConfig=$long_cast")
test "$(yq 'select(.kind == "BackendConfig" and (.metadata.name | test("-api$"))) | .metadata.name' <<<"$long_out")" = "$long_bc" \
  || { echo "long gkeIngress.name lost the -api BackendConfig suffix" >&2; exit 1; }
# A customer name in the GCP profile renders once service.backendConfig follows it.
helm template ar charts/agent-relay -n agent-relay --no-hooks -f charts/agent-relay/values-gcp.yaml \
  --set gkeIngress.name=acme-relay --set relay-cloud-api.service.backendConfig=acme-relay-api \
  --set relaycast.service.backendConfig=acme-relay-cast >/dev/null \
  || { echo "values-gcp.yaml: customer gkeIngress.name with matching backendConfig failed to render" >&2; exit 1; }
if acme_fail=$(helm template ar charts/agent-relay -n agent-relay --no-hooks -f charts/agent-relay/values-gcp.yaml \
  --set gkeIngress.name=acme-relay 2>&1); then
  echo "values-gcp.yaml: stale service.backendConfig rendered" >&2; exit 1
fi
grep -Fq 'relay-cloud-api.service.backendConfig=acme-relay-api' <<<"$acme_fail" \
  || { echo "values-gcp.yaml: stale backendConfig failed without naming the expected value" >&2; echo "$acme_fail" >&2; exit 1; }
# Session ingest's History audience must equal RelayHistory's origin.
if origin_fail=$(helm template ar charts/agent-relay -n agent-relay --no-hooks -f charts/agent-relay/values-gcp.yaml \
  --set relayhistory.relayauth.historyOrigin=https://history.acme.example 2>&1); then
  echo "values-gcp.yaml: mismatched sessions-pipeline.alleyoop.auth.historyOrigin rendered" >&2; exit 1
fi
grep -Fq 'sessions-pipeline.alleyoop.auth.historyOrigin (https://history.placeholder.company) must equal relayhistory.relayauth.historyOrigin (https://history.acme.example)' <<<"$origin_fail" \
  || { echo "values-gcp.yaml: historyOrigin mismatch failed without the expected error" >&2; echo "$origin_fail" >&2; exit 1; }
# RelayHistory write-hold step 1 through the umbrella: History drains to zero
# replicas while its migrate Job takes the write hold.
wh_out=$(helm template proof charts/agent-relay -n agent-relay --no-hooks \
  -f charts/agent-relay/values-gcp-proof.yaml -f charts/agent-relay/ci/gcp-proof-values.yaml \
  --set relayhistory.migrations.allowWriteHold=true --set relayhistory.migrations.drainForWriteHold=true)
test "$(yq 'select(.kind == "Deployment" and .metadata.name == "relayhistory") | .spec.replicas' <<<"$wh_out")" = 0 \
  || { echo "relayhistory.migrations.drainForWriteHold did not drain History" >&2; exit 1; }
test "$(yq 'select(.kind == "Job" and .metadata.labels["app.kubernetes.io/component"] == "migration" and (.metadata.name | test("^relayhistory-migrate-"))) | .spec.template.spec.containers[0].env[] | select(.name == "ALLOW_WRITE_HOLD") | .value' <<<"$wh_out")" = yes \
  || { echo "relayhistory write-hold Job does not take the hold" >&2; exit 1; }
expect_leaf_failure_early() { # expected helm-args...
  local expected=$1 output; shift
  if output=$(helm template ci charts/relay-cloud-api -n ci --no-hooks -f charts/relay-cloud-api/ci/default-values.yaml "$@" 2>&1); then
    echo "relay-cloud-api: rendered despite expected failure: $expected" >&2; exit 1
  fi
  grep -Fq "$expected" <<<"$output" || { echo "relay-cloud-api: failed without expected error: $expected" >&2; echo "$output" >&2; exit 1; }
}
expect_leaf_failure_early "not both" --set service.backendConfig=x-api \
  --set-json 'service.annotations={"cloud.google.com/backend-config":"{\"default\":\"x-api\"}"}'
for bad in 'service.backendConfig=Bad_Name' 'service.backendConfig=0' 'service.backendConfig=false'; do
  expect_leaf_failure_early "service.backendConfig must be a BackendConfig name" --set "$bad"
done
expect_leaf_failure_early "contain google" --set flows.storage=gcs --set flows.gcsBucket=my-google-flows
expect_umbrella_failure "flows.queuePingMs must be below gkeIngress.backends.api.timeoutSec" \
  --set gkeIngress.backends.api.timeoutSec=60 --set relay-cloud-api.flows.queuePingMs=60000
# encryption.keyId is required (relaycontrol crash-loops without it).
expect_umbrella_failure "encryption.keyId is required" --set relay-cloud-api.encryption.keyId=

live_out=$(helm template proof charts/agent-relay -n agent-relay --no-hooks \
  -f charts/agent-relay/values-gcp-proof.yaml \
  -f charts/agent-relay/values-gcp-proof-live.yaml \
  --set relay-cloud-api.image.digest=sha256:2222222222222222222222222222222222222222222222222222222222222222)
if yq 'select(.metadata.name == "relayauth") | .metadata.name' <<<"$live_out" | grep -q .; then
  echo "live profile renders a relayauth manifest" >&2
  exit 1
fi
netpol_names=$(yq 'select(.kind == "NetworkPolicy") | .metadata.name' <<<"$live_out" | grep -v '^---$' || true)
if [[ -z "$netpol_names" ]]; then
  echo "live profile renders no NetworkPolicies" >&2
  exit 1
fi
if grep -q '^relayauth' <<<"$netpol_names"; then
  echo "live profile renders a NetworkPolicy for disabled relayauth" >&2
  exit 1
fi
test "$(yq 'select(.kind == "Deployment" and .metadata.name == "relay-cloud-api") |
  .spec.template.spec.containers[0].env[] | select(.name == "RELAYAUTH_URL") | .value' <<<"$live_out")" = http://relayauth.relayauth.svc:8787
test "$(yq 'select(.kind == "ConfigMap" and .metadata.name == "relayhistory") |
  .data.RELAYAUTH_ISSUER' <<<"$live_out")" = http://relayauth.relayauth.svc:8787
test "$(yq 'select(.kind == "ConfigMap" and .metadata.name == "relayhistory") |
  .data.RELAYAUTH_JWKS_URL' <<<"$live_out")" = http://relayauth.relayauth.svc:8787/.well-known/jwks.json

live_api_env() { yq "select(.kind == \"Deployment\" and .metadata.name == \"relay-cloud-api\") |
  .spec.template.spec.containers[0].env[] | select(.name == \"$1\") | .value" <<<"$live_out"; }
test "$(live_api_env SELFHOST_ENCRYPTION_KEY_ID)" = proof-1
test "$(live_api_env SELFHOST_DASHBOARD_URL)" = https://gcp-proof.agentrelay.com/
test "$(live_api_env SELFHOST_INTERNAL_TOKEN_FILE)" = /var/run/agent-relay/secrets/selfhost-internal-token
test "$(live_api_env SELFHOST_TELEMETRY_LEVEL)" = off
test -z "$(live_api_env SELFHOST_TELEMETRY_INSTALL_KEY_FILE)"
yq 'select(.kind == "Deployment" and .metadata.name == "relay-cloud-api") | .spec.template.spec.volumes[] |
  select(.name == "secrets") | .secret.items[].key' <<<"$live_out" | grep -qx selfhost-internal-token \
  || { echo "live profile does not mount the internal token" >&2; exit 1; }

# ar_ credential custody: authority=relayauth without the relayauth component
# must fail closed at the umbrella level.
if ar_fail=$(helm template proof charts/agent-relay -n agent-relay --no-hooks \
  -f charts/agent-relay/values-gcp-proof.yaml \
  -f charts/agent-relay/ci/gcp-proof-values.yaml \
  --set components.relayauth=false \
  --set relaycast.credentials.format=ar \
  --set relaycast.credentials.authority=relayauth \
  --set relaycast.credentials.relayauth.url=http://relayauth:8787 \
  --set relaycast.secretKeys.relayauthToken=relaycast-relayauth-token 2>&1); then
  echo "authority=relayauth without components.relayauth rendered successfully" >&2
  exit 1
fi
grep -q 'requires components.relayauth=true' <<<"$ar_fail" \
  || { echo "render failed without the expected components.relayauth error" >&2; exit 1; }

# Migration Jobs: spec.template is immutable, so any pod template change
# (here: resources) must produce a new Job name.
proof_args=(-f charts/agent-relay/values-gcp-proof.yaml -f charts/agent-relay/ci/gcp-proof-values.yaml)
for child in relayhistory relay-cloud-api; do
  base_job=$(yq "select(.kind == \"Job\" and .metadata.name == \"${child}-migrate-*\") | .metadata.name" <<<"$out")
  resized=$(helm template proof charts/agent-relay -n agent-relay --no-hooks "${proof_args[@]}" \
    --set "${child}.resources.limits.memory=7Gi" |
    yq "select(.kind == \"Job\" and .metadata.name == \"${child}-migrate-*\") | .metadata.name")
  test -n "$base_job" || { echo "$child: no migration Job rendered" >&2; exit 1; }
  if [ "$base_job" = "$resized" ]; then
    echo "$child: migration Job name ignores pod template changes ($base_job)" >&2
    exit 1
  fi
done

# NOTES.txt waits on Jobs by component=migration; the Job object itself
# (not only its pods) must carry that label.
for child in relayhistory relay-cloud-api; do
  test "$(yq "select(.kind == \"Job\" and .metadata.name == \"${child}-migrate-*\") |
    .metadata.labels[\"app.kubernetes.io/component\"]" <<<"$out")" = migration \
    || { echo "$child: migration Job metadata lacks app.kubernetes.io/component=migration" >&2; exit 1; }
done

# Leaf-chart fail-closed validations for the suite's child charts, rendered
# standalone from their CI values.
expect_leaf_failure() { # chart expected-error helm-args...
  local chart=$1 expected=$2 output; shift 2
  if output=$(helm template ci "charts/$chart" -n ci --no-hooks -f "charts/$chart/ci/default-values.yaml" "$@" 2>&1); then
    echo "$chart: rendered despite expected failure: $expected" >&2
    exit 1
  fi
  grep -Fq "$expected" <<<"$output" \
    || { echo "$chart: failed without expected error: $expected" >&2; echo "$output" >&2; exit 1; }
}
expect_leaf_failure relay-cloud-api "PORT is managed by structured chart values and must not appear in extraEnv" \
  --set-json 'extraEnv=[{"name":"PORT","value":"1"}]'
db_egress='[{"to":[{"ipBlock":{"cidr":"10.20.0.0/24"}}],"ports":[{"protocol":"TCP","port":5432}]}]'
for child in relayhistory relay-cloud-api; do
  expect_leaf_failure "$child" "allowAllEgress=false requires networkPolicy.additionalEgress" \
    --set networkPolicy.allowAllEgress=false
  expect_leaf_failure "$child" "additionalEgress rule needs a non-empty to" \
    --set networkPolicy.allowAllEgress=false --set-json 'networkPolicy.additionalEgress=[{"ports":[{"port":5432}]}]'
  helm template ci "charts/$child" -n ci --no-hooks -f "charts/$child/ci/default-values.yaml" \
    --set networkPolicy.allowAllEgress=false --set-json "networkPolicy.additionalEgress=$db_egress" >/dev/null
done

# relayhistory: extraEnvFrom must not override chart-managed ConfigMap keys,
# so the chart ConfigMap is the last (winning) envFrom source.
last_env_from=$(helm template ci charts/relayhistory -n ci --no-hooks -f charts/relayhistory/ci/default-values.yaml \
  --set-json 'extraEnvFrom=[{"configMapRef":{"name":"operator-extra"}}]' |
  yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].envFrom[-1].configMapRef.name')
test "$last_env_from" = ci-relayhistory \
  || { echo "relayhistory: extraEnvFrom can override the chart ConfigMap (last envFrom is $last_env_from)" >&2; exit 1; }

# relay-cloud-api runtime contract (relaycontrol src/config.ts): fail closed at
# render time on what the API refuses at startup.
expect_leaf_failure relay-cloud-api "encryption.keyId is required" --set encryption.keyId=
expect_leaf_failure relay-cloud-api "encryption.keyId must contain 1-64 URL-safe characters" --set encryption.keyId=bad/id
expect_leaf_failure relay-cloud-api "must be set together" --set encryption.previousKeyId=ci-0
expect_leaf_failure relay-cloud-api "must be set together" --set secretKeys.previousEncryptionKey=old-key
expect_leaf_failure relay-cloud-api "encryption.previousKeyId must differ" \
  --set encryption.previousKeyId=ci-1 --set secretKeys.previousEncryptionKey=old-key
expect_leaf_failure relay-cloud-api "flows.gcsBucket is required" --set flows.storage=gcs
expect_leaf_failure relay-cloud-api "flows.storage must be postgres or gcs" --set flows.storage=s3
expect_leaf_failure relay-cloud-api "flows.queuePingMs must be an integer from 1000 to 120000" --set flows.queuePingMs=500
expect_leaf_failure relay-cloud-api "telemetry.level must be off, errors, or full" --set telemetry.level=verbose
# The standalone Ingress denies /internal when the internal token is set; the
# deny Service name fits 63 characters and carries one component label.
deny_host=$(yq '.publicUrl' charts/relay-cloud-api/ci/default-values.yaml | sed 's#https://##;s#/.*##')
deny_out=$(helm template agent-relay-with-a-very-long-release-name-for-ci-test charts/relay-cloud-api -n ci --no-hooks \
  -f charts/relay-cloud-api/ci/default-values.yaml --set ingress.enabled=true --set-json "ingress.hosts=[\"$deny_host\"]" \
  --set-json 'ingress.tls=[{"hosts":["x"],"secretName":"t"}]' --set secretKeys.internalToken=selfhost-internal-token)
deny_name=$(yq 'select(.kind == "Service" and .metadata.labels["app.kubernetes.io/component"] == "internal-deny") | .metadata.name' <<<"$deny_out" | grep .)
test "${#deny_name}" -le 63 || { echo "relay-cloud-api: internal-deny Service name over 63 characters" >&2; exit 1; }
test "$(yq 'select(.kind == "Ingress") | .spec.rules[0].http.paths[] | select(.path == "/internal") | .backend.service.name' <<<"$deny_out" | grep .)" = "$deny_name" \
  || { echo "relay-cloud-api: /internal is not routed to the deny Service" >&2; exit 1; }
# Default level errors arms only once the install is registered: the default
# render works and sends nothing; a partial registration fails closed.
tele_default=$(helm template ci charts/relay-cloud-api -n ci --no-hooks -f charts/relay-cloud-api/ci/default-values.yaml |
  yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "SELFHOST_TELEMETRY_LEVEL") | .value')
test "$tele_default" = off || { echo "relay-cloud-api: unregistered default telemetry must render off (got $tele_default)" >&2; exit 1; }
test "$(yq '.telemetry.level' charts/relay-cloud-api/values.yaml)" = errors || { echo "relay-cloud-api: telemetry.level default must be errors" >&2; exit 1; }
expect_leaf_failure relay-cloud-api "secretKeys.telemetryInstallKey is required" --set telemetry.installId=inst_abcdefgh12
expect_leaf_failure relay-cloud-api "telemetry.installId is required" --set secretKeys.telemetryInstallKey=telemetry-install-key
expect_leaf_failure relay-cloud-api "telemetry.installId is required" --set telemetry.endpoint=https://agentrelay.com/api/v1/selfhost/telemetry
expect_leaf_failure relay-cloud-api "telemetry.endpoint is required" \
  --set telemetry.installId=inst_abcdefgh12 --set secretKeys.telemetryInstallKey=telemetry-install-key
tele_reg=$(helm template ci charts/relay-cloud-api -n ci --no-hooks -f charts/relay-cloud-api/ci/default-values.yaml \
  --set telemetry.installId=inst_abcdefgh12 --set secretKeys.telemetryInstallKey=telemetry-install-key \
  --set telemetry.endpoint=https://agentrelay.com/api/v1/selfhost/telemetry |
  yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "SELFHOST_TELEMETRY_LEVEL") | .value')
test "$tele_reg" = errors || { echo "relay-cloud-api: a registered install must default to errors (got $tele_reg)" >&2; exit 1; }
expect_leaf_failure relay-cloud-api "telemetry.endpoint must be an https URL" --set telemetry.endpoint=http://ingest.example.org/
rotation_items=$(helm template ci charts/relay-cloud-api -n ci --no-hooks -f charts/relay-cloud-api/ci/default-values.yaml \
  --set encryption.previousKeyId=ci-0 --set secretKeys.previousEncryptionKey=old-key |
  yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "SELFHOST_ENCRYPTION_PREVIOUS_KEY_FILE" or .name == "SELFHOST_ENCRYPTION_PREVIOUS_KEY_ID") | .value')
test "$rotation_items" = "$(printf 'ci-0\n/var/run/agent-relay/secrets/old-key')" \
  || { echo "relay-cloud-api: previous key id/file not rendered ($rotation_items)" >&2; exit 1; }
feed_names=$(helm template ci charts/relay-cloud-api -n ci --no-hooks -f charts/relay-cloud-api/ci/default-values.yaml \
  --set-json 'extraEnv=[{"name":"SELFHOST_DESKTOP_FEED_URL","value":"https://feed.example.com"}]' |
  yq 'select(.kind == "Deployment" or .kind == "Job") | .spec.template.spec.containers[0].env[-1].name' |
  grep -vx -- '---')
test "$feed_names" = "$(printf 'SELFHOST_DESKTOP_FEED_URL\nSELFHOST_DESKTOP_FEED_URL')" \
  || { echo "relay-cloud-api: extraEnv must be last on the API and migration containers (got $feed_names)" >&2; exit 1; }

# The telemetry egress rule (TCP 443) renders only when telemetry is sent:
# level != off and transport=https, under restricted egress.
# https_rules prints how many TCP 443 egress ports the named relay-cloud-api
# NetworkPolicy carries. A failed helm render, a failed yq query or a missing
# policy is an error, never a zero count; only grep's no-match (exit 1) is
# tolerated.
https_rules() { # policy-name helm-args...
  local policy=$1 rendered np ports status=0; shift
  rendered=$(helm template ci charts/relay-cloud-api -n ci --no-hooks -f charts/relay-cloud-api/ci/default-values.yaml \
    --set networkPolicy.allowAllEgress=false --set-json "networkPolicy.additionalEgress=$db_egress" "$@") \
    || { echo "relay-cloud-api: render failed for $policy ($*)" >&2; return 1; }
  np=$(yq "select(.kind == \"NetworkPolicy\" and .metadata.name == \"$policy\")" <<<"$rendered") \
    || { echo "relay-cloud-api: yq failed selecting NetworkPolicy $policy" >&2; return 1; }
  test -n "$np" || { echo "relay-cloud-api: NetworkPolicy $policy was not rendered ($*)" >&2; return 1; }
  ports=$(yq '.spec.egress[] | select(.ports[].port == 443) | .ports[].port' <<<"$np") \
    || { echo "relay-cloud-api: yq failed reading $policy egress" >&2; return 1; }
  grep -c . <<<"$ports" || status=$?
  [ "$status" -le 1 ] || { echo "relay-cloud-api: grep failed counting $policy rules" >&2; return 1; }
}
telemetry_rules() { https_rules ci-relay-cloud-api "$@"; }
expect_rules() { # expected message helm-args...
  local expected=$1 message=$2 count; shift 2
  count=$(telemetry_rules "$@") || exit 1
  test "$count" = "$expected" || { echo "relay-cloud-api: $message (got $count)" >&2; exit 1; }
}
telemetry_on=(--set telemetry.installId=inst_abcdefgh12 --set secretKeys.telemetryInstallKey=telemetry-install-key
  --set telemetry.endpoint=https://agentrelay.com/api/v1/selfhost/telemetry
  --set-json 'telemetry.egressTo=[{"ipBlock":{"cidr":"203.0.113.10/32"}}]')
# The default egressTo is empty: restricted egress with https telemetry must
# fail closed instead of opening TCP 443 to every public address.
if egress_out=$(helm template ci charts/relay-cloud-api -n ci --no-hooks -f charts/relay-cloud-api/ci/default-values.yaml \
  --set networkPolicy.allowAllEgress=false --set-json "networkPolicy.additionalEgress=$db_egress" \
  --set telemetry.level=errors --set telemetry.installId=inst_abcdefgh12 --set secretKeys.telemetryInstallKey=telemetry-install-key \
  --set telemetry.endpoint=https://agentrelay.com/api/v1/selfhost/telemetry 2>&1); then
  echo "relay-cloud-api: empty default telemetry.egressTo rendered under restricted egress" >&2; exit 1
fi
grep -Fq "telemetry.egressTo must not be empty" <<<"$egress_out" \
  || { echo "relay-cloud-api: empty telemetry.egressTo failed without the expected error" >&2; exit 1; }
expect_rules 0 "telemetry egress rendered for an unregistered install"
expect_rules 0 "telemetry egress rendered with level off" --set telemetry.level=off "${telemetry_on[@]}"
expect_rules 0 "telemetry egress rendered for transport=file" \
  --set telemetry.level=errors --set telemetry.transport=file "${telemetry_on[@]}"
expect_rules 1 "no telemetry egress rule with level errors over https" --set telemetry.level=errors "${telemetry_on[@]}"
expect_rules 1 "no telemetry egress rule with level full over https" --set telemetry.level=full "${telemetry_on[@]}"
# The migration Job never sends telemetry: its policy must exist and carry no
# TCP 443 rule.
migration_rules=$(https_rules ci-relay-cloud-api-migration --set telemetry.level=full "${telemetry_on[@]}") || exit 1
test "$migration_rules" = 0 \
  || { echo "relay-cloud-api: migration NetworkPolicy allows TCP 443 ($migration_rules rules)" >&2; exit 1; }
# The helper itself must fail closed: a failing render is an error, not 0.
if https_rules ci-relay-cloud-api --set telemetry.level=verbose >/dev/null 2>&1; then
  echo "relay-cloud-api: https_rules treated a failed render as a count" >&2; exit 1
fi
if https_rules ci-relay-cloud-api-absent >/dev/null 2>&1; then
  echo "relay-cloud-api: https_rules treated a missing NetworkPolicy as a count" >&2; exit 1
fi

# Secret keys: every secretKeys value must be distinct, so neither an optional
# runtime key nor a required one can project the migration credential into the
# API pod.
for key in internalToken previousEncryptionKey telemetryInstallKey databaseUrl relayauthApiKey; do
  expect_leaf_failure relay-cloud-api "both name Secret key \"database-migrations-url\"" \
    --set "secretKeys.$key=database-migrations-url"
done
expect_leaf_failure relay-cloud-api "both name Secret key \"selfhost-bootstrap-token\"" \
  --set secretKeys.internalToken=selfhost-bootstrap-token
# Telemetry value shapes.
expect_leaf_failure relay-cloud-api "telemetry.deployment.cluster must be a string, number or boolean" \
  --set-json 'telemetry.deployment={"cluster":{"name":"x"}}'
expect_leaf_failure relay-cloud-api "telemetry.deployment.endpoint must be a short version-like string" \
  --set-json 'telemetry.deployment={"endpoint":"https://internal.example.org"}'
expect_leaf_failure relay-cloud-api "telemetry.deployment.chart is rendered by the chart" \
  --set-json 'telemetry.deployment={"chart":"other"}'
expect_leaf_failure relay-cloud-api "telemetry.deployment key" --set-json 'telemetry.deployment={"1bad":"x"}'
expect_leaf_failure relay-cloud-api "telemetry.probes[].name must be a string" \
  --set-json 'telemetry.probes=[{"name":123,"url":"https://status.example.org/"}]'
expect_leaf_failure relay-cloud-api "at most 63 characters unless it is a dotted name" \
  --set flows.storage=gcs --set "flows.gcsBucket=$(printf 'a%.0s' $(seq 64))"
expect_leaf_failure relay-cloud-api "dotted components must each be 1-63 characters" \
  --set flows.storage=gcs --set "flows.gcsBucket=$(printf 'a%.0s' $(seq 64)).example"
expect_leaf_failure relay-cloud-api "dotted components must each be 1-63 characters" \
  --set flows.storage=gcs --set flows.gcsBucket=bad..bucket
shape=$(helm template ci charts/relay-cloud-api -n ci --no-hooks -f charts/relay-cloud-api/ci/default-values.yaml \
  "${telemetry_on[@]}" --set telemetry.level=errors \
  --set-json 'telemetry.deployment={"region":"us-central1","nodes":3,"gke":true}' \
  --set-json 'telemetry.probes=[{"name":"status-1","url":"https://status.example.org/"}]' |
  yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "SELFHOST_TELEMETRY_DEPLOYMENT" or .name == "SELFHOST_TELEMETRY_PROBES") | .value')
grep -q '"region":"us-central1"' <<<"$shape" && grep -q '"nodes":3' <<<"$shape" && grep -qx 'status-1=https://status.example.org/' <<<"$shape" \
  || { echo "relay-cloud-api: telemetry deployment/probes not rendered ($shape)" >&2; exit 1; }
helm template ci charts/relay-cloud-api -n ci --no-hooks -f charts/relay-cloud-api/ci/default-values.yaml \
  --set flows.storage=gcs --set flows.gcsBucket=flows.agent-relay.example.com >/dev/null \
  || { echo "relay-cloud-api: valid dotted GCS bucket rejected" >&2; exit 1; }

expect_leaf_failure relay-cloud-api "ingress.hosts must include the publicUrl host" \
  --set-json 'ingress.hosts=["other.gcp-proof.agentrelay.com"]'

expect_leaf_failure relay-dashboard "runtime.apiBasePath must not be /" --set runtime.apiBasePath=/
expect_leaf_failure relay-dashboard "runtime.loginPath must not be /" --set runtime.loginPath=/
expect_leaf_failure relay-dashboard "runtime.apiBasePath and runtime.loginPath must differ" --set runtime.loginPath=/cloud/api/
expect_leaf_failure relay-dashboard "runtime.loginPath must differ from runtime.appPath" --set runtime.appPath=/app --set runtime.loginPath=/app/

for child in relay-dashboard relay-cloud-api relayhistory; do
  expect_leaf_failure "$child" "podLabels must not set selector label app.kubernetes.io/name" \
    --set 'podLabels.app\.kubernetes\.io/name=custom'
done

# The authority gate applies only when Relaycast itself is deployed.
helm template proof charts/agent-relay -n agent-relay --no-hooks \
  --set components.relaycast=false --set components.relayauth=false \
  --set components.sessionsPipeline=false --set components.relayhistory=false \
  --set components.cloudApi=false --set components.dashboard=false \
  --set relaycast.credentials.authority=relayauth >/dev/null \
  || { echo "authority=relayauth gate fired with components.relaycast=false" >&2; exit 1; }

# Umbrella Ingress backends must name Services the children render, also
# without the profile's fullnameOverrides.
no_override=$(helm template ar charts/agent-relay -n agent-relay --no-hooks "${proof_args[@]}" \
  --set relaycast.fullnameOverride=null --set relayhistory.fullnameOverride=null \
  --set relay-cloud-api.fullnameOverride=null --set relay-dashboard.fullnameOverride=null \
  --set relay-dashboard.api.serviceName=null)
rendered_services=$(yq 'select(.kind == "Service") | .metadata.name' <<<"$no_override" | grep -v '^---$' | sort -u)
for backend in $(yq 'select(.kind == "Ingress") | .spec.rules[].http.paths[].backend.service.name' <<<"$no_override" | grep -v '^---$' | sort -u); do
  grep -qx "$backend" <<<"$rendered_services" \
    || { echo "umbrella Ingress backend $backend has no rendered Service" >&2; exit 1; }
done
if mismatch=$(helm template proof charts/agent-relay -n agent-relay --no-hooks "${proof_args[@]}" \
  --set gkeIngress.backends.history.serviceName=history 2>&1); then
  echo "mismatched gkeIngress backend serviceName rendered successfully" >&2
  exit 1
fi
grep -q 'gkeIngress.backends.history.serviceName=history does not match' <<<"$mismatch" \
  || { echo "backend mismatch failed without the expected error" >&2; exit 1; }

# The customer GCP profile stores Sessions objects in GCS through the native
# adapter (Workload Identity), never AWS S3 or HMAC keys.
gcp_out=$(helm template ar charts/agent-relay -n agent-relay --no-hooks -f charts/agent-relay/values-gcp.yaml)
for w in session-status-worker session-summary-worker session-metadata-indexer ar-session-ingest-api; do
  test "$(yq "select(.kind == \"Deployment\" and .metadata.name == \"$w\") |
    .spec.template.spec.containers[0].env[] | select(.name == \"LOCKER_PROVIDER\") | .value" <<<"$gcp_out")" = gcs \
    || { echo "values-gcp.yaml: $w does not select the GCS Locker" >&2; exit 1; }
done
if grep -Eq 'name: "?LOCKER_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)"?$' <<<"$gcp_out"; then
  echo "values-gcp.yaml renders static Locker HMAC credentials" >&2
  exit 1
fi

# The supported-100 overlay sizes Relaycast backups, so it must enable them.
s100=$(helm template ar charts/agent-relay -n agent-relay --no-hooks \
  -f charts/agent-relay/values-gcp.yaml -f charts/agent-relay/values-gcp-supported-100.yaml)
test "$(yq 'select(.kind == "CronJob" and .metadata.name == "relaycast-backup") | .metadata.name' <<<"$s100")" = relaycast-backup \
  || { echo "supported-100 overlay does not render the Relaycast backup CronJob" >&2; exit 1; }
test "$(yq 'select(.kind == "PersistentVolumeClaim" and .metadata.name == "relaycast-backup") | .spec.resources.requests.storage' <<<"$s100")" = 100Gi \
  || { echo "supported-100 overlay backup PVC is not 100Gi" >&2; exit 1; }

# relayauth model B has no default Relaycast URL: the keyring requires one.
if rauth_fail=$(helm template ci charts/relayauth -n ci --no-hooks -f charts/relayauth/ci/default-values.yaml \
  --set secretKeys.relaycastCredentialKeyring=relaycast-credential-keyring \
  --set secretKeys.relaycastInternalSecret=relaycast-internal-secret 2>&1); then
  echo "relayauth model B rendered without relaycast.url" >&2
  exit 1
fi
grep -q 'relaycast.url is required' <<<"$rauth_fail" \
  || { echo "relayauth model B failed without the relaycast.url error" >&2; exit 1; }

# --- durable-actors: the GKE proof overlay (control plane + Relaycast and
# Relayfile in runtime.backend=durable-actors) and the kind proof shape.
da_digest() { printf 'sha256:%s' "$(printf "$1%.0s" $(seq 64))"; }
da_args=(-f charts/agent-relay/values-gcp-proof.yaml -f charts/agent-relay/values-gcp-proof-live.yaml
  -f charts/agent-relay/values-gcp-proof-durable-actors.yaml -f charts/agent-relay/values-gcp-proof-relayfile.yaml
  --set "relaycast.runtime.durableActors.gateway.image.digest=$(da_digest a)"
  --set "relaycast.runtime.durableActors.deployer.image.digest=$(da_digest b)"
  --set "relayfile.runtime.durableActors.image.digest=$(da_digest c)"
  --set "relayfile.runtime.durableActors.workspaceImage.digest=$(da_digest d)")
da_out=$(helm template agent-relay charts/agent-relay -n agent-relay --no-hooks "${da_args[@]}")
da_fail() { echo "durable-actors overlay: $*" >&2; exit 1; }
# Capture yq output before grep -q: with pipefail an early grep exit is a SIGPIPE failure.
da_kind() { local got; got=$(yq "select(.kind == \"$1\" and .metadata.name == \"$2\") | .metadata.name" <<<"$da_out"); grep -qx "$2" <<<"$got"; }
for obj in Deployment/agent-relay-durable-actors Deployment/agent-relay-durable-actors-pool-manager \
  Service/agent-relay-durable-actors Namespace/agent-relay-agent-relay \
  NetworkPolicy/agent-relay-durable-actors NetworkPolicy/agent-relay-durable-actors-control-plane \
  Deployment/relaycast Deployment/relayfile-server Deployment/relayfile-session-broker \
  NetworkPolicy/relayfile-session-broker Service/agent-relay-gcp-proof-actors-edge \
  BackendConfig/agent-relay-gcp-proof-actors-edge; do
  da_kind "${obj%%/*}" "${obj#*/}" || da_fail "missing ${obj}"
done
test "$(yq 'select(.kind == "Job") | .metadata.name' <<<"$da_out" | grep -Ec '^(relaycast|relayfile)-actors-deploy-[0-9a-f]{8}$')" = 2 \
  || da_fail "expected the relaycast and relayfile deploy Jobs"
da_secrets=$(yq 'select(.kind == "Secret") | .metadata.name' <<<"$da_out")
if grep -q . <<<"$da_secrets"; then da_fail "renders a Secret"; fi
if grep -Eq 'helm\.sh/hook:' <<<"$da_out"; then da_fail "renders a Helm hook"; fi
# Custody: only the deploy Jobs and the relayfile session broker read the
# durable-actors admin api-key; internet-facing gateways never do.
admin_readers=$(yq 'select(.kind == "Deployment" or .kind == "Job") | select(.. | select(has("secretKeyRef")) | .secretKeyRef.name == "actors-credentials") | .kind + "/" + .metadata.name' <<<"$da_out" | grep -v '^---$' | sort -u)
for reader in $admin_readers; do
  case $reader in
    Deployment/agent-relay-durable-actors|Deployment/agent-relay-durable-actors-pool-manager) ;;
    Deployment/relayfile-session-broker|Job/relaycast-actors-deploy-*|Job/relayfile-actors-deploy-*) ;;
    *) da_fail "$reader can read the durable-actors admin api-key" ;;
  esac
done
test "$(yq 'select(.kind == "Deployment" and .metadata.name == "relaycast") | .spec.template.spec.containers[0].env[] | select(.name == "DURABLE_ACTORS_SECRET") | .valueFrom.secretKeyRef.name' <<<"$da_out")" = relaycast-durable-actors-invoke \
  || da_fail "the relaycast gateway must use its own invocation Secret"
for consumer in relaycast relayfile-server; do
  test "$(yq "select(.kind == \"Deployment\" and .metadata.name == \"$consumer\") | .spec.template.spec.containers[0].env[] | select(.name == \"DURABLE_ACTORS_CONTROL_PLANE_URL\") | .value" <<<"$da_out")" = http://agent-relay-durable-actors.agent-relay.svc.cluster.local:7100 \
    || da_fail "$consumer does not target the umbrella control plane"
done
test "$(yq 'select(.kind == "Deployment" and .metadata.name == "agent-relay-durable-actors") | .spec.template.spec.containers[0].env[] | select(.name == "DURABLE_ACTORS_PUBLIC_URL") | .value' <<<"$da_out")" = https://actors.gcp-proof.agentrelay.com \
  || da_fail "durable-actors publicUrl is not the actors host"
for host in actors.gcp-proof.agentrelay.com files.gcp-proof.agentrelay.com; do
  domains=$(yq 'select(.kind == "ManagedCertificate") | .spec.domains[]' <<<"$da_out")
  grep -qx "$host" <<<"$domains" || da_fail "ManagedCertificate lacks $host"
done
test "$(yq 'select(.kind == "Ingress") | .spec.rules[] | select(.host == "actors.gcp-proof.agentrelay.com") | .http.paths[0].backend.service.name' <<<"$da_out")" = agent-relay-gcp-proof-actors-edge \
  || da_fail "actors host is not routed to the actors edge Service"
test "$(yq 'select(.kind == "Ingress") | .spec.rules[] | select(.host == "files.gcp-proof.agentrelay.com") | .http.paths[0].backend.service.name' <<<"$da_out")" = relayfile-server \
  || da_fail "files host is not routed to the relayfile gateway"
test "$(yq 'select(.kind == "Service" and .metadata.name == "agent-relay-gcp-proof-actors-edge") | .spec.selector["app.kubernetes.io/name"]' <<<"$da_out")" = agent-relay-durable-actors \
  || da_fail "the actors edge Service does not select the control plane"
# The cast edge-deny rules are unchanged in actor mode.
test "$(yq 'select(.kind == "Ingress") | .spec.rules[] | select(.host == "cast.gcp-proof.agentrelay.com") | .http.paths[] | select(.path == "/internal") | .backend.service.name' <<<"$da_out")" = agent-relay-gcp-proof-cast-edge-deny \
  || da_fail "cast /internal is not edge-denied in actor mode"
if command -v kubeconform >/dev/null; then
  kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version "${KUBE_VERSION:-1.33.0}" <<<"$da_out" >/dev/null \
    || da_fail "kubeconform failed"
fi

# Fail closed on miswiring between the umbrella, the control plane and its consumers.
expect_da_umbrella_failure() { # expected-error helm-args...
  local expected=$1 output; shift
  if output=$(helm template agent-relay charts/agent-relay -n agent-relay --no-hooks "${da_args[@]}" "$@" 2>&1); then
    da_fail "rendered despite expected failure: $expected"
  fi
  grep -Fq "$expected" <<<"$output" || { echo "$output" >&2; da_fail "failed without expected error: $expected"; }
}
expect_da_umbrella_failure "requires components.durableActors=true" --set components.durableActors=false --set gkeIngress.hosts.actors=
expect_da_umbrella_failure "components.durableActors=true has no consumer" \
  --set relaycast.runtime.backend=sqlite --set relayfile.runtime.backend=go --set gkeIngress.hosts.files= \
  --set relaycast.credentials.format=legacy --set relaycast.credentials.authority= --set relayfile.secrets.existingSecret=relayfile
expect_da_umbrella_failure "durable-actors.publicUrl must be https://actors.gcp-proof.agentrelay.com" --set durable-actors.publicUrl=https://other.example.com
expect_da_umbrella_failure "must be durable-actors.credentialsSecret" --set relayfile.runtime.durableActors.adminKeySecret.name=other-admin
expect_da_umbrella_failure "must be durable-actors.storage.bucket" --set relaycast.runtime.durableActors.deployer.artifactBucket=other-bucket
expect_da_umbrella_failure "gkeIngress.hosts.files requires relayfile.service.annotations" --set 'relayfile.service.annotations=null'
expect_da_umbrella_failure "gkeIngress.hosts must all be distinct" --set gkeIngress.hosts.files=actors.gcp-proof.agentrelay.com
expect_da_umbrella_failure "/images/controlPlane/digest" --set durable-actors.images.controlPlane.digest=

expect_da_umbrella_failure "adminKeySecret.key (other-key) must be api-key" --set relaycast.runtime.durableActors.adminKeySecret.key=other-key
expect_da_umbrella_failure "gkeIngress.actorsBackendTimeoutSec must be an integer from 60 to 86400" --set gkeIngress.actorsBackendTimeoutSec=30
expect_da_umbrella_failure "gkeIngress.actorsBackendTimeoutSec must be an integer from 60 to 86400" --set gkeIngress.actorsBackendTimeoutSec=90.5
expect_da_umbrella_failure "gkeIngress.hosts.files requires relayfile.networkPolicy.allowExternalTraffic=false" \
  --set relayfile.networkPolicy.allowExternalTraffic=true --set 'relayfile.networkPolicy.ingressFrom=null'
expect_da_umbrella_failure "gkeIngress requires relayfile.networkPolicy.ingressFrom to allow GKE health checker/proxy range 35.191.0.0/16" \
  --set-json 'relayfile.networkPolicy.ingressFrom=[{"podSelector":{}}]'
expect_da_umbrella_failure "is set by the durable-actors gateway and must not appear in extraEnv" \
  --set-json 'relaycast.extraEnv=[{"name":"DURABLE_ACTORS_CONTROL_PLANE_URL","value":"http://evil"}]'
expect_da_umbrella_failure "is set by the durable-actors gateway and must not appear in extraEnv" \
  --set-json 'relayfile.extraEnv=[{"name":"RELAYFILE_BLOB_BUCKET","value":"other"}]'
expect_da_umbrella_failure "runtime.durableActors.gateway.replicaCount must be a positive integer" --set relaycast.runtime.durableActors.gateway.replicaCount=1.5
expect_da_umbrella_failure "runtime.durableActors.maxUploadBytes must be a positive integer" --set relaycast.runtime.durableActors.maxUploadBytes=1048576.5
expect_da_umbrella_failure "runtime.durableActors.shutdownGraceMs must be a non-negative integer" --set relaycast.runtime.durableActors.shutdownGraceMs=0.5
expect_da_umbrella_failure "runtime.durableActors.image.digest is required" --set relayfile.runtime.durableActors.image.digest= --set relayfile.runtime.durableActors.image.tag=kind
# An external controlPlaneUrl consumer does not use the in-umbrella control plane.
expect_da_umbrella_failure "components.durableActors=true has no consumer" \
  --set relaycast.runtime.durableActors.controlPlaneUrl=https://actors.example.com \
  --set relayfile.runtime.durableActors.controlPlaneUrl=https://actors.example.com
# Both control-plane workloads are behind the control-plane NetworkPolicy.
test "$(yq 'select(.kind == "NetworkPolicy" and .metadata.name == "agent-relay-durable-actors-control-plane") | .spec.podSelector.matchExpressions[0].values | join(",")' <<<"$da_out" | grep .)" = agent-relay-durable-actors,agent-relay-durable-actors-pool-manager \
  || da_fail "the control-plane NetworkPolicy must select the control plane and the pool manager"
# The relayfile gateway is internet-facing and never gets an API token; the
# GKE-only policy shape admits same-namespace pods and the GKE ranges only.
test "$(yq 'select(.kind == "Deployment" and .metadata.name == "relayfile-server") | .spec.template.spec.automountServiceAccountToken' <<<"$da_out")" = false \
  || da_fail "the relayfile gateway must not mount a ServiceAccount token"
test "$(yq 'select(.kind == "NetworkPolicy" and .metadata.name == "relayfile-server") | .spec.ingress[0].from | map(.ipBlock.cidr // "pods") | join(",")' <<<"$da_out" | grep .)" = pods,35.191.0.0/16,130.211.0.0/22 \
  || da_fail "the relayfile gateway NetworkPolicy is not the GKE-only shape"
# JWKS-only relayfile: the HS256 key is optional, so the Secret may omit it.
test "$(yq 'select(.kind == "Deployment" and .metadata.name == "relayfile-server") | .spec.template.spec.containers[0].env[] | select(.name == "RELAYFILE_JWT_SECRET") | .valueFrom.secretKeyRef.optional' <<<"$da_out")" = true \
  || da_fail "with auth.jwksUrl, RELAYFILE_JWT_SECRET must be optional"
# The relaycast actor gateway reads exactly these keys of the proof Secret
# (documented in charts/agent-relay/README.md).
proof_keys=$(yq 'select(.kind == "Deployment" and .metadata.name == "relaycast") | ((.. | select(has("secretKeyRef")) | .secretKeyRef | select(.name == "agent-relay-gcp-proof") | .key), (.. | select(has("secret")) | .secret | select(.secretName == "agent-relay-gcp-proof") | .items[].key))' <<<"$da_out" | grep -v '^---$' | grep . | sort -u | paste -sd, -)
test "$proof_keys" = relaycast-actors-internal-secret,relaycast-credential-keyring,relaycast-file-signing-secret \
  || da_fail "relaycast actor gateway reads unexpected agent-relay-gcp-proof keys: $proof_keys"
for consumer in relaycast relayfile-server; do
  grep -qx "$consumer" <<<"$(yq 'select(.kind == "Deployment") | .metadata.name' <<<"$da_out")" || da_fail "missing $consumer"
done
# NEG and legacy BackendConfig annotations are compared after normalization.
helm template agent-relay charts/agent-relay -n agent-relay --no-hooks "${da_args[@]}" \
  --set-json 'relayfile.service.annotations={"cloud.google.com/neg":"{\"ingress\":true}"}' >/dev/null \
  || da_fail "an equivalent NEG annotation without spaces was refused"
helm template agent-relay charts/agent-relay -n agent-relay --no-hooks "${da_args[@]}" --set relaycast.service.backendConfig= \
  --set-json 'relaycast.service.annotations={"cloud.google.com/backend-config":"{\"default\":\"agent-relay-gcp-proof-cast\"}"}' >/dev/null \
  || da_fail "a matching hand-written relaycast backend-config annotation was refused"
# Explicit zero bounds reach the control plane (non-null, not truthy).
zero_bound=$(helm template agent-relay charts/agent-relay -n agent-relay --no-hooks "${da_args[@]}" --set durable-actors.actors.bounds.minCpuMillis=0 |
  yq 'select(.kind == "Deployment" and .metadata.name == "agent-relay-durable-actors") | .spec.template.spec.containers[0].env[] | select(.name == "DURABLE_ACTORS_SANDBOX_MIN_CPU_MILLIS") | .value')
test "$zero_bound" = 0 || da_fail "actors.bounds.minCpuMillis=0 was dropped"
expect_da_umbrella_failure "gkeIngress.hosts.files requires components.relayfile=true" --set components.relayfile=false
expect_da_umbrella_failure "dnsCidrs/0" --set-json 'durable-actors.networkPolicy.dnsCidrs=["169.254.20.10"]'
expect_da_umbrella_failure "invokeApiKeySecretKey" --set durable-actors.invokeApiKeySecretKey=bad/key

# Long release names (Helm allows 53 characters): every name and label stays
# within 63 characters, deploy Job names keep their hash suffix, and the
# consumers' default control-plane URL is the durable-actors Service name.
long_release=agent-relay-with-a-very-long-release-name-for-ci-test
test "${#long_release}" = 53
long_out=$(helm template "$long_release" charts/agent-relay -n agent-relay --no-hooks "${da_args[@]}" \
  --set relaycast.fullnameOverride= --set relayfile.fullnameOverride= --set relayfile.nameOverride=relayfile-with-a-long-name-override-for-label-tests \
  --set relay-cloud-api.service.backendConfig=agent-relay-gcp-proof-api --set relaycast.service.backendConfig=agent-relay-gcp-proof-cast \
  --set gkeIngress.backends.files.serviceName=) \
  || da_fail "long release name failed to render"
too_long=$(yq '(select(.kind == "Service" or .kind == "Job" or .kind == "Namespace" or .kind == "Deployment") | .metadata.name | select(length > 63)),
  (.metadata.labels // {} | .[] | select(length > 63)),
  (.spec.template.metadata.labels // {} | .[] | select(length > 63))' <<<"$long_out" | grep -v '^---$' || true)
[ -z "$too_long" ] || da_fail "long release name renders names or labels over 63 characters: $too_long"
long_service=$(yq 'select(.kind == "Service" and .spec.ports[0].port == 7100 and .metadata.labels["app.kubernetes.io/component"] != "actors-edge") | .metadata.name' <<<"$long_out" | grep .)
test "$long_service" = "$(printf '%s-durable-actors' "$long_release" | cut -c1-63)" || da_fail "unexpected durable-actors Service name $long_service"
test "${#long_service}" -le 63 || da_fail "durable-actors Service name too long"
for consumer in $(yq 'select(.kind == "Deployment" or .kind == "Job") | select(.spec.template.spec.containers[0].env[]?.name == "DURABLE_ACTORS_CONTROL_PLANE_URL") | .metadata.name' <<<"$long_out" | grep -v '^---$' | sort -u); do
  url=$(yq "select(.metadata.name == \"$consumer\" and (.kind == \"Deployment\" or .kind == \"Job\")) | .spec.template.spec.containers[0].env[] | select(.name == \"DURABLE_ACTORS_CONTROL_PLANE_URL\") | .value" <<<"$long_out" | head -1)
  test "$url" = "http://$long_service.agent-relay.svc.cluster.local:7100" || da_fail "$consumer targets $url, not the Service $long_service"
done
test "$(yq 'select(.kind == "Job" and .metadata.labels["app.kubernetes.io/component"] == "actors-deploy") | .metadata.name' <<<"$long_out" | grep -Ec -- '-[0-9a-f]{8}$')" = 2 \
  || da_fail "long release name lost a deploy Job or its hash suffix"
long_pool=$(yq 'select(.kind == "Deployment" and (.metadata.name | test("pool-manager$"))) | .metadata.name' <<<"$long_out" | grep .)
long_np_values=$(yq 'select(.kind == "NetworkPolicy" and .metadata.labels["app.kubernetes.io/component"] == "durable-actors") | .spec.podSelector.matchExpressions[0].values[]' <<<"$long_out")
grep -qx "$long_pool" <<<"$long_np_values" \
  || da_fail "long release name: the control-plane NetworkPolicy misses the pool manager"

# The kind proof shape (durable-actors dev sidecars, MinIO) renders without
# the GKE-only control plane.
kind_out=$(helm template agent-relay charts/agent-relay -n agent-relay --no-hooks -f ci/agent-relay/kind-durable-actors-values.yaml)
if grep -q 'agent-relay-durable-actors' <<<"$kind_out"; then
  echo "kind proof shape renders the GKE durable-actors control plane" >&2; exit 1
fi
for d in relaycast relayfile-server; do
  test "$(yq "select(.kind == \"Deployment\" and .metadata.name == \"$d\") | .spec.template.spec.containers[1].name" <<<"$kind_out")" = durable-actors-dev \
    || { echo "kind proof shape: $d lacks the durable-actors dev sidecar" >&2; exit 1; }
done

# Single-host mode (global.singleHost.host): one host for the dashboard and the
# control API, no api host; Relaycast and Relay History keep their hosts.
sh_fail() { echo "single-host: $*" >&2; exit 1; }
sh_args=(-f charts/agent-relay/values-gcp-proof.yaml -f charts/agent-relay/ci/single-host-values.yaml)
sh_host=relay.gcp-proof.agentrelay.com
sh_out=$(helm template proof charts/agent-relay -n agent-relay --no-hooks "${sh_args[@]}")
sh_paths() { yq "select(.kind == \"Ingress\") | .spec.rules[] | select(.host == \"$1\") | .http.paths[] | .path + \" \" + .backend.service.name" <<<"$sh_out"; }
test "$(sh_paths "$sh_host")" = "$(printf '%s\n' '/cloud/api relay-cloud-api' '/login relay-cloud-api' '/api relay-cloud-api' '/ relay-dashboard')" \
  || sh_fail "unexpected routes on $sh_host: $(sh_paths "$sh_host")"
test "$(yq 'select(.kind == "Ingress") | .spec.rules[].host' <<<"$sh_out" | sort | tr '\n' ' ')" = \
  "cast.gcp-proof.agentrelay.com history.gcp-proof.agentrelay.com $sh_host " || sh_fail "unexpected Ingress hosts (an api host must not render)"
test "$(yq 'select(.kind == "ManagedCertificate") | .spec.domains[]' <<<"$sh_out" | tr '\n' ' ')" = \
  "$sh_host cast.gcp-proof.agentrelay.com history.gcp-proof.agentrelay.com " || sh_fail "ManagedCertificate domains"
sh_env() { yq "select(.kind == \"Deployment\" and .metadata.name == \"$1\") | .spec.template.spec.containers[0].env[] | select(.name == \"$2\") | .value" <<<"$sh_out"; }
test "$(sh_env relay-cloud-api SELFHOST_PUBLIC_URL)" = "https://$sh_host" || sh_fail "relay-cloud-api publicUrl is not derived"
test "$(sh_env relay-dashboard DASHBOARD_PUBLIC_URL)" = "https://$sh_host" || sh_fail "dashboard publicUrl is not derived"
# The api and cast BackendConfigs (SSE and WebSocket timeouts) are unchanged.
test "$(yq 'select(.kind == "BackendConfig" and .metadata.name == "agent-relay-gcp-proof-api") | .spec.timeoutSec' <<<"$sh_out")" = 3600 || sh_fail "api BackendConfig"
test "$(yq 'select(.kind == "BackendConfig" and .metadata.name == "agent-relay-gcp-proof-cast") | .spec.timeoutSec' <<<"$sh_out")" = 3600 || sh_fail "cast BackendConfig"
test "$(yq 'select(.kind == "Service" and .metadata.name == "relay-cloud-api") | .metadata.annotations["cloud.google.com/backend-config"]' <<<"$sh_out")" = '{"default":"agent-relay-gcp-proof-api"}' || sh_fail "api Service lost its BackendConfig"
test "$(sh_paths cast.gcp-proof.agentrelay.com | head -1)" = "/internal agent-relay-gcp-proof-cast-edge-deny" || sh_fail "cast /internal edge deny"
# The overlay example renders on the customer-neutral template.
helm template ar charts/agent-relay -n agent-relay --no-hooks -f charts/agent-relay/values-gcp.yaml \
  -f charts/agent-relay/values-single-host-example.yaml >/dev/null || sh_fail "values-single-host-example.yaml does not render on values-gcp.yaml"
expect_sh_failure() { # expected-error helm-args...
  local expected=$1 output; shift
  if output=$(helm template proof charts/agent-relay -n agent-relay --no-hooks "${sh_args[@]}" "$@" 2>&1); then
    sh_fail "rendered despite expected failure: $expected"
  fi
  grep -Fq "$expected" <<<"$output" || { echo "$output" >&2; sh_fail "failed without expected error: $expected"; }
}
expect_sh_failure "gkeIngress.hosts.api must be empty in single-host mode" --set gkeIngress.hosts.api=api.gcp-proof.agentrelay.com
expect_sh_failure "gkeIngress.hosts.root is global.singleHost.host" --set gkeIngress.hosts.root=other.gcp-proof.agentrelay.com
expect_sh_failure "gkeIngress.hosts.cast is still required in single-host mode: relaycast cannot be served under a path prefix" --set gkeIngress.hosts.cast=
expect_sh_failure "gkeIngress.hosts.history is still required in single-host mode: relayhistory cannot be served under a path prefix" --set gkeIngress.hosts.history=
expect_sh_failure "global.singleHost.host and gkeIngress.hosts.cast/history must all be distinct" --set gkeIngress.hosts.cast=$sh_host
long_label=$(printf 'a%.0s' $(seq 64))
for bad in https://$sh_host relay..gcp-proof.agentrelay.com relay.-gcp-proof.agentrelay.com Relay.gcp-proof.agentrelay.com 127.0.0.1 "$long_label.agentrelay.com"; do
  expect_sh_failure "global.singleHost.host must be a lowercase DNS hostname" --set global.singleHost.host=$bad
done
expect_sh_failure "runtime.appPath must not be /api or under it" --set relay-dashboard.runtime.appPath=/api/dashboard
expect_sh_failure "relaycast.baseUrl must not use global.singleHost.host" --set relaycast.baseUrl=https://$sh_host
expect_sh_failure "relayhistory.relayauth.historyOrigin must not use global.singleHost.host" \
  --set relayhistory.relayauth.historyOrigin=https://$sh_host --set sessions-pipeline.alleyoop.auth.historyOrigin=https://$sh_host
expect_sh_failure "relay-cloud-api.services.relaycastPublicUrl must not use global.singleHost.host" --set relay-cloud-api.services.relaycastPublicUrl=https://$sh_host
expect_sh_failure "relaycast.ingress.hosts must not include global.singleHost.host" --set-json "relaycast.ingress.hosts=[\"$sh_host\"]"
expect_sh_failure "publicUrl is derived from global.singleHost.host" --set relay-cloud-api.publicUrl=https://api.gcp-proof.agentrelay.com
expect_sh_failure "runtime.publicUrl is derived from global.singleHost.host" --set relay-dashboard.runtime.publicUrl=https://gcp-proof.agentrelay.com
# Leaf charts on their own (non-GKE edge): the dashboard Ingress carries /api.
leaf_sh=$(helm template ci charts/relay-dashboard -n ci --no-hooks -f charts/relay-dashboard/ci/single-host-values.yaml)
test "$(yq 'select(.kind == "Ingress") | .spec.rules[] | .host + " " + ([.http.paths[].path] | join(","))' <<<"$leaf_sh")" = "$sh_host /cloud/api,/login,/api,/" \
  || sh_fail "relay-dashboard leaf Ingress in single-host mode"
if out=$(helm template ci charts/relay-cloud-api -n ci --no-hooks -f charts/relay-cloud-api/ci/single-host-values.yaml --set ingress.enabled=true --set-json "ingress.hosts=[\"$sh_host\"]" --set ingress.externalTls=true 2>&1); then
  sh_fail "relay-cloud-api rendered its own Ingress in single-host mode"
fi
grep -Fq "global.singleHost.host serves the API through the dashboard host" <<<"$out" || { echo "$out" >&2; sh_fail "relay-cloud-api ingress error"; }

# With single-host mode off, every default (subdomain) render is unchanged.
ci/agent-relay/subdomain-golden.sh check

echo "agent-relay GCP proof render contract: ok"
