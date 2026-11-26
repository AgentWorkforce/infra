#!/usr/bin/env bash
# Runs diagnose-install.py's in-cluster database checks for real: an RDS-shaped
# PostgreSQL with TLS in Docker, the real rds-setup.sh pre to create the
# databases, logins and Secret files, then the diagnostic's Job run as a
# container with the pinned psql image, its Secret and rds-ca mounts and its
# exact command, on a network the operator machine can't resolve.
#
# kubectl is faked (as in scripts/selfhost/tests/rds-setup-postgres-test.sh): a
# Secret is the secret-files directory rds-setup.sh pre wrote, a Job is a
# container. Checked: --in-cluster connects with sslmode=verify-full through
# the rds-ca CA, reports the same checks as a local run, never puts a password
# in the Job, its log, stdout or the report, and deletes its Job; without
# --in-cluster, an unreachable database falls back to the Job automatically.
#
# Opt-in, not part of CI: needs Docker, openssl, jq and a sessions-pipeline
# checkout for the bootstrap SQL rds-setup.sh pre runs.
#
#   HOOPDB_BOOTSTRAP_DIR=../sessions-pipeline/supabase/bootstrap \
#     scripts/support/tests/diagnose-in-cluster-postgres-test.sh
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${TEST_DIR}/../../.." && pwd)"
DIAG="$REPO/scripts/support/diagnose-install.py"
RDS_SETUP="$REPO/scripts/selfhost/rds-setup.sh"
: "${HOOPDB_BOOTSTRAP_DIR:?set HOOPDB_BOOTSTRAP_DIR to sessions-pipeline/supabase/bootstrap}"
HOOPDB_BOOTSTRAP_DIR="$(cd -- "$HOOPDB_BOOTSTRAP_DIR" && pwd)"
for t in docker openssl jq python3; do command -v "$t" >/dev/null || { echo "$t is required" >&2; exit 2; }; done
SERVER_IMAGE="${PG_SERVER_IMAGE:-pgvector/pgvector@sha256:b513c48566e4777cd3370451400000c78eda6a08131d68f4c31d4a76f27bd8fd}"
PSQL_IMAGE="$(sed -n 's/^PSQL_IMAGE="\${PSQL_IMAGE:-\(.*\)}"$/\1/p' "$RDS_SETUP")"

TMP_BASE="${AGENT_TMP_DIR:-${HOME}/.agent-tmp}"
mkdir -p "$TMP_BASE"
ROOT="$(mktemp -d "$TMP_BASE/diag-in-cluster.XXXXXX")"
NET="diag-in-cluster-$$"
PG="rds-fixture-$$.db.internal"   # resolvable only on the Docker network
cleanup() {
  docker ps -aq --filter "label=diag-in-cluster=$$" | xargs docker rm -fv >/dev/null 2>&1 || true
  docker rm -fv "$PG" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$ROOT"
}
trap cleanup EXIT
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }

MASTER_PW="$(openssl rand -hex 16)"
MOCK_BIN="$ROOT/bin"; J="$ROOT/jobs"; mkdir -p "$MOCK_BIN" "$J" "$ROOT/sql" "$ROOT/certs" "$ROOT/rds-ca"

# TLS like RDS: the server's certificate names its endpoint and chains to the
# CA in the rds-ca ConfigMap.
( cd "$ROOT/certs"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 2 -subj /CN=fixture-rds-ca 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=$PG" 2>/dev/null
  printf 'subjectAltName=DNS:%s\n' "$PG" >ext
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 2 -extfile ext 2>/dev/null
  chmod 0644 ca.crt server.crt server.key )
cp "$ROOT/certs/ca.crt" "$ROOT/rds-ca/ca.crt"; chmod -R a+rX "$ROOT/rds-ca"

