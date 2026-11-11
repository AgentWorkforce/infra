#!/usr/bin/env bash
# kind test: a FRESH CloudNativePG cluster (charts/sessions-pipeline initdb SQL) and an
# EXISTING one (created without the role, then searchWorkerRole.bootstrapJob)
# converge to the same session_directory_search_worker: exact attributes,
# exactly statement_timeout=2s, no membership (the migration owner hoop has no
# membership and no ADMIN). The Job is run twice (idempotent), and once against
# a drifted role (must fail, 55000, changing nothing).
# Then the full release: see "Full flow" below. In it, the runtime-role and
# function-default Jobs (sessions-pipeline #99) run before migrate. A poisoned owner
# function default is refused by the Job (55000) and held by wait-for-role. With
# that wait bypassed, the migrator refuses it (function_boundary_unproven).
# The image must carry the pinned generation (services-generation).
#
# Real CNPG (deps/pins.txt) on kind, and the real services image
# (SERVICES_IMAGE, required), built from the sessions-pipeline commit in
# services-commit. The published image is private, so CI builds it. Local
# images cannot be referenced by registry digest, so the only change to the
# render is that the bootstrap Job's sql image points at that tag
# (imagePullPolicy Never). Everything else is applied as rendered.
# Usage: SERVICES_IMAGE=<local image> ci/sessions-pipeline-search-worker-role/kind.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HERE="$ROOT/ci/sessions-pipeline-search-worker-role"
. "$HERE/logs.sh"
CLUSTER=${CLUSTER:-sessions-pipeline-role}
CTX="kind-$CLUSTER"
k() { kubectl --context "$CTX" "$@"; }

# On any failure: Job/pod state, events, init container and Job logs, and
# readiness probe failures for every namespace this test uses. No Secret
# objects and no env dumps.
diagnose() {
  local rc=$? ns p c
  [ "$rc" -eq 0 ] && return
  echo "::group::diagnostics (exit $rc)"
  for ns in fresh existing flow-existing flow-drifted; do
    k get namespace "$ns" >/dev/null 2>&1 || continue
    echo "=== $ns"
    k -n "$ns" get cluster.postgresql.cnpg.io,jobs,pods,deploy -o wide 2>&1 || true
    k -n "$ns" get events --sort-by=.lastTimestamp 2>&1 | tail -40 || true
    for p in $(k -n "$ns" get pods -o name 2>/dev/null); do
      echo "--- $p"
      k -n "$ns" get "$p" -o jsonpath='{range .status.initContainerStatuses[*]}init {.name} ready={.ready} {.state}{"\n"}{end}{range .status.containerStatuses[*]}ctr {.name} ready={.ready} {.state}{"\n"}{end}' 2>&1 || true
      # --all-containers can fail on a pending main container before emitting
      # its active init container's logs. Fetch init containers explicitly.
      for c in $(k -n "$ns" get "$p" -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null); do
        k -n "$ns" logs "$p" -c "$c" --prefix --tail=40 2>&1 || true
      done
      k -n "$ns" logs "$p" --all-containers --prefix --tail=40 2>&1 || true
      k -n "$ns" get events --field-selector "involvedObject.name=${p#pod/},reason=Unhealthy" -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>&1 | tail -3 || true
    done
  done
  echo "::endgroup::"
}

# Required: the full release runs on the real services image, built from the
# pinned sessions-pipeline commit (services-commit). There is no skip.
[ -n "${SERVICES_IMAGE:-}" ] || { echo "SERVICES_IMAGE is required: a services image built from sessions-pipeline $(cat "$HERE/services-commit")" >&2; exit 2; }
docker image inspect "$SERVICES_IMAGE" >/dev/null || { echo "SERVICES_IMAGE $SERVICES_IMAGE is not a local image" >&2; exit 2; }
if [ -n "${SERVICES_SRC:-}" ]; then
  [ "$(git -C "$SERVICES_SRC" rev-parse HEAD)" = "$(tr -d '[:space:]' < "$HERE/services-commit")" ] || { echo "SERVICES_SRC is not at services-commit" >&2; exit 2; }
fi

kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --wait 120s

trap diagnose EXIT
kind load docker-image "$SERVICES_IMAGE" --name "$CLUSTER"

# CloudNativePG operator from the pins.
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo add minio https://charts.min.io/ >/dev/null 2>&1 || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update cnpg minio open-telemetry >/dev/null
read -r _ chart version values < <(grep '^cnpg-operator ' "$ROOT/deps/pins.txt")
k create namespace cnpg-system --dry-run=client -o yaml | k apply -f -
helm template cnpg "$chart" --version "$version" -f "$ROOT/deps/$values" --namespace cnpg-system --no-hooks --include-crds \
  | k -n cnpg-system apply --server-side --force-conflicts --field-manager=role-test -f -
