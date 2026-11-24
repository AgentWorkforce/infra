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

# relay-control refuses (and crash-loops on) a service URL with a path,
# credentials, query or fragment (relay-control src/config.ts serviceUrl).
# Every such env it is rendered with must be a bare http(s) origin.
check_control_origins() { # label rendered-manifests
  local bad
  bad=$(yq 'select(.kind == "Deployment" and (.spec.template.spec.containers[0].env // [] | map(.name) | contains(["RELAYCAST_URL"]))) | .spec.template.spec.containers[0].env[] | select(.name == "SELFHOST_PUBLIC_URL" or .name == "RELAYCAST_URL" or .name == "RELAYCAST_PUBLIC_URL" or .name == "RELAYHISTORY_URL" or .name == "SESSION_READ_API_URL" or .name == "SESSION_READ_API_PUBLIC_URL" or .name == "SESSION_ERASE_API_URL" or .name == "SELFHOST_RELAYGATE_PUBLIC_URL" or .name == "SELFHOST_RELAYGATE_ADMIN_URL" or .name == "SELFHOST_CUSTOMER_SUPPORT_URL") | select(has("value") and .value != "") | select(.value | test("^https?://[^/?#@]+/?$") | not) | .name + "=" + .value' <<<"$2" | sed '/^---$/d;/^$/d')
  [ -z "$bad" ] || err "$1: relay-control URL env must be a bare origin (Control refuses a path): $bad"
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
  # README.md ships inside the packaged chart (helm show readme, OCI, Artifact
  # Hub), where repo-relative links point nowhere. Link with absolute URLs.
  if [ "$mode" = static ] && [ -f "charts/$chart/README.md" ] &&
     grep -nE '\]\((\.\.?/|[A-Za-z0-9_-]+\.md)' "charts/$chart/README.md"; then
    err "$chart: README.md has relative links; use https://github.com/AgentWorkforce/infra/blob/main/..."
  fi
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
    if [ "$mode" = static ] && [ "$chart" = agent-relay ]; then
      python3 ci/agent-relay/test_ingress_routes.py || err "$chart: dashboard ingress route contract failed"
    fi
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
        case $chart in relay-control|agent-relay) check_control_origins "$label" "$out" ;; esac
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
      slack-relay)
        # repos: the GitHub token reaches only the repo-sync sidecar; the host
        # mounts /repos read-only and its agents get only Read/Glob/Grep on it.
        v=charts/slack-relay/ci/repos-values.yaml
        repos_out=$(render "$chart" "$v") || { err "$chart: repos render failed"; continue; }
        repos_out=$(yq 'select(.kind == "StatefulSet")' <<<"$repos_out")
        sts='.'
        [ "$(yq "[.spec.template.spec.containers[] | select(.env | any_c(.name == \"GITHUB_TOKEN\")) | .name] | join(\",\")" <<<"$repos_out")" = repo-sync ] \
          || err "$chart: GITHUB_TOKEN must be in the repo-sync container only"
        [ "$(yq "$sts | .spec.template.spec.containers[] | select(.name == \"host\") | .volumeMounts[] | select(.name == \"repos\") | .readOnly" <<<"$repos_out")" = true ] \
          || err "$chart: the host must mount /repos read-only"
        [ "$(yq "$sts | .spec.template.spec.containers[] | select(.name == \"host\") | .env[] | select(.name == \"AGENT_ALLOWED_TOOLS\") | .value" <<<"$repos_out")" = 'Read(./**) Glob(./**) Grep(./**) mcp__relaycast Read(//repos/**) Glob(//repos/**) Grep(//repos/**)' ] \
          || err "$chart: repos must add exactly Read/Glob/Grep on //repos/** to the agents' tools"
        [ "$(yq "$sts | .spec.template.spec.containers[] | select(.name == \"repo-sync\") | .env[] | select(.name == \"REPOS_LIST\") | .value" <<<"$repos_out")" = $'example-org/api\nexample-org/web release/2026' ] \
          || err "$chart: REPOS_LIST must list each repo with its ref"
        ! grep -q 'repo-sync\|/repos' <<<"$(render "$chart" charts/slack-relay/ci/default-values.yaml)" \
          || err "$chart: repos off must render no sidecar or mount"
        expect_render_failure "$chart" "$v" "repos without a token" "repos.enabled needs repos.app.privateKey.name" --set repos.token.name=
        # An empty list syncs every repo the token can read, via the API.
        all_out=$(render "$chart" "$v" --set-json 'repos.list=[]' | yq 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "repo-sync") | .env[] | select(.name == "REPOS_LIST" or .name == "REPOS_API_URL") | .name + "=" + .value')
        [ "$all_out" = $'REPOS_API_URL=https://api.github.com\nREPOS_LIST=' ] || err "$chart: an empty repos.list must render an empty REPOS_LIST and the github.com API: $all_out"
        expect_render_failure "$chart" "$v" "repo path traversal" "must be owner/name" --set-json 'repos.list=["../etc"]'
        expect_render_failure "$chart" "$v" "repo listed twice" "more than once" --set-json 'repos.list=["a/b",{"repo":"A/b","ref":"dev"}]'
        expect_render_failure "$chart" "$v" "repo option-like ref" "must be a branch, tag or commit" --set-json 'repos.list=[{"repo":"a/b","ref":"--upload-pack=x"}]'
        expect_render_failure "$chart" "$v" "repos host with credentials" "repos.host must be a host name or base URL" --set repos.host=https://user:pw@ghe.example.com
        expect_render_failure "$chart" "$v" "repos zero refresh" "repos.refreshMinutes must be a whole number" --set repos.refreshMinutes=0
        ghe_out=$(render "$chart" "$v" --set repos.host=https://ghe.example.com/)
        grep -q 'value: "https://ghe.example.com"' <<<"$ghe_out" || err "$chart: a GHE base URL must render as REPOS_BASE_URL"
        grep -q 'value: "https://ghe.example.com/api/v3"' <<<"$ghe_out" || err "$chart: a GHE host must list repos through <base>/api/v3"
        # repos.app: the GitHub App's private key is a Secret volume only the
        # repo-sync sidecar mounts; no container gets GITHUB_TOKEN from a Secret.
        av=charts/slack-relay/ci/repos-app-values.yaml
        app_out=$(render "$chart" "$av" | yq 'select(.kind == "StatefulSet") | .spec.template.spec') || { err "$chart: repos app render failed"; continue; }
        [ "$(yq '[.containers[] | select(.volumeMounts | any_c(.name == "repo-sync-app-key")) | .name] | join(",")' <<<"$app_out")" = repo-sync ] \
          || err "$chart: only repo-sync may mount the GitHub App private key"
        [ "$(yq '.volumes[] | select(.name == "repo-sync-app-key") | .secret.secretName + "/" + .secret.items[0].key' <<<"$app_out")" = slack-relay-github-app/private-key ] \
          || err "$chart: the app key volume must come from repos.app.privateKey"
        [ "$(yq '[.containers[] | .env[]? | select(.name == "GITHUB_TOKEN")] | length' <<<"$app_out")" = 0 ] \
          || err "$chart: app mode must not render GITHUB_TOKEN"
        [ "$(yq '.containers[] | select(.name == "repo-sync") | .env[] | select(.name == "REPOS_AUTH" or .name == "GITHUB_APP_ID" or .name == "GITHUB_APP_INSTALLATION_ID") | .name + "=" + (.value // (.valueFrom.secretKeyRef.name + ":" + .valueFrom.secretKeyRef.key))' <<<"$app_out")" = $'REPOS_AUTH=app\nGITHUB_APP_ID=slack-relay-github-app:app-id\nGITHUB_APP_INSTALLATION_ID=slack-relay-github-app:installation-id' ] \
          || err "$chart: app mode must read the app and installation IDs from the helper's Secret by default"
        ids_out=$(render "$chart" "$av" --set repos.app.appId=1234567 --set repos.app.installationId=98765432 | yq 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "repo-sync") | .env[] | select(.name == "GITHUB_APP_ID" or .name == "GITHUB_APP_INSTALLATION_ID") | .value')
        [ "$ids_out" = $'1234567\n98765432' ] || err "$chart: numeric app and installation IDs must render as integers: $ids_out"
        expect_render_failure "$chart" "$av" "repos with both app and token" "not both" --set repos.token.name=slack-relay-github
        expect_render_failure "$chart" "$av" "repos app bad installation id" "installationId must be a number" --set repos.app.installationId=abc
        expect_render_failure "$chart" "$av" "repos app bad app id" "appId must be the GitHub App" --set repos.app.appId=not-an-id
        expect_render_failure "$chart" "$av" "repos app fractional installation id" "installationId must be a number" --set-json repos.app.installationId=42.9
        expect_render_failure "$chart" "$av" "repos app fractional app id" "appId must be the GitHub App" --set-json repos.app.appId=1234567.5
        render "$chart" "$v" | yq 'select(.kind == "ConfigMap") | .data | keys | sort | join(",")' | grep -qx 'github-app.mts,repo-list.mts,repo-sync.sh' \
          || err "$chart: the repo-sync ConfigMap must carry repo-sync.sh, repo-list.mts and github-app.mts"
        ;;
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
        rds_out=$(render "$chart" "$v" --set migrations.databaseMode=rds --set migrations.supabaseShim=false --set migrations.runtimeRoleLogin=true --set migrations.rdsLayout=separate-database --set migrations.waitForRole.enabled=false)
        [ "$(yq 'select(.kind == "Job" and (.metadata.name | contains("migrate"))) | [.spec.template.spec.containers[0].env[] | select(.name == "HOOPDB_RDS_LAYOUT" and .value == "separate-database")] | length | select(. == 1)' <<<"$rds_out")" = 1 ] \
          || err "$chart: rdsLayout must render once into the migrate Job"
        ! yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "HOOPDB_RDS_LAYOUT")' <<<"$rds_out" | grep -q . \
          || err "$chart: HOOPDB_RDS_LAYOUT must not reach long-running workloads"
        expect_render_failure "$chart" "$v" "rds layout outside rds" "migrations.rdsLayout is supported only in rds mode" --set migrations.rdsLayout=separate-database
        expect_render_failure "$chart" "$v" "unknown rds layout" "migrations.rdsLayout must be master-owner or separate-database" --set migrations.databaseMode=rds --set migrations.supabaseShim=false --set migrations.runtimeRoleLogin=true --set migrations.rdsLayout=unknown --set migrations.waitForRole.enabled=false
        expect_render_failure "$chart" "$v" "raw rds layout env" "extraEnv must not set HOOPDB_RDS_LAYOUT" --set-json 'extraEnv=[{"name":"HOOPDB_RDS_LAYOUT","value":"separate-database"}]'
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
        for origin in https://history.gcp-proof.agentrelay.com http://history.agent-relay.svc:8080; do
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
        [ "$(yq 'select(.kind == "PodDisruptionBudget") | .spec.maxUnavailable' <<<"$out" | sed '/^$/d')" = 1 ] \
          || err "$chart: the multi-replica actors gateway must render a maxUnavailable=1 PDB"
        [ "$(yq 'select(.kind == "PodDisruptionBudget") | .spec.selector.matchLabels["app.kubernetes.io/name"]' <<<"$out" | sed '/^$/d')" = relaycast ] \
          || err "$chart: the actors gateway PDB selector must match the gateway"
        spread=$(render "$chart" "$v" --set runtime.durableActors.gateway.topologySpread.enabled=true)
        [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.topologySpreadConstraints[0].labelSelector.matchLabels["app.kubernetes.io/name"]' <<<"$spread" | sed '/^$/d')" = relaycast ] \
          || err "$chart: generated gateway topology spread must match the release labels"
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
        # Postgres -> durable-actors migration steps (docs/relaycast-postgres-to-actors-migration.md).
        mig=(--set migration.enabled=true --set migration.runId=run-ci-0001)
        pg=charts/relaycast/ci/postgres-values.yaml
        s3=charts/relaycast/ci/durable-actors-s3-values.yaml
        expect_render_failure "$chart" "$pg" "migration step on the wrong backend" "migration.step=import runs after the cutover" "${mig[@]}" --set migration.step=import
        expect_render_failure "$chart" "$s3" "export after the cutover" "migration.step=export runs on the PostgreSQL release" "${mig[@]}" --set migration.step=export
        expect_render_failure "$chart" "$pg" "unknown migration step" "migration.step must be preflight, export, files, import, verify or open" "${mig[@]}" --set migration.step=copy
        expect_render_failure "$chart" "$pg" "short migration run id" "migration.runId must be 8-64 URL-safe characters" --set migration.enabled=true --set migration.runId=x --set migration.step=export
        expect_render_failure "$chart" "$pg" "non-numeric arSince" "migration.arSince must be epoch seconds" "${mig[@]}" --set migration.step=preflight --set migration.arSince=yesterday
        expect_render_failure "$chart" "$pg" "preflight without arSince" "migration.arSince must be epoch seconds" "${mig[@]}" --set migration.step=preflight
        expect_render_failure "$chart" "$pg" "preflight on a ReadWriteOncePod claim" "cannot share a ReadWriteOncePod" "${mig[@]}" --set migration.step=preflight --set migration.arSince=1 --set persistence.accessMode=ReadWriteOncePod
        out=$(render "$chart" "$pg" "${mig[@]}" --set migration.step=preflight --set migration.arSince=1 --set migration.allowLegacy=true)
        mj='select(.kind == "Job" and .metadata.labels["app.kubernetes.io/component"] == "migration-preflight")'
        [ "$(yq "$mj | .spec.template.spec.affinity.podAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].topologyKey" <<<"$out" | sed '/^$/d')" = kubernetes.io/hostname ] \
          || err "$chart: the online preflight must run on the Relaycast pod's node (ReadWriteOnce claim)"
        [ "$(yq "$mj | .spec.template.spec.containers[0].args | join(\" \")" <<<"$out" | sed '/^$/d')" = "migration-preflight --file-dir /data/relaycast-files --ar-since 1 --export-dir /data --allow-legacy" ] \
          || err "$chart: migration preflight must check legacy credentials, files and export capacity"
        [ "$(yq "$mj | .spec.template.spec.volumes[] | select(.name == \"secrets\") | .secret.items[].path" <<<"$out" | sed '/^$/d')" = database-runtime-url ] \
          || err "$chart: migration preflight must mount only the runtime database URL"
        ! yq 'select(.kind == "Job") | .metadata.name' <<<"$(render "$chart" "$pg")" | grep -q migration \
          || err "$chart: migration Jobs must not render unless migration.enabled"
        out=$(render "$chart" "$pg" "${mig[@]}" --set migration.step=export)
        mj='select(.kind == "Job" and .metadata.labels["app.kubernetes.io/component"] == "migration-export")'
        [ "$(yq "$mj | .spec.template.spec.containers[0].args | join(\" \")" <<<"$out" | sed '/^$/d')" = "export-for-actors --out /data/migration/run-ci-0001 --run-id run-ci-0001" ] \
          || err "$chart: migration export must write to the data claim under the run id"
        [ "$(yq "$mj | [.spec.template.spec.volumes[] | select(.name == \"secrets\") | .secret.items[].path] | join(\",\")" <<<"$out" | sed '/^$/d')" = database-runtime-url,internal-secret ] \
          || err "$chart: migration export must mount only the runtime database URL and the internal secret (block sealing)"
        [ "$(yq "$mj | .spec.template.spec.containers[0].env[] | select(.name == \"RELAYCAST_DATABASE_CA_FILE\") | .value" <<<"$out" | sed '/^$/d')" = /etc/postgres-ca/ca.crt ] \
          || err "$chart: migration export must verify the database against the CA"
        out=$(render "$chart" "$s3" "${mig[@]}" --set migration.step=files)
        mj='select(.kind == "Job" and .metadata.labels["app.kubernetes.io/component"] == "migration-files")'
        [ "$(yq "$mj | [.spec.template.spec.containers[0].env[].name] | join(\",\")" <<<"$out" | sed '/^$/d')" = "RELAYCAST_FILE_STORE,RELAYCAST_S3_BUCKET,RELAYCAST_S3_REGION,RELAYCAST_S3_PREFIX,RELAYCAST_S3_FORCE_PATH_STYLE,NODE_OPTIONS,RELAYCAST_INTERNAL_SECRET_FILE" ] \
          || err "$chart: migration files must get the gateway's file store settings and no secrets"
        [ "$(yq "$mj | .spec.template.spec.containers[0].env[] | select(.name == \"NODE_OPTIONS\") | .value" <<<"$out" | sed '/^$/d')" = --max-old-space-size=768 ] \
          || err "$chart: migration Jobs must size the heap from the memory limit"
        out=$(render "$chart" "$s3" "${mig[@]}" --set migration.step=files --set-json 'extraEnv=[{"name":"NODE_OPTIONS","value":"--max-old-space-size=300"}]')
        [ "$(yq "$mj | [.spec.template.spec.containers[0].env[] | select(.name == \"NODE_OPTIONS\") | .value] | join(\",\")" <<<"$out" | sed '/^$/d')" = --max-old-space-size=300 ] \
          || err "$chart: an operator NODE_OPTIONS must reach the migration Jobs, once"
        [ "$(yq "$mj | .spec.template.spec.containers[0].volumeMounts[] | select(.name == \"data\") | .readOnly" <<<"$out" | sed '/^$/d')" = true ] \
          || err "$chart: migration files must read the old files read-only"
        ! yq 'select(.kind == "PersistentVolumeClaim") | .metadata.name' <<<"$(render "$chart" "$s3")" | grep -q . \
          || err "$chart: durable-actors with s3 files must not render a data claim by default"
        [ "$(yq 'select(.kind == "PersistentVolumeClaim") | .metadata.name' <<<"$(render "$chart" "$s3" --set persistence.retainForMigration=true)" | sed '/^$/d')" = ci-relaycast-data ] \
          || err "$chart: persistence.retainForMigration must keep the previous backend's data claim"
        gwout=$(render "$chart" "$s3" --set runtime.durableActors.socketOrigin=controlPlane)
        cp_url=$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "DURABLE_ACTORS_CONTROL_PLANE_URL") | .value' <<<"$gwout" | sed '/^$/d')
        [ -n "$cp_url" ] && [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "DURABLE_ACTORS_SOCKET_ORIGIN") | .value' <<<"$gwout" | sed '/^$/d')" = "$cp_url" ] \
          || err "$chart: socketOrigin=controlPlane must dial the in-cluster control plane"
        ! yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[].name' <<<"$(render "$chart" "$s3")" | grep -qx DURABLE_ACTORS_SOCKET_ORIGIN \
          || err "$chart: no socket origin unless runtime.durableActors.socketOrigin is set"
        out=$(render "$chart" "$s3" "${mig[@]}" --set migration.step=import)
        mj='select(.kind == "Job" and .metadata.labels["app.kubernetes.io/component"] == "migration-import")'
        [ "$(yq "$mj | .spec.template.spec.containers[0].args[-1]" <<<"$out" | sed '/^$/d')" = "http://ci-relaycast.ci.svc:8787" ] \
          || err "$chart: migration import must reach the gateway Service"
        # Gate-only: the leaf Ingress sends only relaygate's routes to the
        # relaygate Service and denies the rest; the policy ignores ingressFrom.
        v=charts/relaycast/ci/default-values.yaml
        gate=(--set global.relaygate.gateOnly.enabled=true --set ingress.enabled=true --set 'ingress.hosts={relay.example.com}' --set ingress.externalTls=true --set 'networkPolicy.ingressFrom[0].podSelector.matchLabels.app=ingress')
        out=$(render "$chart" "$v" "${gate[@]}") || err "$chart: gate-only did not render"
        [ "$(yq 'select(.kind == "Ingress") | [.spec.rules[0].http.paths[] | .path + ">" + .backend.service.name] | join(" ")' <<<"$out" | sed '/^---$/d;/^$/d')" = "/v1/register>ci-relaygate /v1/check>ci-relaygate /v1/whoami>ci-relaygate /v1/agent>ci-relaygate /v1/agent/node-token>ci-relaygate /v1/node/ws>ci-relaygate /v1/search>ci-relaygate /v1/inbox>ci-relaygate /v1/agents>ci-relaygate /v1/channels>ci-relaygate /v1/messages>ci-relaygate /v1/dm>ci-relaygate /v1/streams>ci-relaygate /v1/deliveries>ci-relaygate />ci-relaycast-deny" ] \
          || err "$chart: gate-only Ingress must route only relaygate's paths to relaygate"
        [ "$(yq 'select(.kind == "NetworkPolicy") | [.spec.ingress[0].from[].podSelector.matchLabels["app.kubernetes.io/name"]] | join(" ")' <<<"$out" | sed '/^---$/d;/^$/d')" = "relaygate relaycast-migration relay-control relayauth" ] \
          || err "$chart: gate-only policy must admit relaygate, the migration Job and networkPolicy.gateOnlyFrom only"
        expect_render_failure "$chart" "$v" "gate-only without a policy" "requires networkPolicy.enabled=true" "${gate[@]}" --set networkPolicy.enabled=false
        # Sessions-only (gateOnly.scope=sessions) leaves Relaycast direct: the
        # Ingress and policy render as with the gate off.
        nogate=("${gate[@]/global.relaygate.gateOnly.enabled=true/global.relaygate.gateOnly.enabled=false}")
        [ "$(render "$chart" "$v" "${gate[@]}" --set global.relaygate.gateOnly.scope=sessions)" = "$(render "$chart" "$v" "${nogate[@]}")" ] \
          || err "$chart: gateOnly.scope=sessions must render Relaycast as with the gate off"
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
        # Co-branding: dashboardKey serves a second PNG from the same ConfigMap.
        logo=$(render "$chart" "$v" --set global.branding.logo.existingConfigMap=relay-brand --set global.branding.logo.key=mark.png --set global.branding.logo.dashboardKey=cobrand.png)
        [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.volumes[] | select(.name == "brand") | [.configMap.items[].path] | join(" ")' <<<"$logo" | grep -v '^---$' | grep .)" = "mark.png cobrand.png" ] \
          || err "$chart: dashboardKey must project a second file beside key"
        kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version "${KUBE_VERSION:-1.33.0}" <<<"$logo" >/dev/null || err "$chart: co-brand logo render failed kubeconform"
        expect_render_failure "$chart" "$v" "dashboardKey without a ConfigMap" "global.branding.logo.dashboardKey names a key in existingConfigMap" --set global.branding.logo.dashboardKey=cobrand.png
        expect_render_failure "$chart" "$v" "dashboardKey type" "global.branding.logo.dashboardKey must be a file name" --set global.branding.logo.existingConfigMap=relay-brand --set global.branding.logo.dashboardKey=cobrand.svg
        expect_render_failure "$chart" "$v" "dashboardKey equal to key" "dashboardKey must differ from key" --set global.branding.logo.existingConfigMap=relay-brand --set global.branding.logo.dashboardKey=logo.png
        ;;
      relay-control)
        v=charts/relay-control/ci/default-values.yaml
        check_postgres_ca "$chart" "$v"
        expect_render_failure "$chart" "$v" "mutable image" "image.digest is required" --set image.digest=
        # services.sessionReadMintIncludeRole: unset by default, "true" when on, and then reserved from extraEnv.
        ! grep -q SESSION_READ_MINT_INCLUDE_ROLE <<<"$(render "$chart" "$v")" || err "$chart: SESSION_READ_MINT_INCLUDE_ROLE must be unset by default"
        grep -Fq '{ name: SESSION_READ_MINT_INCLUDE_ROLE, value: "true" }' <<<"$(render "$chart" "$v" --set services.sessionReadMintIncludeRole=true)" || err "$chart: sessionReadMintIncludeRole=true must render SESSION_READ_MINT_INCLUDE_ROLE=true"
        expect_render_failure "$chart" "$v" "role mint as a string" "services.sessionReadMintIncludeRole must be true or false" --set-string services.sessionReadMintIncludeRole=true
        expect_render_failure "$chart" "$v" "role mint also in extraEnv" "SESSION_READ_MINT_INCLUDE_ROLE is managed by structured chart values" --set services.sessionReadMintIncludeRole=true --set-json 'extraEnv=[{"name":"SESSION_READ_MINT_INCLUDE_ROLE","value":"true"}]'
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
      durable-actors)
        # Local patch 12 (UPSTREAM.md): postgresCa appends the Postgres server CA to the
        # image's system roots (init container postgres-ca-bundle, volume postgres-ca)
        # and points SSL_CERT_FILE at it in the control plane and the pool manager.
        v=charts/durable-actors/ci/eks-values.yaml
        off=$(render "$chart" "$v")
        ! grep -Eq 'postgres-ca|SSL_CERT_FILE|initContainers' <<<"$off" || err "$chart: postgresCa off must render nothing"
        for src in "configMap=rds-ca" "secret=rds-ca-secret"; do
          on=$(render "$chart" "$v" --set postgresCa.enabled=true --set "postgresCa.$src" --set postgresCa.key=global-bundle.pem) || { err "$chart: postgresCa $src did not render"; continue; }
          [ "$(yq 'select(.kind == "Deployment") | .metadata.name' <<<"$on" | grep -v '^---$' | sort | tr '\n' ' ')" = "ci-durable-actors ci-durable-actors-pool-manager " ] \
            || err "$chart: expected the control-plane and pool-manager Deployments"
          if [ "${src%%=*}" = configMap ]; then
            source='.configMap.name == "rds-ca" and (.configMap.items | length) == 1 and .configMap.items[0].key == "global-bundle.pem" and .configMap.items[0].path == "ca.crt"'
          else
            source='.secret.secretName == "rds-ca-secret" and .secret.defaultMode == 0444 and (.secret.items | length) == 1 and .secret.items[0].key == "global-bundle.pem" and .secret.items[0].path == "ca.crt"'
          fi
          ok='([.spec.template.spec.volumes[] | select(.name == "postgres-ca-source" and '"$source"')] | length) == 1'
          ok+=' and ([.spec.template.spec.volumes[] | select(.name == "postgres-ca" and .emptyDir.medium == "Memory")] | length) == 1'
          ok+=' and ([.spec.template.spec.initContainers[] | select(.name == "postgres-ca-bundle" and (.command[-1] | contains("/etc/ssl/certs/ca-certificates.crt")) and (.command[-1] | contains("/etc/postgres-ca-source/ca.crt")) and .securityContext.readOnlyRootFilesystem == true)] | length) == 1'
          ok+=' and .spec.template.spec.initContainers[0].image == .spec.template.spec.containers[0].image'
          ok+=' and ([.spec.template.spec.containers[0].volumeMounts[] | select(.name == "postgres-ca" and .mountPath == "/etc/postgres-ca" and .readOnly == true)] | length) == 1'
          ok+=' and ([.spec.template.spec.containers[0].volumeMounts[] | select(.name == "postgres-ca-source")] | length) == 0'
          ok+=' and ([.spec.template.spec.containers[0].env[] | select(.name == "SSL_CERT_FILE" and .value == "/etc/postgres-ca/ca.crt")] | length) == 1'
          missing=$(yq "select(.kind == \"Deployment\") | select(($ok) | not) | .metadata.name" <<<"$on" | grep -v '^---$' || true)
          [ -z "$missing" ] || err "$chart: postgresCa $src did not reach: $missing"
          kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version "${KUBE_VERSION:-1.33.0}" <<<"$on" >/dev/null || err "$chart: postgresCa $src failed kubeconform"
        done
        expect_render_failure "$chart" "$v" "postgresCa without a source" "postgresCa.enabled=true requires exactly one of postgresCa.configMap or postgresCa.secret" --set postgresCa.enabled=true
        expect_render_failure "$chart" "$v" "postgresCa with both sources" "postgresCa.enabled=true requires exactly one of postgresCa.configMap or postgresCa.secret" --set postgresCa.enabled=true --set postgresCa.configMap=a --set postgresCa.secret=b
        expect_render_failure "$chart" "$v" "postgresCa source while disabled" "postgresCa.configMap and postgresCa.secret require postgresCa.enabled=true" --set postgresCa.configMap=rds-ca
        expect_render_failure "$chart" "$v" "postgresCa non-boolean enabled" "/postgresCa/enabled" --set-string postgresCa.enabled=true
        expect_render_failure "$chart" "$v" "postgresCa bad name" "/postgresCa/configMap" --set postgresCa.enabled=true --set postgresCa.configMap=Bad_Name
        expect_render_failure "$chart" "$v" "postgresCa bad key" "/postgresCa/key" --set postgresCa.enabled=true --set postgresCa.configMap=rds-ca --set postgresCa.key=../x
        resilient=$(render "$chart" "$v" --set podDisruptionBudget.enabled=true --set podDisruptionBudget.maxUnavailable=0 --set topologySpread.enabled=true)
        [ "$(yq 'select(.kind == "PodDisruptionBudget") | .spec.maxUnavailable' <<<"$resilient" | sed '/^$/d')" = 0 ] \
          || err "$chart: singleton control-plane PDB must preserve maxUnavailable=0"
        missing=$(yq 'select(.kind == "Deployment") | select((.spec.template.spec.topologySpreadConstraints[0].labelSelector.matchLabels["app.kubernetes.io/name"] == .metadata.name) | not) | .metadata.name' <<<"$resilient" | grep -v '^---$' || true)
        [ -z "$missing" ] || err "$chart: generated topology spread does not select its Deployment: $missing"
        ;;
      relaygate)
        v=charts/relaygate/ci/sessions-values.yaml
        out=$(render "$chart" "$v")
        env_value() { yq "select(.kind == \"Deployment\") | .spec.template.spec.containers[0].env[] | select(.name == \"$1\") | .value" <<<"$out" | sed '/^---$/d;/^$/d'; }
        [ "$(env_value SESSIONS_URL)" = https://history.example.com ] || err "$chart: SESSIONS_URL not rendered"
        [ "$(env_value SESSIONS_UPLOAD_URL)" = http://session-ingest-api:8080 ] || err "$chart: SESSIONS_UPLOAD_URL not rendered"
        [ "$(env_value SESSIONS_READ_URL)" = http://session-read-api:8080 ] || err "$chart: SESSIONS_READ_URL not rendered"
        [ "$(env_value SESSIONS_HOSTS)" = history.example.com,history.internal.example.com ] || err "$chart: SESSIONS_HOSTS not comma-joined"
        grep -A1 -F -- '- name: SESSIONS_TOKEN' <<<"$out" | grep -Fq 'name: relaygate-sessions' || err "$chart: named sessionsToken not rendered"
        out=$(render "$chart" charts/relaygate/ci/proxy-values.yaml)
        ! grep -Eq 'name: SESSIONS_(TOKEN|UPLOAD_URL|READ_URL|HOSTS)$' <<<"$out" || err "$chart: unset Sessions settings rendered"
        expect_render_failure "$chart" "$v" "split upstream without sessionsUrl" "need proxy.sessionsUrl" --set proxy.sessionsUrl=
        expect_render_failure "$chart" "$v" "sessionsHosts without split upstreams" "proxy.sessionsHosts needs proxy.sessionsUploadUrl and proxy.sessionsReadUrl" --set proxy.sessionsReadUrl=
        expect_render_failure "$chart" "$v" "sessionsHosts loop" "requests would loop back to relaygate" --set proxy.sessionsReadUrl=https://History.example.com:443
        v=charts/relaygate/ci/control-values.yaml
        out=$(render "$chart" "$v")
        [ "$(env_value RELAYCONTROL_INTROSPECT_URL)" = http://relay-control:8080/internal/v1/auth/introspect ] || err "$chart: RELAYCONTROL_INTROSPECT_URL not rendered"
        [ "$(env_value SESSION_INGEST_AUDIENCE)" = https://history.example.com ] || err "$chart: SESSION_INGEST_AUDIENCE not rendered"
        [ "$(env_value SESSIONS_CORS_ORIGINS)" = https://app.example.com,https://history.example.com ] || err "$chart: SESSIONS_CORS_ORIGINS not comma-joined"
        grep -A1 -F -- '- name: RELAYCONTROL_INTROSPECT_SECRET' <<<"$out" | grep -Fq 'name: relaygate-control' || err "$chart: introspect secret not rendered"
        grep -A1 -F -- '- name: SESSIONS_INTERNAL_SECRET' <<<"$out" | grep -Fq 'name: relaygate-sessions-internal' || err "$chart: sessions internal secret not rendered"
        pol=$(yq 'select(.kind == "ConfigMap") | .data["policy.json"]' <<<"$out" | sed '/^---$/d')
        [ "$(jq -c '[.controlPrincipals[] | [.match.orgIds, .match.roles, .gid]]' <<<"$pol")" = '[[["org_example"],["owner","admin"],22],[["org_example"],null,11]]' ] \
          || err "$chart: policy.controlPrincipals rules not rendered as given"
        [ "$(jq -c '.sessionAggregates.gids' <<<"$pol")" = '[22]' ] || err "$chart: policy.sessionAggregates.gids not rendered as given"
        out=$(render "$chart" charts/relaygate/ci/proxy-values.yaml)
        ! grep -Eq 'name: (RELAYCONTROL_INTROSPECT_URL|SESSION_INGEST_AUDIENCE|SESSIONS_CORS_ORIGINS|SESSIONS_INTERNAL_SECRET)$' <<<"$out" || err "$chart: unset Control settings rendered"
        [ "$(yq 'select(.kind == "ConfigMap") | .data["policy.json"] | from_json | .controlPrincipals | length' <<<"$out" | sed '/^---$/d;/^$/d')" = 0 ] \
          || err "$chart: default policy must not grant Control principals"
        # inboxDefaults: the default mirrors the local- inbox rule; an override whose groups lack a gid it names drops
        # that entry (Helm merges the policy map, so the default would otherwise make the policy fail to load).
        inbox_defaults() { render "$chart" charts/relaygate/ci/proxy-values.yaml "$@" | yq 'select(.kind == "ConfigMap") | .data["policy.json"]' | sed '/^---$/d' | jq -c '.inboxDefaults'; }
        [ "$(inbox_defaults)" = '[{"acl":[{"gid":22,"perm":"r"}],"gid":11,"mode":"660"}]' ] || err "$chart: default inboxDefaults must mirror the local- inbox rule"
        [ "$(inbox_defaults --set-json 'policy.groups=[{"gid":22,"name":"pit"}]')" = '[]' ] || err "$chart: inboxDefaults for an undefined gid must not render"
        [ "$(inbox_defaults --set-json 'policy.groups=[{"gid":11,"name":"local"}]')" = '[]' ] || err "$chart: inboxDefaults with an ACL on an undefined gid must not render"
        [ "$(inbox_defaults --set-json 'policy.inboxDefaults=[]')" = '[]' ] || err "$chart: inboxDefaults: [] must opt out"
        # An operator's own entry naming an undefined gid fails closed rather than falling back to relaygate's 660.
        expect_render_failure "$chart" charts/relaygate/ci/proxy-values.yaml "inboxDefaults ACL names an undefined gid" "policy.inboxDefaults entry for gid 11 names gid(s) 44" --set-json 'policy.inboxDefaults=[{"gid":11,"mode":"600","acl":[{"gid":44,"perm":"r"}]}]'
        expect_render_failure "$chart" charts/relaygate/ci/proxy-values.yaml "inboxDefaults for an undefined gid" "policy.inboxDefaults entry for gid 33 names gid(s) 33" --set-json 'policy.inboxDefaults=[{"gid":33,"mode":"600"}]'
        expect_render_failure "$chart" charts/relaygate/ci/proxy-values.yaml "explicit copy of the default inboxDefaults without gid 22" "policy.inboxDefaults entry for gid 11 names gid(s) 22" --set-json 'policy.groups=[{"gid":11,"name":"local"}]' --set-json 'policy.inboxDefaults=[{"gid":11,"mode":"660","acl":[{"gid":22,"perm":"r"}]}]'
        [ "$(inbox_defaults --set-json 'policy.inboxDefaults=[{"gid":11,"mode":"600","acl":[{"gid":22,"perm":"r"}]}]')" = '[{"acl":[{"gid":22,"perm":"r"}],"gid":11,"mode":"600"}]' ] || err "$chart: an operator inboxDefaults entry must render as given"
        expect_render_failure "$chart" "$v" "Sessions CORS/internal secret without sessionsUrl" "need proxy.sessionsUrl" --set proxy.sessionsUrl=
        # Control principals alone (desktop enrolment): no Sessions proxy needed.
        out=$(render "$chart" "$v" --set proxy.sessionsUrl= --set-json 'proxy.sessionsCorsOrigins=[]' --set secrets.sessionsInternalSecret.name=)
        [ "$(env_value RELAYCONTROL_INTROSPECT_URL)" = http://relay-control:8080/internal/v1/auth/introspect ] || err "$chart: introspection must render without the Sessions proxy"
        ! grep -Eq 'name: SESSIONS_URL$' <<<"$out" || err "$chart: SESSIONS_URL rendered with proxy.sessionsUrl empty"
        expect_render_failure "$chart" "$v" "introspect without audience" "control.introspectUrl needs control.sessionIngestAudience" --set control.sessionIngestAudience=
        expect_render_failure "$chart" "$v" "audience without introspectUrl" "need control.introspectUrl" --set control.introspectUrl= --set secrets.relaycontrolIntrospectSecret.name=
        expect_render_failure "$chart" "$v" "introspect secret without introspectUrl" "need control.introspectUrl" --set control.introspectUrl= --set control.sessionIngestAudience=
        expect_render_failure "$chart" "$v" "introspect without secret" "control.introspectUrl needs control.sessionIngestAudience and secrets.relaycontrolIntrospectSecret.name" --set secrets.relaycontrolIntrospectSecret.name=
        # Gate-only (global.relaygate.gateOnly.enabled): refuses to render with
        # a proxy, sessionsHosts or the Control mapping missing, or a renamed Service.
        gate=(-f charts/relaygate/ci/proxy-values.yaml --set proxy.sessionsUploadUrl=http://session-ingest-api:8080 --set proxy.sessionsReadUrl=http://session-read-api:8080 --set 'proxy.sessionsHosts={history.example.com}' --set control.introspectUrl=http://relay-control:8080/internal/v1/auth/introspect --set control.sessionIngestAudience=https://history.example.com --set secrets.relaycontrolIntrospectSecret.name=control-introspect --set global.relaygate.gateOnly.enabled=true --set global.relaygate.gateOnly.sessionsPort=8081)
        render "$chart" "$v" "${gate[@]}" >/dev/null || err "$chart: gate-only did not render"
        expect_render_failure "$chart" "$v" "gate-only without the Relaycast proxy" "global.relaygate.gateOnly.enabled needs proxy.relaycastUrl" "${gate[@]}" --set proxy.relaycastUrl=
        expect_render_failure "$chart" "$v" "gate-only without sessionsHosts" "global.relaygate.gateOnly.enabled needs proxy.relaycastUrl" "${gate[@]}" --set proxy.sessionsHosts=null
        expect_render_failure "$chart" "$v" "gate-only without the Control mapping" "global.relaygate.gateOnly.enabled needs control.introspectUrl" "${gate[@]}" --set control.introspectUrl= --set control.sessionIngestAudience= --set secrets.relaycontrolIntrospectSecret.name=
        expect_render_failure "$chart" "$v" "gate-only with a renamed Service" "set global.relaygate.gateOnly.serviceName" "${gate[@]}" --set fullnameOverride=gate
        expect_render_failure "$chart" "$v" "gate-only without the sessions port" "needs global.relaygate.gateOnly.sessionsPort" "${gate[@]}" --set global.relaygate.gateOnly.sessionsPort=0
        # The main listener always binds 8080 (PORT); service.port only remaps the Service.
        expect_render_failure "$chart" "$v" "gate-only sessions port on the main listener behind a remapped Service" "not 8080, the main listener" "${gate[@]}" --set service.port=80 --set global.relaygate.gateOnly.servicePort=80 --set global.relaygate.gateOnly.sessionsPort=8080
        render "$chart" "$v" "${gate[@]}" --set service.port=8081 --set global.relaygate.gateOnly.servicePort=8081 --set global.relaygate.gateOnly.sessionsPort=8081 >/dev/null \
          || err "$chart: a Service port equal to the sessions port is fine (the main listener is 8080)"
        expect_render_failure "$chart" "$v" "gate-only with no listener peers" "an empty peer list would admit every source" "${gate[@]}" --set sessionsListener.controlFrom=null
        expect_render_failure "$chart" "$v" "gate-only with an empty listener peer" "must be NetworkPolicy peers with selectors" "${gate[@]}" --set-json 'sessionsListener.controlFrom=[{}]'
        expect_render_failure "$chart" "$v" "gate-only with an unlabelled listener peer" "must name the relay-control pods by label" "${gate[@]}" --set-json 'sessionsListener.controlFrom=[{"podSelector":{}}]'
        expect_render_failure "$chart" "$v" "gate-only with an all-namespaces listener peer" "must name the relay-control pods by label" "${gate[@]}" --set-json 'sessionsListener.controlFrom=[{"namespaceSelector":{}}]'
        expect_render_failure "$chart" "$v" "gate-only with an ipBlock listener peer" "never an ipBlock" "${gate[@]}" --set-json 'sessionsListener.controlFrom=[{"ipBlock":{"cidr":"0.0.0.0/0"}}]'

        render "$chart" "$v" "${gate[@]}" --set fullnameOverride=gate --set global.relaygate.gateOnly.serviceName=gate >/dev/null || err "$chart: gate-only with a matching serviceName must render"
        # Sessions-only (gateOnly.scope=sessions): the Relaycast proxy is optional.
        out=$(render "$chart" "$v" "${gate[@]}" --set global.relaygate.gateOnly.scope=sessions --set proxy.relaycastUrl=) || err "$chart: sessions-only without the Relaycast proxy must render"
        ! grep -q 'name: RELAYCAST_URL' <<<"$out" || err "$chart: sessions-only without proxy.relaycastUrl must not render RELAYCAST_URL"
        expect_render_failure "$chart" "$v" "sessions-only without sessionsHosts" "global.relaygate.gateOnly.enabled needs proxy.sessionsUrl" "${gate[@]}" --set global.relaygate.gateOnly.scope=sessions --set proxy.sessionsHosts=null
        expect_render_failure "$chart" "$v" "gate-only with an unknown scope" "global.relaygate.gateOnly.scope must be all or sessions" "${gate[@]}" --set global.relaygate.gateOnly.scope=everything
        ;;
      agent-relay)
        v=charts/agent-relay/ci/gcp-proof-values.yaml
        # externalSecrets (ESO, e.g. AWS SSM): off renders nothing; on renders
        # one ExternalSecret per target Secret, plus a namespaced SecretStore
        # when store.create, and refuses an incomplete configuration.
        ! render "$chart" "$v" | yq '.kind' | grep -qE '^(ExternalSecret|SecretStore)$' || err "$chart: externalSecrets off must render no ExternalSecret or SecretStore"
        es=(--set externalSecrets.enabled=true --set externalSecrets.store.create=true --set externalSecrets.store.provider.aws.service=ParameterStore --set externalSecrets.store.provider.aws.region=us-east-1
          --set externalSecrets.secrets.agent-relay-secrets.data.database-url=/agent-relay/relaycontrol/runtime-url
          --set externalSecrets.secrets.agent-relay-secrets.data.HOOPDB_URL.key=/agent-relay/hoopdb --set externalSecrets.secrets.agent-relay-secrets.data.HOOPDB_URL.property=url
          --set externalSecrets.secrets.search-indexer-runtime.creationPolicy=Merge --set-json 'externalSecrets.secrets.search-indexer-runtime.dataFrom=[{"find":{"path":"/agent-relay/search-indexer/","name":{"regexp":".*"}}}]')
        out=$(render "$chart" "$v" "${es[@]}") || err "$chart: externalSecrets on did not render"
        [ "$(yq 'select(.kind == "ExternalSecret") | .metadata.name + ":" + .spec.target.name + ":" + .spec.secretStoreRef.kind + "/" + .spec.secretStoreRef.name + ":" + .spec.target.creationPolicy' <<<"$out" | sed '/^---$/d' | tr '\n' ' ')" = "agent-relay-secrets:agent-relay-secrets:SecretStore/ci-external-secrets:Owner search-indexer-runtime:search-indexer-runtime:SecretStore/ci-external-secrets:Merge " ] \
          || err "$chart: each externalSecrets entry must target the Secret of its name through the chart SecretStore"
        [ "$(yq 'select(.kind == "SecretStore") | .metadata.name + " " + .spec.provider.aws.service' <<<"$out" | sed '/^---$/d')" = "ci-external-secrets ParameterStore" ] || err "$chart: store.create must render the SecretStore with store.provider"
        [ "$(yq 'select(.kind == "ExternalSecret" and .metadata.name == "agent-relay-secrets") | .spec.data[] | .secretKey + "=" + .remoteRef.key + "#" + (.remoteRef.property // "")' <<<"$out" | tr '\n' ' ')" = "HOOPDB_URL=/agent-relay/hoopdb#url database-url=/agent-relay/relaycontrol/runtime-url# " ] \
          || err "$chart: externalSecrets data must map a string to remoteRef.key and pass a remoteRef map through"
        # ESO CRD schemas pinned to a CRDs-catalog commit, so invalid
        # ExternalSecret/SecretStore fields fail here instead of being skipped.
        eso_schemas='https://raw.githubusercontent.com/datreeio/CRDs-catalog/784ec895547a36e548e6810b41f27baade3a0890/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
        es_only=$(yq 'select(.kind == "ExternalSecret" or .kind == "SecretStore")' <<<"$out")
        [ "$(yq '.kind' <<<"$es_only" | grep -cE '^(ExternalSecret|SecretStore)$')" = 3 ] || err "$chart: externalSecrets must render two ExternalSecrets and one SecretStore"
        kubeconform -strict -summary -schema-location "$eso_schemas" -kubernetes-version "${KUBE_VERSION:-1.33.0}" <<<"$es_only" >/dev/null || { kubeconform -strict -summary -schema-location "$eso_schemas" <<<"$es_only"; err "$chart: externalSecrets failed kubeconform against the ESO schemas"; }
        # Google Secret Manager through GKE Workload Identity: the overlay the GKE
        # guide ships (docs/gcp-install/external-secrets-values.yaml) renders a
        # gcpsm SecretStore and one ExternalSecret per install Secret, all valid
        # against the ESO schemas, and maps every key step 10 creates.
        gsm=docs/gcp-install/external-secrets-values.yaml
        out=$(sed -e 's/__GCP_PROJECT_ID__/ci-project/g' -e 's/__REGION__/us-central1/g' -e 's/__GKE_CLUSTER__/ci-cluster/g' "$gsm" | render "$chart" "$v" -f -) || err "$chart: $gsm did not render"
        [ "$(yq 'select(.kind == "SecretStore") | .spec.provider.gcpsm | .projectID + " " + .auth.workloadIdentity.clusterLocation + " " + .auth.workloadIdentity.clusterName + " " + .auth.workloadIdentity.clusterProjectID + " " + .auth.workloadIdentity.serviceAccountRef.name' <<<"$out" | sed '/^---$/d')" = "ci-project us-central1 ci-cluster ci-project agent-relay-external-secrets" ] \
          || err "$chart: $gsm must render a gcpsm SecretStore that authenticates with Workload Identity as a ServiceAccount"
        ! yq 'select(.kind == "SecretStore") | .spec.provider.gcpsm.auth | keys | .[]' <<<"$out" | grep -qx secretRef || err "$chart: $gsm must not use a service account key (auth.secretRef)"
        [ "$(yq 'select(.kind == "ExternalSecret") | .metadata.name + "=" + (.spec.data | length | tostring) + ":" + .spec.secretStoreRef.kind' <<<"$out" | sed '/^---$/d' | sort | tr '\n' ' ')" = "agent-relay-ingest-edge-runtime=2:SecretStore agent-relay-read-api=1:SecretStore agent-relay-secrets=14:SecretStore search-indexer-owner=1:SecretStore search-indexer-runtime=1:SecretStore " ] \
          || err "$chart: $gsm must map the five install Secrets (19 keys) through the chart SecretStore"
        [ -z "$(yq 'select(.kind == "ExternalSecret") | .metadata.name as $n | .spec.data[] | select(.remoteRef.key != "agent-relay--" + $n + "--" + .secretKey) | .secretKey' <<<"$out" | sed '/^---$/d;/^$/d')" ] \
          || err "$chart: $gsm must read each key from the Secret Manager secret agent-relay--<Secret>--<key> (helm-secrets-prepare.sh names)"
        gsm_only=$(yq 'select(.kind == "ExternalSecret" or .kind == "SecretStore")' <<<"$out")
        kubeconform -strict -summary -schema-location "$eso_schemas" -kubernetes-version "${KUBE_VERSION:-1.33.0}" <<<"$gsm_only" >/dev/null || { kubeconform -strict -summary -schema-location "$eso_schemas" <<<"$gsm_only"; err "$chart: $gsm failed kubeconform against the ESO schemas"; }
        # The chart README's gcpsm example (a remoteRef map with version) validates too.
        out=$(render "$chart" "$v" --set externalSecrets.enabled=true --set externalSecrets.store.create=true --set externalSecrets.store.provider.gcpsm.projectID=ci-project \
          --set externalSecrets.store.provider.gcpsm.auth.workloadIdentity.serviceAccountRef.name=agent-relay-external-secrets \
          --set externalSecrets.secrets.agent-relay-secrets.data.HOOPDB_URL.key=agent-relay--agent-relay-secrets--HOOPDB_URL --set externalSecrets.secrets.agent-relay-secrets.data.HOOPDB_URL.version=latest) || err "$chart: gcpsm remoteRef map did not render"
        kubeconform -strict -summary -schema-location "$eso_schemas" -kubernetes-version "${KUBE_VERSION:-1.33.0}" <<<"$(yq 'select(.kind == "ExternalSecret" or .kind == "SecretStore")' <<<"$out")" >/dev/null || err "$chart: gcpsm remoteRef map failed kubeconform against the ESO schemas"
        [ "$(yq 'select(.kind == "ExternalSecret") | .spec.data[0].remoteRef.version' <<<"$out")" = latest ] || err "$chart: gcpsm remoteRef version must pass through"
        [ "$(render "$chart" "$v" --set externalSecrets.enabled=true --set externalSecrets.secretStoreRef.name=aws-ssm --set externalSecrets.secrets.x.data.k=/p | yq 'select(.kind == "ExternalSecret") | .spec.secretStoreRef.kind + "/" + .spec.secretStoreRef.name')" = ClusterSecretStore/aws-ssm ] \
          || err "$chart: an existing secretStoreRef must be used as given"
        expect_render_failure "$chart" "$v" "externalSecrets without a store" "requires externalSecrets.secretStoreRef.name" --set externalSecrets.enabled=true --set externalSecrets.secrets.x.data.k=/p
        expect_render_failure "$chart" "$v" "externalSecrets store.create without a provider" "requires externalSecrets.store.provider" --set externalSecrets.enabled=true --set externalSecrets.store.create=true --set externalSecrets.secrets.x.data.k=/p
        expect_render_failure "$chart" "$v" "externalSecrets with no secrets" "at least one entry in externalSecrets.secrets" --set externalSecrets.enabled=true --set externalSecrets.secretStoreRef.name=s
        expect_render_failure "$chart" "$v" "externalSecrets entry with no data" "needs data (Secret key -> remote key) or dataFrom" --set externalSecrets.enabled=true --set externalSecrets.secretStoreRef.name=s --set externalSecrets.secrets.x.creationPolicy=Owner
        expect_render_failure "$chart" "$v" "externalSecrets bad Secret name" "must be a DNS-1123 subdomain" --set externalSecrets.enabled=true --set externalSecrets.secretStoreRef.name=s --set externalSecrets.secrets.Bad_Name.data.k=/p
        expect_render_failure "$chart" "$v" "externalSecrets bad data key" "is not a valid Secret data key" --set externalSecrets.enabled=true --set externalSecrets.secretStoreRef.name=s --set 'externalSecrets.secrets.x.data.a/b=/p'
        expect_render_failure "$chart" "$v" "externalSecrets remoteRef without key" "must be a remote key string or a remoteRef map with key" --set externalSecrets.enabled=true --set externalSecrets.secretStoreRef.name=s --set externalSecrets.secrets.x.data.k.property=url
        expect_render_failure "$chart" "$v" "externalSecrets bad creationPolicy" "creationPolicy must be Owner, Merge, Orphan or None" --set externalSecrets.enabled=true --set externalSecrets.secretStoreRef.name=s --set externalSecrets.secrets.x.data.k=/p --set externalSecrets.creationPolicy=Adopt
        # The standalone RelayHistory component was removed; values that would
        # have deployed it must fail instead of silently dropping History.
        expect_render_failure "$chart" "$v" "removed relayhistory component" "components.relayhistory was removed" --set components.relayhistory=true
        expect_render_failure "$chart" "$v" "removed relayhistory values" "the relayhistory values block was removed" --set relayhistory.image.digest=sha256:8fbda9bd89dd33994b6b3331fb403c38a25f04e6742050bd717e99661f3544ba
        render "$chart" "$v" --set components.relayhistory=false >/dev/null || err "$chart: components.relayhistory=false must still render (ignored)"
        expect_render_failure "$chart" "$v" "legacy Control History backend behind gkeIngress" "relay-control.services.relayhistoryBackend must be native" --set relay-control.services.relayhistoryBackend=legacy --set relay-control.services.relayhistoryUrl=http://history:8080 --set relay-control.services.relayhistoryPublicUrl=https://history.gcp-proof.agentrelay.com --set relay-control.services.sessionReadApiMcpReads=false
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
        # values-branding-example.yaml (co-branding) renders: the sign-in page
        # links the customer mark, relay-webapp serves both PNGs, and the
        # dashboard profile points at the combined logo.
        cobrand=$(render "$chart" charts/agent-relay/ci/single-host-values.yaml -f charts/agent-relay/values-branding-example.yaml) || err "$chart: values-branding-example.yaml did not render"
        [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "SELFHOST_LOGIN_LOGO_URL") | .value' <<<"$cobrand")" = https://relay.gcp-proof.agentrelay.com/brand/mark.png ] \
          || err "$chart: the co-brand example must link the sign-in mark on the dashboard origin"
        [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.volumes[] | select(.name == "brand") | [.configMap.items[].path] | join(" ")' <<<"$cobrand" | grep -v '^---$' | grep .)" = "mark.png cobrand.png" ] \
          || err "$chart: the co-brand example must serve mark.png and cobrand.png"
        [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "DASHBOARD_CUSTOMER_PROFILE") | .value' <<<"$cobrand" | jq -r '.logo + " " + (.productName // "unset")')" = "/brand/cobrand.png unset" ] \
          || err "$chart: the co-brand example must keep the Agent Relay name and use the combined logo"
        expect_render_failure "$chart" charts/agent-relay/ci/single-host-values.yaml "hosted logo without the dashboard" "components.webapp=false" --set gkeIngress.enabled=false --set components.webapp=false --set-string 'global.branding.logo.svg=<svg/>'
        render "$chart" charts/agent-relay/ci/single-host-values.yaml --set gkeIngress.enabled=false --set components.webapp=false --set-string 'global.branding.logo.svg=<svg/>' --set relay-control.login.logoUrl=https://cdn.example.com/logo.svg >/dev/null \
          || err "$chart: components.webapp=false with relay-control.login.logoUrl must render"
        # Gate-only (ci/gate-only-values.yaml): the cast and history hosts reach
        # relaygate on exactly the routes it serves; Relaycast, the reader and
        # the ingest edge admit only relaygate (plus Relaycast's direct
        # server-side callers); Control reads Sessions through relaygate.
        g=charts/agent-relay/ci/gate-only-values.yaml
        out=$(render "$chart" "$g") || err "$chart: gate-only did not render"
        routes() { yq "select(.kind == \"Ingress\") | .spec.rules[] | select(.host == \"$1\") | .http.paths[] | .path + \" \" + .pathType + \" \" + .backend.service.name" <<<"$out" | sed '/^---$/d;/^$/d' | tr '\n' ';'; }
        gate=agent-relay-gcp-proof-gate deny=agent-relay-gcp-proof-cast-edge-deny
        want=""; for p in /v1/register /v1/check /v1/whoami /v1/agent /v1/agent/node-token /v1/node/ws /v1/search /v1/inbox; do want+="$p Exact $gate;"; done
        for p in /v1/agents /v1/channels /v1/messages /v1/dm /v1/streams /v1/deliveries; do want+="$p Prefix $gate;"; done
        [ "$(routes cast.gcp-proof.agentrelay.com)" = "$want/ Prefix $deny;" ] || err "$chart: gate-only cast routes: $(routes cast.gcp-proof.agentrelay.com)"
        want=""; for p in /v1/sessions /v1/delivery /v1/digest; do want+="$p Prefix $gate;"; done; for p in /v1/events /v1/ingest /v1/auth/token/refresh /v1/auth/token/revoke /v1/onboarding/heartbeat /v1/upload-consent; do want+="$p Exact $gate;"; done
        [ "$(routes history.gcp-proof.agentrelay.com)" = "$want/ Prefix $deny;" ] || err "$chart: gate-only history routes: $(routes history.gcp-proof.agentrelay.com)"
        # Gate-only (scope all) on every edge: no route sends /internal or /admin
        # anywhere but a deny backend, and relaygate never gets either.
        for gf in "$g" "$g --set gkeIngress.enabled=false --set traefikIngress.enabled=true --set traefikIngress.hosts.root=gcp-proof.agentrelay.com --set traefikIngress.hosts.api=api.gcp-proof.agentrelay.com --set traefikIngress.hosts.cast=cast.gcp-proof.agentrelay.com --set traefikIngress.hosts.history=history.gcp-proof.agentrelay.com" "$g --set gkeIngress.enabled=false --set eksIngress.enabled=true --set eksIngress.domain=gcp-proof.agentrelay.com --set eksIngress.certificateArn=arn:aws:acm:us-east-1:111111111111:certificate/00000000-0000-0000-0000-000000000000"; do
          # shellcheck disable=SC2086
          ga=$(render "$chart" $gf) || { err "$chart: gate-only edge variant did not render: $gf"; continue; }
          bad=$(yq 'select(.kind == "Ingress") | .spec.rules[] | .host as $h | .http.paths[] | select(.path | test("^/+(internal|admin)")) | select(.backend.service.name | test("deny") | not) | $h + .path' <<<"$ga" | sed '/^---$/d;/^$/d')
          [ -z "$bad" ] || err "$chart: gate-only routes /internal or /admin to a backend: $bad"
        done
        # Desktop on a gate-only install uses the sign-in origin as control_url
        # and opens GET /relay-node/v1/ws there; relay-control serves the
        # relay-node routes only at the root path, so the root host must send
        # /relay-node to relay-control, not the dashboard.
        [ "$(routes gcp-proof.agentrelay.com)" = "/cloud/api Prefix relay-control;/login Prefix relay-control;/relay-node Prefix relay-control;/mcp Prefix relay-control;/cloud/mcp Prefix relay-control;/.well-known/oauth-protected-resource Prefix relay-control;/.well-known/oauth-authorization-server Prefix relay-control;/.well-known/openid-configuration Prefix relay-control;/cloud/.well-known Prefix relay-control;/cloud/oauth Prefix relay-control;/ Prefix relay-webapp;" ] \
          || err "$chart: gate-only root routes must send /relay-node to relay-control: $(routes gcp-proof.agentrelay.com)"
        [ "$(yq "select(.kind == \"Service\" and .metadata.name == \"$gate\") | .spec.selector[\"app.kubernetes.io/name\"] + \" \" + .metadata.annotations[\"cloud.google.com/backend-config\"]" <<<"$out" | sed '/^---$/d;/^$/d')" = "relaygate {\"default\": \"$gate\"}" ] || err "$chart: gate edge Service must select relaygate with its BackendConfig"
        [ "$(yq "select(.kind == \"BackendConfig\" and .metadata.name == \"$gate\") | .spec.healthCheck.requestPath + \" \" + (.spec.timeoutSec | tostring)" <<<"$out" | sed '/^---$/d;/^$/d')" = "/healthz 3600" ] || err "$chart: gate edge BackendConfig must check /healthz with the cast timeout"
        peers() { yq "select(.kind == \"NetworkPolicy\" and .metadata.name == \"$1\") | [.spec.ingress[].from[] | (.podSelector.matchLabels[\"app.kubernetes.io/name\"] // .ipBlock.cidr // \"any\")] | join(\" \")" <<<"$out" | sed '/^---$/d;/^$/d'; }
        [ "$(peers relaycast)" = "relaygate relaycast-migration relay-control relayauth" ] || err "$chart: gate-only relaycast peers: $(peers relaycast)"
        [ "$(peers agent-relay-read-api)" = relaygate ] || err "$chart: gate-only reader peers: $(peers agent-relay-read-api)"
        [ "$(peers agent-relay-ingest-edge)" = relaygate ] || err "$chart: gate-only ingest peers: $(peers agent-relay-ingest-edge)"
        [[ " $(peers relay-control) " == *" relaygate "* ]] || err "$chart: gate-only Control must admit relaygate (introspection)"
        check_control_origins "$chart (gate-only)" "$out"
        [ "$(yq 'select(.kind == "Deployment" and .metadata.name == "relay-control") | .spec.template.spec.containers[0].env[] | select(.name == "SESSION_READ_API_URL") | .value' <<<"$out")" = http://ci-relaygate-sessions.ci.svc.cluster.local:8081 ] \
          || err "$chart: gate-only SESSION_READ_API_URL must be relaygate's internal Sessions listener origin"
        # relaygate's internal Sessions listener: SESSIONS_PORT and its port,
        # a ClusterIP Service on it that no Ingress, HTTPRoute or NEG uses, and a
        # policy that admits only relay-control to it.
        [ "$(yq 'select(.kind == "Deployment" and .metadata.name == "ci-relaygate") | .spec.template.spec.containers[0] | ([.env[] | select(.name == "SESSIONS_PORT") | .value] | join(",")) + " " + ([.ports[] | select(.name == "sessions") | .containerPort | tostring] | join(","))' <<<"$out" | sed '/^---$/d;/^ *$/d')" = "8081 8081" ] \
          || err "$chart: gate-only relaygate must render SESSIONS_PORT=8081 and containerPort 8081"
        [ "$(yq 'select(.kind == "Service" and .metadata.name == "ci-relaygate-sessions") | .spec.type + " " + ([.spec.ports[] | (.port | tostring) + ">" + .targetPort] | join(",")) + " " + (.metadata.annotations["cloud.google.com/neg"] // "no-neg")' <<<"$out" | sed '/^---$/d;/^$/d')" = "ClusterIP 8081>sessions no-neg" ] \
          || err "$chart: gate-only sessions Service must be a ClusterIP on 8081 with no NEG"
        ! yq 'select(.kind == "Ingress" or .kind == "HTTPRoute") | .. | select(. == "ci-relaygate-sessions" or . == 8081)' <<<"$out" | grep -q . || err "$chart: no Ingress or HTTPRoute may reach relaygate's internal Sessions listener"
        ! yq 'select(.kind == "Service" and .metadata.annotations["cloud.google.com/neg"] != null and .spec.selector["app.kubernetes.io/name"] == "relaygate") | .spec.ports[] | select(.port == 8081 or .targetPort == "sessions" or .targetPort == 8081) | .port' <<<"$out" | grep -q . || err "$chart: no NEG Service may expose relaygate's internal Sessions listener"
        [ "$(yq 'select(.kind == "NetworkPolicy" and .metadata.name == "ci-relaygate") | [.spec.ingress[] | ((.ports[0].port | tostring) + ":" + ([(.from // [])[] | .podSelector.matchLabels["app.kubernetes.io/name"]] | join("+") | sub("^$"; "any")))] | join(" ")' <<<"$out" | sed '/^---$/d;/^$/d')" = "http:any sessions:relay-control" ] \
          || err "$chart: gate-only relaygate policy must admit only relay-control to the sessions port"
        ctl_env() { yq "select(.kind == \"Deployment\" and .metadata.name == \"relay-control\") | .spec.template.spec.containers[0].env[] | select(.name == \"$1\") | .value" <<<"$2" | sed '/^---$/d;/^$/d'; }
        [ "$(ctl_env SELFHOST_RELAYGATE_PUBLIC_URL "$out")" = https://cast.gcp-proof.agentrelay.com ] && [ "$(ctl_env SELFHOST_RELAYGATE_PUBLIC_URL "$out")" = "$(ctl_env RELAYCAST_PUBLIC_URL "$out")" ] \
          || err "$chart: gate-only SELFHOST_RELAYGATE_PUBLIC_URL must be the cast host, equal to RELAYCAST_PUBLIC_URL"
        [ -z "$(ctl_env SELFHOST_RELAYGATE_PUBLIC_URL "$(render "$chart" "$v")")" ] || err "$chart: SELFHOST_RELAYGATE_PUBLIC_URL must be unset without gate-only"
        grep -A1 -F -- '- name: SESSIONS_INTERNAL_SECRET' <<<"$out" | grep -Fq 'name: agent-relay-gcp-proof, key: session-read-api-secret' || err "$chart: gate-only SESSIONS_INTERNAL_SECRET must be the reader's internal secret"
        [ "$(yq 'select(.kind == "Deployment" and .metadata.name == "ci-relaygate") | .spec.template.spec.containers[0].env[] | select(.name == "SESSIONS_CORS_ORIGINS") | .value' <<<"$out")" = "$(yq 'select(.kind == "Deployment" and .metadata.name == "agent-relay-read-api") | .spec.template.spec.containers[0].env[] | select(.name == "READ_API_CORS_ALLOWED_ORIGINS") | .value' <<<"$out")" ] \
          || err "$chart: gate-only SESSIONS_CORS_ORIGINS must equal the reader's READ_API_CORS_ALLOWED_ORIGINS"
        kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version "${KUBE_VERSION:-1.33.0}" <<<"$out" >/dev/null || err "$chart: gate-only failed kubeconform"
        # Off (the default and an explicit false) renders exactly what it did.
        [ "$(render "$chart" "$v")" = "$(render "$chart" "$v" --set global.relaygate.gateOnly.enabled=false)" ] || err "$chart: gate-only=false must render the default"
        ! yq 'select(.kind == "NetworkPolicy" or .kind == "Ingress") | .. | select(. == "relaygate" or . == "agent-relay-gcp-proof-gate")' <<<"$(render "$chart" "$v")" | grep -q . || err "$chart: the default render must not route to or admit relaygate"
        expect_render_failure "$chart" "$g" "gate-only without relaygate" "requires components.relaygate" --set components.relaygate=false
        # Control-owned policy (global.relaygate.controlPolicy): step 1 gives
        # relay-control relaygate's admin origin and the shared Secrets while
        # relaygate keeps its ConfigMap (to import); step 2 makes relaygate pull
        # the signed policy from relay-control and drops the file.
        cp=(--set global.relaygate.controlPolicy.enabled=true --set global.relaygate.controlPolicy.adminToken.name=relaygate-admin --set global.relaygate.controlPolicy.policySecret.name=relaygate-policy --set global.relaygate.controlPolicy.controlServiceName=relay-control)
        gate_env() { yq "select(.kind == \"Deployment\" and .metadata.name == \"$1\") | .spec.template.spec.containers[0].env[] | select(.name == \"$2\") | (.value // (.valueFrom.secretKeyRef.name + \"/\" + .valueFrom.secretKeyRef.key))" <<<"$3" | sed '/^---$/d;/^ *$/d'; }
        cp1=$(render "$chart" "$g" "${cp[@]}") || err "$chart: control policy step 1 did not render"
        check_control_origins "$chart (control policy)" "$cp1"
        [ "$(gate_env relay-control SELFHOST_RELAYGATE_ADMIN_URL "$cp1")" = http://ci-relaygate.ci.svc.cluster.local:8080 ] || err "$chart: SELFHOST_RELAYGATE_ADMIN_URL must be relaygate's in-cluster origin"
        [ "$(gate_env relay-control SELFHOST_RELAYGATE_ADMIN_TOKEN "$cp1")" = relaygate-admin/token ] && [ "$(gate_env ci-relaygate RELAYGATE_ADMIN_TOKEN "$cp1")" = relaygate-admin/token ] \
          || err "$chart: relay-control and relaygate must share the admin token Secret"
        [ "$(gate_env relay-control SELFHOST_RELAYGATE_POLICY_SECRET "$cp1")" = relaygate-policy/secret ] || err "$chart: SELFHOST_RELAYGATE_POLICY_SECRET must come from controlPolicy.policySecret"
        [ "$(gate_env ci-relaygate RELAYGATE_POLICY "$cp1")" = /policy/policy.json ] && yq 'select(.kind == "ConfigMap" and .metadata.name == "ci-relaygate-policy") | .metadata.name' <<<"$cp1" | grep -q . \
          || err "$chart: control policy step 1 must keep relaygate's policy file and ConfigMap (the import source)"
        [ -z "$(gate_env ci-relaygate RELAYCONTROL_POLICY_URL "$cp1")" ] || err "$chart: relaygate must not pull before controlPolicy.pull"
        cp2=$(render "$chart" "$g" "${cp[@]}" --set global.relaygate.controlPolicy.pull=true) || err "$chart: control policy step 2 did not render"
        render "$chart" "$g" "${cp[@]}" --set global.relaygate.controlPolicy.pull=true --set relaygate.policy.controlPrincipals=null >/dev/null \
          || err "$chart: a pulling relaygate must not need inline policy rules (the policy is in relay-control)"
        check_control_origins "$chart (control policy pull)" "$cp2"
        [ "$(gate_env ci-relaygate RELAYCONTROL_POLICY_URL "$cp2")" = http://relay-control.ci.svc.cluster.local:80/internal/v1/relaygate/policy ] || err "$chart: RELAYCONTROL_POLICY_URL must be relay-control's internal policy route"
        [ "$(gate_env ci-relaygate RELAYCONTROL_POLICY_SECRET "$cp2")" = "$(gate_env relay-control SELFHOST_RELAYGATE_POLICY_SECRET "$cp2")" ] || err "$chart: relaygate and relay-control must share the policy secret"
        [ -z "$(gate_env ci-relaygate RELAYGATE_POLICY "$cp2")" ] || err "$chart: a pulling relaygate must not render RELAYGATE_POLICY"
        ! yq 'select(.kind == "ConfigMap" and .metadata.name == "ci-relaygate-policy") | .metadata.name' <<<"$cp2" | grep -q . || err "$chart: a pulling relaygate must not render the policy ConfigMap"
        ! yq 'select(.kind == "Deployment" and .metadata.name == "ci-relaygate") | .spec.template.spec.volumes[] | select(.name == "policy") | .name' <<<"$cp2" | grep -q . || err "$chart: a pulling relaygate must not mount a policy volume"
        # Network paths: relaygate -> relay-control (Control admits relaygate) and
        # relay-control -> relaygate's admin API (relaygate's main port is open).
        [[ " $(out=$cp2 peers relay-control) " == *" relaygate "* ]] || err "$chart: relay-control must admit relaygate (policy pulls)"
        [ "$(yq 'select(.kind == "NetworkPolicy" and .metadata.name == "ci-relaygate") | [.spec.ingress[] | select(.ports[0].port == "http") | (.from // [] | length)] | join(",")' <<<"$cp2" | sed '/^---$/d;/^ *$/d')" = 0 ] \
          || err "$chart: relaygate's main port (the admin API) must admit relay-control"
        expect_render_failure "$chart" "$v" "control policy without gate-only" "global.relaygate.gateOnly.enabled" --set components.relaygate=true --set relaygate.image.digest=sha256:c66696c51384707c2429a45405c9b2d9c4a3bf729dc5d93b2a8bd96b760e3719 "${cp[@]}"
        expect_render_failure "$chart" "$g" "control policy without the shared Secrets" "needs controlPolicy.adminToken and controlPolicy.policySecret" "${cp[@]}" --set global.relaygate.controlPolicy.policySecret.name=
        expect_render_failure "$chart" "$g" "control policy pull without enabled" "controlPolicy.pull needs controlPolicy.enabled" --set global.relaygate.controlPolicy.pull=true
        expect_render_failure "$chart" "$g" "control policy with the wrong Control Service" "controlServiceName must be the relay-control Service relay-control" "${cp[@]}" --set global.relaygate.controlPolicy.controlServiceName=
        expect_render_failure "$chart" "$g" "control policy with the wrong Control port" "controlServicePort must equal relay-control.service.port" "${cp[@]}" --set global.relaygate.controlPolicy.controlServicePort=8080
        expect_render_failure "$chart" "$g" "control policy secret reused as the introspection secret" "must be a different secret from the introspection secret" "${cp[@]}" --set global.relaygate.controlPolicy.policySecret.name=agent-relay-gcp-proof --set global.relaygate.controlPolicy.policySecret.key=relaycontrol-introspect-secret
        expect_render_failure "$chart" "$g" "control policy with a second admin token" "RELAYGATE_ADMIN_TOKEN comes from controlPolicy.adminToken" "${cp[@]}" --set relaygate.secrets.adminToken.name=other-admin
        expect_render_failure "$chart" "$g" "gate-only with a renamed Control" "relaygate.sessionsListener.controlFrom must select relay-control's pods" --set relay-control.nameOverride=relay-cloud-api
        render "$chart" "$g" --set relay-control.nameOverride=relay-cloud-api --set-json 'relaygate.sessionsListener.controlFrom=[{"podSelector":{"matchLabels":{"app.kubernetes.io/name":"relay-cloud-api"}}}]' --set-json 'relaycast.networkPolicy.gateOnlyFrom=[{"podSelector":{"matchLabels":{"app.kubernetes.io/name":"relay-cloud-api"}}}]' >/dev/null \
          || err "$chart: gate-only with a renamed Control and matching peers must render"
        render "$chart" "$g" --set-json 'relaygate.sessionsListener.controlFrom=[{"podSelector":{"matchExpressions":[{"key":"app.kubernetes.io/name","operator":"In","values":["relay-control"]}]}}]' >/dev/null \
          || err "$chart: gate-only peers selecting Control by matchExpressions must render"
        expect_render_failure "$chart" "$g" "gate-only without the sessions port" "needs global.relaygate.gateOnly.sessionsPort" --set global.relaygate.gateOnly.sessionsPort=0
        expect_render_failure "$chart" "$g" "gate-only sessions port on the main port" "needs global.relaygate.gateOnly.sessionsPort" --set global.relaygate.gateOnly.sessionsPort=8080
        expect_render_failure "$chart" "$g" "gate-only with relaycastPublicUrl off the cast host" "requires relay-control.services.relaycastPublicUrl=https://cast.gcp-proof.agentrelay.com" --set relay-control.services.relaycastPublicUrl=https://relay.gcp-proof.agentrelay.com
        expect_render_failure "$chart" "$g" "gate-only Relaycast upstream on the public host" "relaygate.proxy.relaycastUrl to be the relaycast Service" --set relaygate.proxy.relaycastUrl=https://cast.gcp-proof.agentrelay.com --set relaygate.secrets.relaycastWorkspaceKey.name=k --set relaygate.secrets.relaygateSecret.name=s
        expect_render_failure "$chart" "$g" "gate-only reader upstream not the reader Service" "relaygate.proxy.sessionsReadUrl to be the Sessions reader Service" --set relaygate.proxy.sessionsReadUrl=http://other-read
        expect_render_failure "$chart" "$g" "gate-only upload upstream not the ingest Service" "relaygate.proxy.sessionsUploadUrl to be the ingest edge Service" --set relaygate.proxy.sessionsUploadUrl=http://agent-relay-read-api
        expect_render_failure "$chart" "$g" "gate-only reader upstream on the history host" "requests would loop back to relaygate" --set relaygate.proxy.sessionsReadUrl=https://history.gcp-proof.agentrelay.com
        expect_render_failure "$chart" "$g" "gate-only without the history host in sessionsHosts" "sessionsHosts must include history.gcp-proof.agentrelay.com" --set 'relaygate.proxy.sessionsHosts={other.example.com}'
        expect_render_failure "$chart" "$g" "gate-only without sessionsHosts" "global.relaygate.gateOnly.enabled needs proxy.relaycastUrl" --set relaygate.proxy.sessionsHosts=null
        expect_render_failure "$chart" "$g" "gate-only without the Relaycast proxy" "global.relaygate.gateOnly.enabled needs proxy.relaycastUrl" --set relaygate.proxy.relaycastUrl=
        expect_render_failure "$chart" "$g" "gate-only introspecting elsewhere" "relaygate.control.introspectUrl=http://relay-control.ci.svc.cluster.local/internal/v1/auth/introspect" --set relaygate.control.introspectUrl=http://other.ci.svc.cluster.local/internal/v1/auth/introspect
        expect_render_failure "$chart" "$g" "gate-only CORS drift" "relaygate.proxy.sessionsCorsOrigins must equal" --set 'relaygate.proxy.sessionsCorsOrigins={https://other.agentrelay.com}'
        expect_render_failure "$chart" "$g" "gate-only without CORS origins" "relaygate.proxy.sessionsCorsOrigins must equal" --set relaygate.proxy.sessionsCorsOrigins=null
        expect_render_failure "$chart" "$g" "gate-only another reader internal secret" "relaygate.secrets.sessionsInternalSecret must be the read API's internal secret" --set relaygate.secrets.sessionsInternalSecret.key=other
        expect_render_failure "$chart" "$g" "gate-only without controlPrincipals rules" "requires relaygate.policy.controlPrincipals" --set relaygate.policy.controlPrincipals=null
        expect_render_failure "$chart" "$g" "gate-only wrong ingest audience" "control.sessionIngestAudience must be the ingest origin" --set relaygate.control.sessionIngestAudience=https://other.agentrelay.com
        expect_render_failure "$chart" "$g" "gate-only another introspection Secret" "must be the ingest edge's Control introspection secret" --set relaygate.secrets.relaycontrolIntrospectSecret.name=other
        expect_render_failure "$chart" "$g" "gate-only audience Control does not accept" "introspection.audiences must include" --set 'relay-control.introspection.audiences={https://api.gcp-proof.agentrelay.com}'
        expect_render_failure "$chart" "$g" "gate-only without a Relaycast policy" "relaycast: global.relaygate.gateOnly.enabled requires networkPolicy.enabled=true" --set relaycast.networkPolicy.enabled=false
        expect_render_failure "$chart" "$g" "gate-only without a reader policy" "session-read-api: global.relaygate.gateOnly.enabled requires networkPolicy.enabled=true" --set sessions-pipeline.sessionReadApi.networkPolicy.enabled=false
        expect_render_failure "$chart" "$g" "gate-only without an ingest policy" "requires ingestEdge.networkPolicy.enabled=true" --set sessions-pipeline.ingestEdge.networkPolicy.enabled=false
        expect_render_failure "$chart" "$g" "gate-only with a renamed relaygate" "global.relaygate.gateOnly.serviceName" --set relaygate.fullnameOverride=gate
        # Built-in relaygate, sessions-only (global.relaygate.gateOnly.scope=sessions),
        # on each edge: GKE (gkeIngress), EKS (eksIngress ALB) and AKS
        # (traefikIngress). The history host reaches relaygate on exactly its
        # routes; the cast host, Relaycast's policy and Control's discovery stay
        # as without the gate; the reader and ingest edge admit only relaygate.
        hist_want=""; for p in /v1/events /v1/ingest /v1/auth/token/refresh /v1/auth/token/revoke /v1/onboarding/heartbeat /v1/upload-consent; do hist_want+="$p Exact ci-relaygate;"; done
        for p in /v1/sessions /v1/delivery /v1/digest; do hist_want+="$p Prefix ci-relaygate;"; done
        base=$(render "$chart" "$v")
        for edge in gke eks aks; do
          sv=charts/agent-relay/ci/gate-sessions-$edge-values.yaml
          out=$(render "$chart" "$sv") || { err "$chart: sessions-only ($edge) did not render"; continue; }
          kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version "${KUBE_VERSION:-1.33.0}" <<<"$out" >/dev/null || err "$chart: sessions-only ($edge) failed kubeconform"
          hist=$(routes history.gcp-proof.agentrelay.com)
          case $edge in
            gke) want=""; for p in /v1/sessions /v1/delivery /v1/digest; do want+="$p Prefix $gate;"; done
                 for p in /v1/events /v1/ingest /v1/auth/token/refresh /v1/auth/token/revoke /v1/onboarding/heartbeat /v1/upload-consent; do want+="$p Exact $gate;"; done
                 want+="/ Prefix $deny;" ;;
            eks) want="$hist_want/internal Prefix edge-deny;//internal* ImplementationSpecific edge-deny;/admin Prefix edge-deny;//admin* ImplementationSpecific edge-deny;/* ImplementationSpecific edge-deny;" ;;
            aks) want="$hist_want/internal Prefix edge-deny;/admin Prefix edge-deny;/ Prefix edge-deny;" ;;
          esac
          [ "$hist" = "$want" ] || err "$chart: sessions-only ($edge) history routes: $hist"
          [[ "$(routes cast.gcp-proof.agentrelay.com)" == *" relaycast;" ]] || err "$chart: sessions-only ($edge) cast host must stay on Relaycast: $(routes cast.gcp-proof.agentrelay.com)"
          ! grep -q relaygate <<<"$(routes cast.gcp-proof.agentrelay.com)" || err "$chart: sessions-only ($edge) cast host must not reach relaygate"
          # No edge route sends /internal or /admin anywhere but a deny backend.
          bad=$(yq 'select(.kind == "Ingress") | .spec.rules[] | .host as $h | .http.paths[] | select(.path | test("^/+(internal|admin)")) | select(.backend.service.name | test("deny") | not) | $h + .path' <<<"$out" | sed '/^---$/d;/^$/d')
          [ -z "$bad" ] || err "$chart: sessions-only ($edge) routes /internal or /admin to a backend: $bad"
          [ "$(peers agent-relay-ingest-edge)" = relaygate ] || err "$chart: sessions-only ($edge) ingest peers: $(peers agent-relay-ingest-edge)"
          [ "$(yq 'select(.kind == "NetworkPolicy" and .metadata.name == "relaycast") | .spec' <<<"$out")" = "$(yq 'select(.kind == "NetworkPolicy" and .metadata.name == "relaycast") | .spec' <<<"$base")" ] \
            || err "$chart: sessions-only ($edge) must leave Relaycast's NetworkPolicy as without the gate"
          [ -z "$(ctl_env SELFHOST_RELAYGATE_PUBLIC_URL "$out")" ] || err "$chart: sessions-only ($edge) must not set SELFHOST_RELAYGATE_PUBLIC_URL (Relaycast stays direct)"
          [ "$(ctl_env SESSION_READ_API_URL "$out")" = http://ci-relaygate-sessions.ci.svc.cluster.local:8081 ] || err "$chart: sessions-only ($edge) SESSION_READ_API_URL must be relaygate's internal Sessions listener"
          [ -z "$(gate_env ci-relaygate RELAYCAST_URL "$out")" ] || err "$chart: sessions-only ($edge) relaygate must not proxy Relaycast"
          check_control_origins "$chart (sessions-only $edge)" "$out"
        done
        # The platform example overlays (values-gcp-relaygate.yaml,
        # values-eks-relaygate.yaml) render, route the history host to
        # relaygate, and deploy the relaygate chart's pinned digest, which must
        # match its self-hosted/customer-images.yaml entry.
        rg_digest=sha256:0ca54cddf43b4771fade43d06d280405574ea77280eb0fde392fdb90ee29e248
        [ "$(yq '.images[] | select(.id == "relaygate") | .current.digest' self-hosted/customer-images.yaml)" = "$(yq '.image.digest' charts/relaygate/values.yaml)" ] \
          || err "$chart: charts/relaygate image.digest must match its self-hosted/customer-images.yaml entry"
        gcp_stack=(-f charts/agent-relay/values-gcp.yaml -f charts/agent-relay/values-gcp-native.yaml -f charts/agent-relay/ci/gcp-native-values.yaml -f charts/agent-relay/values-gcp-relaygate.yaml)
        eks_stack=(-f charts/agent-relay/values-eks.yaml -f charts/agent-relay/values-eks-rds-native.yaml -f charts/agent-relay/values-eks-relaygate.yaml --set eksIngress.domain=placeholder.company --set eksIngress.certificateArn=arn:aws:acm:us-east-1:111111111111:certificate/00000000-0000-0000-0000-000000000000)
        for stack in gcp eks; do
          declare -n st="${stack}_stack"
          ex=$(helm template agent-relay charts/agent-relay -n agent-relay --no-hooks "${st[@]}" --set relaygate.image.digest=$rg_digest) || { err "$chart: the $stack relaygate example did not render"; unset -n st; continue; }
          [ "$(yq 'select(.kind == "Ingress") | .spec.rules[] | select(.host == "history.placeholder.company") | .http.paths[] | select(.path == "/v1/sessions") | .backend.service.name' <<<"$ex" | sed '/^---$/d;/^$/d')" = "$([ $stack = gcp ] && echo example-agent-relay-gate || echo agent-relay-relaygate)" ] \
            || err "$chart: the $stack relaygate example must route the history host to relaygate"
          # No digest in the example: the relaygate chart's pinned image (self-hosted/customer-images.yaml).
          [ "$(yq 'select(.kind == "Deployment" and .metadata.name == "agent-relay-relaygate") | .spec.template.spec.containers[0].image' <<<"$(helm template agent-relay charts/agent-relay -n agent-relay --no-hooks "${st[@]}")")" = "ghcr.io/agentworkforce/relaygate@$(yq '.image.digest' charts/relaygate/values.yaml)" ] \
            || err "$chart: the $stack relaygate example must deploy the relaygate chart's pinned digest"
          unset -n st
        done
        # global.relaygate.gateOnly.relayfactsRoutes (off by default) adds
        # /v1/relayfacts and /v1/coordination (Prefix) to relaygate on every edge.
        for edge in gke eks aks; do
          out=$(render "$chart" charts/agent-relay/ci/gate-sessions-$edge-values.yaml --set global.relaygate.gateOnly.relayfactsRoutes=true) || { err "$chart: relayfactsRoutes ($edge) did not render"; continue; }
          for p in /v1/relayfacts /v1/coordination; do
            grep -Eq "(^|;)$p Prefix [^;]*(-gate|relaygate);" <<<"$(routes history.gcp-proof.agentrelay.com)" || err "$chart: relayfactsRoutes ($edge) must route $p to relaygate"
          done
          out=$(render "$chart" charts/agent-relay/ci/gate-sessions-$edge-values.yaml)
          ! grep -Eq '/v1/(relayfacts|coordination) ' <<<"$(routes history.gcp-proof.agentrelay.com)" || err "$chart: without relayfactsRoutes ($edge) the history host must not route /v1/relayfacts or /v1/coordination"
        done
        # The same edges with the gate off route no path to relaygate.
        for f in eks-ingress traefik-ingress; do
          ! yq 'select(.kind == "Ingress") | .. | select(. == "ci-relaygate")' <<<"$(render "$chart" "charts/agent-relay/ci/$f-values.yaml")" | grep -q . || err "$chart: $f without the gate must not route to relaygate"
        done
        s=charts/agent-relay/ci/gate-sessions-eks-values.yaml
        expect_render_failure "$chart" "$s" "gate scope not all or sessions" "global.relaygate.gateOnly.scope must be all" --set global.relaygate.gateOnly.scope=cast
        expect_render_failure "$chart" "$s" "sessions-only without relaygate" "requires components.relaygate" --set components.relaygate=false
        expect_render_failure "$chart" "$s" "sessions-only without a relaygate image" "relaygate: image.digest is required" --set relaygate.image.digest=
        expect_render_failure "$chart" "$s" "sessions-only on a read-only EKS history host" "eksIngress.history.readOnly=true cannot be combined with global.relaygate.gateOnly.enabled" --set eksIngress.history.readOnly=true --set eksIngress.ingest.enabled=false
        expect_render_failure "$chart" "$s" "sessions-only without the EKS history host in sessionsHosts" "sessionsHosts must include history.relay.example.com" --set eksIngress.domain=relay.example.com
        expect_render_failure "$chart" "$s" "sessions-only without sessionsHosts" "global.relaygate.gateOnly.enabled needs proxy.sessionsUrl" --set relaygate.proxy.sessionsHosts=null
        expect_render_failure "$chart" "$s" "sessions-only without controlPrincipals" "requires relaygate.policy.controlPrincipals" --set relaygate.policy.controlPrincipals=null
        expect_render_failure "$chart" "$s" "sessions-only Relaycast upstream on the public host" "relaygate.proxy.relaycastUrl to be the relaycast Service" --set relaygate.proxy.relaycastUrl=https://cast.gcp-proof.agentrelay.com --set relaygate.secrets.relaycastWorkspaceKey.name=k --set relaygate.secrets.relaygateSecret.name=s
        expect_render_failure "$chart" charts/agent-relay/ci/gate-sessions-aks-values.yaml "sessions-only without the Traefik history host in sessionsHosts" "sessionsHosts must include history.other.example.com" --set traefikIngress.hosts.history=history.other.example.com
        expect_render_failure "$chart" charts/agent-relay/ci/gate-sessions-aks-values.yaml "scope all on Traefik with relaycastPublicUrl off the cast host" "the traefikIngress cast host is relaygate's public origin" --set global.relaygate.gateOnly.scope=all --set relaygate.proxy.relaycastUrl=http://relaycast:8787 --set relaygate.secrets.relaycastWorkspaceKey.name=k --set relaygate.secrets.relaygateSecret.name=s --set relay-control.services.relaycastPublicUrl=https://relay.gcp-proof.agentrelay.com
        expect_render_failure "$chart" charts/agent-relay/ci/gate-sessions-eks-values.yaml "scope all on EKS with relaycastPublicUrl off the cast host" "the eksIngress cast host is relaygate's public origin" --set global.relaygate.gateOnly.scope=all --set relaygate.proxy.relaycastUrl=http://relaycast:8787 --set relaygate.secrets.relaycastWorkspaceKey.name=k --set relaygate.secrets.relaygateSecret.name=s --set relay-control.services.relaycastPublicUrl=https://relay.gcp-proof.agentrelay.com
        expect_render_failure "$chart" "$v" "ar_ authority without relayauth" "relaycast.credentials.authority=relayauth requires components.relayauth=true" --set components.relayauth=false --set relaycast.credentials.format=ar --set relaycast.credentials.authority=relayauth --set relaycast.credentials.relayauth.url=http://relayauth:8787 --set relaycast.secretKeys.relayauthToken=relaycast-relayauth-token
        ;;
    esac
  fi
done
exit $fail
