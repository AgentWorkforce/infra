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
    if [ "$chart" = agent-relay ]; then
      if [ "$(basename "$v")" = gcp-native-values.yaml ]; then
        args=(-f "charts/agent-relay/values-gcp.yaml" -f "charts/agent-relay/values-gcp-native.yaml" -f "$v")
      else
        args=(-f "charts/agent-relay/values-gcp-proof.yaml" -f "$v")
      fi
    fi
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

# postgresCa (the optional Postgres server CA bundle): off renders nothing; on,
# every Deployment and migrate Job container gets exactly one read-only mount and
# NODE_EXTRA_CA_CERTS; a half-configured value is refused.
check_postgres_ca() { # chart valuesfile
  local chart=$1 v=$2 off on missing total
  off=$(render "$chart" "$v") || { err "$chart: postgresCa off did not render"; return; }
  ! grep -Eq 'NODE_EXTRA_CA_CERTS|PGSSLROOTCERT|postgres-ca' <<<"$off" || err "$chart: postgresCa off must render nothing"
  on=$(render "$chart" "$v" --set postgresCa.enabled=true --set postgresCa.configMap=ca-bundle) || { err "$chart: postgresCa on did not render"; return; }
  local workloads='select(.kind == "Deployment" or (.kind == "Job" and (.metadata.name | contains("migrate"))))'
  total=$(yq "$workloads | .metadata.name" <<<"$on" | grep -v '^---$' | grep -c .)
  [ "$total" -ge 1 ] || err "$chart: postgresCa check found no workloads"
  missing=$(yq "$workloads | select(([.spec.template.spec.containers[0].env[] | select(.name == \"NODE_EXTRA_CA_CERTS\" and .value == \"/etc/postgres-ca/ca.crt\")] | length) != 1 or ([.spec.template.spec.containers[0].volumeMounts[] | select(.name == \"postgres-ca\" and .mountPath == \"/etc/postgres-ca\" and .readOnly == true)] | length) != 1 or ([.spec.template.spec.volumes[] | select(.name == \"postgres-ca\" and .configMap.name == \"ca-bundle\" and .configMap.items[0].path == \"ca.crt\")] | length) != 1) | .metadata.name" <<<"$on" | grep -v '^---$' || true)
  [ -z "$missing" ] || err "$chart: postgresCa did not reach: $missing"
  kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version "${KUBE_VERSION:-1.33.0}" <<<"$on" >/dev/null || err "$chart: postgresCa on failed kubeconform"
  on=$(render "$chart" "$v" --set postgresCa.enabled=true --set postgresCa.secret=ca-secret --set postgresCa.key=rds.pem) || { err "$chart: postgresCa Secret did not render"; return; }
  missing=$(yq "$workloads | select(([.spec.template.spec.volumes[] | select(.name == \"postgres-ca\" and .secret.secretName == \"ca-secret\" and .secret.items[0].key == \"rds.pem\" and .secret.defaultMode == 0444)] | length) != 1) | .metadata.name" <<<"$on" | grep -v '^---$' || true)
  [ -z "$missing" ] || err "$chart: postgresCa Secret volume wrong in: $missing"
  expect_render_failure "$chart" "$v" "postgresCa without a source" "postgresCa.enabled=true requires exactly one of postgresCa.configMap or postgresCa.secret" --set postgresCa.enabled=true
  expect_render_failure "$chart" "$v" "postgresCa with both sources" "postgresCa.enabled=true requires exactly one of postgresCa.configMap or postgresCa.secret" --set postgresCa.enabled=true --set postgresCa.configMap=a --set postgresCa.secret=b
  expect_render_failure "$chart" "$v" "postgresCa source while disabled" "require postgresCa.enabled=true" --set postgresCa.configMap=ca-bundle
  expect_render_failure "$chart" "$v" "postgresCa non-boolean enabled" "postgresCa.enabled must be a boolean" --set-string postgresCa.enabled=true
  expect_render_failure "$chart" "$v" "postgresCa bad name" "must be a Kubernetes object name" --set postgresCa.enabled=true --set postgresCa.configMap=Bad_Name
  expect_render_failure "$chart" "$v" "postgresCa bad key" "postgresCa.key must be a Kubernetes data key" --set postgresCa.enabled=true --set postgresCa.configMap=ca-bundle --set postgresCa.key=../x
  expect_render_failure "$chart" "$v" "postgresCa extraEnv override" "NODE_EXTRA_CA_CERTS" --set postgresCa.enabled=true --set postgresCa.configMap=ca-bundle --set-json 'extraEnv=[{"name":"NODE_EXTRA_CA_CERTS","value":"/x"}]'
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
          if [ "$chart" = agent-relay ]; then
            if [ "$(basename "$v")" = gcp-native-values.yaml ]; then
              args=(-f "charts/agent-relay/values-gcp.yaml" -f "charts/agent-relay/values-gcp-native.yaml" -f "$v")
            else
              args=(-f "charts/agent-relay/values-gcp-proof.yaml" -f "$v")
            fi
          fi
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
        check_postgres_ca "$chart" "$v"
        expect_render_failure "$chart" "$v" "postgresCa component env override" "components.referee.env must not set NODE_EXTRA_CA_CERTS" --set postgresCa.enabled=true --set postgresCa.configMap=ca-bundle --set-json 'components.referee.env=[{"name":"NODE_EXTRA_CA_CERTS","value":"/x"}]'
        # locker-init opens no Postgres connection; wait-for-role is psql (PGSSLROOTCERT).
        ca_out=$(render "$chart" "$v" --set postgresCa.enabled=true --set postgresCa.configMap=ca-bundle --set migrations.waitForRole.enabled=true --set migrations.waitForRole.image=ghcr.io/cloudnative-pg/postgresql:17@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff --set lockerInit.enabled=true)
        [ "$(yq 'select(.kind == "Job" and (.metadata.name | contains("locker-init"))) | .spec.template.spec.volumes[] | select(.name == "postgres-ca") | .name' <<<"$ca_out")" = "" ] \
          || err "$chart: locker-init must not mount the Postgres CA"
        [ "$(yq 'select(.kind == "Job" and (.metadata.name | contains("migrate"))) | .spec.template.spec.initContainers[0].env[] | select(.name == "PGSSLROOTCERT") | .value' <<<"$ca_out" | grep -v '^---$')" = /etc/postgres-ca/ca.crt ] \
          || err "$chart: wait-for-role must set PGSSLROOTCERT when postgresCa is on"
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
        check_postgres_ca "$chart" "$v"
        expect_render_failure "$chart" "$v" "postgresCa ingest env override" "must not set NODE_EXTRA_CA_CERTS" --set postgresCa.enabled=true --set postgresCa.configMap=ca-bundle --set-json 'ingest.env=[{"name":"NODE_EXTRA_CA_CERTS","value":"/x"}]'
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
        # Keyed creates: the workspace bootstrap secret and proof policy (relaycast #622).
        expect_render_failure "$chart" "$v" "actors proof without bootstrap secret" "bootstrapProofRequired=true with runtime.backend=durable-actors requires secretKeys.workspaceBootstrapSecret" --set bootstrapProofRequired=true
        expect_render_failure "$chart" "$v" "actors proof not a bool" "bootstrapProofRequired must be true or false" --set-string bootstrapProofRequired=yes --set secretKeys.workspaceBootstrapSecret=wbs
        expect_render_failure "$chart" "$v" "actors bootstrap secret in extraEnv" "must not appear in extraEnv" --set-json 'extraEnv=[{"name":"RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET","value":"x"}]'
        expect_render_failure "$chart" "$v" "actors proof flag in extraEnv" "must not appear in extraEnv" --set-json 'extraEnv=[{"name":"RELAYCAST_WORKSPACE_BOOTSTRAP_PROOF_REQUIRED","value":"true"}]'
        expect_render_failure "$chart" "$v" "actors bootstrap file in extraEnv" "must not appear in extraEnv" --set-json 'extraEnv=[{"name":"RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET_FILE","value":"/tmp/key"}]'
        out=$(render "$chart" charts/relaycast/ci/default-values.yaml --set secretKeys.workspaceBootstrapSecret=wbs)
        ! grep -q wbs <<<"$out" || err "$chart: the SQLite render must ignore secretKeys.workspaceBootstrapSecret"
        out=$(render "$chart" "$v")
        gw_env() { yq "select(.kind == \"Deployment\") | .spec.template.spec.containers[] | select(.name == \"$1\") | .env[] | select(.name == \"$2\") | $3" <<<"$out"; }
        [ "$(gw_env gateway RELAYCAST_WORKSPACE_BOOTSTRAP_PROOF_REQUIRED .value)" = false ] \
          || err "$chart: the actors gateway must render RELAYCAST_WORKSPACE_BOOTSTRAP_PROOF_REQUIRED=false by default"
        [ -z "$(gw_env gateway RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET .name)" ] \
          || err "$chart: the actors gateway renders RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET without secretKeys.workspaceBootstrapSecret"
        out=$(render "$chart" "$v" --set secretKeys.workspaceBootstrapSecret=relaycast-actors-workspace-bootstrap-secret --set bootstrapProofRequired=true)
        [ "$(gw_env gateway RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET '.valueFrom.secretKeyRef.name + "/" + .valueFrom.secretKeyRef.key')" = relaycast-secrets/relaycast-actors-workspace-bootstrap-secret ] \
          || err "$chart: the actors gateway must read RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET from existingSecret/secretKeys.workspaceBootstrapSecret"
        [ "$(gw_env gateway RELAYCAST_WORKSPACE_BOOTSTRAP_PROOF_REQUIRED .value)" = true ] \
          || err "$chart: bootstrapProofRequired=true must render RELAYCAST_WORKSPACE_BOOTSTRAP_PROOF_REQUIRED=true on the actors gateway"
        [ -z "$(gw_env gateway RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET_FILE .name)" ] \
          || err "$chart: the actors gateway must read the bootstrap secret as exact bytes (env), not _FILE"
        # Configurable names must be honored, not silently replaced by example names.
        original_job=$(yq 'select(.kind == "Job") | .metadata.name' <<<"$out")
        out=$(render "$chart" "$v" --set existingSecret=custom-gateway --set secretKeys.workspaceBootstrapSecret=custom-bootstrap --set bootstrapProofRequired=true)
        [ "$(gw_env gateway RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET '.valueFrom.secretKeyRef.name + "/" + .valueFrom.secretKeyRef.key')" = custom-gateway/custom-bootstrap ] \
          || err "$chart: actor bootstrap wiring ignores configurable Secret names"
        # Neither the bootstrap reference nor its proof policy changes the deployer
        # inputs. Operators must explicitly rerun a completed Job and refresh actors.
        [ "$(yq 'select(.kind == "Job") | .metadata.name' <<<"$out")" = "$original_job" ] \
          || err "$chart: bootstrap wiring unexpectedly changes deployer identity"
        # The dev sidecar is the actors' env: it gets the same two values.
        out=$(render "$chart" charts/relaycast/ci/durable-actors-dev-values.yaml --set secretKeys.workspaceBootstrapSecret=wbs --set bootstrapProofRequired=true)
        for c in gateway durable-actors-dev; do
          [ "$(gw_env "$c" RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET '.valueFrom.secretKeyRef.name + "/" + .valueFrom.secretKeyRef.key')" = relaycast-secrets/wbs ] \
            || err "$chart: devRuntime $c must read RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET from secretKeys.workspaceBootstrapSecret"
          [ "$(gw_env "$c" RELAYCAST_WORKSPACE_BOOTSTRAP_PROOF_REQUIRED .value)" = true ] \
            || err "$chart: devRuntime $c must render RELAYCAST_WORKSPACE_BOOTSTRAP_PROOF_REQUIRED=true"
        done
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
        # global.branding.logo: nothing by default; an inline SVG becomes a
        # chart ConfigMap and an existing ConfigMap key is mounted read-only at
        # html/brand/<key>, which the image serves at /brand/<key>.
        ! grep -q brand <<<"$out" || err "$chart: no global.branding.logo must render no brand volume or ConfigMap"
        svg='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10" style="fill:#123"/></svg>'
        logo=$(render "$chart" "$v" --set-string "global.branding.logo.svg=$svg")
        [ "$(yq 'select(.kind == "ConfigMap" and .metadata.name == "ci-relay-webapp-brand") | .data["logo.svg"]' <<<"$logo")" = "$svg" ] \
          || err "$chart: an inline logo must render the ci-relay-webapp-brand ConfigMap with logo.svg"
        [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].volumeMounts[] | select(.name == "brand") | .mountPath + " " + (.readOnly | tostring)' <<<"$logo")" = "/usr/share/nginx/html/brand true" ] \
          || err "$chart: the logo must be mounted read-only at /usr/share/nginx/html/brand"
        [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.volumes[] | select(.name == "brand") | .configMap.name + " " + .configMap.items[0].key' <<<"$logo")" = "ci-relay-webapp-brand logo.svg" ] \
          || err "$chart: the brand volume must project logo.svg from the chart ConfigMap"
        logo=$(render "$chart" "$v" --set global.branding.logo.existingConfigMap=relay-brand --set global.branding.logo.key=acme-logo.png)
        [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.volumes[] | select(.name == "brand") | .configMap.name + " " + .configMap.items[0].path' <<<"$logo")" = "relay-brand acme-logo.png" ] \
          || err "$chart: existingConfigMap must project its key as the served file"
        ! yq 'select(.kind == "ConfigMap") | .metadata.name' <<<"$logo" | grep -q brand || err "$chart: existingConfigMap must not render a chart ConfigMap"
        kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version "${KUBE_VERSION:-1.33.0}" <<<"$logo" >/dev/null || err "$chart: branding logo render failed kubeconform"
        expect_render_failure "$chart" "$v" "logo with both sources" "set svg or existingConfigMap, not both" --set-string "global.branding.logo.svg=$svg" --set global.branding.logo.existingConfigMap=relay-brand
        expect_render_failure "$chart" "$v" "logo key without a ConfigMap" "global.branding.logo.key names a key in existingConfigMap" --set global.branding.logo.key=logo.png
        expect_render_failure "$chart" "$v" "logo key path" "global.branding.logo.key must be a file name" --set global.branding.logo.existingConfigMap=relay-brand --set global.branding.logo.key=../logo.png
        expect_render_failure "$chart" "$v" "logo key type" "global.branding.logo.key must be a file name" --set global.branding.logo.existingConfigMap=relay-brand --set global.branding.logo.key=logo.gif
        expect_render_failure "$chart" "$v" "non-SVG inline logo" "must be SVG markup" --set-string 'global.branding.logo.svg=hello'
        expect_render_failure "$chart" "$v" "scripted SVG" "must not contain script" --set-string 'global.branding.logo.svg=<svg><script>alert(1)</script></svg>'
        expect_render_failure "$chart" "$v" "SVG event handler" "must not contain script" --set-string 'global.branding.logo.svg=<svg onload=alert(1)></svg>'
        expect_render_failure "$chart" "$v" "SVG encoded javascript: URL" "must not contain script" --set-string 'global.branding.logo.svg=<svg><a href="javascript&#58;alert(1)"><rect/></a></svg>'
        expect_render_failure "$chart" "$v" "SVG javascript: URL with a tab" "must not contain script" --set-string "global.branding.logo.svg=<svg><a href=\"java$(printf '\t')script:alert(1)\"><rect/></a></svg>"
        expect_render_failure "$chart" "$v" "namespace-prefixed SVG script" "must not contain script" --set-string 'global.branding.logo.svg=<svg:svg xmlns:svg="http://www.w3.org/2000/svg"><svg:script>alert(1)</svg:script></svg:svg>'
        expect_render_failure "$chart" "$v" "SVG entity declaration" "must not contain script" --set-string 'global.branding.logo.svg=<!DOCTYPE svg [<!ENTITY x "y">]><svg/>'
        expect_render_failure "$chart" "$v" "SVG in an existing ConfigMap" "global.branding.logo.key must be a file name" --set global.branding.logo.existingConfigMap=relay-brand --set global.branding.logo.key=logo.svg
        logo=$(render "$chart" "$v" --set global.branding.logo.existingConfigMap=relay-brand)
        [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.volumes[] | select(.name == "brand") | .configMap.items[0].key' <<<"$logo")" = "logo.png" ] \
          || err "$chart: existingConfigMap without key must serve logo.png"
        expect_render_failure "$chart" "$v" "unknown logo setting" "global.branding.logo.url is not a setting" --set global.branding.logo.url=https://x.example/logo.svg
        ;;
      relay-control)
        v=charts/relay-control/ci/default-values.yaml
        check_postgres_ca "$chart" "$v"
        expect_render_failure "$chart" "$v" "mutable image" "image.digest is required" --set image.digest=
        expect_render_failure "$chart" "$v" "malformed digest" "image.digest must be sha256:<64 lowercase hex characters>" --set image.digest=sha256:abc
        expect_render_failure "$chart" "$v" "missing Secret" "existingSecret is required" --set existingSecret=
        expect_render_failure "$chart" "$v" "multiple replicas" "replicaCount must be 1" --set replicaCount=2
        expect_render_failure "$chart" "$v" "missing runtime database role" "database.runtimeRole must be a valid PostgreSQL role name" --set database.runtimeRole=
        expect_render_failure "$chart" "$v" "invalid public URL" "publicUrl must be an HTTPS origin with no path" --set publicUrl=https://gcp-proof.agentrelay.com/cloud
        expect_render_failure "$chart" "$v" "invalid internal History origin" "services.relayhistoryUrl must be an HTTP(S) origin" --set services.relayhistoryUrl=http://relayhistory:8080/v1
        expect_render_failure "$chart" "$v" "plaintext public Relaycast origin" "services.relaycastPublicUrl must be a public HTTPS origin" --set services.relaycastPublicUrl=http://cast.gcp-proof.agentrelay.com
        expect_render_failure "$chart" "$v" "private public History origin" "services.relayhistoryPublicUrl must be a public HTTPS origin" --set services.relayhistoryPublicUrl=https://relayhistory
        # Optional features: usage is a managed name; an unknown one fails, default renders none.
        [ "$(render "$chart" "$v" --set 'selectedFeatures={flows,usage}' | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "SELFHOST_FEATURES") | .value')" = flows,usage ] \
          || err "$chart: selectedFeatures={flows,usage} must render SELFHOST_FEATURES=flows,usage"
        [ "$(render "$chart" "$v" --set 'selectedFeatures={usage,usage_people}' | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "SELFHOST_FEATURES") | .value')" = usage,usage_people ] \
          || err "$chart: selectedFeatures={usage,usage_people} must render SELFHOST_FEATURES=usage,usage_people"
        expect_render_failure "$chart" "$v" "unknown optional feature" "selectedFeatures contains an unknown optional component" --set 'selectedFeatures={usage,teleport}'
        # launch is a managed name too (relay-control docs/agent-launch.md).
        [ "$(render "$chart" "$v" --set 'selectedFeatures={usage,launch}' | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "SELFHOST_FEATURES") | .value')" = usage,launch ] \
          || err "$chart: selectedFeatures={usage,launch} must render SELFHOST_FEATURES=usage,launch"
        out=$(render "$chart" "$v")
        grep -q 'name: SELFHOST_PUBLIC_URL' <<<"$out" || err "$chart: SELFHOST_PUBLIC_URL is not rendered"
        grep -q 'name: RELAYCAST_PUBLIC_URL' <<<"$out" || err "$chart: RELAYCAST_PUBLIC_URL is not rendered"
        grep -q 'name: RELAYHISTORY_PUBLIC_URL' <<<"$out" || err "$chart: RELAYHISTORY_PUBLIC_URL is not rendered"
        grep -q 'name: DATABASE_MIGRATIONS_URL_FILE' <<<"$out" || err "$chart: migration owner URL is not file-backed"
        ! yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[].name' <<<"$out" | grep -q '^DATABASE_MIGRATIONS_URL_FILE$' \
          || err "$chart: API Deployment can read the migration owner URL"
        [ "$(yq 'select(.kind == "Job") | .spec.template.spec.containers[0].command | join(" ")' <<<"$out")" = node ] \
          || err "$chart: migration Job must invoke node directly"
        [ "$(yq 'select(.kind == "Job") | .spec.template.spec.containers[0].args | join(" ")' <<<"$out")" = node_modules/relay-control/dist/migrate-cli.js ] \
          || err "$chart: migration Job must invoke the packaged migrate CLI directly"
        ! grep -q 'export DATABASE_URL_FILE' <<<"$out" || err "$chart: obsolete migration DATABASE_URL_FILE adapter is still rendered"
        ! grep -Eq 'CLOUD_EDITION|NEXT_PUBLIC_APP_URL|OIDC_|AUTH_SESSION_SECRET|NEXT_CACHE' <<<"$out" \
          || err "$chart: full-Cloud/Next environment leaked into the selfhost API chart"
        # Session read handoff and introspection render only when configured,
        # with their secrets as mounted files.
        ! grep -Eq 'SESSION_READ_API|RELAYCONTROL_INTROSPECT|SELFHOST_INTROSPECT' <<<"$out" \
          || err "$chart: read API handoff env must not render by default"
        sr_args=(--set services.sessionReadApiUrl=http://session-read-api:8080 --set services.sessionReadApiPublicUrl=https://read.gcp-proof.agentrelay.com
          --set secretKeys.sessionReadApiSecret=session-read-api-secret --set services.sessionReadApiMcpReads=true
          --set secretKeys.introspectSecret=relaycontrol-introspect-secret --set 'introspection.audiences={https://read.gcp-proof.agentrelay.com}')
        sr_env=$(render "$chart" "$v" "${sr_args[@]}" | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | .name + "=" + (.value // "")')
        for want in "SESSION_READ_API_URL=http://session-read-api:8080" "SESSION_READ_API_PUBLIC_URL=https://read.gcp-proof.agentrelay.com" \
          "SESSION_READ_API_SECRET_FILE=/var/run/agent-relay/secrets/session-read-api-secret" "SESSION_READ_API_MCP_READS=true" \
          "RELAYCONTROL_INTROSPECT_SECRET_FILE=/var/run/agent-relay/secrets/relaycontrol-introspect-secret" \
          "SELFHOST_INTROSPECT_AUDIENCES=https://read.gcp-proof.agentrelay.com"; do
          grep -qxF "$want" <<<"$sr_env" || err "$chart: session read values did not render $want"
        done
        [ "$(render "$chart" "$v" --set secretKeys.introspectSecret=relaycontrol-introspect-secret | yq 'select(.kind == "Ingress") | .spec.rules[0].http.paths[0].path')" = /internal ] \
          || err "$chart: the Ingress must deny /internal when the introspection route is enabled"
        expect_render_failure "$chart" "$v" "partial session read handoff" "must be set together" --set services.sessionReadApiUrl=http://session-read-api:8080
        expect_render_failure "$chart" "$v" "MCP reads without handoff" "services.sessionReadApiMcpReads requires" --set services.sessionReadApiMcpReads=true
        expect_render_failure "$chart" "$v" "plaintext read API public origin" "services.sessionReadApiPublicUrl must be a public HTTPS origin" --set services.sessionReadApiUrl=http://session-read-api:8080 --set services.sessionReadApiPublicUrl=http://read.gcp-proof.agentrelay.com --set secretKeys.sessionReadApiSecret=session-read-api-secret
        expect_render_failure "$chart" "$v" "audiences without secret" "introspection.audiences requires secretKeys.introspectSecret" --set 'introspection.audiences={https://read.gcp-proof.agentrelay.com}'
        expect_render_failure "$chart" "$v" "audience with a path" "introspection.audiences entries must be http(s) origins" --set secretKeys.introspectSecret=relaycontrol-introspect-secret --set 'introspection.audiences={https://read.gcp-proof.agentrelay.com/v1}'
        # bootstrap-signup: identity settings render to relaycontrol's env and
        # their secrets only as mounted files.
        idv=charts/relay-control/ci/identity-values.yaml
        id_out=$(render "$chart" "$idv")
        id_env=$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | .name + "=" + (.value // "")' <<<"$id_out")
        for want in "SELFHOST_BOOTSTRAP_ORG_NAME=Acme" "SELFHOST_BOOTSTRAP_ADMIN_EMAIL=ops@acme.com" \
          "SELFHOST_OIDC_ISSUER=https://accounts.google.com" "SELFHOST_OIDC_ALLOWED_DOMAINS=acme.com" \
          "SELFHOST_OIDC_CLIENT_SECRET_FILE=/var/run/agent-relay/secrets/oidc-client-secret" \
          "SELFHOST_MICROSOFT_CLIENT_ID=11111111-2222-3333-4444-555555555555" "SELFHOST_MICROSOFT_TENANT=common" \
          "SELFHOST_MICROSOFT_CLIENT_SECRET_FILE=/var/run/agent-relay/secrets/microsoft-client-secret" \
          "RELAYCAST_INTERNAL_SECRET_FILE=/var/run/agent-relay/secrets/relaycast-internal-secret" \
          "SELFHOST_SMTP_PASSWORD_FILE=/var/run/agent-relay/secrets/smtp-password" "SELFHOST_SMTP_PORT=465" \
          "SELFHOST_EMAIL_LOGIN=true" "SELFHOST_AUTO_JOIN_DOMAINS=acme.com" "SELFHOST_INVITE_TTL_HOURS=72" \
          "SELFHOST_SIGNIN_METHODS=email_link,password" "SELFHOST_TRUSTED_PROXIES=1" \
          "SELFHOST_SETUP_KEY_FILE=/var/run/agent-relay/secrets/selfhost-setup-key"; do
          grep -qxF "$want" <<<"$id_env" || err "$chart: identity values did not render $want"
        done
        [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.volumes[] | select(.name == "secrets") | .secret.items[].key' <<<"$id_out" | grep -cE '^(oidc-client-secret|microsoft-client-secret|smtp-password|relaycast-internal-secret|selfhost-setup-key)$')" = 5 ] \
          || err "$chart: identity secrets must be projected into the secrets volume"
        ! grep -Eq 'SELFHOST_BOOTSTRAP_(ORG|ADMIN|WORKSPACE)|SELFHOST_(OIDC|MICROSOFT|SMTP|EMAIL|AUTO_JOIN|INVITE)_|RELAYCAST_INTERNAL_SECRET|SELFHOST_(SIGNIN_METHODS|TRUSTED_PROXIES|SETUP_KEY)|selfhost-setup-key' <<<"$out" \
          || err "$chart: identity env must not render without identity values"
        # The setup key reaches only the API pod, never the migration Job.
        ! yq 'select(.kind == "Job")' <<<"$id_out" | grep -Eq 'selfhost-setup-key|SELFHOST_SETUP_KEY' \
          || err "$chart: the migrate Job must not receive the setup key"
        # Password sign-in alone renders only password; an explicit trustedProxies wins.
        pw_env=$(render "$chart" "$v" --set dashboardUrl=https://gcp-proof.agentrelay.com/ --set auth.password.enabled=true --set auth.trustedProxies=0 \
          | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | .name + "=" + (.value // "")')
        for want in "SELFHOST_SIGNIN_METHODS=password" "SELFHOST_TRUSTED_PROXIES=0"; do
          grep -qxF "$want" <<<"$pw_env" || err "$chart: password sign-in did not render $want"
        done
        grep -q '^SELFHOST_EMAIL_LOGIN=' <<<"$pw_env" && err "$chart: password sign-in alone must not enable email links"
        tp_env=$(render "$chart" "$v" --set auth.trustedProxies=2 | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | .name + "=" + (.value // "")')
        grep -qxF "SELFHOST_TRUSTED_PROXIES=2" <<<"$tp_env" || err "$chart: an explicit trustedProxies must render without password sign-in"
        grep -q '^SELFHOST_SIGNIN_METHODS=' <<<"$tp_env" && err "$chart: trustedProxies alone must not set sign-in methods"
        expect_render_failure "$chart" "$v" "setup key without password sign-in" "secretKeys.setupKey requires auth.password.enabled" --set secretKeys.setupKey=selfhost-setup-key
        # Sign-in co-branding: SELFHOST_LOGIN_LOGO_URL follows the
        # relay-webapp-hosted global.branding.logo on the dashboard origin
        # unless login.logoUrl overrides it; nothing renders by default.
        ! grep -q 'SELFHOST_LOGIN_' <<<"$out$id_out" || err "$chart: no login logo or org name must render without branding"
        lg_env() { render "$chart" "$@" | yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name | test("^SELFHOST_LOGIN_")) | .name + "=" + .value'; }
        [ "$(lg_env "$idv" --set-string 'global.branding.logo.svg=<svg/>')" = "SELFHOST_LOGIN_LOGO_URL=https://gcp-proof.agentrelay.com/brand/logo.svg" ] \
          || err "$chart: an inline logo must link <dashboardUrl origin>/brand/logo.svg"
        [ "$(lg_env "$idv" --set global.branding.logo.existingConfigMap=relay-brand --set global.branding.logo.key=acme.png --set login.orgName='Example Corp' | paste -sd' ' -)" = "SELFHOST_LOGIN_LOGO_URL=https://gcp-proof.agentrelay.com/brand/acme.png SELFHOST_LOGIN_ORG_NAME=Example Corp" ] \
          || err "$chart: an existing ConfigMap logo must link its key, and login.orgName must render"
        [ "$(lg_env "$idv" --set-string 'global.branding.logo.svg=<svg/>' --set login.logoUrl=https://cdn.example.com/logo.svg)" = "SELFHOST_LOGIN_LOGO_URL=https://cdn.example.com/logo.svg" ] \
          || err "$chart: login.logoUrl must override the hosted logo"
        [ "$(lg_env "$idv" --set 'login.logoUrl=https://cdn.example.com?asset=logo')" = "SELFHOST_LOGIN_LOGO_URL=https://cdn.example.com?asset=logo" ] \
          || err "$chart: login.logoUrl must accept a query right after the host"
        [ "$(lg_env charts/relay-control/ci/single-host-values.yaml --set-string 'global.branding.logo.svg=<svg/>')" = "SELFHOST_LOGIN_LOGO_URL=https://relay.gcp-proof.agentrelay.com/brand/logo.svg" ] \
          || err "$chart: single-host mode must link the logo on the single host"
        expect_render_failure "$chart" "$v" "hosted logo without a dashboard origin" "global.branding.logo needs dashboardUrl" --set-string 'global.branding.logo.svg=<svg/>'
        expect_render_failure "$chart" "$v" "hosted logo on a plaintext dashboard" "the sign-in logo must be https" --set-string 'global.branding.logo.svg=<svg/>' --set dashboardUrl=http://dashboard.example.com/
        expect_render_failure "$chart" "$v" "plaintext login logo" "login.logoUrl must be an absolute https URL" --set login.logoUrl=http://cdn.example.com/logo.svg
        expect_render_failure "$chart" "$v" "login logo without a host" "login.logoUrl must be an absolute https URL" --set 'login.logoUrl=https://:443/logo.png'
        expect_render_failure "$chart" "$v" "login logo with credentials" "login.logoUrl must be an absolute https URL" --set login.logoUrl=https://u:p@cdn.example.com/logo.svg
        expect_render_failure "$chart" "$v" "unknown login setting" "login.logo is not a setting" --set login.logo=x
        expect_render_failure "$chart" "$idv" "login logo in extraEnv as well" "SELFHOST_LOGIN_LOGO_URL is managed" --set-string 'global.branding.logo.svg=<svg/>' --set-json 'extraEnv=[{"name":"SELFHOST_LOGIN_LOGO_URL","value":"https://cdn.example.com/x.svg"}]'
        render "$chart" "$idv" --set-json 'extraEnv=[{"name":"SELFHOST_LOGIN_LOGO_URL","value":"https://cdn.example.com/x.svg"}]' >/dev/null \
          || err "$chart: SELFHOST_LOGIN_LOGO_URL in extraEnv must keep working without branding values"
        expect_render_failure "$chart" "$v" "numeric password setting" "auth.password.enabled must be a boolean" --set auth.password.enabled=0
        expect_render_failure "$chart" "$v" "string password setting" "auth.password.enabled must be a boolean" --set-string auth.password.enabled=true
        expect_render_failure "$chart" "$v" "trustedProxies out of range" "auth.trustedProxies must be an integer from 0 to 99" --set auth.trustedProxies=100
        expect_render_failure "$chart" "$v" "trustedProxies not a number" "auth.trustedProxies must be an integer from 0 to 99" --set auth.trustedProxies=one
        expect_render_failure "$chart" "$v" "password sign-in without dashboardUrl" "dashboardUrl is required with bootstrap, auth.oidc, auth.microsoft, auth.emailLink, auth.password or smtp" --set auth.password.enabled=true
        expect_render_failure "$chart" "$v" "setup key naming the migrations URL" "both name Secret key" --set auth.password.enabled=true --set dashboardUrl=https://gcp-proof.agentrelay.com/ --set secretKeys.setupKey=database-migrations-url
        # Password pepper: off by default. When set, only the API gets it, as a
        # private copy made by the init container.
        pepper_out=$(render "$chart" "$v" --set secretKeys.passwordPepper=password-pepper)
        ! grep -Fq 'password-pepper' <<<"$out" || err "$chart: password pepper must not render without its key"
        [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.initContainers[0].name' <<<"$pepper_out")" = password-pepper ] \
          || err "$chart: password pepper needs its init container"
        yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | .name + "=" + (.value // "")' <<<"$pepper_out" \
          | grep -qxF "SELFHOST_PASSWORD_PEPPER_FILE=/var/run/agent-relay/password-pepper/pepper" \
          || err "$chart: password pepper env must point at the private copy"
        [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.volumes[] | select(.name == "password-pepper") | .emptyDir.medium' <<<"$pepper_out")" = Memory ] \
          || err "$chart: password pepper copy must be memory-backed"
        ! yq 'select(.kind == "Job")' <<<"$pepper_out" | grep -Fq 'password-pepper' || err "$chart: the migrate Job must not receive the password pepper"
        expect_render_failure "$chart" "$v" "pepper naming the migrations URL" "secretKeys.passwordPepper must not name secretKeys.databaseMigrationsUrl" --set secretKeys.passwordPepper=database-migrations-url
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
        expect_render_failure "$chart" "$v" "Microsoft without client secret" "auth.microsoft.clientId requires secretKeys.microsoftClientSecret" --set auth.microsoft.clientId=x --set dashboardUrl=https://gcp-proof.agentrelay.com/
        expect_render_failure "$chart" "$v" "Microsoft secret without client id" "secretKeys.microsoftClientSecret is set but auth.microsoft.clientId is empty" --set secretKeys.microsoftClientSecret=microsoft-client-secret
        expect_render_failure "$chart" "$v" "Microsoft without dashboardUrl" "dashboardUrl is required with bootstrap, auth.oidc, auth.microsoft" --set auth.microsoft.clientId=x --set secretKeys.microsoftClientSecret=microsoft-client-secret
        expect_render_failure "$chart" "$v" "bad Microsoft tenant" "auth.microsoft.tenant must be common, consumers, organizations or a tenant id" --set auth.microsoft.clientId=x --set secretKeys.microsoftClientSecret=microsoft-client-secret --set auth.microsoft.tenant=contoso.onmicrosoft.com --set dashboardUrl=https://gcp-proof.agentrelay.com/
        expect_render_failure "$chart" "$v" "bad Microsoft redirect URL" "auth.microsoft.redirectUrl must be <origin>/login/microsoft/callback" --set auth.microsoft.clientId=x --set secretKeys.microsoftClientSecret=microsoft-client-secret --set auth.microsoft.redirectUrl=https://relay.acme.com/login/oidc/callback --set dashboardUrl=https://gcp-proof.agentrelay.com/
        expect_render_failure "$chart" "$v" "Microsoft settings without client id" "auth.microsoft.* settings need auth.microsoft.clientId" --set auth.microsoft.tenant=common
        expect_render_failure "$chart" "$v" "email links without SMTP" "auth.emailLink.enabled requires smtp.host" --set dashboardUrl=https://gcp-proof.agentrelay.com/ --set auth.emailLink.enabled=true
        expect_render_failure "$chart" "$v" "SMTP without from" "smtp.from is required with smtp.host" --set dashboardUrl=https://gcp-proof.agentrelay.com/ --set smtp.host=smtp.acme.com
        expect_render_failure "$chart" "$v" "SMTP user without password" "smtp.username and secretKeys.smtpPassword must be set together" --set dashboardUrl=https://gcp-proof.agentrelay.com/ --set smtp.host=smtp.acme.com --set smtp.from=relay@acme.com --set smtp.username=u
        expect_render_failure "$chart" "$v" "SMTP port zero" "smtp.port must be 1-65535" --set dashboardUrl=https://gcp-proof.agentrelay.com/ --set smtp.host=smtp.acme.com --set smtp.from=relay@acme.com --set smtp.port=0
        expect_render_failure "$chart" "$v" "SMTP without dashboardUrl" "dashboardUrl is required with bootstrap, auth.oidc, auth.microsoft, auth.emailLink, auth.password or smtp" --set smtp.host=smtp.acme.com --set smtp.from=relay@acme.com
        expect_render_failure "$chart" "$v" "bad invite TTL" "auth.inviteTtlHours must be an integer from 1 to 720" --set auth.inviteTtlHours=0
        expect_render_failure "$chart" "$v" "identity secret reusing an API key" "both name Secret key" --set secretKeys.relaycastInternalSecret=selfhost-bootstrap-token --set bootstrap.orgName=Acme --set bootstrap.adminEmail=ops@acme.com --set dashboardUrl=https://gcp-proof.agentrelay.com/
        [ -n "$(render "$chart" "$v" --set dashboardUrl=https://gcp-proof.agentrelay.com/ --set auth.oidc.issuer=http://dex:5556/dex --set auth.oidc.clientId=x --set secretKeys.oidcClientSecret=oidc-client-secret --set auth.oidc.allowHttpIssuer=true)" ] \
          || err "$chart: allowHttpIssuer=true must accept an in-cluster http issuer"
        ;;
      relayhistory)
        v=charts/relayhistory/ci/default-values.yaml
        check_postgres_ca "$chart" "$v"
        expect_render_failure "$chart" "$v" "postgresCa extraConfig override" "NODE_EXTRA_CA_CERTS is managed by structured chart values" --set postgresCa.enabled=true --set postgresCa.configMap=ca-bundle --set extraConfig.NODE_EXTRA_CA_CERTS=/x
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
      relaychief-control)
        v=charts/relaychief-control/ci/default-values.yaml
        check_postgres_ca "$chart" "$v"
        expect_render_failure "$chart" "$v" "mutable image" "image.digest is required" --set image.digest=
        expect_render_failure "$chart" "$v" "malformed digest" "image.digest must be sha256:<64 lowercase hex characters>" --set image.digest=sha256:abc
        expect_render_failure "$chart" "$v" "missing Secret" "existingSecret is required" --set existingSecret=
        expect_render_failure "$chart" "$v" "missing relay-control origin" "config.relaycontrolUrl (RELAYCONTROL_URL) is required" --set config.relaycontrolUrl=
        expect_render_failure "$chart" "$v" "relay-control URL with a path" "config.relaycontrolUrl (RELAYCONTROL_URL) is required" --set config.relaycontrolUrl=https://control.example.com/v1
        expect_render_failure "$chart" "$v" "missing public origin" "config.publicOrigin (RELAYCHIEF_CONTROL_PUBLIC_ORIGIN) is required" --set config.publicOrigin=
        for origin in ftp://chief.example.com https://chief.example.com/ https://user@chief.example.com chief.example.com; do
          expect_render_failure "$chart" "$v" "public origin $origin" "config.publicOrigin (RELAYCHIEF_CONTROL_PUBLIC_ORIGIN) is required" --set "config.publicOrigin=$origin"
        done
        expect_render_failure "$chart" "$v" "bad browser origin" "config.browserOrigins must be comma-separated http(s) origins" --set 'config.browserOrigins=https://a.example.com\,app.example.com'
        expect_render_failure "$chart" "$v" "bad Nango host" "config.nangoHost (NANGO_HOST) must be an http(s) origin" --set config.nangoHost=nango.example.com --set secretKeys.nangoSecretKey=NANGO_SECRET_KEY
        expect_render_failure "$chart" "$v" "NANGO_HOST without the key" "config.nangoHost (NANGO_HOST) requires secretKeys.nangoSecretKey" --set config.nangoHost=https://nango.example.com
        expect_render_failure "$chart" "$v" "unsafe Secret key path" "secretKeys.adminToken must be a Kubernetes Secret data key" --set-string secretKeys.adminToken=../key
        expect_render_failure "$chart" "$v" "empty required Secret key" "secretKeys.databaseUrl is required" --set secretKeys.databaseUrl=
        expect_render_failure "$chart" "$v" "multiple replicas" "replicaCount must be 1" --set replicaCount=2
        expect_render_failure "$chart" "$v" "fractional replicas" "replicaCount must be 1" --set replicaCount=1.5
        expect_render_failure "$chart" "$v" "string replicas" "replicaCount must be 1" --set-string replicaCount=1
        expect_render_failure "$chart" "$v" "server port on the admin port" "server.port must not be 3201" --set server.port=3201
        expect_render_failure "$chart" "$v" "public Service" "service.type must be ClusterIP" --set service.type=LoadBalancer
        expect_render_failure "$chart" "$v" "restricted egress with no rules" "requires networkPolicy.additionalEgress" --set-json 'networkPolicy.additionalEgress=[]'
        for name in ADMIN_HOST ADMIN_PORT HOST PORT NANGO_HOST NANGO_SECRET_KEY DATABASE_URL RELAYCHIEF_CONTROL_RELAY_SECRET RELAYCHIEF_CONTROL_ENCRYPTION_KEY_ID RELAYCHIEF_CONTROL_ENCRYPTION_KEY; do
          expect_render_failure "$chart" "$v" "$name through extraEnv" "$name is managed by structured chart values and must not appear in extraEnv" --set-json "extraEnv=[{\"name\":\"$name\",\"value\":\"x\"}]"
        done
        expect_render_failure "$chart" "$v" "ingress without hosts" "ingress.enabled=true requires at least one host" --set ingress.enabled=true
        expect_render_failure "$chart" "$v" "ingress without TLS" "ingress.enabled=true requires ingress.tls unless externalTls=true" --set ingress.enabled=true --set-json 'ingress.hosts=["chief.example.com"]'
        expect_render_failure "$chart" "$v" "ingress blocked by NetworkPolicy" "ingress with networkPolicy requires networkPolicy.ingressFrom" --set ingress.enabled=true --set-json 'ingress.hosts=["chief.example.com"]' --set ingress.externalTls=true
        expect_render_failure "$chart" "$v" "root ingress path" "must be an absolute path other than /" --set-json 'ingress.extraPaths=[{"path":"/"}]'
        expect_render_failure "$chart" "$v" "bad ingress pathType" "pathType must be Prefix or Exact" --set-json 'ingress.extraPaths=[{"path":"/api/v1","pathType":"ImplementationSpecific"}]'
        # A yq expression that runs over every document prints blank lines and
        # separators for the documents it does not match; keep only the values.
        rq() { yq "$1" <<<"$2" | { grep -Ev '^(---)?$' || true; }; }
        out=$(render "$chart" "$v")
        deployment='select(.kind == "Deployment") | .spec.template.spec'
        [ "$(yq 'select(.kind == "Secret") | .metadata.name' <<<"$out")" = "" ] || err "$chart: the chart must not render a Secret"
        [ "$(yq 'select(.kind == "Ingress") | .metadata.name' <<<"$out")" = "" ] || err "$chart: Ingress must be off by default"
        [ "$(rq "$deployment | [.containers[0].env[] | select(.name == \"ADMIN_HOST\") | .value] | join(\",\")" "$out")" = 127.0.0.1 ] \
          || err "$chart: ADMIN_HOST must render exactly once as 127.0.0.1"
        [ "$(rq "$deployment | [.containers[0].ports[].containerPort] | join(\",\")" "$out")" = 3200 ] \
          || err "$chart: the container must expose only the server port"
        [ "$(rq 'select(.kind == "Service") | [.spec.ports[].port] | join(",")' "$out")" = 3200 ] \
          || err "$chart: the Service must expose only the server port"
        [ "$(yq 'select(.kind == "ConfigMap") | .data.PORT' <<<"$out")" = 3200 ] || err "$chart: PORT must render as 3200"
        [ "$(yq "$deployment | .containers[0].startupProbe.httpGet.path + \" \" + .containers[0].livenessProbe.httpGet.path + \" \" + .containers[0].readinessProbe.httpGet.path" <<<"$out")" = "/healthz /healthz /readyz" ] \
          || err "$chart: probes must be /healthz (startup, liveness) and /readyz (readiness)"
        [ "$(yq "$deployment | (.containers[0].command // [] | length) + (.containers[0].args // [] | length)" <<<"$out")" = 0 ] \
          || err "$chart: the server must run the image default command"
        [ "$(yq "$deployment | .securityContext.runAsUser" <<<"$out")" = 1000 ] || err "$chart: the pod must run as uid 1000"
        [ "$(yq "$deployment | .containers[0].securityContext.readOnlyRootFilesystem" <<<"$out")" = true ] || err "$chart: the root filesystem must be read-only"
        [ "$(yq "$deployment | .volumes[] | select(.name == \"tmp\") | .emptyDir.medium" <<<"$out")" = Memory ] || err "$chart: /tmp must be a tmpfs"
        ! grep -Eq 'NANGO_(HOST|SECRET_KEY)|RELAYCHIEF_CONTROL_BROWSER_ORIGINS' <<<"$out" || err "$chart: optional env must not render when unset"
        ! grep -q 'part-of: agent-relay' <<<"$out" || err "$chart: the chart is not part of the agent-relay umbrella"
        job='select(.kind == "Job") | .spec.template.spec'
        [ "$(yq "$job | .containers[0].command[0] + \" \" + .containers[0].args[0]" <<<"$out")" = "node node_modules/relaychief-control/dist/migrate-cli.js" ] \
          || err "$chart: the migrate Job must run the packaged migrate CLI"
        [ "$(rq "$job | [.containers[0].env[].name] | join(\",\")" "$out")" = DATABASE_URL ] \
          || err "$chart: the migrate Job must receive only DATABASE_URL"
        yq 'select(.kind == "Job") | .metadata.name' <<<"$out" | grep -Eq '^ci-relaychief-control-migrate-[0-9a-f]{8}$' \
          || err "$chart: the migrate Job must be named by its template hash"
        salted=$(render "$chart" "$v" --set migrations.identitySalt=retry)
        [ "$(yq 'select(.kind == "Job") | .metadata.name' <<<"$salted")" != "$(yq 'select(.kind == "Job") | .metadata.name' <<<"$out")" ] \
          || err "$chart: migrations.identitySalt must change the Job name"
        placed=$(render "$chart" "$v" --set nodeSelector.pool=chief --set-json 'tolerations=[{"key":"dedicated","operator":"Exists","effect":"NoSchedule"}]' --set-json 'affinity={"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"zone","operator":"Exists"}]}]}}}')
        for workload in "$job" "$deployment"; do
          [ "$(rq "$workload | .nodeSelector.pool + \" \" + .tolerations[0].key + \" \" + .affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key" "$placed")" = "chief dedicated zone" ] \
            || err "$chart: nodeSelector, tolerations and affinity must reach the server and the migrate Job"
        done
        nango_key=$(render "$chart" "$v" --set secretKeys.nangoSecretKey=NANGO_SECRET_KEY)
        [ "$(yq "$deployment | .containers[0].env[] | select(.name == \"NANGO_SECRET_KEY\") | .valueFrom.secretKeyRef.key" <<<"$nango_key")" = NANGO_SECRET_KEY ] \
          || err "$chart: NANGO_SECRET_KEY must come from the existing Secret"
        # Relay identity: all three Secret keys or none.
        ! grep -q 'RELAYCHIEF_CONTROL_\(RELAY_SECRET\|ENCRYPTION_KEY\)' <<<"$out" || err "$chart: relay identity env must not render when unset"
        relay_identity=(--set secretKeys.relaySecret=RELAYCHIEF_CONTROL_RELAY_SECRET --set secretKeys.encryptionKeyId=RELAYCHIEF_CONTROL_ENCRYPTION_KEY_ID --set secretKeys.encryptionKey=RELAYCHIEF_CONTROL_ENCRYPTION_KEY)
        relay=$(render "$chart" "$v" "${relay_identity[@]}")
        for name in RELAYCHIEF_CONTROL_RELAY_SECRET RELAYCHIEF_CONTROL_ENCRYPTION_KEY_ID RELAYCHIEF_CONTROL_ENCRYPTION_KEY; do
          [ "$(rq "$deployment | [.containers[0].env[] | select(.name == \"$name\") | .valueFrom.secretKeyRef.name + \"/\" + .valueFrom.secretKeyRef.key] | join(\",\")" "$relay")" = "relaychief-control-secrets/$name" ] \
            || err "$chart: $name must render once from the existing Secret"
        done
        [ "$(rq "$job | [.containers[0].env[].name] | join(\",\")" "$relay")" = DATABASE_URL ] \
          || err "$chart: relay identity env must not reach the migrate Job"
        for missing in relaySecret encryptionKeyId encryptionKey; do
          expect_render_failure "$chart" "$v" "relay identity without secretKeys.$missing" "must be set together or not at all" "${relay_identity[@]}" --set "secretKeys.$missing="
        done
        expect_render_failure "$chart" "$v" "relay secret alone" "must be set together or not at all" --set secretKeys.relaySecret=RELAYCHIEF_CONTROL_RELAY_SECRET
        expect_render_failure "$chart" "$v" "unsafe relay identity key path" "secretKeys.encryptionKey must be a Kubernetes Secret data key" "${relay_identity[@]}" --set-string secretKeys.encryptionKey=../key
        v=charts/relaychief-control/ci/alb-values.yaml
        out=$(render "$chart" "$v")
        [ "$(rq 'select(.kind == "Ingress") | [.spec.rules[0].http.paths[] | .path + "=" + .pathType] | join(",")' "$out")" = "/chief/v1=Prefix" ] \
          || err "$chart: the default Ingress must expose only /chief/v1 (Prefix)"
        [ "$(rq 'select(.kind == "NetworkPolicy" and (.metadata.name | test("migration$") | not)) | [.spec.ingress[0].from[].ipBlock.cidr] | join(",")' "$out")" = "10.0.1.0/24,10.0.2.0/24" ] \
          || err "$chart: networkPolicy.ingressFrom must admit ALB subnets"
        [ "$(yq 'select(.kind == "ConfigMap") | .data.RELAYCHIEF_CONTROL_BROWSER_ORIGINS' <<<"$out")" = "https://app.example.com, https://admin.example.com" ] \
          || err "$chart: browser origins did not render"
        extra=$(render "$chart" "$v" --set-json 'ingress.extraPaths=[{"path":"/api/v1"}]')
        [ "$(rq 'select(.kind == "Ingress") | [.spec.rules[0].http.paths[] | .path + "=" + .pathType] | join(",")' "$extra")" = "/chief/v1=Prefix,/api/v1=Prefix" ] \
          || err "$chart: ingress.extraPaths must add routes after /chief/v1"
        ;;
      relayfile-control)
        v=charts/relayfile-control/ci/default-values.yaml
        check_postgres_ca "$chart" "$v"
        expect_render_failure "$chart" "$v" "mutable image" "image.digest is required" --set image.digest=
        expect_render_failure "$chart" "$v" "malformed digest" "image.digest must be sha256:<64 lowercase hex characters>" --set image.digest=sha256:abc
        expect_render_failure "$chart" "$v" "missing Secret" "existingSecret is required" --set existingSecret=
        expect_render_failure "$chart" "$v" "missing Relayfile URL" "config.relayfileBaseUrl (RELAYFILE_BASE_URL) is required" --set config.relayfileBaseUrl=
        expect_render_failure "$chart" "$v" "missing relay-control origin" "config.relaycontrolBaseUrl (RELAYCONTROL_BASE_URL) is required" --set config.relaycontrolBaseUrl=
        expect_render_failure "$chart" "$v" "relay-control URL with a path" "config.relaycontrolBaseUrl (RELAYCONTROL_BASE_URL) is required" --set config.relaycontrolBaseUrl=https://control.example.com/v1
        expect_render_failure "$chart" "$v" "empty required Secret key" "secretKeys.databaseUrl is required" --set secretKeys.databaseUrl=
        expect_render_failure "$chart" "$v" "unsafe Secret key path" "secretKeys.adminToken must be a Kubernetes Secret data key" --set-string secretKeys.adminToken=../key
        expect_render_failure "$chart" "$v" "multiple replicas" "replicaCount must be 1" --set replicaCount=2
        expect_render_failure "$chart" "$v" "server port on the admin port" "server.port must not be 3101" --set server.port=3101
        expect_render_failure "$chart" "$v" "public Service" "service.type must be ClusterIP" --set service.type=LoadBalancer
        expect_render_failure "$chart" "$v" "restricted egress with no rules" "requires networkPolicy.additionalEgress" --set-json 'networkPolicy.additionalEgress=[]'
        expect_render_failure "$chart" "$v" "ingress without Flows" "ingress.enabled=true requires flows.enabled=true" --set ingress.enabled=true
        for name in LISTEN ADMIN_LISTEN MIGRATE_ON_START DATABASE_URL RELAYFILE_CONTROL_BROKER_SECRET RELAYFILE_CONTROL_BROKER_SECRET_FILE; do
          expect_render_failure "$chart" "$v" "$name through extraEnv" "$name is managed by structured chart values and must not appear in extraEnv" --set-json "extraEnv=[{\"name\":\"$name\",\"value\":\"x\"}]"
        done
        rq() { yq "$1" <<<"$2" | { grep -Ev '^(---)?$' || true; }; }
        out=$(render "$chart" "$v")
        deployment='select(.kind == "Deployment") | .spec.template.spec'
        [ "$(yq 'select(.kind == "Secret") | .metadata.name' <<<"$out")" = "" ] || err "$chart: the chart must not render a Secret"
        [ "$(yq 'select(.kind == "Ingress") | .metadata.name' <<<"$out")" = "" ] || err "$chart: Ingress must be off by default"
        [ "$(rq "$deployment | [.containers[0].ports[].containerPort] | join(\",\")" "$out")" = 3100 ] || err "$chart: the container must expose only port 3100"
        [ "$(rq 'select(.kind == "Service") | [.spec.ports[].port] | join(",")' "$out")" = 3100 ] || err "$chart: the Service must expose only port 3100"
        [ "$(yq "$deployment | .containers[0].readinessProbe.httpGet.path" <<<"$out")" = /readyz ] || err "$chart: readiness must be /readyz"
        [ "$(yq 'select(.kind == "ConfigMap") | .data.MIGRATE_ON_START' <<<"$out")" = 1 ] || err "$chart: MIGRATE_ON_START must render as 1"
        [ "$(yq 'select(.kind == "ConfigMap") | .data.ADMIN_LISTEN' <<<"$out")" = 127.0.0.1:3101 ] || err "$chart: the admin listener must stay on loopback"
        [ "$(rq "$deployment | [.containers[0].env[].name] | join(\",\")" "$out")" = DATABASE_URL,RELAYFILE_INTERNAL_HMAC_SECRET,RELAYFILE_CONTROL_ADMIN_TOKEN,RELAYCONTROL_SERVICE_TOKEN ] \
          || err "$chart: the default render must inject only the four core Secret env vars"
        ! grep -Eq 'FLOWS_ENABLED|RELAYCONTROL_LICENSE' <<<"$out" || err "$chart: Flows and license env must not render by default"
        [ "$(helm template relayfile-control "charts/$chart" --namespace ci --no-hooks -f "$v" | yq 'select(.kind == "Service") | .metadata.name')" = relayfile-control ] \
          || err "$chart: a release named relayfile-control must create the Service the ALB script targets by default"
        v=charts/relayfile-control/ci/flows-values.yaml
        for field in config.publicOrigin flows.encryptionKeyId; do
          expect_render_failure "$chart" "$v" "Flows without $field" "flows.enabled=true requires $field" --set "$field="
        done
        expect_render_failure "$chart" "$v" "Flows without Relaycast" "flows.enabled=true requires flows.workerRelaycastUrl or flows.relaycastPublicUrl" --set flows.workerRelaycastUrl=
        expect_render_failure "$chart" "$v" "Flows without the broker key" "flows.enabled=true requires secretKeys.brokerSecret" --set secretKeys.brokerSecret=
        expect_render_failure "$chart" "$v" "equal introspect and broker keys" "name the same Secret key" --set secretKeys.brokerSecret=RELAYCONTROL_INTROSPECT_SECRET
        expect_render_failure "$chart" "$v" "half-set key rotation" "must be set together" --set flows.previousEncryptionKeyId=k0
        out=$(render "$chart" "$v")
        [ "$(rq 'select(.kind == "Ingress") | [.spec.rules[0].http.paths[] | .path + "=" + .pathType] | join(",")' "$out")" = "/cloud/api/v1/flows=Prefix,/cloud/api/v1/workers=Prefix,/cloud/api/v1/workflows=Prefix,/api/v1/flows=Prefix,/api/v1/workers=Prefix,/api/v1/workflows=Prefix" ] \
          || err "$chart: the Ingress must route exactly the Flows paths and their /cloud aliases"
        for name in RELAYCONTROL_INTROSPECT_SECRET RELAYFILE_CONTROL_BROKER_SECRET RELAYFILE_CONTROL_ENCRYPTION_KEY; do
          [ "$(yq "select(.kind == \"Deployment\") | .spec.template.spec.containers[0].env[] | select(.name == \"$name\") | .valueFrom.secretKeyRef.key" <<<"$out")" = "$name" ] \
            || err "$chart: $name must come from the existing Secret"
        done
        ;;
      agent-relay)
        v=charts/agent-relay/ci/gcp-proof-values.yaml
        expect_render_failure "$chart" "$v" "missing History image" "image.digest is required" --set relayhistory.image.digest=
        expect_render_failure "$chart" "$v" "missing API image" "image.digest is required" --set relay-control.image.digest=
        expect_render_failure "$chart" "$v" "missing dashboard image" "image.digest is required" --set relay-webapp.image.digest=
        expect_render_failure "$chart" "$v" "dashboardUrl off the root host" "relay-control.dashboardUrl must be on the dashboard host" --set relay-control.dashboardUrl=https://elsewhere.agentrelay.com/
        [ -n "$(render "$chart" "$v" --set relay-control.dashboardUrl=https://gcp-proof.agentrelay.com:443/)" ] || err "$chart: dashboardUrl with an explicit :443 on the root host must render"
        # One global.branding.logo value hosts the logo on the dashboard and
        # points Control's sign-in page at it.
        logo=$(render "$chart" charts/agent-relay/ci/single-host-values.yaml --set-string 'global.branding.logo.svg=<svg xmlns="http://www.w3.org/2000/svg"/>')
        [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "SELFHOST_LOGIN_LOGO_URL") | .value' <<<"$logo")" = https://relay.gcp-proof.agentrelay.com/brand/logo.svg ] \
          || err "$chart: global.branding.logo must set relay-control's SELFHOST_LOGIN_LOGO_URL on the dashboard origin"
        [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.volumes[] | select(.name == "brand") | .configMap.name' <<<"$logo")" = "$(yq 'select(.kind == "ConfigMap" and (.data | has("logo.svg"))) | .metadata.name' <<<"$logo")" ] \
          || err "$chart: global.branding.logo must mount the chart's logo ConfigMap into relay-webapp"
        expect_render_failure "$chart" charts/agent-relay/ci/single-host-values.yaml "hosted logo without the dashboard" "components.webapp=false" --set gkeIngress.enabled=false --set components.webapp=false --set-string 'global.branding.logo.svg=<svg/>'
        render "$chart" charts/agent-relay/ci/single-host-values.yaml --set gkeIngress.enabled=false --set components.webapp=false --set-string 'global.branding.logo.svg=<svg/>' --set relay-control.login.logoUrl=https://cdn.example.com/logo.svg >/dev/null \
          || err "$chart: components.webapp=false with relay-control.login.logoUrl must render"
        expect_render_failure "$chart" "$v" "ar_ authority without relayauth" "relaycast.credentials.authority=relayauth requires components.relayauth=true" --set components.relayauth=false --set relaycast.credentials.format=ar --set relaycast.credentials.authority=relayauth --set relaycast.credentials.relayauth.url=http://relayauth:8787 --set relaycast.secretKeys.relayauthToken=relaycast-relayauth-token
        ;;
    esac
  fi
done
exit $fail