k -n cnpg-system rollout status deploy --timeout=300s
helm dependency build "$ROOT/charts/sessions-pipeline" >/dev/null

render() { # namespace [helm args]
  local ns=$1; shift
  helm template sessions-pipeline "$ROOT/charts/sessions-pipeline" --namespace "$ns" --no-hooks \
    -f "$ROOT/charts/sessions-pipeline/ci/search-worker-bootstrap-values.yaml" \
    --set hoopdb.cluster.storage.size=1Gi "$@"
}
cluster_of() { yq 'select(.kind == "Cluster")'; }
bootstrap_of() { yq 'select(.metadata.labels."app.kubernetes.io/component" == "search-worker-role-bootstrap")'; }

# FRESH: the chart's Cluster as is (initdb creates the role).
k create namespace fresh --dry-run=client -o yaml | k apply -f -
render fresh | cluster_of | k -n fresh apply --server-side -f -
# EXISTING: the same Cluster without the two role statements (a cluster from before them).
k create namespace existing --dry-run=client -o yaml | k apply -f -
render existing | cluster_of \
  | yq '.spec.bootstrap.initdb.postInitApplicationSQL |= map(select(test("session_directory_search_worker") | not))' \
  | k -n existing apply --server-side -f -
for ns in fresh existing; do k -n "$ns" wait cluster.postgresql.cnpg.io/hoopdb --for=condition=Ready --timeout=600s; done

psql_in() { # ns sql
  local pod
  pod=$(k -n "$1" get pods -l cnpg.io/cluster=hoopdb,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
  k -n "$1" exec -i "$pod" -c postgres -- psql -X -At -d hoopdb -c "$2"
}
[ -z "$(psql_in existing "SELECT 1 FROM pg_roles WHERE rolname = 'session_directory_search_worker'")" ] || { echo "existing cluster already has the role"; exit 1; }

JOB_LOG= JOB_EXIT=
run_job() { # ns suffix -> 0 if the Job completed; sets JOB_LOG and JOB_EXIT (the bootstrap container's exit code)
  local ns=$1 suffix=$2 name
  render "$ns" | bootstrap_of \
    | yq "(select(.kind == \"Job\") | .metadata.name) += \"-$suffix\" | (select(.kind == \"Job\") | .spec.backoffLimit) = 0 | (select(.kind == \"Job\") | .spec.template.spec.initContainers[0].image) = \"$SERVICES_IMAGE\" | (select(.kind == \"Job\") | .spec.template.spec.initContainers[0].imagePullPolicy) = \"Never\"" \
    | k -n "$ns" apply --server-side --force-conflicts -f -
  name=$(render "$ns" | bootstrap_of | yq -r 'select(.kind == "Job") | .metadata.name')-$suffix
  k -n "$ns" wait "job/$name" --for=jsonpath='{.status.conditions[0].status}'=True --timeout=300s >/dev/null || true
  JOB_LOG=$(k -n "$ns" logs "job/$name" -c bootstrap 2>&1 || true)
  echo "$JOB_LOG"
  JOB_EXIT=$(k -n "$ns" get pods -l "batch.kubernetes.io/job-name=$name" -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="bootstrap")].state.terminated.exitCode}')
  [ "$(k -n "$ns" get "job/$name" -o jsonpath='{.status.succeeded}')" = "1" ]
}
# The container ran the file (not an image pull or exec failure), psql reported
# SQLSTATE $1, and the container exited with psql's script-error status 3.
assert_sqlstate() { # sqlstate where
  grep -qF "bootstrap session_directory_search_worker via " <<<"$JOB_LOG" || { echo "$2: the bootstrap container never reached psql"; exit 1; }
  grep -qE "^(psql:[^ ]* )?ERROR:  $1: bootstrap session_directory_search_worker" <<<"$JOB_LOG" || { echo "$2: no SQLSTATE $1 from the bootstrap file"; exit 1; }
  grep -qxF "bootstrap session_directory_search_worker: psql exit 3" <<<"$JOB_LOG" || { echo "$2: psql did not exit 3"; exit 1; }
  [ "$JOB_EXIT" = 3 ] || { echo "$2: bootstrap container exit code is '$JOB_EXIT', want 3"; exit 1; }
}

run_job existing first || { echo "bootstrap Job failed on the existing cluster"; exit 1; }
run_job existing again || { echo "bootstrap Job is not idempotent"; exit 1; }

