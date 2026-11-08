#!/usr/bin/env bash
# Chart checks shared by CI and local runs.
#
#   scripts/ci/charts.sh static [chart...]   lint, hook ban, determinism, kubeconform
#   scripts/ci/charts.sh dryrun [chart...]   server-side dry-run apply on a cluster
#
# Every chart is checked once per charts/<chart>/ci/*-values.yaml (or once with
# defaults when it has none). Renders use `helm template --no-hooks`, the way
# Alchemy's Kubernetes.HelmChart installs, so a chart that only works through
# Helm hooks fails here.
set -euo pipefail
cd "$(dirname "$0")/../.."

mode=${1:?usage: charts.sh static|dryrun [chart...]}; shift
charts=("$@")
[ ${#charts[@]} -gt 0 ] || charts=($(ls -d charts/*/ | xargs -n1 basename))
fail=0
err() { echo "::error::$*"; fail=1; }

render() { # chart valuesfile [extra helm args]
  local chart=$1 v=$2 args=(); shift 2
  if [ -n "$v" ]; then
    args=(-f "$v")
    # The umbrella CI fixture supplies immutable proof/render image identities
    # on the operator-facing GCP proof values.
    [ "$chart" = agent-relay ] && args=(-f "charts/agent-relay/values-gcp-proof.yaml" -f "$v")
  fi
  helm template ci "charts/$chart" --namespace ci --no-hooks --include-crds "${args[@]}" "$@"
}

expect_render_failure() { # chart valuesfile label expected-error [extra helm args]
  local chart=$1 v=$2 label=$3 expected=$4 output; shift 4
  echo "--- static: $chart (reject $label)"
  if output=$(render "$chart" "$v" "$@" 2>&1); then
    err "$chart: $label unexpectedly rendered successfully"
  elif ! grep -Fq "$expected" <<<"$output"; then
    err "$chart: $label failed without expected error: $expected"
    echo "$output"
  fi
}

# helm dependency build only resolves https repositories that are added.
add_repos() { # Chart.yaml
  local repo
  for repo in $(sed -n 's/^ *repository: *\(https:.*\)/\1/p' "$1" | sort -u); do
    helm repo add "dep-$(echo "$repo" | md5sum | cut -c1-8)" "$repo" >/dev/null 2>&1 || true
  done
}

for chart in "${charts[@]}"; do
  [ -f "charts/$chart/Chart.yaml" ] || { err "$chart: no Chart.yaml"; continue; }
  if [ -f "charts/$chart/Chart.lock" ] || grep -q '^dependencies:' "charts/$chart/Chart.yaml"; then
    # Helm does not recursively vendor dependencies of a file:// dependency.
    # Build the sessions umbrella first so agent-relay always contains its
    # sessions-pipeline-worker/alleyoop/third-party children, even in an isolated check.
    # (charts sort alphabetically, so agent-relay runs before sessions-pipeline
    # has added its https repositories: add them here too.)
    if [ "$chart" = agent-relay ]; then
      add_repos charts/sessions-pipeline/Chart.yaml
      helm dependency build charts/sessions-pipeline >/dev/null || { err "$chart: nested sessions-pipeline dependency build failed"; continue; }
    fi
    add_repos "charts/$chart/Chart.yaml"
    helm dependency build "charts/$chart" >/dev/null || { err "$chart: helm dependency build failed"; continue; }
  fi
  values=(charts/"$chart"/ci/*-values.yaml)
  [ -e "${values[0]}" ] || values=("")
  for v in "${values[@]}"; do
    label="$chart${v:+ ($(basename "$v"))}"
    echo "--- $mode: $label"
    case $mode in
      static)
        args=()
        if [ -n "$v" ]; then
          args=(-f "$v")
          [ "$chart" = agent-relay ] && args=(-f "charts/agent-relay/values-gcp-proof.yaml" -f "$v")
        fi
        helm lint --strict "charts/$chart" "${args[@]}" >/dev/null || { helm lint --strict "charts/$chart" "${args[@]}"; err "$label: helm lint --strict failed"; continue; }
        out=$(render "$chart" "$v") || { err "$label: render failed"; continue; }
        if [[ "$v" == *numeric-extra-env-values.yaml ]]; then
          count_quoted_env() {
            local name=$1 value=$2
            awk -v name="$name" -v value="$value" '
              index($0, "- name: \"" name "\"") || index($0, "- name: " name) { found=1; next }
              found && index($0, "value: \"" value "\"") { quoted++; found=0 }
              found && /value:/ { found=0 }
              END { print quoted + 0 }
            ' <<<"$out"
          }
          count_value_from_env() {
            local name=$1
            awk -v name="$name" '
              index($0, "- name: \"" name "\"") || index($0, "- name: " name) { found=1; next }
              found && /valueFrom:/ { structured++; found=0 }
              found && /- name:/ { found=0 }
              END { print structured + 0 }
            ' <<<"$out"
          }
          case $chart in
            session-ingest-api) expected_shared=1; component_env=INGEST_RETRY_LIMIT ;;
            sessions-pipeline-worker) expected_shared=5; component_env=REFEREE_RETRY_LIMIT ;;
            *) err "$label: numeric env fixture is unsupported for $chart"; expected_shared=0; component_env=UNKNOWN ;;
          esac
          [ "$(count_quoted_env REDIS_PORT 6378)" -eq "$expected_shared" ] \
            || err "$label: REDIS_PORT must render as the quoted string \"6378\" in all $expected_shared workloads"
          [ "$(count_value_from_env REDIS_PASSWORD)" -eq "$expected_shared" ] \
            || err "$label: REDIS_PASSWORD valueFrom must remain structured in all $expected_shared workloads"
          [ "$(count_quoted_env OPTIONAL_FLAG '')" -eq "$expected_shared" ] \
            || err "$label: null OPTIONAL_FLAG must render as an empty string in all $expected_shared workloads"
          [ "$(count_quoted_env "$component_env" 6379)" -eq 1 ] \
            || err "$label: component EnvVar $component_env must render as the quoted string \"6379\""
        fi
        if [[ "$v" == *pod-identity-values.yaml ]] && grep -Eq '^[[:space:]]*- name: LOCKER_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)[[:space:]]*$' <<<"$out"; then
          err "$label: podIdentity mode renders a static Locker credential environment variable"
        fi
        if [[ "$v" == *migration-owner-values.yaml ]]; then
          migration_ref=$(yq 'select(.kind == "Job" and (.metadata.name | contains("migrate"))) | .spec.template.spec.containers[0].env[] | select(.name == "HOOPDB_URL") | .valueFrom.secretKeyRef | .name + "/" + .key' <<<"$out")
          [ "$migration_ref" = "hoopdb-migration/HOOPDB_MIGRATION_URL" ] \
            || err "$label: migrate Job must read only the migration-owner URL, got $migration_ref"
          runtime_refs=$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "HOOPDB_URL") | .valueFrom.secretKeyRef | .name + "/" + .key' <<<"$out" | grep -v '^---$' | sort -u)
          [ "$runtime_refs" = "hoopdb-runtime/HOOPDB_URL" ] \
            || err "$label: long-running workloads must read only the runtime URL, got $runtime_refs"
        fi
        if [ "$chart" = "sessions-pipeline-worker" ]; then
          summary_file_refs=$(grep -Ec '^[[:space:]]*- name: SUMMARY_MASTER_KEYS_FILE[[:space:]]*$' <<<"$out" || true)
          summary_value_refs=$(grep -Ec '^[[:space:]]*- name: SUMMARY_MASTER_KEYS[[:space:]]*$' <<<"$out" || true)
          [ "$summary_file_refs" -eq 1 ] || err "$label: SUMMARY_MASTER_KEYS_FILE must be injected exactly once (Bob Costas only), found $summary_file_refs"
          [ "$summary_value_refs" -eq 0 ] || err "$label: SUMMARY_MASTER_KEYS must never be injected as an environment variable, found $summary_value_refs"
        fi
        # --no-hooks drops hooked objects, so ban hooks on a full render.
        # Helm test hooks are allowed (e.g. in third-party subcharts): dropping them is harmless.
        if helm template ci "charts/$chart" --namespace ci "${args[@]}" | grep -E '^\s*"?helm\.sh/hook"?\s*:' | grep -vE ':\s*"?test(-success)?"?\s*$'; then
          err "$label: renders a helm.sh/hook annotation. Hooks never run under Alchemy (helm template --no-hooks); use a plain Job instead"
        fi
        if ! diff -q <(echo "$out") <(render "$chart" "$v") >/dev/null; then
          err "$label: render is not deterministic (randAlphaNum/lookup/now?); every render would look like drift"
        fi
        kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version "${KUBE_VERSION:-1.33.0}" <<<"$out" || err "$label: kubeconform failed"
        ;;
      dryrun)
        dryrun_out=$(render "$chart" "$v")
        # Generic CI clusters do not install GKE's ManagedCertificate,
        # FrontendConfig and BackendConfig CRDs. Their schemas are covered by static rendering;
        # dry-run the portable Kubernetes objects here.
        if [ "$chart" = agent-relay ]; then
          dryrun_out=$(yq 'select(.kind != "ManagedCertificate" and .kind != "FrontendConfig" and .kind != "BackendConfig")' <<<"$dryrun_out")
        fi
        # A server-side dry run does not create a Namespace it applies, so
        # objects a chart places in a namespace it renders itself (the
        # durable-actors sandbox namespace) would fail as NotFound. Create
        # rendered Namespaces for real first; CI clusters are disposable.
        rendered_ns=$(yq 'select(.kind == "Namespace")' <<<"$dryrun_out")
        if [ -n "$(tr -d '[:space:]-' <<<"$rendered_ns")" ]; then
          kubectl apply --server-side --field-manager=ci -f - <<<"$rendered_ns" >/dev/null \
            || err "$label: creating rendered Namespaces failed"
        fi
        # kubectl refuses an object whose metadata.namespace differs from -n,
        # so apply objects the chart places in another namespace (the
        # durable-actors sandbox namespace <release>-<ns>) per namespace.
        other_ns=$(yq -N 'select(.metadata.namespace != null and .metadata.namespace != "ci") | .metadata.namespace' <<<"$dryrun_out" | sort -u)
        kubectl apply --server-side --dry-run=server --field-manager=ci -n ci -f - \
          <<<"$(yq 'select(.metadata.namespace == null or .metadata.namespace == "ci")' <<<"$dryrun_out")" >/dev/null \
          || err "$label: server-side dry-run apply failed"
        for ns in $other_ns; do
          kubectl apply --server-side --dry-run=server --field-manager=ci -n "$ns" -f - \
            <<<"$(NS="$ns" yq 'select(.metadata.namespace == strenv(NS))' <<<"$dryrun_out")" >/dev/null \
            || err "$label: server-side dry-run apply in namespace $ns failed"
        done
        ;;
      *) echo "unknown mode $mode" >&2; exit 2 ;;
    esac
  done
  if [ "$mode" = static ]; then
    case $chart in
      sessions-pipeline-worker)
        v=charts/sessions-pipeline-worker/ci/pod-identity-values.yaml
        expect_render_failure "$chart" "$v" "unknown credential mode" "locker.credentials.mode must be secret or podIdentity" --set locker.credentials.mode=invalid
        expect_render_failure "$chart" "$v" "missing database Secret" "hoopdb.existingSecret or existingSecret is required for HOOPDB_URL" --set hoopdb.existingSecret=
        expect_render_failure "$chart" "$v" "migration Secret without key" "migrations.hoopdb.existingSecret and key must be set together" --set migrations.hoopdb.existingSecret=hoopdb-migration
        expect_render_failure "$chart" "$v" "migration key without Secret" "migrations.hoopdb.existingSecret and key must be set together" --set migrations.hoopdb.key=HOOPDB_MIGRATION_URL
        v=charts/sessions-pipeline-worker/ci/external-secrets-values.yaml
        expect_render_failure "$chart" "$v" "unmapped managed migration key" "externalSecrets.data must map HOOPDB_MIGRATION_URL" --set migrations.hoopdb.existingSecret=sessions-pipeline --set migrations.hoopdb.key=HOOPDB_MIGRATION_URL
        render "$chart" "$v" --set migrations.enabled=false --set migrations.hoopdb.existingSecret=sessions-pipeline --set migrations.hoopdb.key=HOOPDB_MIGRATION_URL >/dev/null \
          || err "$chart: disabled migrations must not require the unused managed migration key"
        numeric=$(render "$chart" "$v" --set migrations.hoopdb.existingSecret=hoopdb-migration --set-string migrations.hoopdb.key=123)
        grep -Fq 'key: "123"' <<<"$numeric" \
          || err "$chart: numeric-looking migration Secret keys must remain quoted strings"
        v=charts/sessions-pipeline-worker/ci/pod-identity-values.yaml
        expect_render_failure "$chart" "$v" "missing summary Secret" "summaryEncryption.existingSecret or existingSecret is required when bob-costas is enabled" --set summaryEncryption.existingSecret=
        expect_render_failure "$chart" "$v" "duplicate summary key env" "configure summaryEncryption instead of components.bob-costas.env" --set-json 'components.bob-costas.env=[{"name":"SUMMARY_MASTER_KEYS","value":"not-a-real-key"}]'
        expect_render_failure "$chart" "$v" "secret mode without endpoint" "locker.endpoint is required when locker.credentials.mode=secret" --set locker.credentials.mode=secret --set existingSecret=sessions-pipeline
        expect_render_failure "$chart" "$v" "extraEnv in-cluster http" "extraEnv must not set ALLOW_IN_CLUSTER_HTTP" --set-json 'extraEnv=[{"name":"ALLOW_IN_CLUSTER_HTTP","value":"true"}]'
        expect_render_failure "$chart" "$v" "component in-cluster http" "components.referee.env must not set ALLOW_IN_CLUSTER_HTTP" --set-json 'components.referee.env=[{"name":"ALLOW_IN_CLUSTER_HTTP","value":"true"}]'
        ;;
      session-ingest-api)
        v=charts/session-ingest-api/ci/pod-identity-values.yaml
        expect_render_failure "$chart" "$v" "unknown credential mode" "locker.credentials.mode must be secret or podIdentity" --set locker.credentials.mode=invalid
        expect_render_failure "$chart" "$v" "missing database Secret" "hoopdb.existingSecret or existingSecret is required for HOOPDB_URL" --set hoopdb.existingSecret=
        expect_render_failure "$chart" "$v" "secret mode without endpoint" "locker.endpoint is required when locker.credentials.mode=secret" --set locker.credentials.mode=secret --set existingSecret=sessions-pipeline
        expect_render_failure "$chart" "$v" "local JWKS without Secret" "existingSecret is required when auth.localJwks=true" --set auth.jwksUrl= --set auth.localJwks=true
        expect_render_failure "$chart" "$v" "interim bearer in production" "auth.allowInterimRelayAuthBearer=true is allowed only when environment=local" --set auth.allowInterimRelayAuthBearer=true
        expect_render_failure "$chart" "$v" "interim bearer through raw env" "configure auth.allowInterimRelayAuthBearer instead of ingest.env" --set-json 'ingest.env=[{"name":"ALLOW_INTERIM_RELAYAUTH_BEARER","value":"true"}]'
        expect_render_failure "$chart" "$v" "interim bearer through extraEnv" "configure auth.allowInterimRelayAuthBearer instead of extraEnv" --set-json 'extraEnv=[{"name":"ALLOW_INTERIM_RELAYAUTH_BEARER","value":"true"}]'
        expect_render_failure "$chart" "$v" "non-boolean interim bearer" "auth.allowInterimRelayAuthBearer must be a boolean" --set-string auth.allowInterimRelayAuthBearer=true
        default_auth=$(render "$chart" "$v")
        grep -A1 -F -- '- name: ALLOW_INTERIM_RELAYAUTH_BEARER' <<<"$default_auth" | grep -Fq 'value: "false"' \
          || err "$chart: interim RelayAuth bearer must render false by default"
        local_auth=$(render "$chart" "$v" --set environment=local --set auth.allowInterimRelayAuthBearer=true)
        grep -A1 -F -- '- name: ALLOW_INTERIM_RELAYAUTH_BEARER' <<<"$local_auth" | grep -Fq 'value: "true"' \
          || err "$chart: explicit local interim RelayAuth bearer opt-in did not render true"
        for origin in https://history.example.com/x https://history.example.com:99999 https://history.example.com:8a https://user@history.example.com 'https://history..example.com' https://-history.example.com ftp://history.example.com; do
          expect_render_failure "$chart" "$v" "history origin $origin" "auth.historyOrigin must be a bare origin" --set "auth.historyOrigin=$origin"
        done
        for origin in https://history.gcp-proof.agentrelay.com http://relayhistory.relayhistory.svc:8080; do
          render "$chart" "$v" --set "auth.historyOrigin=$origin" >/dev/null || err "$chart: valid auth.historyOrigin $origin rejected"
        done
        ;;
      relayauth)
        v=charts/relayauth/ci/default-values.yaml
        expect_render_failure "$chart" "$v" "mutable image" "image.digest is required" --set image.digest=
        expect_render_failure "$chart" "$v" "malformed digest" "image.digest must be sha256:<64 lowercase hex characters>" --set image.digest=sha256:abc
        expect_render_failure "$chart" "$v" "missing external Secret" "existingSecret is required" --set existingSecret=
        expect_render_failure "$chart" "$v" "unsafe Secret key path" "secretKeys.signingKey must be a Kubernetes Secret data key" --set-string secretKeys.signingKey=../key.pem
        expect_render_failure "$chart" "$v" "multiple SQLite writers" "replicaCount must be 1" --set replicaCount=2
        expect_render_failure "$chart" "$v" "JWKS ingress without host" "jwksIngress.enabled=true requires at least one host" --set jwksIngress.enabled=true
        expect_render_failure "$chart" "$v" "public JWKS with private discovery URL" "jwksIngress.enabled=true requires an explicit externally reachable baseUrl" --set jwksIngress.enabled=true --set jwksIngress.hosts[0]=auth.example.com
        expect_render_failure "$chart" "$v" "blocked JWKS ingress" "jwksIngress with networkPolicy requires networkPolicy.ingressFrom" --set jwksIngress.enabled=true --set jwksIngress.hosts[0]=auth.example.com --set baseUrl=https://auth.example.com --set networkPolicy.enabled=true
        expect_render_failure "$chart" "$v" "keyring without relaycast secret" "secretKeys.relaycastInternalSecret is required when secretKeys.relaycastCredentialKeyring is set" --set secretKeys.relaycastCredentialKeyring=relaycast-credential-keyring
        expect_render_failure "$chart" "$v" "relaycast secret without keyring" "secretKeys.relaycastInternalSecret requires secretKeys.relaycastCredentialKeyring" --set secretKeys.relaycastInternalSecret=relaycast-internal-secret
        expect_render_failure "$chart" "$v" "service key without keyring" "secretKeys.relaycastServiceApiKey requires secretKeys.relaycastCredentialKeyring" --set secretKeys.relaycastServiceApiKey=relaycast-service-api-key
        ;;
      relaycast)
        v=charts/relaycast/ci/default-values.yaml
        expect_render_failure "$chart" "$v" "mutable image" "image.digest is required" --set image.digest=
        expect_render_failure "$chart" "$v" "malformed digest" "image.digest must be sha256:<64 lowercase hex characters>" --set image.digest=sha256:abc
        expect_render_failure "$chart" "$v" "missing origin" "baseUrl is required" --set baseUrl=
        expect_render_failure "$chart" "$v" "plaintext public origin" "baseUrl must be an HTTPS origin" --set baseUrl=http://relay.example.com
        expect_render_failure "$chart" "$v" "origin with path" "baseUrl must be an HTTPS origin" --set baseUrl=https://relay.example.com/relay
        expect_render_failure "$chart" "$v" "single-label origin" "baseUrl must be an HTTPS origin" --set baseUrl=https://localhost
        expect_render_failure "$chart" "$v" "IP-literal origin" "baseUrl must be an HTTPS origin" --set baseUrl=https://127.0.0.1
        expect_render_failure "$chart" "$v" "origin with credentials" "baseUrl must be an HTTPS origin" --set baseUrl=https://user:pass@relay.example.com
        expect_render_failure "$chart" "$v" "special-use local origin" "baseUrl must not use the special-use .local namespace" --set baseUrl=https://relay.example.local
        expect_render_failure "$chart" "$v" "special-use localhost origin" "baseUrl must not use the special-use .localhost namespace" --set baseUrl=https://relay.localhost
        expect_render_failure "$chart" "$v" "invalid public port" "baseUrl port must be between 1 and 65535" --set baseUrl=https://relay.example.com:65536
        expect_render_failure "$chart" "$v" "insecure origin with path" "baseUrl must be an origin" --set allowInsecureBaseUrl=true --set baseUrl=http://relaycast.relaycast.svc:8787/x
        expect_render_failure "$chart" "$v" "missing Secret" "existingSecret is required" --set existingSecret=
        expect_render_failure "$chart" "$v" "unsafe Secret key path" "secretKeys.internalSecret must be a Kubernetes Secret data key" --set-string secretKeys.internalSecret=../key
        expect_render_failure "$chart" "$v" "non-boolean public create" "publicWorkspaceCreate must be true or false" --set-string publicWorkspaceCreate=yes
        expect_render_failure "$chart" "$v" "direct public Service" "service.type must be ClusterIP" --set service.type=LoadBalancer
        expect_render_failure "$chart" "$v" "multiple SQLite writers" "replicaCount must be 1" --set replicaCount=2
        expect_render_failure "$chart" "$v" "zero SQLite writers" "replicaCount must be 1" --set replicaCount=0
        expect_render_failure "$chart" "$v" "unreleased HA backend" "runtime.backend must be sqlite" --set runtime.backend=armadillo
        expect_render_failure "$chart" "$v" "unsafe persistence access mode" "persistence.accessMode must be ReadWriteOnce or ReadWriteOncePod" --set persistence.accessMode=ReadWriteMany
        expect_render_failure "$chart" "$v" "secret via extraEnv" "RELAYCAST_INTERNAL_SECRET is managed by structured chart values" --set-json 'extraEnv=[{"name":"RELAYCAST_INTERNAL_SECRET","value":"not-a-real-secret"}]'
        expect_render_failure "$chart" "$v" "bootstrap secret via extraEnv" "RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET is managed by structured chart values" --set-json 'extraEnv=[{"name":"RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET","value":"not-a-real-secret"}]'
        expect_render_failure "$chart" "$v" "public create via extraEnv" "RELAYCAST_PUBLIC_WORKSPACE_CREATE is managed by structured chart values" --set-json 'extraEnv=[{"name":"RELAYCAST_PUBLIC_WORKSPACE_CREATE","value":"true"}]'
        expect_render_failure "$chart" "$v" "reserved database path" "RELAYCAST_DB_PATH is managed by structured chart values" --set-json 'extraEnv=[{"name":"RELAYCAST_DB_PATH","value":"/tmp/other.db"}]'
        expect_render_failure "$chart" "$v" "zero message retention" "retention.messageTtlDays must be a positive integer" --set retention.messageTtlDays=0
        expect_render_failure "$chart" "$v" "negative message retention" "retention.messageTtlDays must be a positive integer" --set retention.messageTtlDays=-1
        expect_render_failure "$chart" "$v" "boolean message retention" "retention.messageTtlDays must be a positive integer" --set retention.messageTtlDays=true
        expect_render_failure "$chart" "$v" "zero mailbox TTL" "mailbox.ttlMs must be a positive integer" --set mailbox.ttlMs=0
        expect_render_failure "$chart" "$v" "boolean mailbox TTL" "mailbox.ttlMs must be a positive integer" --set mailbox.ttlMs=true
        expect_render_failure "$chart" "$v" "zero mailbox depth" "mailbox.depthCap must be a positive integer" --set mailbox.depthCap=0
        expect_render_failure "$chart" "$v" "boolean mailbox depth" "mailbox.depthCap must be a positive integer" --set mailbox.depthCap=true
        expect_render_failure "$chart" "$v" "unknown credential format" "credentials.format must be legacy or ar" --set credentials.format=jwt
        expect_render_failure "$chart" "$v" "ar format without authority" "credentials.authority is required when credentials.format=ar" --set credentials.format=ar
        expect_render_failure "$chart" "$v" "relayauth authority without URL" "credentials.relayauth.url is required when credentials.authority=relayauth" --set credentials.authority=relayauth --set secretKeys.relayauthToken=relaycast-relayauth-token
        expect_render_failure "$chart" "$v" "relayauth authority without token" "secretKeys.relayauthToken is required when credentials.authority=relayauth" --set credentials.authority=relayauth --set credentials.relayauth.url=http://relayauth:8787
        expect_render_failure "$chart" "$v" "self authority without keyring" "secretKeys.credentialKeyring is required when credentials.authority=self" --set credentials.authority=self
        expect_render_failure "$chart" "$v" "tagger URL without token" "secretKeys.relayauthToken is required when credentials.relayauth.url is set" --set credentials.relayauth.url=http://relayauth:8787
        expect_render_failure "$chart" "$v" "tagger token without URL" "credentials.relayauth.url is required when secretKeys.relayauthToken is set" --set secretKeys.relayauthToken=relaycast-relayauth-token
        expect_render_failure "$chart" "$v" "tagger token via extraEnv" "RELAYCAST_RELAYAUTH_TOKEN_FILE is managed by structured chart values" --set-json 'extraEnv=[{"name":"RELAYCAST_RELAYAUTH_TOKEN_FILE","value":"/tmp/t"}]'
        expect_render_failure "$chart" "$v" "keyring via extraEnv" "RELAYCAST_CREDENTIAL_KEYRING_FILE is managed by structured chart values" --set-json 'extraEnv=[{"name":"RELAYCAST_CREDENTIAL_KEYRING_FILE","value":"/tmp/k"}]'
        v=charts/relaycast/ci/full-values.yaml
        expect_render_failure "$chart" "$v" "ingress with public create" "ingress.enabled requires publicWorkspaceCreate=false" --set publicWorkspaceCreate=true
        expect_render_failure "$chart" "$v" "ingress with insecure origin" "ingress.enabled requires an HTTPS public baseUrl" --set allowInsecureBaseUrl=true
        expect_render_failure "$chart" "$v" "ingress without hosts" "ingress.enabled=true requires at least one host" --set-json 'ingress.hosts=[]'
        expect_render_failure "$chart" "$v" "ingress host mismatch" "ingress.hosts must include the baseUrl host" --set-json 'ingress.hosts=["other.example.com"]'
        expect_render_failure "$chart" "$v" "ingress blocked by NetworkPolicy" "ingress with networkPolicy requires networkPolicy.ingressFrom" --set-json 'networkPolicy.ingressFrom=[]'
        expect_render_failure "$chart" "$v" "backup on ReadWriteOncePod" "backup.enabled requires persistence.accessMode=ReadWriteOnce" --set persistence.accessMode=ReadWriteOncePod
        expect_render_failure "$chart" "$v" "zero backup retention" "backup.keep must be a positive integer" --set backup.keep=0
        expect_render_failure "$chart" "$v" "ingress without TLS" "ingress.enabled=true requires ingress.tls" --set-json 'ingress.tls=[]'
        # Long release names: suffixed names stay distinct and within limits.
        long=$(render "$chart" "$v" --set fullnameOverride="$(printf 'a%.0s' $(seq 63))")
        [ "$(yq 'select(.kind == "Service") | .metadata.name' <<<"$long" | grep -v '^---' | sort -u | wc -l | tr -d " ")" = 2 ] || err "$chart: long fullname collapses the app and deny Services"
        [ "$(yq 'select(.kind == "CronJob") | .metadata.name | length' <<<"$long")" -le 52 ] || err "$chart: long fullname makes the CronJob name exceed 52 characters"
        # Rendered-contract checks: secrets only as files, edge denials routed
        # to the endpoint-less Service, public create off.
        out=$(render "$chart" "$v")
        grep -q 'name: RELAYCAST_INTERNAL_SECRET_FILE' <<<"$out" || err "$chart: internal secret is not passed as a file"
        grep -q 'name: RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET_FILE' <<<"$out" || err "$chart: bootstrap secret is not passed as a file"
        ! grep -Eq 'name: RELAYCAST_(INTERNAL|WORKSPACE_BOOTSTRAP)_SECRET$' <<<"$out" || err "$chart: a secret is rendered as a plain environment variable"
        [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "RELAYCAST_PUBLIC_WORKSPACE_CREATE") | .value' <<<"$out")" = false ] \
          || err "$chart: public workspace create is not off"
        for p in /internal /v1/workspaces /v1/workspaces/; do
          [ "$(yq "select(.kind == \"Ingress\") | .spec.rules[0].http.paths[] | select(.path == \"$p\") | .backend.service.name" <<<"$out")" = ci-relaycast-deny ] \
            || err "$chart: ingress path $p is not routed to the deny Service"
        done
        [ "$(yq 'select(.kind == "Service" and .metadata.name == "ci-relaycast-deny") | (.spec | has("selector") | not)' <<<"$out")" = true ] \
          || err "$chart: the deny Service must have no selector"
        [ "$(yq 'select(.kind == "CronJob") | .spec.jobTemplate.spec.template.metadata.labels["app.kubernetes.io/name"]' <<<"$out")" = relaycast-backup ] \
          || err "$chart: backup pods must not carry the Service selector labels"
        # runtime.backend=durable-actors (env contract v1).
        v=charts/relaycast/ci/durable-actors-values.yaml
        expect_render_failure "$chart" "$v" "actors without ar_ credentials" "requires credentials.format=ar" --set credentials.format=legacy --set credentials.authority=
        expect_render_failure "$chart" "$v" "actors without keyring" "requires secretKeys.credentialKeyring" --set secretKeys.credentialKeyring=
        expect_render_failure "$chart" "$v" "actors with insecure origin" "requires an HTTPS public baseUrl" --set allowInsecureBaseUrl=true --set ingress.enabled=false
        expect_render_failure "$chart" "$v" "actors gateway with admin Secret" "must not be the admin key Secret" --set runtime.durableActors.invocationSecret.name=actors-credentials
        expect_render_failure "$chart" "$v" "actors gateway key in existingSecret" "must be its own Secret" --set runtime.durableActors.invocationSecret.name=relaycast-secrets
        expect_render_failure "$chart" "$v" "actors without invocation Secret" "invocationSecret.name is required" --set runtime.durableActors.invocationSecret.name=
        expect_render_failure "$chart" "$v" "actors local files with replicas" "requires fileStore.driver gcs or s3" --set runtime.durableActors.fileStore.driver=local
        expect_render_failure "$chart" "$v" "actors without file bucket" "fileStore.bucket is required" --set runtime.durableActors.fileStore.bucket=
        expect_render_failure "$chart" "$v" "actors with SQLite backup" "backup.enabled backs up the SQLite volume" --set backup.enabled=true
        expect_render_failure "$chart" "$v" "actors with SQLite retention" "retention.* and mailbox.* configure the SQLite image" --set retention.messageTtlDays=7
        expect_render_failure "$chart" "$v" "actors deployer without bucket" "deployer.artifactBucket is required" --set runtime.durableActors.deployer.artifactBucket=
        expect_render_failure "$chart" "$v" "actors deployer without actor env" "actorEnvSecrets is required" --set-json 'runtime.durableActors.actorEnvSecrets=[]'
        expect_render_failure "$chart" "$v" "actors unpinned gateway" "runtime.durableActors.gateway.image.digest (or, for local proofs" --set runtime.durableActors.gateway.image.digest=
        expect_render_failure "$chart" "$v" "actors dev runtime unacknowledged" "requires devRuntime.acknowledgeNonProduction=true" --set runtime.durableActors.devRuntime.enabled=true
        out=$(render "$chart" "$v")
        [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "DURABLE_ACTORS_SECRET") | .valueFrom.secretKeyRef.name' <<<"$out")" = relaycast-durable-actors-invoke ] \
          || err "$chart: the actors gateway must read DURABLE_ACTORS_SECRET from the invocation Secret"
        [ "$(yq 'select(.kind == "Job") | .spec.template.spec.containers[0].env[] | select(.name == "DURABLE_ACTORS_SECRET") | .valueFrom.secretKeyRef.name' <<<"$out")" = actors-credentials ] \
          || err "$chart: the deployer must read the admin api-key Secret"
        ! yq 'select(.kind == "Deployment") | .. | select(has("secretKeyRef")) | .secretKeyRef.name' <<<"$out" | grep -qx actors-credentials \
          || err "$chart: the actors gateway can read the durable-actors admin api-key"
        [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "RELAYCAST_PUBLIC_WORKSPACE_CREATE") | .value' <<<"$out")" = false ] \
          || err "$chart: the actors gateway allows public workspace create"
        ! yq 'select(.kind == "PersistentVolumeClaim") | .metadata.name' <<<"$out" | grep -q . \
          || err "$chart: the actors gateway with an object file store renders a PVC"
        ;;
      relayfile)
        v=charts/relayfile/ci/durable-actors-values.yaml
        expect_render_failure "$chart" "$v" "unknown backend" "runtime.backend must be go or durable-actors" --set runtime.backend=bogus
        expect_render_failure "$chart" "$v" "actors without Secret" "runtime.durableActors.existingSecret is required" --set runtime.durableActors.existingSecret=
        expect_render_failure "$chart" "$v" "actors with Go inline secrets" "are Go-server values" --set secrets.jwtSecret=not-a-real-secret
        expect_render_failure "$chart" "$v" "actors without token verification" "secretKeys.jwtSecret or auth.jwksUrl is required" --set runtime.durableActors.secretKeys.jwtSecret= --set auth.jwksUrl=
        expect_render_failure "$chart" "$v" "actors inline blobs in production" "driver=inline is only allowed with devRuntime" --set runtime.durableActors.blobStore.driver=inline
        expect_render_failure "$chart" "$v" "actors gateway sharing the admin Secret" "must be a different Secret" --set runtime.durableActors.adminKeySecret.name=relayfile-actors
        expect_render_failure "$chart" "$v" "actors without broker token" "secretKeys.brokerToken is required" --set runtime.durableActors.secretKeys.brokerToken=
        expect_render_failure "$chart" "$v" "actors deployer without bucket" "deployer.artifactBucket is required" --set runtime.durableActors.deployer.artifactBucket=
        expect_render_failure "$chart" "$v" "actors unpinned image" "runtime.durableActors.image.digest is required" --set runtime.durableActors.image.digest=
        expect_render_failure "$chart" "$v" "actors tag-only image" "runtime.durableActors.image.digest is required (image tags are only allowed with devRuntime)" --set runtime.durableActors.image.digest= --set runtime.durableActors.image.tag=v1
        expect_render_failure "$chart" "$v" "actors tag-only workspace image" "runtime.durableActors.workspaceImage.digest is required" --set runtime.durableActors.workspaceImage.digest= --set runtime.durableActors.workspaceImage.tag=v1
        expect_render_failure "$chart" "$v" "actors fractional replicas" "gateway.replicaCount must be a positive integer" --set runtime.durableActors.gateway.replicaCount=1.5
        expect_render_failure "$chart" "$v" "actors fractional inline max" "inlineMaxBytes must be a non-negative integer" --set runtime.durableActors.blobStore.inlineMaxBytes=10.5
        expect_render_failure "$chart" "$v" "actors extraEnv override" "is set by the durable-actors gateway and must not appear in extraEnv" --set-json 'extraEnv=[{"name":"DURABLE_ACTORS_CONTROL_PLANE_URL","value":"http://x"}]'
        expect_render_failure "$chart" "$v" "ingressFrom with external traffic" "networkPolicy.ingressFrom requires networkPolicy.allowExternalTraffic=false" --set networkPolicy.enabled=true --set-json 'networkPolicy.ingressFrom=[{"podSelector":{}}]'
        v=charts/relayfile/ci/durable-actors-dev-values.yaml
        expect_render_failure "$chart" "$v" "dev runtime unacknowledged" "requires devRuntime.acknowledgeNonProduction=true" --set runtime.durableActors.devRuntime.acknowledgeNonProduction=false
        expect_render_failure "$chart" "$v" "dev runtime autoscaled" "devRuntime forces one replica" --set autoscaling.enabled=true
        out=$(render "$chart" charts/relayfile/ci/durable-actors-values.yaml)
        ! yq 'select(.kind == "Deployment" and .metadata.name == "ci-relayfile-server") | .. | select(has("secretKeyRef")) | .secretKeyRef.name' <<<"$out" | grep -qx actors-credentials \
          || err "$chart: the internet-facing gateway can read the durable-actors admin api-key"
        [ "$(yq 'select(.kind == "Deployment" and .metadata.name == "ci-relayfile-session-broker") | .spec.template.spec.containers[0].env[] | select(.name == "DURABLE_ACTORS_SECRET") | .valueFrom.secretKeyRef.name' <<<"$out")" = actors-credentials ] \
          || err "$chart: the session broker must read the admin api-key Secret"
        [ "$(yq 'select(.kind == "NetworkPolicy" and .metadata.name == "ci-relayfile-session-broker") | .spec.ingress[0].from[0].podSelector.matchLabels["app.kubernetes.io/component"]' <<<"$out")" = server ] \
          || err "$chart: the session broker NetworkPolicy must admit only gateway pods"
        dev=$(render "$chart" charts/relayfile/ci/durable-actors-dev-values.yaml)
        [ "$(yq 'select(.kind == "Deployment") | .spec.replicas' <<<"$dev")" = 1 ] || err "$chart: devRuntime must force one replica"
        ! yq 'select(.kind == "Job" or (.kind == "Deployment" and .metadata.name == "ci-relayfile-session-broker")) | .metadata.name' <<<"$dev" | grep -q . \
          || err "$chart: devRuntime must not render the broker or the deploy Job"
        ;;
      relay-webapp)
        v=charts/relay-webapp/ci/default-values.yaml
        expect_render_failure "$chart" "$v" "mutable image" "image.digest is required" --set image.digest=
        expect_render_failure "$chart" "$v" "malformed digest" "image.digest must be sha256:<64 lowercase hex characters>" --set image.digest=sha256:abc
        expect_render_failure "$chart" "$v" "public Service" "service.type must be ClusterIP" --set service.type=LoadBalancer
        expect_render_failure "$chart" "$v" "missing API backend" "api.serviceName is required" --set api.serviceName=
        expect_render_failure "$chart" "$v" "invalid public URL" "runtime.publicUrl must be an HTTPS origin" --set runtime.publicUrl=http://gcp-proof.agentrelay.com
        expect_render_failure "$chart" "$v" "ingress without TLS" "ingress.enabled=true requires ingress.tls" --set-json 'ingress.tls=[]'
        out=$(render "$chart" "$v")
        [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.initContainers[0].name' <<<"$out")" = copy-dashboard ] \
          || err "$chart: writable dashboard content must be prepared by the hardened init container"
        [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].volumeMounts[] | select(.mountPath == "/usr/share/nginx/html") | .name' <<<"$out")" = html ] \
          || err "$chart: runtime-config.js cannot be written with a read-only root filesystem"
        ! yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[].name' <<<"$out" | grep -qx DASHBOARD_CUSTOMER_PROFILE \
          || err "$chart: no customerProfile must render no DASHBOARD_CUSTOMER_PROFILE (default branding)"
        expect_render_failure "$chart" "$v" "non-map customer profile" "customerProfile must be a map" --set customerProfile=Acme
        expect_render_failure "$chart" "$v" "false customer profile" "customerProfile must be a map" --set customerProfile=false
        expect_render_failure "$chart" "$v" "list customer profile" "customerProfile must be a map" --set-json 'customerProfile=[]'
        expect_render_failure "$chart" "$v" "empty-string customer profile" "customerProfile must be a map" --set-string 'customerProfile='
        brand=$(render "$chart" charts/relay-webapp/ci/branding.profile.yaml)
        profile=$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "DASHBOARD_CUSTOMER_PROFILE") | .value' <<<"$brand")
        [ "$(jq -r '.productName + " " + .logo.dark + " " + (.poweredByAgentRelay | tostring)' <<<"$profile")" = "Acme Relay https://acme.example/brand/logo-on-dark.svg true" ] \
          || err "$chart: customerProfile must render as one JSON object in DASHBOARD_CUSTOMER_PROFILE"
        ;;
      relay-control)
        v=charts/relay-control/ci/default-values.yaml
        expect_render_failure "$chart" "$v" "mutable image" "image.digest is required" --set image.digest=
        expect_render_failure "$chart" "$v" "malformed digest" "image.digest must be sha256:<64 lowercase hex characters>" --set image.digest=sha256:abc
        expect_render_failure "$chart" "$v" "missing Secret" "existingSecret is required" --set existingSecret=
        expect_render_failure "$chart" "$v" "multiple replicas" "replicaCount must be 1" --set replicaCount=2
        expect_render_failure "$chart" "$v" "missing runtime database role" "database.runtimeRole must be a valid PostgreSQL role name" --set database.runtimeRole=
        expect_render_failure "$chart" "$v" "invalid public URL" "publicUrl must be an HTTPS origin with no path" --set publicUrl=https://gcp-proof.agentrelay.com/cloud
        expect_render_failure "$chart" "$v" "invalid internal History origin" "services.relayhistoryUrl must be an HTTP(S) origin" --set services.relayhistoryUrl=http://relayhistory:8080/v1
        expect_render_failure "$chart" "$v" "plaintext public Relaycast origin" "services.relaycastPublicUrl must be a public HTTPS origin" --set services.relaycastPublicUrl=http://cast.gcp-proof.agentrelay.com
        expect_render_failure "$chart" "$v" "private public History origin" "services.relayhistoryPublicUrl must be a public HTTPS origin" --set services.relayhistoryPublicUrl=https://relayhistory
        out=$(render "$chart" "$v")
        grep -q 'name: SELFHOST_PUBLIC_URL' <<<"$out" || err "$chart: SELFHOST_PUBLIC_URL is not rendered"
        grep -q 'name: RELAYCAST_PUBLIC_URL' <<<"$out" || err "$chart: RELAYCAST_PUBLIC_URL is not rendered"
        grep -q 'name: RELAYHISTORY_PUBLIC_URL' <<<"$out" || err "$chart: RELAYHISTORY_PUBLIC_URL is not rendered"
        grep -q 'name: DATABASE_MIGRATIONS_URL_FILE' <<<"$out" || err "$chart: migration owner URL is not file-backed"
        ! yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[].name' <<<"$out" | grep -q '^DATABASE_MIGRATIONS_URL_FILE$' \
          || err "$chart: API Deployment can read the migration owner URL"
        [ "$(yq 'select(.kind == "Job") | .spec.template.spec.containers[0].command | join(" ")' <<<"$out")" = node ] \
          || err "$chart: migration Job must invoke node directly"
        [ "$(yq 'select(.kind == "Job") | .spec.template.spec.containers[0].args | join(" ")' <<<"$out")" = node_modules/@cloud/selfhost-api/dist/migrate-cli.js ] \
          || err "$chart: migration Job must invoke the packaged migrate CLI directly"
        ! grep -q 'export DATABASE_URL_FILE' <<<"$out" || err "$chart: obsolete migration DATABASE_URL_FILE adapter is still rendered"
        ! grep -Eq 'CLOUD_EDITION|NEXT_PUBLIC_APP_URL|OIDC_|AUTH_SESSION_SECRET|NEXT_CACHE' <<<"$out" \
          || err "$chart: full-Cloud/Next environment leaked into the selfhost API chart"
        # bootstrap-signup: identity settings render to relaycontrol's env and
        # their secrets only as mounted files.
        idv=charts/relay-control/ci/identity-values.yaml
        id_out=$(render "$chart" "$idv")
        id_env=$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | .name + "=" + (.value // "")' <<<"$id_out")
        for want in "SELFHOST_BOOTSTRAP_ORG_NAME=Acme" "SELFHOST_BOOTSTRAP_ADMIN_EMAIL=ops@acme.com" \
          "SELFHOST_OIDC_ISSUER=https://accounts.google.com" "SELFHOST_OIDC_ALLOWED_DOMAINS=acme.com" \
          "SELFHOST_OIDC_CLIENT_SECRET_FILE=/var/run/agent-relay/secrets/oidc-client-secret" \
          "RELAYCAST_INTERNAL_SECRET_FILE=/var/run/agent-relay/secrets/relaycast-internal-secret" \
          "SELFHOST_SMTP_PASSWORD_FILE=/var/run/agent-relay/secrets/smtp-password" "SELFHOST_SMTP_PORT=465" \
          "SELFHOST_EMAIL_LOGIN=true" "SELFHOST_AUTO_JOIN_DOMAINS=acme.com" "SELFHOST_INVITE_TTL_HOURS=72"; do
          grep -qxF "$want" <<<"$id_env" || err "$chart: identity values did not render $want"
        done
        [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.volumes[] | select(.name == "secrets") | .secret.items[].key' <<<"$id_out" | grep -cE '^(oidc-client-secret|smtp-password|relaycast-internal-secret)$')" = 3 ] \
          || err "$chart: identity secrets must be projected into the secrets volume"
        ! grep -Eq 'SELFHOST_BOOTSTRAP_(ORG|ADMIN|WORKSPACE)|SELFHOST_(OIDC|SMTP|EMAIL|AUTO_JOIN|INVITE)_|RELAYCAST_INTERNAL_SECRET' <<<"$out" \
          || err "$chart: identity env must not render without identity values"
        expect_render_failure "$chart" "$v" "bootstrap without admin" "bootstrap.orgName and bootstrap.adminEmail must be set together" --set bootstrap.orgName=Acme
        expect_render_failure "$chart" "$v" "bootstrap with a bad admin email" "bootstrap.adminEmail must be an email address" --set bootstrap.orgName=Acme --set bootstrap.adminEmail=ops
        expect_render_failure "$chart" "$v" "bootstrap without dashboardUrl" "dashboardUrl is required with bootstrap" --set bootstrap.orgName=Acme --set bootstrap.adminEmail=ops@acme.com --set secretKeys.relaycastInternalSecret=relaycast-internal-secret
        expect_render_failure "$chart" "$v" "bootstrap without the Relaycast secret" "bootstrap.orgName requires secretKeys.relaycastInternalSecret" --set dashboardUrl=https://gcp-proof.agentrelay.com/ --set bootstrap.orgName=Acme --set bootstrap.adminEmail=ops@acme.com
        expect_render_failure "$chart" "$v" "plaintext OIDC issuer" "auth.oidc.issuer must be an https URL" --set auth.oidc.issuer=http://dex:5556/dex --set auth.oidc.clientId=x --set secretKeys.oidcClientSecret=oidc-client-secret --set dashboardUrl=https://gcp-proof.agentrelay.com/
        expect_render_failure "$chart" "$v" "OIDC without client secret" "auth.oidc.issuer requires secretKeys.oidcClientSecret" --set auth.oidc.issuer=https://accounts.google.com --set auth.oidc.clientId=x --set dashboardUrl=https://gcp-proof.agentrelay.com/
        expect_render_failure "$chart" "$v" "OIDC without client id" "auth.oidc.clientId is required" --set auth.oidc.issuer=https://accounts.google.com --set secretKeys.oidcClientSecret=oidc-client-secret --set dashboardUrl=https://gcp-proof.agentrelay.com/
        expect_render_failure "$chart" "$v" "OIDC settings without issuer" "auth.oidc.* settings need auth.oidc.issuer" --set auth.oidc.clientId=x
        expect_render_failure "$chart" "$v" "bad allowed domain" "list email domains such as example.com" --set auth.oidc.issuer=https://accounts.google.com --set auth.oidc.clientId=x --set secretKeys.oidcClientSecret=oidc-client-secret --set-json 'auth.oidc.allowedDomains=["not a domain"]' --set dashboardUrl=https://gcp-proof.agentrelay.com/
        expect_render_failure "$chart" "$v" "bad redirect URL" "auth.oidc.redirectUrl must be <origin>/login/oidc/callback" --set auth.oidc.issuer=https://accounts.google.com --set auth.oidc.clientId=x --set secretKeys.oidcClientSecret=oidc-client-secret --set auth.oidc.redirectUrl=https://relay.acme.com/callback --set dashboardUrl=https://gcp-proof.agentrelay.com/
        expect_render_failure "$chart" "$v" "email links without SMTP" "auth.emailLink.enabled requires smtp.host" --set dashboardUrl=https://gcp-proof.agentrelay.com/ --set auth.emailLink.enabled=true
        expect_render_failure "$chart" "$v" "SMTP without from" "smtp.from is required with smtp.host" --set dashboardUrl=https://gcp-proof.agentrelay.com/ --set smtp.host=smtp.acme.com
        expect_render_failure "$chart" "$v" "SMTP user without password" "smtp.username and secretKeys.smtpPassword must be set together" --set dashboardUrl=https://gcp-proof.agentrelay.com/ --set smtp.host=smtp.acme.com --set smtp.from=relay@acme.com --set smtp.username=u
        expect_render_failure "$chart" "$v" "SMTP port zero" "smtp.port must be 1-65535" --set dashboardUrl=https://gcp-proof.agentrelay.com/ --set smtp.host=smtp.acme.com --set smtp.from=relay@acme.com --set smtp.port=0
        expect_render_failure "$chart" "$v" "SMTP without dashboardUrl" "dashboardUrl is required with bootstrap, auth.oidc, auth.emailLink or smtp" --set smtp.host=smtp.acme.com --set smtp.from=relay@acme.com
        expect_render_failure "$chart" "$v" "bad invite TTL" "auth.inviteTtlHours must be an integer from 1 to 720" --set auth.inviteTtlHours=0
        expect_render_failure "$chart" "$v" "identity secret reusing an API key" "both name Secret key" --set secretKeys.relaycastInternalSecret=selfhost-bootstrap-token --set bootstrap.orgName=Acme --set bootstrap.adminEmail=ops@acme.com --set dashboardUrl=https://gcp-proof.agentrelay.com/
        [ -n "$(render "$chart" "$v" --set dashboardUrl=https://gcp-proof.agentrelay.com/ --set auth.oidc.issuer=http://dex:5556/dex --set auth.oidc.clientId=x --set secretKeys.oidcClientSecret=oidc-client-secret --set auth.oidc.allowHttpIssuer=true)" ] \
          || err "$chart: allowHttpIssuer=true must accept an in-cluster http issuer"
        ;;
      relayhistory)
        v=charts/relayhistory/ci/default-values.yaml
        expect_render_failure "$chart" "$v" "mutable image" "image.digest is required" --set image.digest=
        expect_render_failure "$chart" "$v" "malformed digest" "image.digest must be sha256:<64 lowercase hex characters>" --set image.digest=sha256:abc
        expect_render_failure "$chart" "$v" "missing database Secret" "database.existingSecret is required" --set database.existingSecret=
        expect_render_failure "$chart" "$v" "missing origin" "relayauth.historyOrigin must be an HTTPS origin" --set relayauth.historyOrigin=
        expect_render_failure "$chart" "$v" "plaintext origin" "relayauth.historyOrigin must be an HTTPS origin" --set relayauth.historyOrigin=http://history.example.com
        expect_render_failure "$chart" "$v" "ingress without TLS" "ingress.enabled=true requires ingress.tls" --set-json 'ingress.tls=[]'
        expect_render_failure "$chart" "$v" "drain without write hold" "migrations.drainForWriteHold requires migrations.allowWriteHold=true" --set migrations.drainForWriteHold=true
        expect_render_failure "$chart" "$v" "drain without migrations" "migrations.drainForWriteHold requires migrations.enabled=true" --set migrations.drainForWriteHold=true --set migrations.allowWriteHold=true --set migrations.enabled=false
        expect_render_failure "$chart" "$v" "replicaCount 0" "set migrations.drainForWriteHold=true instead" --set replicaCount=0
        # Write-hold step 1 drains History to zero replicas and runs the Job with the hold;
        # default and step 2 keep one replica and no hold.
        wh=$(helm template ci "charts/$chart" -n ci --no-hooks -f "$v" --set migrations.allowWriteHold=true --set migrations.drainForWriteHold=true) \
          || err "$chart: write-hold step 1 failed to render"
        [ "$(yq 'select(.kind == "Deployment") | .spec.replicas' <<<"$wh")" = 0 ] || err "$chart: drainForWriteHold did not render replicas 0"
        [ "$(yq 'select(.kind == "Job") | .spec.template.spec.containers[0].env[] | select(.name == "ALLOW_WRITE_HOLD") | .value' <<<"$wh")" = yes ] \
          || err "$chart: write-hold step 1 Job does not take the write hold"
        # The Job must not start migrating while a History pod still terminates:
        # an init container polls the API for this release's History pods.
        [ "$(yq 'select(.kind == "Job") | .spec.template.spec.initContainers[0].name' <<<"$wh")" = wait-for-history-drain ] \
          || err "$chart: write-hold step 1 Job does not wait for History to drain"
        [ "$(yq 'select(.kind == "Job") | .spec.template.spec.initContainers[0].env[] | select(.name == "HISTORY_SELECTOR") | .value' <<<"$wh")" = "app.kubernetes.io/name=relayhistory,app.kubernetes.io/instance=ci,app.kubernetes.io/component=history" ] \
          || err "$chart: drain wait selector is not release-scoped"
        [ "$(yq 'select(.kind == "Job") | .spec.template.spec.containers[0].volumeMounts[].name' <<<"$wh" | grep -c drain-wait-token || true)" = 0 ] \
          || err "$chart: the migrate container must not mount the drain-wait token"
        [ "$(yq 'select(.kind == "Role") | .rules[0].verbs | join(",")' <<<"$wh")" = list ] \
          || err "$chart: drain-wait Role must only list pods"
        expect_render_failure "$chart" "$v" "drain without API egress" "requires migrations.drainWaitApiServerEgress" --set migrations.drainForWriteHold=true --set migrations.allowWriteHold=true --set networkPolicy.allowAllEgress=false --set-json 'networkPolicy.additionalEgress=[{"to":[{"ipBlock":{"cidr":"10.0.0.5/32"}}]}]'
        expect_render_failure "$chart" "$v" "fractional drain wait" "migrations.drainWaitSeconds must be a positive integer" --set migrations.drainWaitSeconds=1.5
        expect_render_failure "$chart" "$v" "drain wait over the Job deadline" "migrations.drainWaitSeconds must be below migrations.activeDeadlineSeconds" --set migrations.drainForWriteHold=true --set migrations.allowWriteHold=true --set migrations.drainWaitSeconds=3600
        expect_render_failure "$chart" "$v" "drain wait on the default ServiceAccount" "requires serviceAccount.name" --set migrations.drainForWriteHold=true --set migrations.allowWriteHold=true --set serviceAccount.create=false
        [ "$(helm template ci "charts/$chart" -n ci --no-hooks -f "$v" --set migrations.allowWriteHold=true --set migrations.drainForWriteHold=true --set networkPolicy.allowAllEgress=false --set-json 'networkPolicy.additionalEgress=[{"to":[{"ipBlock":{"cidr":"10.0.0.5/32"}}]}]' --set-json 'migrations.drainWaitApiServerEgress=[{"ipBlock":{"cidr":"10.0.0.1/32"}}]' --set migrations.drainWaitApiServerPort=6443 | yq 'select(.kind == "NetworkPolicy" and (.metadata.name | test("migration$"))) | .spec.egress[-1].ports[0].port')" = 6443 ] \
          || err "$chart: drainWaitApiServerPort is not rendered in the migration policy"
        dflt=$(helm template ci "charts/$chart" -n ci --no-hooks -f "$v") || err "$chart: default render failed"
        [ "$(yq 'select(.kind == "Role") | .metadata.name' <<<"$dflt")" = "" ] || err "$chart: default render must not grant pod list"
        [ "$(yq 'select(.kind == "Deployment") | .spec.replicas' <<<"$dflt")" = 1 ] || err "$chart: default render is not one replica"
        [ "$(yq 'select(.kind == "Job") | .spec.template.spec.containers[0].env[] | select(.name == "ALLOW_WRITE_HOLD") | .value' <<<"$dflt")" = no ] \
          || err "$chart: default Job takes a write hold"
        ;;
      agent-relay)
        v=charts/agent-relay/ci/gcp-proof-values.yaml
        expect_render_failure "$chart" "$v" "missing History image" "image.digest is required" --set relayhistory.image.digest=
        expect_render_failure "$chart" "$v" "missing API image" "image.digest is required" --set relay-control.image.digest=
        expect_render_failure "$chart" "$v" "missing dashboard image" "image.digest is required" --set relay-webapp.image.digest=
        expect_render_failure "$chart" "$v" "dashboardUrl off the root host" "relay-control.dashboardUrl must be on the dashboard host" --set relay-control.dashboardUrl=https://elsewhere.agentrelay.com/
        [ -n "$(render "$chart" "$v" --set relay-control.dashboardUrl=https://gcp-proof.agentrelay.com:443/)" ] || err "$chart: dashboardUrl with an explicit :443 on the root host must render"
        expect_render_failure "$chart" "$v" "ar_ authority without relayauth" "relaycast.credentials.authority=relayauth requires components.relayauth=true" --set components.relayauth=false --set relaycast.credentials.format=ar --set relaycast.credentials.authority=relayauth --set relaycast.credentials.relayauth.url=http://relayauth:8787 --set relaycast.secretKeys.relayauthToken=relaycast-relayauth-token
        ;;
    esac
  fi
done
exit $fail
