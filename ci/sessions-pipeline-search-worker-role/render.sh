#!/usr/bin/env bash
# Rendered-chart assertions for the session directory search Worker role
# (charts/sessions-pipeline: hoopdb initdb SQL + searchWorkerRole.bootstrapJob). Offline.
# Usage: ci/sessions-pipeline-search-worker-role/render.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CHART="$ROOT/charts/sessions-pipeline"
fail=0
err() { echo "::error::$*"; fail=1; }
render() { helm template ci "$CHART" --namespace ci --no-hooks "$@"; }
base=(-f "$CHART/ci/default-values.yaml")
on=(-f "$CHART/ci/search-worker-bootstrap-values.yaml")

# 1. Fresh clusters: initdb creates the role with exactly the spec, as postgres.
sql=$(render "${base[@]}" | yq -r 'select(.kind == "Cluster") | .spec.bootstrap.initdb.postInitApplicationSQL[]')
grep -qxF "CREATE ROLE session_directory_search_worker NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION" <<<"$sql" || err "initdb: CREATE ROLE with the exact attributes is missing"
grep -qxF "ALTER ROLE session_directory_search_worker SET statement_timeout = '2s'" <<<"$sql" || err "initdb: statement_timeout = '2s' is missing"
# No grant of the role to anyone (the migration owner hoop gets no membership or ADMIN).
if grep -Ei "GRANT +session_directory_search_worker|session_directory_search_worker +TO" <<<"$sql"; then err "initdb: the role is granted to someone"; fi
# deps/cnpg-cluster-values.yaml carries the same two statements.
for line in "CREATE ROLE session_directory_search_worker NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION" "ALTER ROLE session_directory_search_worker SET statement_timeout = '2s'"; do
  yq -r '.cluster.initdb.postInitApplicationSQL[]' "$ROOT/deps/cnpg-cluster-values.yaml" | grep -qxF "$line" || err "deps/cnpg-cluster-values.yaml: missing: $line"
done

# 2. The existing-cluster Job is off by default: no Job, ServiceAccount or RBAC.
off=$(render "${base[@]}")
[ -z "$(yq -r 'select(.metadata.labels."app.kubernetes.io/component" == "search-worker-role-bootstrap") | .kind' <<<"$off")" ] || err "bootstrap objects rendered while disabled"