CHECK="
SELECT 'attrs', rolcanlogin, rolinherit, rolbypassrls, rolsuper, rolcreaterole, rolcreatedb, rolreplication FROM pg_roles WHERE rolname = 'session_directory_search_worker';
SELECT 'settings', s.setdatabase, s.setconfig FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole WHERE r.rolname = 'session_directory_search_worker';
SELECT 'members', count(*) FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid JOIN pg_roles u ON u.oid = m.member WHERE 'session_directory_search_worker' IN (g.rolname, u.rolname);
SELECT 'hoop', count(*) FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid JOIN pg_roles u ON u.oid = m.member WHERE g.rolname = 'session_directory_search_worker' AND u.rolname = 'hoop';
"
want=$'attrs|f|f|f|f|f|f|f\nsettings|0|{statement_timeout=2s}\nmembers|0\nhoop|0'
fresh=$(psql_in fresh "$CHECK"); existing=$(psql_in existing "$CHECK")
echo "fresh:";    echo "$fresh"
echo "existing:"; echo "$existing"
[ "$fresh" = "$want" ] || { echo "fresh cluster does not match the spec"; exit 1; }
[ "$existing" = "$fresh" ] || { echo "fresh and existing clusters do not converge"; exit 1; }

# The Job never alters a drifted role: it fails (55000) and changes nothing.
psql_in existing "ALTER ROLE session_directory_search_worker SET statement_timeout = '3s'" >/dev/null
if run_job existing drifted; then echo "bootstrap Job accepted a drifted role"; exit 1; fi
assert_sqlstate 55000 "drifted role"
[ "$(psql_in existing "SELECT s.setconfig FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole WHERE r.rolname = 'session_directory_search_worker'")" = "{statement_timeout=3s}" ] \
  || { echo "the failed Job changed the role"; exit 1; }
echo "search-worker-role kind: role OK (fresh and existing converge; idempotent; drift refused with 55000, exit 3)"