cat >"$MOCK_BIN/aws" <<MOCK
#!/usr/bin/env bash
printf '{"username":"postgres","password":"%s"}\n' "$MASTER_PW"
MOCK
cat >"$MOCK_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [[ "$prev" == -o ]] && out="$a"; prev="$a"; done
cat "$MOCK_CA" >"$out"
MOCK
# Fake kubectl. rds-setup.sh's calls (create secret/configmap, apply a Job, get
# job status, logs) as in rds-setup-postgres-test.sh; the diagnostic's calls
# (get secret, create -f - a Job, get job, logs job/, delete job) against
# containers. Every argv and every Job manifest is recorded.
cat >"$MOCK_BIN/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
J="$MOCK_JOBS"
printf '%s\n' "$*" >>"$J/argv.log"
args=" $* "
name_after() { local prev="" a; for a in "${@:2}"; do [[ "$prev" == "$1" ]] && { printf '%s' "$a"; return; }; prev="$a"; done; }
case "$args" in
  *" create secret generic "*)
    n="$(name_after generic "$@")"; rm -rf "$J/secret-$n"; mkdir -p "$J/secret-$n"
    for a in "$@"; do [[ "$a" == --from-file=* ]] && cp -R "${a#--from-file=}/." "$J/secret-$n/"; done
    exit 0 ;;
  *" create configmap "*)
    n="$(name_after configmap "$@")"; mkdir -p "$J/cm-$n"
    for a in "$@"; do case "$a" in --from-file=*=*) f="${a#--from-file=}"; cp "${f#*=}" "$J/cm-$n/${f%%=*}" ;; esac; done
    chmod 0755 "$J/cm-$n"; find "$J/cm-$n" -type f -exec chmod 0644 {} +
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: %s}\n' "$n"; exit 0 ;;
  *" apply -f - "*)   # rds-setup.sh's Jobs: run to completion, as its own test does
    doc="$(cat)"
    if jq -e '.kind == "Job"' <<<"$doc" >/dev/null 2>&1; then
      n="$(jq -r .metadata.name <<<"$doc")"
      secret="$(jq -r '.spec.template.spec.containers[0].envFrom[0].secretRef.name' <<<"$doc")"
      image="$(jq -r '.spec.template.spec.containers[0].image' <<<"$doc")"
      envs=(-e HOME=/tmp -e PGHOST="$MOCK_PGHOST" -e PGPORT=5432 -e PGSSLMODE=disable)
      for f in "$J/secret-$secret"/*; do envs+=(-e "$(basename "$f")=$(cat "$f")"); done
      rc=0
      docker run --rm --network "$MOCK_NET" --user 26:26 "${envs[@]}" \
        -v "$MOCK_SQL:/sql:ro" -v "$J/cm-$n-run:/run-script:ro" "$image" sh /run-script/run.sh \
        >"$J/log-$n" 2>&1 || rc=$?
      printf '%s' "$rc" >"$J/rc-$n"
    fi
    exit 0 ;;
  *" get job "*" -o jsonpath={.status.succeeded} "*)
    n="$(name_after job "$@")"; [[ "$(cat "$J/rc-$n" 2>/dev/null)" == 0 ]] && printf 1; exit 0 ;;
  *" get job "*" -o jsonpath={.status.failed} "*)
    n="$(name_after job "$@")"; [[ -s "$J/rc-$n" && "$(cat "$J/rc-$n")" != 0 ]] && printf 1; exit 0 ;;
  *" get secret "*" -o json "*)   # the deployed Secrets = the files rds-setup.sh pre wrote
    n="$(name_after secret "$@")"; d="$MOCK_SECRET_FILES/$n"
    [[ -d "$d" ]] || { echo "Error from server (NotFound): secrets \"$n\" not found" >&2; exit 1; }
    for f in "$d"/*; do jq -n --arg k "$(basename "$f")" --arg v "$(base64 <"$f" | tr -d '\n')" '{($k): $v}'; done \
      | jq -s '{kind: "Secret", data: add}'
    exit 0 ;;
  *" create -f - "*)   # the diagnostic's Job: start its pod as a container
    doc="$(cat)"; n="$(jq -r .metadata.name <<<"$doc")"
    printf '%s' "$doc" >"$J/diag-job-$n.json"
    pod='.spec.template.spec'
    image="$(jq -r "$pod.containers[0].image" <<<"$doc")"
    vols=()
    # Secret volumes: only the listed keys, readable by the pod's fsGroup (26).
    while IFS=$'\t' read -r vname secret mount; do
      d="$J/vol-$n-$vname"; mkdir -p "$d"
      for key in $(jq -r --arg v "$vname" "$pod.volumes[] | select(.name == \$v) | .secret.items[].key" <<<"$doc"); do
        [[ -f "$MOCK_SECRET_FILES/$secret/$key" ]] && cp "$MOCK_SECRET_FILES/$secret/$key" "$d/$key"
      done
      chmod -R a+rX "$d"; vols+=(-v "$d:$mount:ro")
    done < <(jq -r "$pod as \$p | \$p.volumes[] | select(.secret) | [.name, .secret.secretName, (.name as \$n | \$p.containers[0].volumeMounts[] | select(.name == \$n) | .mountPath)] | @tsv" <<<"$doc")
    # ConfigMaps: only rds-ca exists in this fixture (the optional cloud-sql-ca is absent).
    while IFS=$'\t' read -r cm mount; do
      [[ "$cm" == rds-ca ]] && vols+=(-v "$MOCK_RDS_CA:$mount:ro")
    done < <(jq -r "$pod as \$p | \$p.volumes[] | select(.configMap) | [.configMap.name, (.name as \$n | \$p.containers[0].volumeMounts[] | select(.name == \$n) | .mountPath)] | @tsv" <<<"$doc")
    envs=()
    while IFS=$'\t' read -r k v; do export "$k=$(printf '%s' "$v" | base64 -d)"; envs+=(-e "$k"); done \
      < <(jq -r "$pod.containers[0].env[] | [.name, (.value | @base64)] | @tsv" <<<"$doc")
    cmd=()
    while IFS= read -r a; do cmd+=("$(printf '%s' "$a" | base64 -d)"); done < <(jq -r "$pod.containers[0].command[] | @base64" <<<"$doc")
    user="$(jq -r "$pod.securityContext.runAsUser" <<<"$doc"):$(jq -r "$pod.securityContext.runAsGroup" <<<"$doc")"
    docker run -d --name "diag-$n" --label "diag-in-cluster=$MOCK_PID" --network "$MOCK_NET" --user "$user" \
      --read-only --tmpfs /tmp:rw,size=16m --cap-drop ALL --security-opt no-new-privileges \
      "${vols[@]}" "${envs[@]}" --entrypoint "${cmd[0]}" "$image" "${cmd[@]:1}" >/dev/null
    echo "job.batch/$n"; exit 0 ;;
  *" get job "*" -o json "*)
    n="$(name_after job "$@")"
    if [[ "$n" == agent-relay-diagnose-db-* ]]; then
      state="$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "diag-$n")"
      case "$state" in
        "exited 0") echo '{"status":{"succeeded":1}}' ;;
        exited*) echo '{"status":{"failed":1}}' ;;
        *) echo '{"status":{"active":1}}' ;;
      esac
    else
      printf '{"metadata":{"name":"%s","labels":{"app.kubernetes.io/instance":"agent-relay","app.kubernetes.io/component":"hoopdb-migrate"}},"status":{"succeeded":1}}\n' "$n"
    fi
    exit 0 ;;
  *" get pods "*) echo '{"items":[]}'; exit 0 ;;
  *" logs job/"*)
    for a in "$@"; do
      if [[ "$a" == job/agent-relay-diagnose-db-* ]]; then docker logs "diag-${a#job/}" 2>/dev/null | tee "$J/diag-log-${a#job/}"
      elif [[ "$a" == job/* ]]; then cat "$J/log-${a#job/}"; fi
    done; exit 0 ;;
  *" delete job "*)
    n="$(name_after job "$@")"; docker rm -f "diag-$n" >/dev/null 2>&1 || true; touch "$J/deleted-$n"; exit 0 ;;
  *" config current-context "*) echo fixture; exit 0 ;;
  *" auth can-i create jobs.batch "*) echo yes; exit 0 ;;
esac
exit 0
MOCK
chmod +x "$MOCK_BIN"/*
cp -R "$HOOPDB_BOOTSTRAP_DIR/." "$ROOT/sql/"; chmod -R a+rX "$ROOT/sql"

docker network create "$NET" >/dev/null
export PATH="$MOCK_BIN:$PATH" MOCK_JOBS="$J" MOCK_NET="$NET" MOCK_PGHOST="$PG" MOCK_SQL="$ROOT/sql" \
  MOCK_CA="$ROOT/certs/ca.crt" MOCK_RDS_CA="$ROOT/rds-ca" MOCK_PID=$$
export AWS_REGION=us-west-2 RDS_HOST="$PG" RDS_ADMIN_SECRET_ARN=arn:aws:secretsmanager:us-west-2:111122223333:secret:fixture
export SERVICES_IMAGE="fixture/sessions-pipeline@sha256:1111111111111111111111111111111111111111111111111111111111111111"
export NAMESPACE=agent-relay KUBE_CONTEXT=fixture JOB_TIMEOUT_SECONDS=120 RELEASE=agent-relay PSQL_IMAGE
export STATE_DIR="$ROOT/state" MOCK_SECRET_FILES="$ROOT/state/secret-files"

# RDS-shaped server: rdsadmin is the only superuser; the master login has
# CREATEROLE/CREATEDB and a NOLOGIN rds_superuser; TLS on with the fixture CA.
docker run -d --name "$PG" --network "$NET" -e POSTGRES_USER=rdsadmin -e POSTGRES_PASSWORD="$(openssl rand -hex 12)" \
  -v "$ROOT/certs:/certs-src:ro" --entrypoint bash "$SERVER_IMAGE" -c \
  'mkdir -p /tmp/certs && cp /certs-src/server.crt /certs-src/server.key /tmp/certs/ && chown postgres /tmp/certs/* && chmod 600 /tmp/certs/server.key && exec docker-entrypoint.sh postgres -c password_encryption=scram-sha-256 -c ssl=on -c ssl_cert_file=/tmp/certs/server.crt -c ssl_key_file=/tmp/certs/server.key' >/dev/null
for i in $(seq 1 60); do
  docker exec "$PG" pg_isready -h 127.0.0.1 -U rdsadmin -d postgres >/dev/null 2>&1 && break
  [[ "$i" != 60 ]] || fail "server did not become ready"; sleep 1
done
sleep 2
docker exec -u root "$PG" sh -c 'for f in /usr/share/postgresql/*/extension/vector.control; do grep -q "^trusted" "$f" || echo "trusted = true" >>"$f"; done'
docker exec -i "$PG" psql -X -q -v ON_ERROR_STOP=1 -U rdsadmin -d postgres >/dev/null <<SQL
CREATE ROLE rds_superuser NOLOGIN;
GRANT pg_monitor, pg_signal_backend, pg_read_all_settings, pg_read_all_stats TO rds_superuser WITH ADMIN OPTION;
CREATE ROLE postgres LOGIN CREATEROLE CREATEDB PASSWORD '$MASTER_PW';
GRANT rds_superuser TO postgres WITH ADMIN OPTION;
GRANT ALL ON DATABASE postgres TO rds_superuser;
SQL
sv="$(docker exec "$PG" psql -XAt -U rdsadmin -d postgres -c 'SHOW server_version' | cut -d' ' -f1)"
echo "# server $sv, psql image ${PSQL_IMAGE%%@*}"