# 3. Enabled: a separate Job, its own ServiceAccount and a minimal Role.
out=$(render "${on[@]}")
pick() { yq "select(.kind == \"$1\" and .metadata.labels.\"app.kubernetes.io/component\" == \"search-worker-role-bootstrap\")" <<<"$out"; }
job=$(pick Job)
[ -n "$job" ] || err "enabled: no bootstrap Job"
sa=$(yq -r '.spec.template.spec.serviceAccountName' <<<"$job")
migrate_sa=$(yq -r 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate") | .spec.template.spec.serviceAccountName' <<<"$out")
[ "$sa" != "$migrate_sa" ] || err "bootstrap Job shares the migrate Job's ServiceAccount ($sa)"
[ "$(yq -r '.metadata.name' <<<"$job")" != "$(yq -r 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate") | .metadata.name' <<<"$out")" ] || err "bootstrap and migrate are the same Job"
rules=$(pick Role | yq -o=json -I=0 '.rules')
[ "$rules" = '[{"apiGroups":[""],"resources":["pods"],"verbs":["get","list"]},{"apiGroups":[""],"resources":["pods/exec"],"verbs":["create"]}]' ] || err "Role is not exactly pods get/list + pods/exec create: $rules"
[ -z "$(yq 'select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding") | select(.metadata.labels."app.kubernetes.io/component" == "search-worker-role-bootstrap")' <<<"$out")" ] || err "cluster-scoped RBAC rendered"
# Images by digest; the SQL comes from the services image; superuser access stays off.
yq -r '.spec.template.spec.initContainers[0].image' <<<"$job" | grep -Eq '@sha256:[0-9a-f]{64}$' || err "sql image is not digest-pinned"
yq -r '.spec.template.spec.containers[0].image' <<<"$job" | grep -Eq '@sha256:[0-9a-f]{64}$' || err "kubectl image is not digest-pinned"
yq -r '.spec.template.spec.initContainers[0].command | join(" ")' <<<"$job" | grep -qF "/app/supabase/bootstrap/session_directory_search_worker.sql" || err "sql file path"
yq -r '.spec.template.spec.containers[0].args[0]' <<<"$job" | grep -qF 'kubectl exec -i "$pod" -c postgres -- psql -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -X -d "${DATABASE}" -f - < /work/bootstrap.sql || rc=$?' || err "exec command"
yq -r '.spec.template.spec.containers[0].args[0]' <<<"$job" | grep -qxF 'exit "$rc"' || err "the container does not exit with psql's status"

# 3a. API token: none pod-wide; projected into the kubectl container only.
[ "$(yq -r '.spec.template.spec.automountServiceAccountToken' <<<"$job")" = "false" ] || err "pod-level automountServiceAccountToken is not false"
[ "$(yq -r '[.spec.template.spec.initContainers[].volumeMounts[] | select(.name == "kube-api" or (.mountPath | test("serviceaccount")))] | length' <<<"$job")" = 0 ] || err "the sql initContainer mounts an API token"
[ "$(yq -r '[.spec.template.spec.containers[].volumeMounts[] | select(.name == "kube-api" and .mountPath == "/var/run/secrets/kubernetes.io/serviceaccount")] | length' <<<"$job")" = 1 ] || err "the kubectl container does not mount the projected token"
[ "$(yq -r '.spec.template.spec.volumes[] | select(.name == "kube-api") | [.projected.sources[] | keys | .[0]] | join(",")' <<<"$job")" = "serviceAccountToken,configMap,downwardAPI" ] || err "kube-api is not a projected token volume"

# 3b. Pull auth: the bootstrap Job uses the workloads' pull Secret.
for args in "--set worker.imagePullSecrets[0].name=ghcr-pull" "--set shared.imagePullSecrets[0].name=unused"; do
  o=$(render "${on[@]}" $args)
  b=$(yq -o=json -I=0 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "search-worker-role-bootstrap") | .spec.template.spec.imagePullSecrets' <<<"$o")
  m=$(yq -o=json -I=0 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate") | .spec.template.spec.imagePullSecrets' <<<"$o")
  [ "$b" = "$m" ] || err "bootstrap pull secrets ($b) differ from the migrate Job's ($m) with $args"
done
o=$(render "${on[@]}" --set 'worker.imagePullSecrets[0].name=ghcr-pull')
[ "$(yq -r 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "search-worker-role-bootstrap") | .spec.template.spec.imagePullSecrets[0].name' <<<"$o")" = "ghcr-pull" ] || err "bootstrap Job has no imagePullSecrets"

# 3c. Order: migrate's first init container waits for the role, on the HoopDb image.
mig=$(yq 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate")' <<<"$out")
[ "$(yq -r '.spec.template.spec.initContainers[0].name' <<<"$mig")" = "wait-for-role" ] || err "migrate has no wait-for-role init container"
[ "$(yq -r '.spec.template.spec.initContainers[0].env[] | select(.name == "ROLES") | .value' <<<"$mig")" = "session_directory_search_worker sessions_pipeline_runtime" ] || err "wait-for-role does not wait for the search Worker and runtime roles"
[ "$(yq -r '.spec.template.spec.initContainers[0].image' <<<"$mig")" = "$(yq -r 'select(.kind == "Cluster") | .spec.imageName' <<<"$out")" ] || err "wait-for-role image differs from the HoopDb image"
[ "$(yq -r '.spec.template.spec.initContainers[0].env[] | select(.name == "HOOPDB_URL") | .valueFrom.secretKeyRef.name' <<<"$mig")" = "$(yq -r '.spec.template.spec.containers[0].env[] | select(.name == "HOOPDB_URL") | .valueFrom.secretKeyRef.name' <<<"$mig")" ] || err "wait-for-role reads a different HOOPDB_URL"
[ "$(yq -r 'select(.kind == "Cluster") | .spec.enableSuperuserAccess' <<<"$out")" = "false" ] || err "enableSuperuserAccess is not false"
[ -z "$(yq 'select(.metadata.annotations."helm.sh/hook")' <<<"$out")" ] || err "a Helm hook was rendered"

# 3d. A separate migration-owner URL (migrations.hoopdb) reaches migrate and its
# wait-for-role (which checks the owner's own function default), never a workload.
o=$(render "${on[@]}" --set worker.migrations.hoopdb.existingSecret=hoopdb-migration --set worker.migrations.hoopdb.key=HOOPDB_MIGRATION_URL)
m=$(yq 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate")' <<<"$o")
[ "$(yq -r '.spec.template.spec.initContainers[0].env[] | select(.name == "HOOPDB_URL") | .valueFrom.secretKeyRef | .name + "/" + .key' <<<"$m")" = "hoopdb-migration/HOOPDB_MIGRATION_URL" ] || err "wait-for-role does not use the migration-owner URL"
[ "$(yq -r '.spec.template.spec.containers[0].env[] | select(.name == "HOOPDB_URL") | .valueFrom.secretKeyRef | .name + "/" + .key' <<<"$m")" = "hoopdb-migration/HOOPDB_MIGRATION_URL" ] || err "migrate does not use the migration-owner URL"
[ -z "$(yq -r 'select(.kind == "Deployment") | .spec.template.spec | ((.initContainers // []) + .containers)[] | (.env // [])[] | select(.name == "HOOPDB_URL") | .valueFrom.secretKeyRef.name' <<<"$o" | grep -x hoopdb-migration)" ] || err "a workload reads the migration-owner URL"

# 4. Misconfiguration fails the render.
expect_fail() { local msg=$1; shift; if o=$(render "$@" 2>&1); then err "rendered despite: $msg"; elif ! grep -qF "$msg" <<<"$o"; then err "wrong error for $msg: $o"; fi; }
expect_fail "sqlImage.repository and .digest are required" "${base[@]}" --set searchWorkerRole.bootstrapJob.enabled=true --set privilegedSql.sqlImage.digest=
expect_fail "sqlImage.digest must be sha256" "${on[@]}" --set searchWorkerRole.bootstrapJob.sqlImage.digest=latest
expect_fail "kubectlImage.digest must be sha256" "${on[@]}" --set searchWorkerRole.bootstrapJob.kubectlImage.digest=
expect_fail "needs worker.migrations.waitForRole.enabled" "${on[@]}" --set hoopdb.enabled=false --set runtimeRole.bootstrapJob.enabled=false --set functionDefaultRevoke.bootstrapJob.enabled=false --set worker.migrations.waitForRole.enabled=false --set worker.migrations.waitForRole.functionDefault=false
expect_fail "waitForRole.image must be a full image reference" "${on[@]}" --set worker.migrations.waitForRole.image=postgres:17

# 4a. migrate always runs the phase 2 verify; nothing can turn it off.
for o in "$(render "${base[@]}")" "$out"; do
  [ "$(yq -r 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate") | [.spec.template.spec.containers[0].env[] | select(.name == "HOOPDB_ROLE_VERIFY") | .value] | join(",")' <<<"$o" | grep .)" = "true" ] || err "migrate does not set HOOPDB_ROLE_VERIFY=true exactly once"
done
[ -z "$(render "${on[@]}" | yq -r '.. | select(type == "!!map" and .name == "HOOPDB_ROLE_VERIFY" and .value != "true") | .value' | grep .)" ] || err "HOOPDB_ROLE_VERIFY rendered with a value other than true"

# 6. The migrator's database profile (sessions-pipeline #99): first-class
# worker.migrations values, each rendered exactly once, into migrate only.
PROFILE_NAMES="HOOPDB_DB_MODE HOOPDB_SUPABASE_SHIM HOOPDB_RUNTIME_ROLE HOOPDB_RUNTIME_ROLE_LOGIN HOOPDB_RUNTIME_WORKLOAD_ROLE HOOPDB_FUNCTION_BOUNDARY_MODE HOOPDB_FUNCTION_BOUNDARY_APPROVED HOOPDB_ROLE_VERIFY HOOPDB_ROLE_BOOTSTRAP"
migrate_env() { yq -r 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate") | .spec.template.spec.containers[0].env[] | .name + "=" + (.value // "<ref>")' <<<"$1" | grep .; }
others_env() { yq -r 'select((.kind == "Deployment" or .kind == "Job") and .metadata.labels."app.kubernetes.io/component" != "hoopdb-migrate") | .spec.template.spec | ((.initContainers // []) + .containers)[] | (.env // [])[] | .name' <<<"$1" | grep . || true; }
check_profile() { # label rendered expected-lines...
  local label=$1 o=$2; shift 2
  local got; got=$(migrate_env "$o" | grep -E "^($(tr ' ' '|' <<<"$PROFILE_NAMES"))=" | sort)
  local want; want=$(printf '%s\n' "$@" | sort)
  [ "$got" = "$want" ] || err "$label: migrate profile env is [$(tr '\n' ' ' <<<"$got")], want [$(tr '\n' ' ' <<<"$want")]"
  for n in $PROFILE_NAMES; do
    others_env "$o" | grep -qxF "$n" && err "$label: $n rendered outside migrate"
  done
  # The waiter's init container must not see the profile either.
  [ -z "$(yq -r 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate") | .spec.template.spec.initContainers[]?.env[]? | select(.name | test("^HOOPDB_(DB_MODE|SUPABASE_SHIM|RUNTIME_|FUNCTION_)")) | .name' <<<"$o" | grep .)" ] || err "$label: profile env in the wait-for-role container"
  return 0
}
FB=HOOPDB_FUNCTION_BOUNDARY_MODE=global-default-revoke
check_profile "selfhosted (CNPG)" "$out" HOOPDB_DB_MODE=selfhosted HOOPDB_SUPABASE_SHIM=true HOOPDB_RUNTIME_ROLE=sessions_pipeline_runtime HOOPDB_RUNTIME_ROLE_LOGIN=true $FB HOOPDB_ROLE_VERIFY=true
o=$(render "${on[@]}" --set worker.migrations.runtimeRoleLogin=false --set worker.migrations.runtimeWorkloadRole=sessions_pipeline_app)
check_profile "selfhosted, login false + workload role" "$o" HOOPDB_DB_MODE=selfhosted HOOPDB_SUPABASE_SHIM=true HOOPDB_RUNTIME_ROLE=sessions_pipeline_runtime HOOPDB_RUNTIME_ROLE_LOGIN=false HOOPDB_RUNTIME_WORKLOAD_ROLE=sessions_pipeline_app $FB HOOPDB_ROLE_VERIFY=true
yq -r 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-runtime-role-bootstrap") | .spec.template.spec.containers[0].args[0]' <<<"$o" | grep -qF -- "-v 'runtime_role=sessions_pipeline_runtime' -v 'runtime_login=false' -v 'workload_role=sessions_pipeline_app' -X -d \"\${DATABASE}\" -f -" || err "runtime-role Job does not pass runtime_login=false"
# External database (Supabase, or RDS / Cloud SQL): no in-cluster bootstrap.
ext=(-f "$CHART/ci/default-values.yaml" --set hoopdb.enabled=false --set runtimeRole.bootstrapJob.enabled=false --set functionDefaultRevoke.bootstrapJob.enabled=false --set worker.migrations.waitForRole.functionDefault=false --set worker.hoopdb.existingSecret=ext-db --set alleyoop.hoopdb.existingSecret=ext-db)
sb=("${ext[@]}" --set worker.migrations.databaseMode=supabase --set worker.migrations.supabaseShim=null --set worker.migrations.functionBoundaryMode= --set worker.migrations.waitForRole.enabled=false)
o=$(render "${sb[@]}")
check_profile "supabase (external)" "$o" HOOPDB_DB_MODE=supabase HOOPDB_SUPABASE_SHIM=false HOOPDB_RUNTIME_ROLE=sessions_pipeline_runtime HOOPDB_RUNTIME_ROLE_LOGIN=true HOOPDB_ROLE_VERIFY=true
o=$(render "${sb[@]}" --set worker.migrations.functionBoundaryMode=global-default-revoke)
check_profile "supabase, operator-selected boundary" "$o" HOOPDB_DB_MODE=supabase HOOPDB_SUPABASE_SHIM=false HOOPDB_RUNTIME_ROLE=sessions_pipeline_runtime HOOPDB_RUNTIME_ROLE_LOGIN=true $FB HOOPDB_ROLE_VERIFY=true
o=$(render "${sb[@]}" --set worker.migrations.functionBoundaryMode=event-trigger)
check_profile "supabase, event-trigger boundary" "$o" HOOPDB_DB_MODE=supabase HOOPDB_SUPABASE_SHIM=false HOOPDB_RUNTIME_ROLE=sessions_pipeline_runtime HOOPDB_RUNTIME_ROLE_LOGIN=true HOOPDB_FUNCTION_BOUNDARY_MODE=event-trigger HOOPDB_ROLE_VERIFY=true
[ -z "$(yq -r 'select(.metadata.labels."app.kubernetes.io/component" == "hoopdb-runtime-role-bootstrap" or .metadata.labels."app.kubernetes.io/component" == "search-worker-role-bootstrap" or .metadata.labels."app.kubernetes.io/component" == "hoopdb-function-default-revoke") | .kind' <<<"$o" | grep .)" ] || err "external database: an in-cluster bootstrap object rendered"
# cloudsql mode with HOOPDB_ROLE_BOOTSTRAP=false, and a workload role passed to the runtime-role Job.
o=$(render "${ext[@]}" --set worker.migrations.databaseMode=cloudsql --set worker.migrations.supabaseShim=false --set worker.migrations.roleBootstrap=false)
check_profile "cloudsql (external, role bootstrap off)" "$o" HOOPDB_DB_MODE=cloudsql HOOPDB_SUPABASE_SHIM=false HOOPDB_ROLE_BOOTSTRAP=false HOOPDB_RUNTIME_ROLE=sessions_pipeline_runtime HOOPDB_RUNTIME_ROLE_LOGIN=true $FB HOOPDB_ROLE_VERIFY=true
o=$(render "${on[@]}" --set worker.migrations.runtimeWorkloadRole=sessions_pipeline_app)
yq -r 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-runtime-role-bootstrap") | .spec.template.spec.containers[0].args[0]' <<<"$o" | grep -qF -- "-v 'runtime_role=sessions_pipeline_runtime' -v 'runtime_login=true' -v 'workload_role=sessions_pipeline_app' -X" || err "runtime-role Job does not pass workload_role"
# local mode: runtimeRoleLogin and functionBoundaryMode are optional; unset, neither is rendered.
o=$(render "${ext[@]}" --set worker.migrations.databaseMode=local --set worker.migrations.runtimeRoleLogin=null --set worker.migrations.functionBoundaryMode=)
check_profile "local (login and boundary unset)" "$o" HOOPDB_DB_MODE=local HOOPDB_SUPABASE_SHIM=true HOOPDB_RUNTIME_ROLE=sessions_pipeline_runtime HOOPDB_ROLE_VERIFY=true
o=$(render "${ext[@]}")
check_profile "selfhosted (external RDS / Cloud SQL)" "$o" HOOPDB_DB_MODE=selfhosted HOOPDB_SUPABASE_SHIM=true HOOPDB_RUNTIME_ROLE=sessions_pipeline_runtime HOOPDB_RUNTIME_ROLE_LOGIN=true $FB HOOPDB_ROLE_VERIFY=true

# The runtime-role Job: a separate privileged Job (own SA, minimal Role, no
# pod-wide token, projected token only in kubectl, pull Secret), in the HoopDb db.
rt=$(pick_c() { yq "select(.kind == \"$1\" and .metadata.labels.\"app.kubernetes.io/component\" == \"hoopdb-runtime-role-bootstrap\")" <<<"$out"; }; pick_c Job)
[ -n "$rt" ] || err "no runtime-role bootstrap Job with the in-cluster HoopDb"
yq -r '.spec.template.spec.containers[0].args[0]' <<<"$rt" | grep -qF -- "psql -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -v 'runtime_role=sessions_pipeline_runtime' -v 'runtime_login=true' -X -d \"\${DATABASE}\" -f - < /work/bootstrap.sql" || err "runtime-role Job psql command"
[ "$(yq -r '.spec.template.spec.containers[0].env[] | select(.name == "DATABASE") | .value' <<<"$rt")" = "hoopdb" ] || err "runtime-role Job does not run in the HoopDb database"
yq -r '.spec.template.spec.initContainers[0].command | join(" ")' <<<"$rt" | grep -qF "/app/supabase/bootstrap/hoopdb_runtime_role.sql" || err "runtime-role sql file path"
[ "$(yq -r '.spec.template.spec.automountServiceAccountToken' <<<"$rt")" = "false" ] || err "runtime-role Job: pod-level token"
[ "$(yq -r '[.spec.template.spec.initContainers[].volumeMounts[] | select(.name == "kube-api")] | length' <<<"$rt")" = 0 ] || err "runtime-role Job: token in the sql init container"
rsa=$(yq -r '.spec.template.spec.serviceAccountName' <<<"$rt")
for c in hoopdb-migrate search-worker-role-bootstrap; do
  [ "$rsa" != "$(yq -r "select(.kind == \"Job\" and .metadata.labels.\"app.kubernetes.io/component\" == \"$c\") | .spec.template.spec.serviceAccountName" <<<"$out" | grep .)" ] || err "runtime-role Job shares $c's ServiceAccount"
done
rrules=$(yq -o=json -I=0 'select(.kind == "Role" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-runtime-role-bootstrap") | .rules' <<<"$out" | grep .)
[ "$rrules" = '[{"apiGroups":[""],"resources":["pods"],"verbs":["get","list"]},{"apiGroups":[""],"resources":["pods/exec"],"verbs":["create"]}]' ] || err "runtime-role Role is not exactly pods get/list + pods/exec create: $rrules"
o=$(render "${on[@]}" --set 'worker.imagePullSecrets[0].name=ghcr-pull')
[ "$(yq -r 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-runtime-role-bootstrap") | .spec.template.spec.imagePullSecrets[0].name' <<<"$o" | grep .)" = "ghcr-pull" ] || err "runtime-role Job has no imagePullSecrets"

# Refusals: the migrator's own, and the chart's placement rules.
expect_fail "databaseMode must be local, selfhosted, cloudsql, supabase or rds" "${on[@]}" --set worker.migrations.databaseMode=
expect_fail "databaseMode must be local, selfhosted, cloudsql, supabase or rds" "${on[@]}" --set worker.migrations.databaseMode=cloud
expect_fail "supabaseShim must be set (true or false) in selfhosted mode" "${on[@]}" --set worker.migrations.supabaseShim=null
expect_fail "supabaseShim must not be true in supabase mode" "${sb[@]}" --set worker.migrations.supabaseShim=true
expect_fail "waitForRole must be disabled in supabase mode" "${sb[@]}" --set worker.migrations.waitForRole.enabled=true
expect_fail "functionBoundaryMode must be global-default-revoke" "${on[@]}" --set worker.migrations.functionBoundaryMode=yes
expect_fail "functionBoundaryMode=event-trigger is supported only in supabase mode, not selfhosted" "${on[@]}" --set worker.migrations.functionBoundaryMode=event-trigger
expect_fail "functionBoundaryMode is required in selfhosted mode" "${ext[@]}" --set worker.migrations.functionBoundaryMode=
expect_fail "functionBoundaryApproved was renamed functionBoundaryMode" "${on[@]}" --set worker.migrations.functionBoundaryApproved=global-default-revoke
expect_fail "runtimeRole is required" "${on[@]}" --set worker.migrations.runtimeRole=
expect_fail "runtimeRole is required" "${on[@]}" --set worker.migrations.runtimeRole=1bad
expect_fail "runtimeRole must not be the search Worker role" "${on[@]}" --set worker.migrations.runtimeRole=session_directory_search_worker
expect_fail "runtimeRoleLogin must be set (true or false) in selfhosted mode" "${on[@]}" --set worker.migrations.runtimeRoleLogin=null
expect_fail "runtimeRoleLogin must be true or false" "${on[@]}" --set-string worker.migrations.runtimeRoleLogin=yes
expect_fail "runtimeWorkloadRole must be a role name" "${on[@]}" --set worker.migrations.runtimeWorkloadRole=1x
expect_fail 'must not be the migration owner "hoop"' "${on[@]}" --set worker.migrations.runtimeRole=hoop
expect_fail "databaseMode must be selfhosted, not" "${base[@]}" --set worker.migrations.databaseMode=supabase --set worker.migrations.supabaseShim=null --set worker.migrations.waitForRole.enabled=false --set worker.migrations.waitForRole.functionDefault=false
expect_fail "runtimeRole.bootstrapJob.enabled must be true" "${on[@]}" --set runtimeRole.bootstrapJob.enabled=false
expect_fail "runtimeRole.bootstrapJob is for the in-cluster HoopDb only" "${ext[@]}" --set runtimeRole.bootstrapJob.enabled=true
expect_fail "search-worker-role-bootstrap runs in the in-cluster HoopDb" "${ext[@]}" --set searchWorkerRole.bootstrapJob.enabled=true --set searchWorkerRole.bootstrapJob.sqlImage.repository=x --set "searchWorkerRole.bootstrapJob.sqlImage.digest=sha256:$(printf '%064d' 1)"
expect_fail "hoopdb-runtime-role-bootstrap: sqlImage.repository and .digest are required" "${base[@]}" --set functionDefaultRevoke.bootstrapJob.sqlImage.digest=$(printf 'sha256:%064d' 1) --set runtimeRole.bootstrapJob.sqlImage.digest= --set privilegedSql.sqlImage.digest=
for n in $PROFILE_NAMES; do
  expect_fail "extraEnv must not set $n" "${on[@]}" --set "worker.extraEnv[0].name=$n" --set "worker.extraEnv[0].value=x"
  expect_fail "components.referee.env must not set $n" "${on[@]}" --set "worker.components.referee.env[0].name=$n" --set "worker.components.referee.env[0].value=x"
done

# 5. values.yaml ends with exactly one newline.
[ "$(tail -c 2 "$CHART/values.yaml" | od -An -c | tr -d ' ')" != '\n\n' ] && [ "$(tail -c 1 "$CHART/values.yaml" | od -An -c | tr -d ' ')" = '\n' ] || err "charts/sessions-pipeline/values.yaml must end with a single newline"

[ $fail -eq 0 ] && echo "search-worker-role render: OK"
exit $fail