# ---------------------------------------------------------------------------
# Full flow: the whole umbrella release, as Alchemy applies it, on the
# services image: bootstrap -> migrate (wait-for-role, phase 1 verify,
# migrations, phase 2 verify) -> workloads ready.
# ---------------------------------------------------------------------------
k delete namespace fresh existing --wait=false >/dev/null 2>&1 || true
IMG_REPO=${SERVICES_IMAGE%:*} IMG_TAG=${SERVICES_IMAGE##*:}
# The three privileged in-cluster SQL Jobs (search Worker, runtime role, function default).
BOOT_SEL='.kind == "Job" and (.metadata.labels."app.kubernetes.io/component" == "search-worker-role-bootstrap" or .metadata.labels."app.kubernetes.io/component" == "hoopdb-runtime-role-bootstrap" or .metadata.labels."app.kubernetes.io/component" == "hoopdb-function-default-revoke")'
full_render() { # ns [helm args]
  local ns=$1; shift
  helm template sessions-pipeline "$ROOT/charts/sessions-pipeline" --namespace "$ns" --no-hooks "$@" \
    -f "$ROOT/charts/sessions-pipeline/ci/kind-values.yaml" \
    --set global.imageRegistry= --set hoopdb.cluster.storage.size=1Gi --set otel.enabled=false --set global.otel.endpoint= \
    --set "worker.image.repository=$IMG_REPO" --set "worker.image.tag=$IMG_TAG" --set worker.image.digest= \
    --set "alleyoop.image.repository=$IMG_REPO" --set "alleyoop.image.tag=$IMG_TAG" --set alleyoop.image.digest= \
    --set searchWorkerRole.bootstrapJob.enabled=true \
    --set "privilegedSql.sqlImage.repository=$IMG_REPO" \
    --set "privilegedSql.sqlImage.digest=sha256:$(printf '%064d' 1)" \
    | yq "(select($BOOT_SEL) | .spec.template.spec.initContainers[0]) |= (.image = \"$SERVICES_IMAGE\" | .imagePullPolicy = \"Never\")"
  # The only change to the render: a local image cannot be referenced by
  # registry digest, so the bootstrap Jobs' sql image points at the same tag.
}
is_boot_job="select($BOOT_SEL)"
not_boot_job="select(($BOOT_SEL) | not)"
RT=sessions_pipeline_runtime
prepare_ns() { # ns with_role(fresh|absent|drifted)
  local ns=$1
  k create namespace "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n "$ns" create secret generic sessions-pipeline-locker --from-literal=rootUser=locker --from-literal=rootPassword=locker-kind-only \
    --from-literal=SUMMARY_MASTER_KEYS="kind1:$(openssl rand -hex 32)" --from-literal=JWKS_JSON='{"keys":[]}' \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  if [ "$2" = fresh ]; then full_render "$ns" | cluster_of | k -n "$ns" apply --server-side -f - >/dev/null
  else full_render "$ns" | cluster_of \
    | yq '.spec.bootstrap.initdb.postInitApplicationSQL |= map(select(test("session_directory_search_worker") | not))' \
    | k -n "$ns" apply --server-side -f - >/dev/null; fi
  k -n "$ns" wait cluster.postgresql.cnpg.io/hoopdb --for=condition=Ready --timeout=600s >/dev/null
  if [ "$2" = drifted ]; then
    psql_in "$ns" "CREATE ROLE session_directory_search_worker NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION" >/dev/null
    psql_in "$ns" "ALTER ROLE session_directory_search_worker SET statement_timeout = '3s'" >/dev/null
  fi
}
app_ready() { # ns -> total readyReplicas over the four app Deployments
  k -n "$1" get deploy -l 'app.kubernetes.io/name in (worker,session-ingest-api)' -o json | jq '[.items[].status.readyReplicas // 0] | add // 0'
}
app_count() { k -n "$1" get deploy -l 'app.kubernetes.io/name in (worker,session-ingest-api)' -o name | wc -l; }
job_name() { k -n "$1" get jobs -l "app.kubernetes.io/component=$2" -o jsonpath='{.items[0].metadata.name}'; }
pod_of() { k -n "$1" get pods -l "batch.kubernetes.io/job-name=$2" -o jsonpath='{.items[0].metadata.name}'; }
cstat() { # ns pod jsonpath-under-status
  k -n "$1" get pod "$2" -o jsonpath="{.status.$3}"
}
epoch() { date -d "$1" +%s; }

# The image's migration generation: readiness needs PASS for exactly this.
gen=$(docker run --rm --entrypoint bun "$SERVICES_IMAGE" src/hoopdb/migrate.ts --generation | tr -d '[:space:]')
[[ "$gen" =~ ^[0-9a-f]{64}$ ]] || { echo "cannot read the image's migration generation ($gen)"; exit 1; }
# The image is the pinned one: its generation is the reviewed one (services-generation).
[ "$gen" = "$(tr -d '[:space:]' < "$HERE/services-generation")" ] || { echo "image generation $gen != pinned $(cat "$HERE/services-generation")"; exit 1; }
echo "services image: source $(cat "$HERE/services-commit"), generation $gen (pinned)"

# 1. EXISTING cluster without the role. Apply everything but the bootstrap
# Job and hold it back for a window: migrate must wait, workloads stay unready.
prepare_ns flow-existing absent
[ -z "$(psql_in flow-existing "SELECT 1 FROM pg_roles WHERE rolname IN ('session_directory_search_worker', '$RT')")" ] || { echo "flow-existing: a role is present before bootstrap"; exit 1; }
full_render flow-existing | yq "$not_boot_job" | k -n flow-existing apply --server-side --force-conflicts --field-manager=role-test -f - >/dev/null
[ "$(app_count flow-existing)" = 4 ] || { echo "flow-existing: expected 4 app Deployments"; exit 1; }
mj=$(job_name flow-existing hoopdb-migrate)
k -n flow-existing wait --for=condition=complete job -l app.kubernetes.io/component=locker-init --timeout=300s >/dev/null
for i in $(seq 1 12); do  # 120s
  sleep 10
  [ "$(k -n flow-existing get "job/$mj" -o jsonpath='{.status.succeeded}')" != 1 ] || { echo "flow-existing: migrate completed before the bootstrap ran"; exit 1; }
  [ "$(app_ready flow-existing)" = 0 ] || { echo "flow-existing: a workload became ready before bootstrap+migrate"; exit 1; }
done
mp=$(pod_of flow-existing "$mj")
[ -z "$(cstat flow-existing "$mp" 'containerStatuses[?(@.name=="migrate")].state.running')$(cstat flow-existing "$mp" 'containerStatuses[?(@.name=="migrate")].state.terminated')" ] \
  || { echo "flow-existing: the migrate container started while the role was absent"; exit 1; }
log_matches -F "wait-for-role: waiting for session_directory_search_worker $RT + owner function default" k -n flow-existing logs "$mp" -c wait-for-role || { echo "flow-existing: wait-for-role did not wait for the roles and the function default"; exit 1; }
echo "flow-existing: held 120s without the bootstrap: migrate waiting in wait-for-role, 0 app pods ready"

# 2. Now the bootstrap Job. It runs; migrate follows; workloads become ready.
full_render flow-existing | yq "$is_boot_job" | k -n flow-existing apply --server-side --force-conflicts --field-manager=role-test -f - >/dev/null
bj=$(job_name flow-existing search-worker-role-bootstrap); rj=$(job_name flow-existing hoopdb-runtime-role-bootstrap); fj=$(job_name flow-existing hoopdb-function-default-revoke)
k -n flow-existing wait --for=condition=complete "job/$bj" --timeout=300s >/dev/null || { k -n flow-existing logs "job/$bj" -c bootstrap; echo "flow-existing: bootstrap failed"; exit 1; }
k -n flow-existing wait --for=condition=complete "job/$rj" --timeout=300s >/dev/null || { k -n flow-existing logs "job/$rj" -c bootstrap; echo "flow-existing: runtime role bootstrap failed"; exit 1; }
k -n flow-existing wait --for=condition=complete "job/$fj" --timeout=300s >/dev/null || { k -n flow-existing logs "job/$fj" -c bootstrap; echo "flow-existing: function default bootstrap failed"; exit 1; }
k -n flow-existing wait --for=condition=complete "job/$mj" --timeout=900s >/dev/null || { k -n flow-existing logs "job/$mj" --all-containers; echo "flow-existing: migrate failed"; exit 1; }
k -n flow-existing rollout status deploy -l 'app.kubernetes.io/name in (worker,session-ingest-api)' --timeout=600s >/dev/null
[ "$(app_ready flow-existing)" -ge 4 ] || { echo "flow-existing: workloads not ready after bootstrap+migrate"; exit 1; }
bp=$(pod_of flow-existing "$bj"); mp=$(pod_of flow-existing "$mj")
b_start=$(epoch "$(cstat flow-existing "$bp" 'containerStatuses[?(@.name=="bootstrap")].state.terminated.startedAt')")
w_end=$(epoch "$(cstat flow-existing "$mp" 'initContainerStatuses[?(@.name=="wait-for-role")].state.terminated.finishedAt')")
m_start=$(epoch "$(cstat flow-existing "$mp" 'containerStatuses[?(@.name=="migrate")].state.terminated.startedAt')")
[ "$w_end" -ge "$b_start" ] && [ "$m_start" -ge "$b_start" ] || { echo "flow-existing: order violated (bootstrap start $b_start, wait end $w_end, migrate start $m_start)"; exit 1; }
r_start=$(epoch "$(cstat flow-existing "$(pod_of flow-existing "$rj")" 'containerStatuses[?(@.name=="bootstrap")].state.terminated.startedAt')")
[ "$w_end" -ge "$r_start" ] && [ "$m_start" -ge "$r_start" ] || { echo "flow-existing: order violated (runtime role bootstrap start $r_start, wait end $w_end, migrate start $m_start)"; exit 1; }
# The runtime role as hoopdb_runtime_role.sql leaves it, and as migrate accepted it:
# no TEMP (PUBLIC's revoked too), CONNECT, least-privilege attributes, no memberships.
RTCHECK="
SELECT 'attrs', rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls FROM pg_roles WHERE rolname = '$RT';
SELECT 'connect', has_database_privilege('$RT', 'hoopdb', 'CONNECT');
SELECT 'temp', has_database_privilege('$RT', 'hoopdb', 'TEMPORARY');
SELECT 'public_temp', EXISTS (SELECT 1 FROM pg_database d, aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a WHERE d.datname = 'hoopdb' AND a.grantee = 0 AND a.privilege_type = 'TEMPORARY');
SELECT 'members', count(*) FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member WHERE r.rolname = '$RT';
"
rt_got=$(psql_in flow-existing "$RTCHECK")
[ "$rt_got" = $'attrs|t|f|f|f|f|f\nconnect|t\ntemp|f\npublic_temp|f\nmembers|0' ] || { echo "$rt_got"; echo "flow-existing: runtime role does not match (LOGIN, CONNECT, no TEMP, PUBLIC without TEMP, no memberships)"; exit 1; }
log_matches -xF "bootstrap hoopdb runtime role $RT: psql exit 0" k -n flow-existing logs "$(pod_of flow-existing "$rj")" -c bootstrap || { echo "flow-existing: runtime role Job did not report psql exit 0"; exit 1; }
echo "flow-existing: runtime role $RT: LOGIN, CONNECT yes, TEMP no (PUBLIC revoked), no memberships; bootstrap $r_start <= migrate $m_start"
# The function boundary as hoopdb_function_default_revoke.sql leaves it: the owner's
# and every superuser's global function default is exactly {<self>:EXECUTE}.
f_start=$(epoch "$(cstat flow-existing "$(pod_of flow-existing "$fj")" 'containerStatuses[?(@.name=="bootstrap")].state.terminated.startedAt')")
[ "$w_end" -ge "$f_start" ] && [ "$m_start" -ge "$f_start" ] || { echo "flow-existing: order violated (function default bootstrap start $f_start, wait end $w_end, migrate start $m_start)"; exit 1; }
log_matches -xF "bootstrap hoopdb function default for hoop: psql exit 0" k -n flow-existing logs "$(pod_of flow-existing "$fj")" -c bootstrap || { echo "flow-existing: function default Job did not report psql exit 0"; exit 1; }
FDCHECK="SELECT r.rolname, (SELECT array_agg(a.grantee::regrole::text || ':' || a.privilege_type || ':' || a.is_grantable::text) FROM pg_default_acl d, aclexplode(d.defaclacl) a WHERE d.defaclrole = r.oid AND d.defaclnamespace = 0 AND d.defaclobjtype = 'f') FROM pg_roles r WHERE r.rolname = 'hoop' OR r.rolsuper ORDER BY 1"
FDACL="SELECT d.defaclacl FROM pg_default_acl d JOIN pg_roles r ON r.oid = d.defaclrole WHERE r.rolname = 'hoop' AND d.defaclnamespace = 0 AND d.defaclobjtype = 'f'"
fd_got=$(psql_in flow-existing "$FDCHECK")
[ "$fd_got" = $'hoop|{hoop:EXECUTE:false}\npostgres|{postgres:EXECUTE:false}' ] || { echo "$fd_got"; echo "flow-existing: owner/superuser function defaults are not exactly {<self>:EXECUTE}"; exit 1; }
grep -qF '"error_code":"function_boundary_unproven"' <<<"$(k -n flow-existing logs "$mp" -c migrate)" && { echo "flow-existing: migrate reported function_boundary_unproven"; exit 1; }
echo "flow-existing: function default hoop + postgres = {<self>:EXECUTE}; bootstrap $f_start <= migrate $m_start; migrate's global-default-revoke gate passed"
mlog=$(k -n flow-existing logs "$mp" -c migrate)
# Phase 1 passed; phase 2 passed and recorded PASS for this image's generation.
grep '"message":"role check passed"' <<<"$mlog" | grep -qF '"reason":"bootstrap:session_directory_search_worker"' || { echo "flow-existing: migrate did not pass phase 1"; exit 1; }
grep '"message":"role validation pending"' <<<"$mlog" | grep -qF "\"reason\":\"$gen\"" || { echo "flow-existing: migrate did not mark validation pending for $gen"; exit 1; }
grep '"message":"role validation passed"' <<<"$mlog" | grep -qF "\"reason\":\"$gen\"" || { echo "flow-existing: migrate did not pass phase 2 for $gen"; exit 1; }
[ "$(psql_in flow-existing "$CHECK")" = "$want" ] || { echo "flow-existing: role does not match the spec after the full flow"; exit 1; }
echo "flow-existing: bootstrap started $b_start <= wait-for-role released $w_end <= migrate started $m_start; phase 1 + phase 2 passed; $(app_ready flow-existing) app pods ready"

# 3. PHASE-2-ONLY failure after the ledger is complete (the crash window).
# Readiness reads the role validation marker on every probe: ready only while it
# is 'pass' for the image's own generation (sessions-pipeline #96).
MARKER="SELECT status || '|' || generation FROM sessions.__96bulls_role_validation WHERE name = 'session_directory_search_worker'"
LEDGER="SELECT count(*) FROM sessions.__96bulls_migrations"
[ "$(psql_in flow-existing "$MARKER")" = "pass|$gen" ] || { echo "phase2: marker is not pass for $gen after a good migrate: $(psql_in flow-existing "$MARKER")"; exit 1; }
ledger_before=$(psql_in flow-existing "$LEDGER")
# A direct table privilege: phase 1 ignores grants, phase 2's allowlist refuses it.
psql_in flow-existing "GRANT SELECT ON sessions.session_index TO session_directory_search_worker" >/dev/null
# The next deploy's migrate (a new content-addressed Job; no retries).
full_render flow-existing --set worker.migrations.activeDeadlineSeconds=3599 \
  | yq 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate") | .spec.backoffLimit = 0' \
  | k -n flow-existing apply --server-side --force-conflicts --field-manager=role-test -f - >/dev/null
mj2=$(k -n flow-existing get jobs -l app.kubernetes.io/component=hoopdb-migrate -o json | jq -r --arg old "$mj" '[.items[] | select(.metadata.name != $old)][0].metadata.name')
[ -n "$mj2" ] && [ "$mj2" != null ] || { echo "phase2: no second migrate Job"; exit 1; }
k -n flow-existing wait --for=condition=failed "job/$mj2" --timeout=600s >/dev/null || { echo "phase2: the second migrate did not fail"; exit 1; }
mlog=$(k -n flow-existing logs "$(pod_of flow-existing "$mj2")" -c migrate 2>&1)
grep '"message":"role check passed"' <<<"$mlog" | grep -qF '"reason":"bootstrap:session_directory_search_worker"' || { echo "phase2: phase 1 did not pass (the fault must be phase-2-only)"; exit 1; }
grep '"message":"role check failed"' <<<"$mlog" | grep -F '"reason":"verify:session_directory_search_worker"' | grep -qF '"error_code":"55000"' \
  || { echo "$mlog" | tail -5; echo "phase2: phase 2 did not refuse the grant with 55000"; exit 1; }
[ "$(psql_in flow-existing "$LEDGER")" = "$ledger_before" ] || { echo "phase2: the ledger changed"; exit 1; }
[ "$(psql_in flow-existing "$MARKER")" = "pending|$gen" ] || { echo "phase2: marker is not pending for $gen: $(psql_in flow-existing "$MARKER")"; exit 1; }
# Running pods drop out (probe re-reads the marker) and new pods never become ready.
for i in $(seq 1 18); do [ "$(app_ready flow-existing)" = 0 ] && break; sleep 10; done
[ "$(app_ready flow-existing)" = 0 ] || { echo "phase2: running workloads stayed ready after the phase 2 failure"; exit 1; }
k -n flow-existing delete pods -l 'app.kubernetes.io/name in (worker,session-ingest-api)' --wait=false >/dev/null
for i in $(seq 1 9); do sleep 10; [ "$(app_ready flow-existing)" = 0 ] || { echo "phase2: a workload became ready while phase 2 fails"; exit 1; }; done
echo "flow-existing phase2: ledger complete ($ledger_before rows, unchanged); phase 1 passed, phase 2 55000; marker pending|${gen:0:12}; 0 app pods ready (running and restarted, 90s)"

# 4. TEMP on the runtime role: the migrator refuses it before writing anything.
psql_in flow-existing "REVOKE SELECT ON sessions.session_index FROM session_directory_search_worker" >/dev/null
psql_in flow-existing "GRANT TEMPORARY ON DATABASE hoopdb TO $RT" >/dev/null
full_render flow-existing --set worker.migrations.activeDeadlineSeconds=3598 \
  | yq 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate") | .spec.backoffLimit = 0' \
  | k -n flow-existing apply --server-side --force-conflicts --field-manager=role-test -f - >/dev/null
mj3=$(k -n flow-existing get jobs -l app.kubernetes.io/component=hoopdb-migrate -o json | jq -r --arg a "$mj" --arg b "$mj2" '[.items[] | select(.metadata.name != $a and .metadata.name != $b)][0].metadata.name')
k -n flow-existing wait --for=condition=failed "job/$mj3" --timeout=600s >/dev/null || { echo "temp: migrate accepted a runtime role with TEMPORARY"; exit 1; }
tlog=$(k -n flow-existing logs "$(pod_of flow-existing "$mj3")" -c migrate 2>&1)
grep -qF '"error_code":"runtime_role_unsafe"' <<<"$tlog" || { echo "$tlog" | tail -5; echo "temp: migrate did not refuse with runtime_role_unsafe"; exit 1; }
[ "$(psql_in flow-existing "$LEDGER")" = "$ledger_before" ] || { echo "temp: the ledger changed"; exit 1; }
for i in $(seq 1 6); do sleep 10; [ "$(app_ready flow-existing)" = 0 ] || { echo "temp: a workload became ready"; exit 1; }; done
echo "flow-existing temp: runtime role with TEMPORARY refused (runtime_role_unsafe), ledger unchanged, 0 app pods ready"

# 5. A poisoned owner function default (EXECUTE to authenticated). The function
# default Job refuses it (55000, pg_default_acl unchanged); wait-for-role holds
# migrate; and with that wait bypassed (test-only edit of the rendered Job), the
# migrator itself refuses with function_boundary_unproven before any write.
psql_in flow-existing "REVOKE TEMPORARY ON DATABASE hoopdb FROM $RT" >/dev/null
psql_in flow-existing "ALTER DEFAULT PRIVILEGES FOR ROLE hoop GRANT EXECUTE ON FUNCTIONS TO authenticated" >/dev/null
acl_before=$(psql_in flow-existing "$FDACL")
full_render flow-existing | yq 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-function-default-revoke") | .metadata.name += "-poisoned" | .spec.backoffLimit = 0' \
  | k -n flow-existing apply --server-side --force-conflicts --field-manager=role-test -f - >/dev/null
k -n flow-existing wait --for=condition=failed "job/$fj-poisoned" --timeout=300s >/dev/null || { echo "poisoned: the function default Job accepted a poisoned default"; exit 1; }
plog=$(k -n flow-existing logs "job/$fj-poisoned" -c bootstrap 2>&1)
grep -qF "55000: function default bootstrap refused (nothing changed): hoop has a poisoned function default (authenticated EXECUTE)" <<<"$plog" || { echo "$plog" | tail -5; echo "poisoned: no 55000 refusal naming the poisoned default"; exit 1; }
grep -qxF "bootstrap hoopdb function default for hoop: psql exit 3" <<<"$plog" || { echo "poisoned: psql did not exit 3"; exit 1; }
[ "$(psql_in flow-existing "$FDACL")" = "$acl_before" ] || { echo "poisoned: the refused Job changed pg_default_acl"; exit 1; }
full_render flow-existing --set worker.migrations.activeDeadlineSeconds=3597 \
  | yq 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate") | .spec.backoffLimit = 0' \
  | k -n flow-existing apply --server-side --force-conflicts --field-manager=role-test -f - >/dev/null
mj4=$(k -n flow-existing get jobs -l app.kubernetes.io/component=hoopdb-migrate -o json | jq -r --arg a "$mj" --arg b "$mj2" --arg c "$mj3" '[.items[] | select(.metadata.name != $a and .metadata.name != $b and .metadata.name != $c)][0].metadata.name')
for i in $(seq 1 6); do  # 60s
  sleep 10
  [ -z "$(cstat flow-existing "$(pod_of flow-existing "$mj4")" 'containerStatuses[?(@.name=="migrate")].state.running')$(cstat flow-existing "$(pod_of flow-existing "$mj4")" 'containerStatuses[?(@.name=="migrate")].state.terminated')" ] \
    || { echo "poisoned: migrate started while the owner function default was poisoned"; exit 1; }
done
log_matches -F "+ owner function default" k -n flow-existing logs "$(pod_of flow-existing "$mj4")" -c wait-for-role || { echo "poisoned: wait-for-role did not wait for the function default"; exit 1; }
k -n flow-existing delete job "$mj4" --wait=true >/dev/null
full_render flow-existing --set worker.migrations.activeDeadlineSeconds=3596 \
  | yq 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate") | .spec.backoffLimit = 0 | (.spec.template.spec.initContainers[0].env[] | select(.name == "FUNCTION_DEFAULT") | .value) = "false"' \
  | k -n flow-existing apply --server-side --force-conflicts --field-manager=role-test -f - >/dev/null
mj5=$(k -n flow-existing get jobs -l app.kubernetes.io/component=hoopdb-migrate -o json | jq -r --arg a "$mj" --arg b "$mj2" --arg c "$mj3" '[.items[] | select(.metadata.name != $a and .metadata.name != $b and .metadata.name != $c)][0].metadata.name')
k -n flow-existing wait --for=condition=failed "job/$mj5" --timeout=600s >/dev/null || { echo "poisoned: migrate accepted a poisoned owner function default"; exit 1; }
flog=$(k -n flow-existing logs "$(pod_of flow-existing "$mj5")" -c migrate 2>&1)
grep -qF '"error_code":"function_boundary_unproven"' <<<"$flog" || { echo "$flog" | tail -5; echo "poisoned: migrate did not refuse with function_boundary_unproven"; exit 1; }
[ "$(psql_in flow-existing "$LEDGER")" = "$ledger_before" ] || { echo "poisoned: the ledger changed"; exit 1; }
for i in $(seq 1 3); do sleep 10; [ "$(app_ready flow-existing)" = 0 ] || { echo "poisoned: a workload became ready"; exit 1; }; done
echo "flow-existing poisoned: function default Job 55000 (exit 3, pg_default_acl unchanged); migrate held 60s in wait-for-role; with the wait bypassed, migrate refused function_boundary_unproven; ledger unchanged; 0 app pods ready"
k delete namespace flow-existing --wait=false >/dev/null

# 3. DRIFTED: a role that differs from the spec, then the whole release at
# once. Both Jobs fail with 55000, the role is unchanged, nothing becomes ready.
prepare_ns flow-drifted drifted
full_render flow-drifted \
  | yq '(select(.kind == "Job" and (.metadata.labels."app.kubernetes.io/component" == "search-worker-role-bootstrap" or .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate")) | .spec.backoffLimit) = 0' \
  | k -n flow-drifted apply --server-side --force-conflicts --field-manager=role-test -f - >/dev/null
bj=$(job_name flow-drifted search-worker-role-bootstrap); mj=$(job_name flow-drifted hoopdb-migrate)
k -n flow-drifted wait --for=condition=failed "job/$bj" --timeout=300s >/dev/null || { echo "flow-drifted: bootstrap did not fail"; exit 1; }
JOB_LOG=$(k -n flow-drifted logs "job/$bj" -c bootstrap 2>&1); echo "$JOB_LOG"
JOB_EXIT=$(cstat flow-drifted "$(pod_of flow-drifted "$bj")" 'containerStatuses[?(@.name=="bootstrap")].state.terminated.exitCode')
assert_sqlstate 55000 "flow-drifted (full flow)"
k -n flow-drifted wait --for=condition=failed "job/$mj" --timeout=600s >/dev/null || { echo "flow-drifted: migrate did not fail"; exit 1; }
mlog=$(k -n flow-drifted logs "$(pod_of flow-drifted "$mj")" -c migrate 2>&1)
grep '"message":"role check failed"' <<<"$mlog" | grep -F '"reason":"bootstrap:session_directory_search_worker"' | grep -qF '"error_code":"55000"' \
  || { echo "$mlog" | tail -5; echo "flow-drifted: migrate did not refuse the role with 55000"; exit 1; }
for i in $(seq 1 6); do sleep 10; [ "$(app_ready flow-drifted)" = 0 ] || { echo "flow-drifted: a workload became ready"; exit 1; }; done
[ "$(psql_in flow-drifted "SELECT s.setconfig FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole WHERE r.rolname = 'session_directory_search_worker'")" = "{statement_timeout=3s}" ] || { echo "flow-drifted: the role was changed"; exit 1; }
echo "flow-drifted: bootstrap 55000 (exit 3), migrate 55000, role unchanged, 0 app pods ready after 60s"
k delete namespace flow-drifted --wait=false >/dev/null
echo "search-worker-role kind: FULL FLOW OK"