bash "$RDS_SETUP" pre >"$ROOT/pre.log" 2>&1 || { cat "$ROOT/pre.log" >&2; fail "rds-setup.sh pre failed"; }
[[ -d "$MOCK_SECRET_FILES/agent-relay-secrets" ]] || fail "pre wrote no secret-files"
pass "rds-setup.sh pre created the databases, logins and Secret files"
# Valid JSON the redaction must not depend on: escaped slashes in the wrapped URL
# and a sibling password field (the read API Secret's optional clickhouse block).
f="$MOCK_SECRET_FILES/agent-relay-read-api/RELAYHISTORY_READ_API_SECRET"
SIBLING_PW="sibling-$(openssl rand -hex 8)"
jq -c --arg pw "$SIBLING_PW" '. + {clickhouse: {password: $pw}}' "$f" | sed 's#/#\\/#g' >"$f.new" && mv "$f.new" "$f"
# A query parameter the contract doesn't allow, carrying a secret: refused, never logged.
QUERY_PW="query-$(openssl rand -hex 8)"
g="$MOCK_SECRET_FILES/agent-relay-secrets/database-url"; printf '%s&sslpassword=%s' "$(cat "$g")" "$QUERY_PW" >"$g.new" && mv "$g.new" "$g"
grep -q 'postgresql:\\/\\/' "$f" || fail "fixture: escaped slashes not written"

