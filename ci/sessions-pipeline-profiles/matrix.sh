#!/usr/bin/env bash
# Bootstrap/render matrix for charts/sessions-pipeline. It covers every shipped profile
# (charts/sessions-pipeline/profiles/*.yaml) and every CI values file
# (charts/sessions-pipeline/ci/*-values.yaml), including the AWS and GCP stack shapes.
# Each is rendered the way Alchemy installs (helm template --no-hooks) and
# checked against the sessions-pipeline #99 migration contract. The checks cover:
# - the app workloads and the migrate Job;
# - the migrator profile env, exactly once and in migrate only;
# - HoopDb and Locker;
# - the role/boundary bootstrap path. A fresh in-cluster cluster gets initdb
#   plus the runtime-role and function-default Jobs. An existing cluster also
#   gets the search Worker Job. An external selfhosted database gets
#   wait-for-role only. Supabase gets nothing in-cluster.
# A profile without a row fails the matrix. So do the mode combinations the
# migrator or the chart must refuse.
#
#   ci/sessions-pipeline-profiles/matrix.sh static   offline: lint + render assertions
#   ci/sessions-pipeline-profiles/matrix.sh dryrun   also server-side dry-run apply (needs
#                                          a cluster with the CNPG CRDs and ns ci)
# Run `helm dependency build charts/sessions-pipeline` first.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CHART="$ROOT/charts/sessions-pipeline"
mode=${1:-static}
case $mode in static|dryrun) ;; *) echo "usage: $0 static|dryrun" >&2; exit 2 ;; esac
fail=0
err() { echo "::error::$*"; fail=1; }
render() { helm template ci "$CHART" --namespace ci --no-hooks "$@"; }

node --test "$ROOT/ci/sessions-pipeline-profiles/search-indexer-bootstrap-guard.test.mjs"