# The operator machine can't resolve the database (the split-VPN case), so
# --in-cluster is the only way in.
cd "$ROOT"
run_diag() { # name args...
  local name="$1"; shift
  python3 "$DIAG" --context fixture --namespace agent-relay --release agent-relay --values --no-s3-check \
    --output "$ROOT/$name.json" "$@" >"$ROOT/$name.out" 2>&1 || true
}
status() { jq -r --arg c "$2" '.checks[] | select(.check == $c) | .status' "$ROOT/$1.json"; }

run_diag explicit --scope database --in-cluster
[[ -s "$ROOT/explicit.json" ]] || { cat "$ROOT/explicit.out" >&2; fail "--in-cluster wrote no report"; }
[[ "$(status explicit database.in-cluster)" == PASS ]] || { cat "$ROOT/explicit.out" >&2; fail "--in-cluster Job did not complete"; }
[[ "$(status explicit credential.control-runtime)" == FAIL ]] || fail "a URL with sslpassword= was not refused"
for slot in control-owner cast-owner cast-runtime hoop-owner hoop-runtime read-runtime; do
  [[ "$(status explicit "credential.$slot")" == PASS ]] || { cat "$ROOT/explicit.out" >&2; fail "credential.$slot is not PASS"; }
  [[ "$(status explicit "database.$slot.identity")" == PASS ]] || { cat "$ROOT/explicit.out" >&2; fail "database.$slot.identity is not PASS"; }
  [[ "$(status explicit "database.$slot.tls")" == PASS ]] || fail "database.$slot.tls is not PASS (verify-full via rds-ca)"
done
pass "--in-cluster: six logins (one JSON-wrapped with escaped slashes) connect from the Job with verify-full through rds-ca; a URL with sslpassword= is refused"
[[ "$(status explicit cast.runtime_no_create)" == PASS && "$(status explicit cast.owner_temp)" == PASS ]] \
  || fail "Relaycast catalog checks did not come back from the Job"
[[ "$(status explicit hoop.vector)" == PASS ]] || fail "HoopDb catalog checks did not come back from the Job"
[[ "$(status explicit database.cast-runtime.restricted)" == PASS ]] || fail "runtime restriction check missing"
pass "--in-cluster: Relaycast and HoopDb catalog checks return through the Job log"
# Logins pre leaves NOLOGIN until post: a fixed category, not a raw error.
for slot in read-runtime ingest-runtime search-runtime search-owner; do
  st="$(status explicit "database.$slot")"; [[ -z "$st" || "$st" == UNKNOWN || "$st" == FAIL ]] || fail "database.$slot unexpected $st"
done

job="$(ls "$J" | sed -n 's/^diag-job-\(.*\)\.json$/\1/p' | head -n1)"
[[ -n "$job" && -e "$J/deleted-$job" ]] || fail "the Job was not deleted"
! docker ps -a --format '{{.Names}}' | grep -q "^diag-$job$" || fail "the Job's container survived"
jq -e '.spec.template.spec.automountServiceAccountToken == false and .spec.backoffLimit == 0
       and .spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem == true
       and (.spec.template.spec.volumes | map(select(.secret)) | all(.secret.items | length > 0))
       and .spec.ttlSecondsAfterFinished > 0 and .spec.activeDeadlineSeconds > 0' "$J/diag-job-$job.json" >/dev/null \
  || fail "the Job is not locked down"