# The inputs a shipped profile leaves to the operator (CI values files carry
# their own).
REQUIRED=(--set global.tenant.orgId=org_ci --set alleyoop.auth.jwksUrl=https://relayauth.example.com/.well-known/jwks.json)
RUNTIME=(--set worker.migrations.runtimeRole=sessions_pipeline_runtime --set worker.migrations.runtimeRoleLogin=true)

# file (relative to charts/sessions-pipeline) | HoopDb Cluster | Locker | databaseMode | shape
#   fresh     in-cluster, new cluster: initdb creates the search Worker role; the
#             runtime-role and function-default Jobs; wait for roles + function default
#   existing  in-cluster, existing cluster: fresh plus the search Worker Job
#   external  external plain Postgres: no SQL Jobs; wait for the roles only
#   supabase  external Supabase: no SQL Jobs, no wait-for-role, no shim
#   rds       external Amazon RDS: no SQL Jobs, no wait-for-role, no shim
#   rds-native RDS plus the customer-native read, ingest, and OpenSearch slots;
#              release inputs come from the synthetic render-only overlay
MATRIX=(
  "profiles/aws-rds-native.yaml|no|no|rds|rds-native"
  "profiles/selfhost-postgres.yaml|yes|yes|selfhosted|fresh"
  "profiles/migration.yaml|yes|yes|selfhosted|existing"
  "profiles/external-supabase.yaml|no|yes|supabase|supabase"
  "profiles/external-selfhosted.yaml|no|yes|selfhosted|external"
  "profiles/external-rds.yaml|no|yes|rds|rds"
  "ci/default-values.yaml|yes|yes|selfhosted|fresh"
  "ci/read-api-values.yaml|yes|yes|selfhosted|fresh"
  "ci/ingest-edge-values.yaml|yes|yes|selfhosted|fresh"
  "ci/native-consumer-values.yaml|no|yes|selfhosted|native"
  "ci/search-indexer-values.yaml|yes|yes|selfhosted|fresh"
  "ci/kind-values.yaml|yes|yes|selfhosted|fresh"
  "ci/search-worker-bootstrap-values.yaml|yes|yes|selfhosted|existing"
  "ci/aws-cnpg-values.yaml|yes|no|selfhosted|fresh"
  "ci/pod-identity-values.yaml|no|no|supabase|supabase"
  "ci/ingest-edge-pod-identity-values.yaml|no|no|supabase|supabase"
  "ci/gcp-cloudsql-values.yaml|no|no|cloudsql|external"
)

# Every profile on disk has a row (a new profile cannot skip the matrix).
for f in "$CHART"/profiles/*.yaml "$CHART"/ci/*-values.yaml; do
  rel=${f#"$CHART"/}
  printf '%s\n' "${MATRIX[@]}" | cut -d'|' -f1 | grep -qxF "$rel" || err "$rel: no row in the profile matrix"
done

# Services image pins. The in-cluster CNPG profiles and the AWS proof values
# pin the image built from sessions-pipeline main 7d7229b (#124 + #125 + #139 + #137,
# generation eff8b3be...259b): GHCR
# (publish-image run 41375745173) and ECR (publish-image-ecr run 41375747474). The workloads and
# the privileged SQL Jobs use the same image, and no Job overrides it. The
# Every other profile (external-selfhosted, and the external-Supabase one, which
# stays held) and the GCP values pin the GHCR image too. The chart
# defaults (worker and alleyoop image.digest) are the same GHCR image, so a path
# that pins nothing still gets it. The row loop below asserts that every
# matrix row's 96bulls-services containers use those final images. The native
# ingest-edge and read-api render fixtures carry separate synthetic image refs;
# they do not qualify a native artifact or assert its provenance/final pin.
GHCR="ghcr.io/agentworkforce/96bulls-services@sha256:6f22ea17dff336e1431664542759fd27958649388b90a0b2f0881883caa7c6b2"
ECR="500268966557.dkr.ecr.us-west-2.amazonaws.com/96bulls-services@sha256:5bb6075240afa02a1b1797a81c07bffa029954eac7803d702ecba20db35d4db9"
RDS_GHCR="ghcr.io/agentworkforce/96bulls-services@sha256:b2b74a19375e86bbd5c70a30ea5edbd28cac3de103490bc428de007f4a38b821"
RDS_NATIVE_CI="ghcr.io/agentworkforce/96bulls-services@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
pins_of() { yq -r '[.worker.image.tag, .worker.image.digest, .alleyoop.image.tag, .alleyoop.image.digest, .privilegedSql.sqlImage.digest, .searchWorkerRole.bootstrapJob.sqlImage.digest, .runtimeRole.bootstrapJob.sqlImage.digest, .functionDefaultRevoke.bootstrapJob.sqlImage.digest] | map(select(. != null and . != "")) | join(",")' "$1"; }
# Rendered image refs of every services container (workloads, migrate, the SQL Jobs' sql copy).
services_refs() {
  render "$@" | yq -r 'select(.kind == "Deployment" or .kind == "Job") | .spec.template.spec | ((.initContainers // []) + .containers)[] | select(.image | test("96bulls-services")) | .image' | grep -v '^---$' | sort -u
}
# The chart defaults are the final GHCR image.
for v in "$ROOT/charts/sessions-pipeline-worker/values.yaml" "$ROOT/charts/session-ingest-api/values.yaml"; do
  [ "$(yq -r '.image.digest' "$v")" = "${GHCR#*@}" ] || err "${v#"$ROOT"/}: image.digest is not the final 7d7229b GHCR digest"
done
for pair in "profiles/selfhost-postgres.yaml|$GHCR" "profiles/migration.yaml|$GHCR" "profiles/external-supabase.yaml|$GHCR" "profiles/external-selfhosted.yaml|$GHCR" "profiles/external-rds.yaml|$RDS_GHCR" "profiles/aws-rds-native.yaml|$RDS_NATIVE_CI" "ci/gcp-cloudsql-values.yaml|$GHCR" "ci/aws-cnpg-values.yaml|$ECR"; do
  rel=${pair%%|*} want=${pair#*|}
  extra=(); [[ $rel == profiles/* ]] && extra=("${REQUIRED[@]}")
  [[ $rel == profiles/external-supabase.yaml ]] && extra+=(--set supabaseActivation.hold=false)
  [[ $rel == profiles/external-selfhosted.yaml ]] && extra+=("${RUNTIME[@]}")
  [[ $rel == profiles/external-rds.yaml ]] && extra+=("${RUNTIME[@]}")
  [[ $rel == profiles/aws-rds-native.yaml ]] && extra+=(-f "$CHART/ci/aws-rds-native-inputs.yaml")
  got=$(services_refs -f "$CHART/$rel" "${extra[@]}" | tr '\n' ' ' | sed 's/ $//')
  [ "$got" = "$want" ] || err "$rel: services images are [$got], want exactly [$want]"
done

ROLE_SQL="CREATE ROLE session_directory_search_worker NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION"
PROFILE_ENV="HOOPDB_DB_MODE HOOPDB_SUPABASE_SHIM HOOPDB_ROLE_BOOTSTRAP HOOPDB_RUNTIME_ROLE HOOPDB_RUNTIME_ROLE_LOGIN HOOPDB_RUNTIME_WORKLOAD_ROLE HOOPDB_FUNCTION_BOUNDARY_MODE"
count() { yq "select($1)" <<<"$out" | yq -N 'select(. != null) | .kind' | grep -c . || true; }
has() { [ "$(count "$1")" -ge 1 ]; }
none() { [ "$(count "$1")" -eq 0 ]; }
comp() { echo ".metadata.labels.\"app.kubernetes.io/component\" == \"$1\""; }
# name=value pairs of the migrate container's profile env, sorted.
profile_env() {
  yq -r 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate") | .spec.template.spec.containers[0].env[] | select(.value != null) | .name + "=" + .value' <<<"$out" \
    | grep -E "^($(tr ' ' '|' <<<"$PROFILE_ENV"))=" | sort
}

expect_fail() { # message helm-args...
  local msg=$1 o; shift
  if o=$(render "$@" 2>&1); then err "rendered despite: $msg"
  elif ! grep -qF "$msg" <<<"$o"; then err "wrong error for \"$msg\": $(grep -m1 Error <<<"$o")"; fi
}

for row in "${MATRIX[@]}"; do
  IFS='|' read -r rel cluster locker dbmode shape <<<"$row"
  f="$CHART/$rel"; label="sessions-pipeline ($rel)"
  [ -f "$f" ] || { err "$label: profile file missing"; continue; }
  args=(-f "$f")
  if [[ $rel == profiles/* ]]; then
    args+=("${REQUIRED[@]}")
    # Operator inputs the profile leaves empty must fail the render; then supply them.
    case $shape in
      external|rds)
        expect_fail "migrations.runtimeRole is required" "${args[@]}"
        expect_fail "migrations.runtimeRoleLogin must be set (true or false) in $dbmode mode" "${args[@]}" --set worker.migrations.runtimeRole=sessions_pipeline_runtime
        args+=("${RUNTIME[@]}") ;;
      rds-native)
        # A required services digest may be rejected by a component subchart
        # before the umbrella release contract runs; either way the native
        # profile remains fail-closed until the release overlay is supplied.
        expect_fail "image.digest requires an owner-approved compatible image" "${args[@]}"
        args+=(-f "$CHART/ci/aws-rds-native-inputs.yaml") ;;
      supabase)
        # Fail-closed: the profile itself does not render.
        expect_fail "supabaseActivation.hold: the external-Supabase profile is fail-closed" "${args[@]}"
        args+=(--set supabaseActivation.hold=false) ;;
    esac
  fi
  echo "--- $mode: $label"
  helm lint --strict "$CHART" "${args[@]}" >/dev/null || { helm lint --strict "$CHART" "${args[@]}"; err "$label: helm lint --strict failed"; continue; }
  out=$(render "${args[@]}") || { err "$label: render failed"; continue; }

  # Every services image this row renders is a final 7d7229b image: GHCR, or
  # ECR on the AWS path only. Any other digest or tag (e.g. the old db2663d
  # default) fails.
  imgs=$(yq -r 'select(.kind == "Deployment" or .kind == "Job") | .spec.template.spec | ((.initContainers // []) + .containers)[] | select(.image | test("96bulls-services")) | .image' <<<"$out" | grep -v '^---$' | sort -u)
  [ -n "$imgs" ] || err "$label: no services image rendered"
  while read -r img; do
    [ -z "$img" ] && continue
    case $img in
      "$GHCR") ;;
      "$ECR") [ "$rel" = ci/aws-cnpg-values.yaml ] || err "$label: ECR image outside the AWS path: $img" ;;
      "$RDS_GHCR") [ "$rel" = profiles/external-rds.yaml ] || err "$label: RDS-mode image outside the RDS profile: $img" ;;
      "$RDS_NATIVE_CI") [ "$rel" = profiles/aws-rds-native.yaml ] || err "$label: synthetic native RDS image outside its profile: $img" ;;
      *) err "$label: non-final services image: $img" ;;
    esac
  done <<<"$imgs"

  # App workloads and the migrate Job, in every profile.
  deployments="ci-worker-session-status-worker ci-worker-session-summary-worker ci-session-ingest-api"
  if [ "$shape" = rds-native ]; then
    deployments="ci-worker-session-status-worker ci-worker-session-summary-worker ci-worker-session-metadata-indexer ci-read-api ci-ingest-edge ci-search-indexer"
  elif [ "$rel" = ci/native-consumer-values.yaml ]; then
    deployments="$deployments ci-native-consumer"
    none '.kind == "Deployment" and .metadata.name == "ci-worker-session-metadata-indexer"' || err "$label: old indexer overlaps native consumer"
  else
    deployments="$deployments ci-worker-session-metadata-indexer"
  fi
  for d in $deployments; do
    has ".kind == \"Deployment\" and .metadata.name == \"$d\"" || err "$label: Deployment $d missing"
  done
  none '.metadata.annotations."helm.sh/hook"' || err "$label: a Helm hook rendered"
  mig=$(yq "select(.kind == \"Job\" and $(comp hoopdb-migrate))" <<<"$out")
  if [ "$shape" = native ]; then
    none ".kind == \"Job\" and $(comp hoopdb-migrate)" || err "$label: legacy migration Job must be disabled for native driver ordering"
    for d in ci-worker-session-status-worker ci-worker-session-summary-worker ci-session-ingest-api; do
      [ "$(yq -r "select(.kind == \"Deployment\" and .metadata.name == \"$d\") | .spec.replicas" <<<"$out")" = 0 ] || err "$label: legacy runtime $d must be stopped in the native fixture"
    done
  else
    has ".kind == \"Job\" and $(comp hoopdb-migrate)" || err "$label: migrate Job missing"
    [ "$(yq -r '.spec.template.spec.containers[0].env[] | select(.name == "HOOPDB_ROLE_VERIFY") | .value' <<<"$mig")" = true ] || err "$label: migrate does not run the phase 2 role verify"
  fi

  # The migrator profile (#99): exactly this env in migrate, nowhere else.
  case $dbmode in
    selfhosted) want=$'HOOPDB_DB_MODE=selfhosted\nHOOPDB_FUNCTION_BOUNDARY_MODE=global-default-revoke\nHOOPDB_RUNTIME_ROLE=sessions_pipeline_runtime\nHOOPDB_RUNTIME_ROLE_LOGIN=true\nHOOPDB_SUPABASE_SHIM=true' ;;
    cloudsql)   want=$'HOOPDB_DB_MODE=cloudsql\nHOOPDB_FUNCTION_BOUNDARY_MODE=global-default-revoke\nHOOPDB_ROLE_BOOTSTRAP=false\nHOOPDB_RUNTIME_ROLE=sessions_pipeline_runtime\nHOOPDB_RUNTIME_ROLE_LOGIN=true\nHOOPDB_SUPABASE_SHIM=false' ;;
    rds)        want=$'HOOPDB_DB_MODE=rds\nHOOPDB_FUNCTION_BOUNDARY_MODE=global-default-revoke\nHOOPDB_RUNTIME_ROLE=sessions_pipeline_runtime\nHOOPDB_RUNTIME_ROLE_LOGIN=true\nHOOPDB_SUPABASE_SHIM=false' ;;
    supabase)   want=$'HOOPDB_DB_MODE=supabase\nHOOPDB_RUNTIME_ROLE=sessions_pipeline_runtime\nHOOPDB_RUNTIME_ROLE_LOGIN=true\nHOOPDB_SUPABASE_SHIM=false' ;;
  esac
  # The external-Supabase profile selects the event-trigger boundary (#125).
  [ "$rel" = profiles/external-supabase.yaml ] && want=$(printf '%s\nHOOPDB_FUNCTION_BOUNDARY_MODE=event-trigger\n' "$want" | sort)
  if [ "$shape" = native ]; then want=""; got=""; else got=$(profile_env); fi
  [ "$got" = "$want" ] || err "$label: migrate profile env is [$(tr '\n' ' ' <<<"$got")], want [$(tr '\n' ' ' <<<"$want")]"
  for n in $PROFILE_ENV HOOPDB_FUNCTION_BOUNDARY_APPROVED; do
    c=$(yq -r "select(.metadata.labels.\"app.kubernetes.io/name\" != \"session-pipeline-consumer\") | [.. | select(type == \"!!map\" and .name == \"$n\" and has(\"value\"))] | length" <<<"$out" | awk '{s+=$1} END {print s+0}')
    case $n in HOOPDB_FUNCTION_BOUNDARY_APPROVED) w=0 ;; *) w=$(grep -c "^$n=" <<<"$want" || true) ;; esac
    [ "$c" = "$w" ] || err "$label: $n rendered $c times, want $w (migrate only)"
  done

  # HoopDb.
  if [ "$cluster" = yes ]; then
    has '.kind == "Cluster" and .metadata.name == "hoopdb"' || err "$label: HoopDb Cluster missing"
    [ "$(yq -r 'select(.kind == "Cluster") | .spec.enableSuperuserAccess' <<<"$out")" = false ] || err "$label: enableSuperuserAccess is not false"
  else
    none '.kind == "Cluster"' || err "$label: a HoopDb Cluster rendered for an external database"
  fi

  # Locker.
  if [ "$locker" = yes ]; then
    has '.kind == "Deployment" and .metadata.name == "session-object-storage"' || err "$label: Locker Deployment missing"
    has ".kind == \"Job\" and $(comp locker-init)" || err "$label: locker-init Job missing"
  else
    none '.kind == "Deployment" and .metadata.name == "session-object-storage"' || err "$label: Locker rendered with locker disabled"
  fi

  # The bootstrap path: which privileged Jobs, and what migrate waits for.
  case $shape in
    fresh)    jobs="hoopdb-runtime-role-bootstrap hoopdb-function-default-revoke"; roles="session_directory_search_worker sessions_pipeline_runtime"; fd=true ;;
    existing) jobs="search-worker-role-bootstrap hoopdb-runtime-role-bootstrap hoopdb-function-default-revoke"; roles="session_directory_search_worker sessions_pipeline_runtime"; fd=true ;;
    external) jobs=""; roles="session_directory_search_worker sessions_pipeline_runtime"; fd=false ;;
    supabase) jobs=""; roles=""; fd="" ;;
    rds|rds-native) jobs=""; roles=""; fd="" ;;
    native)   jobs=""; roles=""; fd="" ;;
  esac
  for c in search-worker-role-bootstrap hoopdb-runtime-role-bootstrap hoopdb-function-default-revoke; do
    if [[ " $jobs " == *" $c "* ]]; then
      for k in Job ServiceAccount Role RoleBinding; do
        [ "$(count ".kind == \"$k\" and $(comp "$c")")" = 1 ] || err "$label: exactly one $c $k expected"
      done
      [ "$(yq -o=json -I=0 "select(.kind == \"Role\" and $(comp "$c")) | .rules" <<<"$out")" = '[{"apiGroups":[""],"resources":["pods"],"verbs":["get","list"]},{"apiGroups":[""],"resources":["pods/exec"],"verbs":["create"]}]' ] || err "$label: $c Role is not pods get/list + pods/exec create"
    else
      none "$(comp "$c")" || err "$label: $c objects rendered ($shape shape)"
    fi
  done
  none '.kind == "ClusterRole" or .kind == "ClusterRoleBinding"' || err "$label: cluster-scoped RBAC rendered"
  args0() { yq -r "select(.kind == \"Job\" and $(comp "$1")) | .spec.template.spec.containers[0].args[0]" <<<"$out"; }
  if [[ " $jobs " == *" hoopdb-function-default-revoke "* ]]; then
    args0 hoopdb-function-default-revoke | grep -qF "psql -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -v 'migration_owner=hoop' -X" || err "$label: function-default Job does not pass -v migration_owner=hoop"
    [ "$(yq -r "select(.kind == \"Job\" and $(comp hoopdb-function-default-revoke)) | .spec.template.spec.initContainers[0].command | join(\" \")" <<<"$out")" = "cp /app/supabase/bootstrap/hoopdb_function_default_revoke.sql /work/bootstrap.sql" ] || err "$label: function-default Job copies the wrong file"
  fi
  if [[ " $jobs " == *" hoopdb-runtime-role-bootstrap "* ]]; then
    args0 hoopdb-runtime-role-bootstrap | grep -qF -- "-v 'runtime_role=sessions_pipeline_runtime' -v 'runtime_login=true' -X" || err "$label: runtime-role Job does not pass runtime_role/runtime_login"
  fi
  if [ "$shape" = fresh ] || [ "$shape" = existing ]; then
    sql=$(yq -r 'select(.kind == "Cluster") | .spec.bootstrap.initdb.postInitApplicationSQL[]' <<<"$out")
    grep -qxF "$ROLE_SQL" <<<"$sql" || err "$label: initdb SQL does not create the search Worker role"
  fi
  w0=$(yq -r '.spec.template.spec.initContainers[0].name // ""' <<<"$mig")
  if [ -z "$roles" ]; then
    [ "$w0" != wait-for-role ] || err "$label: migrate waits for roles in $shape shape"
  else
    [ "$w0" = wait-for-role ] || err "$label: migrate does not wait for the roles"
    [ "$(yq -r '.spec.template.spec.initContainers[0].env[] | select(.name == "ROLES") | .value' <<<"$mig")" = "$roles" ] || err "$label: wait-for-role waits for the wrong roles"
    [ "$(yq -r '.spec.template.spec.initContainers[0].env[] | select(.name == "FUNCTION_DEFAULT") | .value' <<<"$mig")" = "$fd" ] || err "$label: wait-for-role FUNCTION_DEFAULT is not $fd"
  fi

  if [ "$mode" = dryrun ]; then
    render --include-crds "${args[@]}" \
      | kubectl apply --server-side --dry-run=server --field-manager=profile-matrix -n ci -f - >/dev/null \
      || err "$label: server-side dry-run apply failed"
  fi
done

if [ "$mode" = static ]; then
  echo "--- static: AWS RDS native customer contract"
  out=$(render -f "$CHART/profiles/aws-rds-native.yaml" -f "$CHART/ci/aws-rds-native-inputs.yaml") \
    || err "aws-rds-native: synthetic release overlay did not render"

  expect_fail "releaseContract.unifiedServicesDigest must be a boolean" \
    -f "$CHART/profiles/aws-rds-native.yaml" -f "$CHART/ci/aws-rds-native-inputs.yaml" \
    --set-string releaseContract.unifiedServicesDigest=true

  expect_fail "releaseContract.unifiedServicesDigest requires searchIndexer.image.digest to equal worker.image.digest" \
    -f "$CHART/profiles/aws-rds-native.yaml" -f "$CHART/ci/aws-rds-native-inputs.yaml" \
    --set searchIndexer.image.digest=sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee

  # The release overlay supplies one immutable services artifact to every
  # workload and Job; no chart default may leak into this profile.
  refs=$(yq -r 'select(.kind == "Deployment" or .kind == "Job") | .spec.template.spec | ((.initContainers // []) + .containers)[] | select(.image | test("96bulls-services")) | .image' <<<"$out" | grep -v '^---$' | sort -u)
  [ "$refs" = "$RDS_NATIVE_CI" ] || err "aws-rds-native: services images are [$refs], want only $RDS_NATIVE_CI"

  for pair in \
    "ci-read-api|agent-relay-session-read" \
    "ci-ingest-edge|agent-relay-session-ingest-api" \
    "ci-search-indexer|agent-relay-search-indexer" \
    "ci-worker-session-status-worker|agent-relay-worker"; do
    name=${pair%%|*}; sa=${pair#*|}
    got=$(yq -r "select(.kind == \"Deployment\" and .metadata.name == \"$name\") | .spec.template.spec.serviceAccountName" <<<"$out")
    [ "$got" = "$sa" ] || err "aws-rds-native: $name uses ServiceAccount $got, want $sa"
  done

  service_accounts=$(yq -r 'select(.kind == "ServiceAccount") | .metadata.name' <<<"$out" | grep -v '^---$' | sort -u)
  [ "$service_accounts" = $'agent-relay-search-indexer\nagent-relay-session-ingest-api\nagent-relay-session-read\nagent-relay-worker' ] \
    || err "aws-rds-native: rendered ServiceAccounts are [$service_accounts]"

  locker_init=$(yq -r 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "locker-init") | .metadata.name' <<<"$out" | grep -v '^---$' || true)
  [ -z "$locker_init" ] || err "aws-rds-native: external Terraform bucket still renders locker initializer $locker_init"

  # Pod Identity means no static AWS/Locker key variables anywhere.
  static_keys=$(yq -r 'select(.kind == "Deployment" or .kind == "Job") | .spec.template.spec.containers[].env[]?.name | select(. == "AWS_ACCESS_KEY_ID" or . == "AWS_SECRET_ACCESS_KEY" or . == "LOCKER_ACCESS_KEY_ID" or . == "LOCKER_SECRET_ACCESS_KEY")' <<<"$out" | grep -v '^---$' || true)
  [ -z "$static_keys" ] || err "aws-rds-native: static object-store credentials rendered: $static_keys"

  read_value() {
    yq -r "select(.kind == \"Deployment\" and .metadata.name == \"ci-read-api\") | .spec.template.spec.containers[0].env[] | select(.name == \"$1\") | .value" <<<"$out" | grep -v '^---$'
  }
  [ "$(read_value READ_API_AUTH_MODE)" = self_issued ] || err "aws-rds-native: read API is not self-issued"
  [ "$(read_value READ_API_EVENT_MESSAGE_IDS)" = true ] || err "aws-rds-native: read API message IDs are not enabled"
  [ "$(read_value READ_API_COORDINATION_OVERLAPS_ENABLED)" = true ] || err "aws-rds-native: coordination overlaps are not enabled"
  [ "$(read_value READ_API_COORDINATION_OVERLAPS_BACKEND)" = postgres ] || err "aws-rds-native: coordination overlaps are not using postgres"
  [ "$(read_value READ_API_SESSION_QUERY)" = true ] || err "aws-rds-native: session query path is not enabled"
  # Evaluation evidence: Output and the digest from the Postgres facts, no narrative model.
  [ "$(read_value READ_API_OUTPUT_ENABLED)" = 1 ] || err "aws-rds-native: output route is not enabled"
  [ "$(read_value READ_API_OUTPUT_BACKEND)" = postgres ] || err "aws-rds-native: output route is not using postgres"
  [ "$(read_value READ_API_DIGEST_ENABLED)" = 1 ] || err "aws-rds-native: digest route is not enabled"
  [ "$(read_value READ_API_DIGEST_BACKEND)" = postgres ] || err "aws-rds-native: digest route is not using postgres"
  for name in READ_API_DIGEST_NARRATIVE_MODEL OPENAI_API_KEY OPENAI_BASE_URL READ_API_DIGEST_NARRATIVE_DB_URL; do
    [ -z "$(read_value "$name")" ] || err "aws-rds-native: read API renders $name; the profile must make no model call"
  done
  [ "$(yq -r 'select(.kind == "Deployment" and .metadata.name == "ci-search-indexer") | .spec.template.spec.containers[0].env[] | select(.name == "RELAYHISTORY_SELFHOST_OUTPUT_FACTS") | .value' <<<"$out" | grep -v '^---$')" = true ] \
    || err "aws-rds-native: search indexer does not write output facts"
  bootstrap_job=$(yq -r 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "search-indexer-bootstrap")' <<<"$out" | grep -v '^---$')
  [ -n "$bootstrap_job" ] || err "aws-rds-native: search indexer bootstrap Job did not render"
  [ "$(yq -r '.spec.backoffLimit' <<<"$bootstrap_job")" = 0 ] || err "aws-rds-native: bootstrap uses Kubernetes retries and can leave an Error Pod"
  [ "$(yq -r '.spec.template.spec.restartPolicy' <<<"$bootstrap_job")" = Never ] || err "aws-rds-native: bootstrap restartPolicy changed"
  [ "$(yq -r '.spec.template.spec.containers[0].args | join(" ")' <<<"$bootstrap_job")" = "exec bun run /app/bootstrap-guard/bootstrap-guard.mjs" ] \
    || err "aws-rds-native: bootstrap does not run the catalog guard"
  guard_name=$(yq -r '.spec.template.spec.volumes[] | select(.name == "bootstrap-guard") | .configMap.name' <<<"$bootstrap_job")
  [ -n "$guard_name" ] || err "aws-rds-native: bootstrap guard ConfigMap volume missing"
  guard=$(yq -r "select(.kind == \"ConfigMap\" and .metadata.name == \"$guard_name\") | .data.\"bootstrap-guard.mjs\"" <<<"$out" | grep -v '^---$')
  grep -qF 'SELECT pg_advisory_lock(961996, 1)' <<<"$guard" || err "aws-rds-native: bootstrap does not share the Sessions migrator lock"
  grep -qF 'SELECT pg_advisory_unlock(961996, 1)' <<<"$guard" || err "aws-rds-native: bootstrap does not release the Sessions migrator lock"
  grep -qF "rolname='search_consumer_runtime'" <<<"$guard" || err "aws-rds-native: bootstrap does not wait for the post-migration runtime LOGIN"
  grep -qF 'isRetryableCatalogRace(result.output)' <<<"$guard" || err "aws-rds-native: bootstrap catalog retry is not explicit"
  bootstrap_env() { yq -r ".spec.template.spec.containers[0].env[] | select(.name == \"$1\") | .value" <<<"$bootstrap_job"; }
  [ "$(bootstrap_env SEARCH_BOOTSTRAP_CATALOG_RETRY_MAX_ATTEMPTS)" = 3 ] || err "aws-rds-native: bootstrap retry attempts"
  [ "$(bootstrap_env SEARCH_BOOTSTRAP_CATALOG_RETRY_DELAY_SECONDS)" = 2 ] || err "aws-rds-native: bootstrap retry delay"
  [ "$(bootstrap_env SEARCH_BOOTSTRAP_WAIT_FOR_RUNTIME_ROLE_LOGIN)" = true ] || err "aws-rds-native: bootstrap does not wait for rds-setup post"
  [ "$(bootstrap_env SEARCH_BOOTSTRAP_RUNTIME_ROLE_WAIT_SECONDS)" = 600 ] || err "aws-rds-native: bootstrap runtime-role wait"
  [ "$(bootstrap_env SEARCH_BOOTSTRAP_RUNTIME_ROLE_POLL_SECONDS)" = 2 ] || err "aws-rds-native: bootstrap runtime-role poll"
  expect_fail "searchIndexer.bootstrap.backoffLimit must be 0" \
    -f "$CHART/profiles/aws-rds-native.yaml" -f "$CHART/ci/aws-rds-native-inputs.yaml" --set searchIndexer.bootstrap.backoffLimit=1
  expect_fail "searchIndexer.bootstrap.catalogRetry.maxAttempts must be an integer from 1 through 10" \
    -f "$CHART/profiles/aws-rds-native.yaml" -f "$CHART/ci/aws-rds-native-inputs.yaml" --set searchIndexer.bootstrap.catalogRetry.maxAttempts=0
  expect_fail "searchIndexer.bootstrap.rolePollSeconds must not exceed roleWaitSeconds" \
    -f "$CHART/profiles/aws-rds-native.yaml" -f "$CHART/ci/aws-rds-native-inputs.yaml" --set searchIndexer.bootstrap.roleWaitSeconds=1
  facts_jobs=$(yq -r 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "output-facts-bootstrap") | .metadata.name' <<<"$out" | grep -v '^---$' || true)
  [ -z "$facts_jobs" ] || err "aws-rds-native: the output facts bootstrap Job must stay an explicit operator step, rendered $facts_jobs"
  # Selected, the Job is deterministic, hook-free, owner-identity and changes name only with its spec or runId.
  facts_render() { render -f "$CHART/profiles/aws-rds-native.yaml" -f "$CHART/ci/aws-rds-native-inputs.yaml" --set searchIndexer.outputFacts.bootstrap.enabled=true "$@" \
    | yq -r 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "output-facts-bootstrap")' | grep -v '^---$'; }
  job=$(facts_render) || err "aws-rds-native: output facts bootstrap Job did not render"
  job_name=$(yq -r '.metadata.name' <<<"$job")
  [[ $job_name =~ ^ci-search-indexer-output-facts-[0-9a-f]{8}$ ]] || err "aws-rds-native: output facts Job name $job_name"
  [ "$(facts_render | yq -r '.metadata.name')" = "$job_name" ] || err "aws-rds-native: output facts Job name is not deterministic"
  [ "$(facts_render --set searchIndexer.outputFacts.bootstrap.runId=r2 | yq -r '.metadata.name')" != "$job_name" ] || err "aws-rds-native: runId does not rename the output facts Job"
  # Any change to the immutable pod template must rename the Job, or the upgrade is rejected.
  [ "$(facts_render --set searchIndexer.image.pullPolicy=Always | yq -r '.metadata.name')" != "$job_name" ] || err "aws-rds-native: a pull-policy change does not rename the output facts Job"
  [ "$(facts_render --set searchIndexer.resources.limits.memory=2Gi | yq -r '.metadata.name')" != "$job_name" ] || err "aws-rds-native: a resources change does not rename the output facts Job"
  [ "$(yq -r '.metadata.annotations // {} | keys | map(select(test("helm.sh/hook"))) | length' <<<"$job")" = 0 ] || err "aws-rds-native: output facts Job carries Helm hooks"
  [ "$(yq -r '.spec.backoffLimit' <<<"$job")" = 0 ] || err "aws-rds-native: output facts Job retries"
  job_env() { yq -r ".spec.template.spec.containers[0].env[] | select(.name == \"$1\") | (.value // .valueFrom.secretKeyRef.name)" <<<"$job"; }
  [ "$(job_env SERVICE)" = session-pipeline-output-facts-bootstrap ] || err "aws-rds-native: output facts Job SERVICE"
  [ "$(job_env RELAYHISTORY_SELFHOST_OUTPUT_FACTS)" = true ] || err "aws-rds-native: output facts Job flag"
  [ "$(job_env RELAYHISTORY_PIPELINE_CONSUMER_SECRET)" = search-indexer-owner ] || err "aws-rds-native: output facts Job does not use the owner Secret"
  [ "$(job_env RELAYHISTORY_SELFHOST_OUTPUT_FACTS_BOOTSTRAP_DEADLINE_SECONDS)" = 7200 ] || err "aws-rds-native: output facts Job deadline"
  expect_fail "searchIndexer.outputFacts.bootstrap.enabled requires searchIndexer.outputFacts.enabled=true" \
    -f "$CHART/profiles/aws-rds-native.yaml" -f "$CHART/ci/aws-rds-native-inputs.yaml" \
    --set searchIndexer.outputFacts.enabled=false --set searchIndexer.outputFacts.bootstrap.enabled=true
  expect_fail "activeDeadlineSeconds must exceed deadlineSeconds" \
    -f "$CHART/profiles/aws-rds-native.yaml" -f "$CHART/ci/aws-rds-native-inputs.yaml" \
    --set searchIndexer.outputFacts.bootstrap.enabled=true --set searchIndexer.outputFacts.bootstrap.deadlineSeconds=9000
  [ "$(yq -r 'select(.kind == "Deployment" and .metadata.name == "ci-ingest-edge") | .spec.template.spec.containers[0].env[] | select(.name == "RELAYCONTROL_INTROSPECT_URL") | .value' <<<"$out" | grep -v '^---$')" = http://ci-relay-control.ci.svc.cluster.local ] \
    || err "aws-rds-native: ingest edge does not use the release-overlay Control Service URL"
  [ "$(read_value SEARCH_INDEX_BACKEND)" = opensearch ] || err "aws-rds-native: read API does not select OpenSearch"
  [ "$(read_value LOCKER_BUCKET)" = ci-sessions ] || err "aws-rds-native: read API canonical bucket differs from ingest"

  for deployment in ci-read-api ci-ingest-edge ci-search-indexer; do
    ca=$(yq -r "select(.kind == \"Deployment\" and .metadata.name == \"$deployment\") | .spec.template.spec.containers[0].env[] | select(.name == \"SESSION_POSTGRES_CA_SHA256\") | .value" <<<"$out" | grep -v '^---$')
    [ "$ca" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ] \
      || err "aws-rds-native: $deployment does not pin the RDS CA"
  done

  secret_refs=$(yq -r '.. | select(has("secretKeyRef")) | .secretKeyRef.name' <<<"$out" | grep -v '^---$' | sort -u)
  for secret in agent-relay-secrets agent-relay-read-api agent-relay-ingest-edge-runtime search-indexer-runtime search-indexer-owner; do
    grep -qxF "$secret" <<<"$secret_refs" \
      || err "aws-rds-native: Secret $secret is not referenced"
  done
fi

# The external-Supabase profile: sessions_pipeline_runtime with LOGIN and no workload
# role (never the drifted legacy relayhistory_runtime), the Worker pinned to
# session_directory_search_worker, and the event-trigger function boundary
# (sessions-pipeline #125, supabase only). It stays held (supabaseActivation.hold),
# and migrate refuses (function_boundary_unproven) before any write until the
# operator's reviewed trigger is in the catalog.
SBP="$CHART/profiles/external-supabase.yaml"
[ "$(yq -r '[.worker.migrations.runtimeRole, .worker.migrations.runtimeRoleLogin, (.worker.migrations.runtimeWorkloadRole // ""), (.worker.migrations.functionBoundaryMode // ""), .worker.migrations.waitForRole.role] | map(tostring) | join("|")' "$SBP")" = "sessions_pipeline_runtime|true||event-trigger|session_directory_search_worker" ] \
  || err "profiles/external-supabase.yaml: runtime sessions_pipeline_runtime LOGIN, no workload role, event-trigger boundary, Worker session_directory_search_worker"
grep -q relayhistory_runtime <(yq -r '.. | select(tag == "!!str")' "$SBP") && err "profiles/external-supabase.yaml: uses relayhistory_runtime"

# Mode combinations the chart must refuse (the migrator's refusals at render
# time, plus the chart's in-cluster rules). Bases: an in-cluster selfhosted
# file, AWS external Supabase, GCP Cloud SQL.
if [ "$mode" = static ]; then
  echo "--- static: refused combinations"
  IN=(-f "$CHART/ci/default-values.yaml")
  SB=(-f "$CHART/ci/pod-identity-values.yaml")
  GCP=(-f "$CHART/ci/gcp-cloudsql-values.yaml")
  expect_fail "databaseMode must be local, selfhosted, cloudsql, supabase or rds" "${IN[@]}" --set worker.migrations.databaseMode=
  expect_fail "worker.migrations.databaseMode must be selfhosted, not \"supabase\"" "${IN[@]}" --set worker.migrations.databaseMode=supabase --set worker.migrations.supabaseShim=false --set worker.migrations.waitForRole.enabled=false --set worker.migrations.waitForRole.functionDefault=false
  expect_fail "worker.migrations.databaseMode must be selfhosted, not \"local\"" "${IN[@]}" --set worker.migrations.databaseMode=local
  expect_fail "supabaseShim must not be true in supabase mode" "${SB[@]}" --set worker.migrations.supabaseShim=true
  expect_fail "waitForRole must be disabled in supabase mode" "${SB[@]}" --set worker.migrations.waitForRole.enabled=true
  expect_fail "functionDefaultRevoke.bootstrapJob is for the in-cluster CNPG HoopDb only" "${SB[@]}" --set functionDefaultRevoke.bootstrapJob.enabled=true
  expect_fail "runtimeRole.bootstrapJob is for the in-cluster HoopDb only" "${SB[@]}" --set runtimeRole.bootstrapJob.enabled=true
  expect_fail "functionDefaultRevoke.bootstrapJob is for the in-cluster CNPG HoopDb only" "${GCP[@]}" --set functionDefaultRevoke.bootstrapJob.enabled=true
  expect_fail "runtimeRoleLogin must be set (true or false) in supabase mode" "${SB[@]}" --set worker.migrations.runtimeRoleLogin=null
  RDS=(-f "$CHART/profiles/external-rds.yaml" "${REQUIRED[@]}" "${RUNTIME[@]}")
  expect_fail "waitForRole must be disabled in rds mode" "${RDS[@]}" --set worker.migrations.waitForRole.enabled=true
  expect_fail "supabaseShim must not be true in rds mode" "${RDS[@]}" --set worker.migrations.supabaseShim=true
  expect_fail "roleBootstrap must not be true in rds mode" "${RDS[@]}" --set worker.migrations.roleBootstrap=true
  expect_fail "runtimeWorkloadRole is not supported in rds mode" "${RDS[@]}" --set worker.migrations.runtimeWorkloadRole=app
  expect_fail "runtimeRoleLogin must be true in rds mode" "${RDS[@]}" --set worker.migrations.runtimeRoleLogin=false
  # The RDS profile with a CA bundle: every app workload and migrate gets it.
  out=$(render "${RDS[@]}" --set worker.postgresCa.enabled=true --set worker.postgresCa.configMap=rds-ca --set alleyoop.postgresCa.enabled=true --set alleyoop.postgresCa.configMap=rds-ca) || err "rds + postgresCa did not render"
  ca_gaps=$(yq 'select((.kind == "Deployment" or (.kind == "Job" and (.metadata.name | contains("migrate")))) and (.spec.template.spec.containers[0].image | contains("96bulls-services"))) | select(([.spec.template.spec.containers[0].env[] | select(.name == "NODE_EXTRA_CA_CERTS")] | length) != 1) | .metadata.name' <<<"$out" | grep -v '^---$' || true)
  [ -z "$ca_gaps" ] || err "rds + postgresCa: no CA in $ca_gaps"
  [ "$(yq 'select(.kind == "Job" and (.metadata.name | contains("migrate"))) | .kind' <<<"$out" | grep -c Job)" = 1 ] || err "rds + postgresCa: expected one migrate Job"
  ! render "${RDS[@]}" | grep -q NODE_EXTRA_CA_CERTS || err "rds profile must not set NODE_EXTRA_CA_CERTS by default"
  expect_fail "supabaseShim must be set (true or false) in cloudsql mode" "${GCP[@]}" --set worker.migrations.supabaseShim=null
  expect_fail "functionBoundaryMode is required in cloudsql mode" "${GCP[@]}" --set worker.migrations.functionBoundaryMode=
  expect_fail "functionBoundaryMode is required in selfhosted mode" "${IN[@]}" --set worker.migrations.functionBoundaryMode=
  expect_fail "databaseMode must be local, selfhosted, cloudsql, supabase or rds" "${GCP[@]}" --set worker.migrations.databaseMode=cloud
  expect_fail "roleBootstrap must not be true in supabase mode" "${SB[@]}" --set worker.migrations.roleBootstrap=true
  expect_fail "roleBootstrap must be true or false" "${GCP[@]}" --set-string worker.migrations.roleBootstrap=no
  expect_fail "worker.migrations.databaseMode must be selfhosted, not \"cloudsql\"" "${IN[@]}" --set worker.migrations.databaseMode=cloudsql
  expect_fail "functionBoundaryMode=event-trigger is supported only in supabase mode, not cloudsql" "${GCP[@]}" --set worker.migrations.functionBoundaryMode=event-trigger
  expect_fail "functionBoundaryMode=event-trigger is supported only in supabase mode, not selfhosted" "${IN[@]}" --set worker.migrations.functionBoundaryMode=event-trigger
  expect_fail "functionBoundaryMode must be global-default-revoke or (supabase only) event-trigger" "${SB[@]}" --set worker.migrations.functionBoundaryMode=yes
  # Supabase mode accepts event-trigger and renders it into migrate.
  out=$(render "${SB[@]}" --set worker.migrations.functionBoundaryMode=event-trigger) || err "supabase + event-trigger did not render"
  profile_env | grep -qxF HOOPDB_FUNCTION_BOUNDARY_MODE=event-trigger || err "supabase + event-trigger: migrate lacks HOOPDB_FUNCTION_BOUNDARY_MODE=event-trigger"
  expect_fail "functionBoundaryApproved was renamed functionBoundaryMode" "${SB[@]}" --set worker.migrations.functionBoundaryApproved=global-default-revoke
  expect_fail "functionDefaultRevoke.bootstrapJob.enabled must be true with the in-cluster HoopDb" "${IN[@]}" --set functionDefaultRevoke.bootstrapJob.enabled=false
  expect_fail "runtimeRole.bootstrapJob.enabled must be true with the in-cluster HoopDb" "${IN[@]}" --set runtimeRole.bootstrapJob.enabled=false
  expect_fail "needs worker.migrations.waitForRole.functionDefault=true" "${IN[@]}" --set worker.migrations.waitForRole.functionDefault=false
  expect_fail "runtimeRole must not be the migration owner \"hoop\"" "${IN[@]}" --set worker.migrations.runtimeRole=hoop
  expect_fail "runtimeRole must not be the search Worker role" "${GCP[@]}" --set worker.migrations.runtimeRole=session_directory_search_worker
  for n in HOOPDB_DB_MODE HOOPDB_SUPABASE_SHIM HOOPDB_RUNTIME_ROLE HOOPDB_RUNTIME_ROLE_LOGIN HOOPDB_FUNCTION_BOUNDARY_MODE HOOPDB_FUNCTION_BOUNDARY_APPROVED HOOPDB_ROLE_BOOTSTRAP; do
    expect_fail "extraEnv must not set $n" "${GCP[@]}" --set "worker.extraEnv[0].name=$n" --set "worker.extraEnv[0].value=x"
  done
  # GCS Locker: the services refuse HMAC keys on GCS and the S3 client against
  # storage.googleapis.com, and locker.provider=gcs arms their data-path
  # readiness check. The GCP Cloud SQL file renders the native GCS shape.
  out=$(render "${GCP[@]}") || err "gcp-cloudsql did not render"
  for w in ci-worker-session-status-worker ci-worker-session-summary-worker ci-worker-session-metadata-indexer ci-session-ingest-api; do
    gcs_env=$(yq "select(.kind == \"Deployment\" and .metadata.name == \"$w\") | .spec.template.spec.containers[0].env[] | select(.name == \"LOCKER_PROVIDER\" or .name == \"PIPELINE_RAW_PROVIDER\") | .name + \"=\" + .value" <<<"$out" | sort | tr '\n' ' ')
    [ "$gcs_env" = "LOCKER_PROVIDER=gcs PIPELINE_RAW_PROVIDER=gcs " ] || err "gcp-cloudsql: $w lacks LOCKER_PROVIDER=gcs/PIPELINE_RAW_PROVIDER=gcs (got: $gcs_env)"
  done
  grep -Eq 'name: "?LOCKER_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)"?$' <<<"$out" && err "gcp-cloudsql: GCS Locker renders a static HMAC credential"
  expect_fail "locker.provider=gcs requires locker.credentials.mode=podIdentity" "${GCP[@]}" --set worker.locker.credentials.mode=secret --set worker.locker.endpoint=https://storage.googleapis.com
  expect_fail "locker.provider=gcs requires locker.endpoint to be empty or https://storage.googleapis.com" "${GCP[@]}" --set worker.locker.endpoint=https://gcs.example.com
  expect_fail "needs CLOUD_SQL_CONNECTION_NAME in extraEnv" "${GCP[@]}" --set worker.extraEnv=null
  expect_fail "needs PUBSUB_SUBSCRIPTION in extraEnv" "${GCP[@]}" --set-json 'alleyoop.extraEnv=[{"name":"CLOUD_SQL_CONNECTION_NAME","value":"p:r:i"},{"name":"REDIS_HOST","value":"10.0.0.3"},{"name":"REDIS_PORT","value":"6378"},{"name":"REDIS_AUTH_ENABLED","value":"false"},{"name":"REDIS_TRANSIT_ENCRYPTION","value":"SERVER_AUTHENTICATION"},{"name":"REDIS_TLS_CA_PEM","value":"ca"},{"name":"PUBSUB_TOPIC","value":"t"}]'
  expect_fail "lockerInit.enabled must be false with locker.provider=gcs" "${GCP[@]}" --set worker.lockerInit.enabled=true
  expect_fail "locker.endpoint is a Google Cloud Storage endpoint: set locker.provider=gcs" "${SB[@]}" --set worker.locker.endpoint=https://storage.googleapis.com
  expect_fail "locker.provider must be s3 or gcs" "${SB[@]}" --set alleyoop.locker.provider=azure
  expect_fail "extraEnv must not set LOCKER_PROVIDER: use locker.provider" "${SB[@]}" --set 'worker.extraEnv[0].name=LOCKER_PROVIDER' --set 'worker.extraEnv[0].value=gcs'
  # Worker NetworkPolicy: an empty `to` matches every destination, so a
  # required rule without destinations must refuse to render, and a rendered
  # egress rule must never carry an empty or missing `to`.
  NP=(--set worker.networkPolicy.enabled=true
    --set-json 'worker.networkPolicy.dns.to=[{"ipBlock":{"cidr":"10.0.0.10/32"}}]'
    --set-json 'worker.networkPolicy.database.to=[{"ipBlock":{"cidr":"10.10.0.0/24"}}]'
    --set-json 'worker.networkPolicy.objectStorage.to=[{"ipBlock":{"cidr":"199.36.153.8/30"}}]')
  expect_fail "networkPolicy.dns.to must list destinations" "${IN[@]}" --set worker.networkPolicy.enabled=true
  expect_fail "networkPolicy.workloadIdentity.to must list destinations" "${GCP[@]}" "${NP[@]}"
  out=$(render "${GCP[@]}" "${NP[@]}" --set-json 'worker.networkPolicy.workloadIdentity.to=[{"ipBlock":{"cidr":"169.254.169.254/32"}}]') \
    || err "worker NetworkPolicy with explicit destinations did not render"
  np_rules=$(yq 'select(.kind == "NetworkPolicy" and .metadata.labels."app.kubernetes.io/name" == "worker") | .spec.egress | length' <<<"$out")
  [ "$np_rules" = 4 ] || err "worker NetworkPolicy: expected 4 egress rules, got $np_rules"
  np_open=$(yq 'select(.kind == "NetworkPolicy" and .metadata.labels."app.kubernetes.io/name" == "worker") | .spec.egress[] | select((.to // []) | length == 0)' <<<"$out")
  [ -z "$np_open" ] || err "worker NetworkPolicy renders an egress rule with an empty to (allows every destination)"
fi

[ $fail -eq 0 ] && echo "sessions-pipeline profile matrix ($mode): OK (${#MATRIX[@]} profiles)"
exit $fail