pass "the Job is deleted afterwards, has no ServiceAccount token, a read-only root and only the credential keys"

for f in "$ROOT/explicit.json" "$ROOT/explicit.out" "$J/diag-job-$job.json" "$J/diag-log-$job" "$J/argv.log"; do
  for pw in "$MASTER_PW" "$SIBLING_PW" "$QUERY_PW" $(cat "$STATE_DIR"/passwords/* 2>/dev/null); do
    ! grep -qF -- "$pw" "$f" || fail "a password reached $(basename "$f")"
  done
done
! grep -q 'postgres[a-z]*://' "$ROOT/explicit.json" "$ROOT/explicit.out" || fail "a URL reached the report"
pass "no password reaches the Job manifest, its log, kubectl argv, stdout or the report"

# The rehearsal: no --in-cluster, the database is unreachable from here, so the
# run falls back to the Job by itself.
run_diag fallback --scope database
grep -q 'running the database checks inside the cluster' "$ROOT/fallback.out" || { cat "$ROOT/fallback.out" >&2; fail "no automatic fallback"; }
[[ "$(status fallback database.in-cluster)" == PASS && "$(status fallback database.control-owner.identity)" == PASS ]] \
  || { cat "$ROOT/fallback.out" >&2; fail "fallback did not produce the database checks"; }
[[ "$(jq -r .databaseChecksFrom "$ROOT/fallback.json")" == cluster ]] || fail "report does not say where the checks ran"
! jq -e '.checks[] | select(.detail == "network" or .detail == "dns" or .detail == "tool-missing")' "$ROOT/fallback.json" >/dev/null \
  || fail "the unreachable local attempts were kept in the report"
pass "without --in-cluster, an unreachable database falls back to the in-cluster Job"

e="$(jq -r '.summary | "PASS \(.PASS) FAIL \(.FAIL) UNKNOWN \(.UNKNOWN)"' "$ROOT/explicit.json")"
echo "# --in-cluster summary: $e (FAIL/UNKNOWN are the logins rds-setup.sh post activates and the unmigrated schema)"
count_jobs() { local n=0 f; for f in "$J"/diag-job-*.json; do [[ -e "$f" ]] && n=$((n+1)); done; echo "$n"; }
jobs_before="$(count_jobs)"
run_diag nofallback --scope database --no-in-cluster
[[ -s "$ROOT/nofallback.json" ]] || { cat "$ROOT/nofallback.out" >&2; fail "--no-in-cluster wrote no report"; }
[[ "$(jq -r .databaseChecksFrom "$ROOT/nofallback.json")" == this-machine ]] || fail "--no-in-cluster report not local"
# --scope database reads no cluster Secrets here, so the local result is "no credentials".
jq -e '[.checks[] | select(.check == "database" or (.check | startswith("database.")))] | length > 0' "$ROOT/nofallback.json" >/dev/null || fail "no local database results"
[[ "$(count_jobs)" == "$jobs_before" ]] || fail "--no-in-cluster created a Job"
! grep -q 'inside the cluster' "$ROOT/nofallback.out" || fail "--no-in-cluster still ran the Job"
pass "--no-in-cluster keeps the local result"
[[ -n "${OUT_DIR:-}" ]] && cp "$ROOT"/*.out "$ROOT"/*.json "$OUT_DIR"/ 2>/dev/null || true
