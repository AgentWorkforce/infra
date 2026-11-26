#!/usr/bin/env bash
# Runs the real rds-setup.sh pre (and optionally post) against a disposable
# RDS-shaped PostgreSQL in Docker, once per server major and psql client, and
# checks the resulting role and grant model.
#
# The server models RDS: the only SUPERUSER is rdsadmin; the master login
# "postgres" has CREATEROLE and CREATEDB and inherits a NOLOGIN rds_superuser.
# kubectl is faked: each Job rds-setup.sh submits runs as a container on a
# private Docker network, with the Job's psql image (PSQL_IMAGE), its Secret as
# environment and the HoopDb bootstrap SQL mounted at /sql, exactly as the
# in-cluster Job would. Not covered: TLS verify-full (the fixture uses
# sslmode=disable) and real RDS parameter groups.
#
# Opt-in, not part of run-tests.sh: needs Docker and a sessions-pipeline
# checkout for the SQL the services image ships at /app/supabase/bootstrap.
#
#   HOOPDB_BOOTSTRAP_DIR=../sessions-pipeline/supabase/bootstrap \
#     scripts/selfhost/tests/rds-setup-postgres-test.sh
#
# With SESSIONS_PIPELINE_DIR (a sessions-pipeline checkout after `bun install`
# and the object-store build), each run also applies the HoopDb migrations in
# rds/separate-database mode as hoopdb_owner, as the chart's migrate Job does,
# then runs `rds-setup.sh post` and checks the activated logins.
#
# Optional: PG_SERVER_IMAGES (space-separated, pgvector images pinned by
# digest; default pg16, pg17 and pg18), PSQL_IMAGES (space-separated client
# images; default the rds-setup.sh pin, a PostgreSQL 17 client, plus a
# PostgreSQL 18 client) and BUN_IMAGE.
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RDS_SETUP="$(cd -- "${TEST_DIR}/.." && pwd)/rds-setup.sh"
: "${HOOPDB_BOOTSTRAP_DIR:?set HOOPDB_BOOTSTRAP_DIR to sessions-pipeline/supabase/bootstrap}"
HOOPDB_BOOTSTRAP_DIR="$(cd -- "$HOOPDB_BOOTSTRAP_DIR" && pwd)"
[[ -s "$HOOPDB_BOOTSTRAP_DIR/rds_owner_function_default_revoke.sql" ]] \
  || { echo "HOOPDB_BOOTSTRAP_DIR has no rds_owner_function_default_revoke.sql" >&2; exit 2; }
command -v docker >/dev/null || { echo "docker is required" >&2; exit 2; }
SESSIONS_PIPELINE_DIR="${SESSIONS_PIPELINE_DIR:-}"
if [[ -n "$SESSIONS_PIPELINE_DIR" ]]; then
  SESSIONS_PIPELINE_DIR="$(cd -- "$SESSIONS_PIPELINE_DIR" && pwd)"
  [[ -s "$SESSIONS_PIPELINE_DIR/src/hoopdb/migrate.ts" && -d "$SESSIONS_PIPELINE_DIR/node_modules" ]] \
    || { echo "SESSIONS_PIPELINE_DIR needs src/hoopdb/migrate.ts and node_modules (run bun install)" >&2; exit 2; }
fi
BUN_IMAGE="${BUN_IMAGE:-oven/bun@sha256:3aa040e5445efa09d75bb428a64ba50db13e2b3ac9b6b0c7f145615f62b2ee18}"

PG_SERVER_IMAGES="${PG_SERVER_IMAGES:-pgvector/pgvector@sha256:484e838076e04939d27d3e176e91c86eea96236126023be8d3059761122e579f pgvector/pgvector@sha256:b513c48566e4777cd3370451400000c78eda6a08131d68f4c31d4a76f27bd8fd pgvector/pgvector@sha256:38681dc6eaf55308e2a4c6de392d131652dcfac70e1263e35cd9b5ea3fe39782}"
PSQL_IMAGES="${PSQL_IMAGES:-$(sed -n 's/^PSQL_IMAGE="\${PSQL_IMAGE:-\(.*\)}"$/\1/p' "$RDS_SETUP") pgvector/pgvector@sha256:38681dc6eaf55308e2a4c6de392d131652dcfac70e1263e35cd9b5ea3fe39782}"

TMP_BASE="${AGENT_TMP_DIR:-${HOME}/.agent-tmp}"
mkdir -p "$TMP_BASE"
ROOT="$(mktemp -d "$TMP_BASE/rds-setup-pg.XXXXXX")"
NET="rds-setup-pg-$$"
PG="rds-setup-pg-$$"
cleanup() {
  docker rm -fv "$PG" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$ROOT"
}
trap cleanup EXIT
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }

MASTER_PW="$(openssl rand -hex 16)"
MOCK_BIN="$ROOT/bin"; mkdir -p "$MOCK_BIN" "$ROOT/jobs"
cat >"$MOCK_BIN/aws" <<MOCK
#!/usr/bin/env bash
printf '{"username":"postgres","password":"%s"}\n' "$MASTER_PW"
MOCK
cat >"$MOCK_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [[ "$prev" == -o ]] && out="$a"; prev="$a"; done
printf '%s\n' '-----BEGIN CERTIFICATE-----' 'fixture' '-----END CERTIFICATE-----' >"$out"
MOCK
# Fake kubectl: Secrets and ConfigMaps become directories, a Job becomes a container run.
cat >"$MOCK_BIN/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
J="$MOCK_JOBS"
args=" $* "
name_after() { local prev="" a; for a in "${@:2}"; do [[ "$prev" == "$1" ]] && { printf '%s' "$a"; return; }; prev="$a"; done; }
case "$args" in
  *" create secret generic "*)
    n="$(name_after generic "$@")"; rm -rf "$J/secret-$n"; mkdir -p "$J/secret-$n"
    for a in "$@"; do [[ "$a" == --from-file=* ]] && cp -R "${a#--from-file=}/." "$J/secret-$n/"; done
    exit 0 ;;
  *" create configmap "*)
    n="$(name_after configmap "$@")"; mkdir -p "$J/cm-$n"
    for a in "$@"; do
      case "$a" in --from-file=*=*) f="${a#--from-file=}"; cp "${f#*=}" "$J/cm-$n/${f%%=*}" ;; esac
    done
    # rds-setup.sh runs under umask 077; a real ConfigMap mount is world-readable,
    # and the Job container runs as UID 26, so model that.
    chmod 0755 "$J/cm-$n"; find "$J/cm-$n" -type f -exec chmod 0644 {} +
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: %s}\n' "$n"; exit 0 ;;
  *" apply -f - "*)
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
  *" get job "*" -o json "*)
    n="$(name_after job "$@")"
    printf '{"metadata":{"name":"%s","labels":{"app.kubernetes.io/instance":"%s","app.kubernetes.io/component":"hoopdb-migrate"}},"status":{"succeeded":1}}\n' "$n" "$RELEASE"
    exit 0 ;;
  *" logs job/"*)
    for a in "$@"; do [[ "$a" == job/* ]] && cat "$J/log-${a#job/}"; done; exit 0 ;;
esac
exit 0
MOCK
chmod +x "$MOCK_BIN"/*
chmod -R a+rX "$HOOPDB_BOOTSTRAP_DIR" 2>/dev/null || true

docker network create "$NET" >/dev/null
export PATH="$MOCK_BIN:$PATH" MOCK_JOBS="$ROOT/jobs" MOCK_NET="$NET" MOCK_PGHOST="$PG" MOCK_SQL="$HOOPDB_BOOTSTRAP_DIR"
export AWS_REGION=us-west-2 RDS_HOST="$PG" RDS_ADMIN_SECRET_ARN=arn:aws:secretsmanager:us-west-2:111122223333:secret:fixture
export SERVICES_IMAGE="fixture/sessions-pipeline@sha256:1111111111111111111111111111111111111111111111111111111111111111"
export NAMESPACE=agent-relay KUBE_CONTEXT=fixture JOB_TIMEOUT_SECONDS=120 RELEASE=agent-relay MIGRATION_JOB=fixture-hoopdb-migrate

su() { docker exec -i "$PG" psql -X -v ON_ERROR_STOP=1 -U rdsadmin -At "$@"; }
login() { # role password database sql (TCP + password, as the service would)
  docker run --rm --network "$NET" -e PGPASSWORD="$2" "$CLIENT" psql -X -v ON_ERROR_STOP=1 -At \
    "host=$PG port=5432 user=$1 dbname=$3 sslmode=disable" -c "$4"
}
start_server() {
  docker rm -fv "$PG" >/dev/null 2>&1 || true
  docker run -d --name "$PG" --network "$NET" -e POSTGRES_USER=rdsadmin -e POSTGRES_PASSWORD="$(openssl rand -hex 12)" \
    "$1" -c password_encryption=scram-sha-256 >/dev/null
  local i
  for i in $(seq 1 60); do
    docker exec "$PG" pg_isready -h 127.0.0.1 -U rdsadmin -d postgres >/dev/null 2>&1 && break
    [[ "$i" != 60 ]] || fail "server $1 did not become ready"; sleep 1
  done
  # RDS lets rds_superuser create vector; vanilla pgvector needs it marked trusted.
  docker exec -u root "$PG" sh -c 'for f in /usr/share/postgresql/*/extension/vector.control; do grep -q "^trusted" "$f" || echo "trusted = true" >>"$f"; done'
  su -d postgres >/dev/null <<SQL
CREATE ROLE rds_superuser NOLOGIN;
GRANT pg_monitor, pg_signal_backend, pg_read_all_settings, pg_read_all_stats TO rds_superuser WITH ADMIN OPTION;
CREATE ROLE postgres LOGIN CREATEROLE CREATEDB PASSWORD '$MASTER_PW';
GRANT rds_superuser TO postgres WITH ADMIN OPTION;
GRANT ALL ON DATABASE postgres TO rds_superuser;
SQL
}

for server in $PG_SERVER_IMAGES; do
  for CLIENT in $PSQL_IMAGES; do
    export PSQL_IMAGE="$CLIENT" STATE_DIR="$ROOT/state-$RANDOM"
    rm -rf "$MOCK_JOBS"; mkdir -p "$MOCK_JOBS"
    start_server "$server"
    sv="$(su -d postgres -c 'SHOW server_version' | cut -d' ' -f1)"
    cv="$(docker run --rm "$CLIENT" psql --version | awk '{print $3}')"
    label="server $sv, psql $cv"
    echo "# $label"

    bash "$RDS_SETUP" pre >"$ROOT/pre.log" 2>&1 \
      || { cat "$ROOT/pre.log" "$MOCK_JOBS"/log-* >&2 2>/dev/null; fail "$label: rds-setup.sh pre failed"; }
    [[ "$(cat "$STATE_DIR/hoopdb-layout")" == dedicated-owner ]] || fail "$label: layout is not dedicated-owner"
    grep -q 'protected role membership edges: 0' "$MOCK_JOBS/log-agent-relay-rds-pre" || fail "$label: protected edges not zero"
    ! grep -Eq 'WARNING|ERROR' "$MOCK_JOBS"/log-* || fail "$label: a Job logged a WARNING or ERROR"
    pass "$label: pre creates the dedicated-owner layout with no protected membership edges"

    [[ "$(su -d postgres -c "select pg_get_userbyid(datdba) from pg_database where datname='hoopdb'")" == hoopdb_owner ]] \
      || fail "$label: hoopdb is not owned by hoopdb_owner"
    [[ -z "$(su -d postgres -c "select 1 from pg_roles where rolname='agent_relay_hoopdb_role_creator'")" ]] \
      || fail "$label: the disposable role creator survived"
    [[ -z "$(su -d postgres -c "select rolname from pg_authid where rolcanlogin and rolname <> 'rdsadmin' and rolpassword not like 'SCRAM-SHA-256\$%'")" ]] \
      || fail "$label: a login has a non-SCRAM password"
    pass "$label: hoopdb_owner owns HoopDb, creator dropped, every password SCRAM"

    for pair in relaycast_owner:relaycast control_owner:relaycontrol control_api_runtime:relaycontrol hoopdb_owner:hoopdb \
                sessions_pipeline_runtime:hoopdb bulls96_read_api:hoopdb bulls96_session_ingest:hoopdb; do
      role="${pair%%:*}"; db="${pair#*:}"
      [[ "$(login "$role" "$(cat "$STATE_DIR/passwords/$role")" "$db" 'select session_user')" == "$role" ]] \
        || fail "$label: $role cannot log in to $db"
    done
    pass "$label: generated service logins authenticate over TCP"

    # relaycast's identity check refuses a login with SUPERUSER, CREATEROLE,
    # CREATEDB, REPLICATION or BYPASSRLS, or one that reaches any other role.
    for role in relaycast_owner relaycast_runtime; do
      [[ "$(su -d relaycast -c "select rolsuper or rolcreaterole or rolcreatedb or rolreplication or rolbypassrls from pg_roles where rolname='$role'")" == f ]] \
        || fail "$label: $role has a privileged attribute"
      reach="$(login "$role" "$(cat "$STATE_DIR/passwords/$role")" relaycast "with recursive me as (select oid from pg_roles where rolname=current_user), granted(oid) as (select m.roleid from pg_auth_members m where m.member=(select oid from me) union select m.roleid from pg_auth_members m join granted g on m.member=g.oid) select count(*) from pg_roles r where r.oid <> (select oid from me) and (pg_has_role(current_user, r.oid, 'MEMBER') or r.oid in (select oid from granted))")"
      [[ "$reach" == 0 ]] || fail "$label: $role reaches $reach other role(s)"
    done
    o="$(cat "$STATE_DIR/passwords/relaycast_owner")"; r="$(cat "$STATE_DIR/passwords/relaycast_runtime")"
    login relaycast_owner "$o" relaycast 'create table public.fixture(id int primary key generated always as identity, v text)' >/dev/null
    login relaycast_runtime "$r" relaycast "insert into public.fixture(v) values ('x'); select count(*) from public.fixture" >/dev/null \
      || fail "$label: relaycast_runtime lacks default table privileges"
    if login relaycast_runtime "$r" relaycast 'create table public.forbidden(id int)' >/dev/null 2>&1; then
      fail "$label: relaycast_runtime can CREATE in public"
    fi
    [[ "$(login relaycast_runtime "$r" relaycast "select has_database_privilege(current_database(),'TEMP') or has_schema_privilege('public','CREATE')")" == f ]] \
      || fail "$label: relaycast_runtime has TEMP or public CREATE"
    pass "$label: relaycast logins pass the identity-check attributes, memberships and schema grants"

    defaults="$(su -d hoopdb -c "select string_agg(pg_get_userbyid(d.defaclrole)||'='||array_to_string(d.defaclacl,','), ';' order by pg_get_userbyid(d.defaclrole)) from pg_default_acl d where d.defaclobjtype='f' and d.defaclnamespace=0 and pg_get_userbyid(d.defaclrole) in ('postgres','rds_superuser','hoopdb_owner')")"
    [[ "$defaults" == "hoopdb_owner=hoopdb_owner=X/hoopdb_owner;postgres=postgres=X/postgres;rds_superuser=rds_superuser=X/rds_superuser" ]] \
      || fail "$label: function defaults are $defaults"
    h="$(cat "$STATE_DIR/passwords/hoopdb_owner")"
    login hoopdb_owner "$h" hoopdb 'create function sessions.fixture() returns int language sql as $$ select 1 $$' >/dev/null
    [[ "$(su -d hoopdb -c "select coalesce(array_to_string(proacl, ','), 'NULL') from pg_proc where oid='sessions.fixture()'::regprocedure")" == "hoopdb_owner=X/hoopdb_owner" ]] \
      || fail "$label: PUBLIC can execute a new sessions function"
    # The migrator refuses any sessions function it did not create.
    login hoopdb_owner "$h" hoopdb 'drop function sessions.fixture()' >/dev/null
    pass "$label: function EXECUTE defaults revoked from PUBLIC for owner, master and rds_superuser"

    bash "$RDS_SETUP" pre >"$ROOT/pre2.log" 2>&1 || fail "$label: rerun of pre failed"
    grep -q 'dedicated-owner HoopDb already active' "$ROOT/pre2.log" || fail "$label: rerun did not converge"
    pass "$label: rerun of pre converges without changes"

    [[ -n "$SESSIONS_PIPELINE_DIR" ]] || continue
    # The chart's migrate Job env for examples/aws (rds, separate-database).
    docker run --rm --network "$NET" -v "$SESSIONS_PIPELINE_DIR:/app" -w /app \
      -e HOOPDB_URL="postgresql://hoopdb_owner:$h@$PG:5432/hoopdb?sslmode=disable" \
      -e HOOPDB_DB_MODE=rds -e HOOPDB_RDS_LAYOUT=separate-database -e HOOPDB_SUPABASE_SHIM=false \
      -e HOOPDB_RUNTIME_ROLE=sessions_pipeline_runtime -e HOOPDB_RUNTIME_ROLE_LOGIN=true \
      -e HOOPDB_FUNCTION_BOUNDARY_MODE=global-default-revoke -e OTEL_EXPORTER_OTLP_ENDPOINT= \
      "$BUN_IMAGE" bun run src/hoopdb/migrate.ts >"$ROOT/migrate.log" 2>&1 \
      || { tail -40 "$ROOT/migrate.log" >&2; fail "$label: HoopDb migrations failed"; }
    applied="$(su -d hoopdb -c "select count(*) from pg_namespace n join pg_class c on c.relnamespace=n.oid where n.nspname='sessions' and c.relkind in ('r','p')")"
    [[ "$applied" -gt 0 ]] || fail "$label: migrations created no sessions tables"
    pass "$label: HoopDb migrations apply as hoopdb_owner in rds/separate-database mode ($applied sessions tables)"

    bash "$RDS_SETUP" post >"$ROOT/post.log" 2>&1 \
      || { cat "$ROOT/post.log" >&2; fail "$label: rds-setup.sh post failed"; }
    ! grep -Eq 'WARNING|ERROR' "$MOCK_JOBS/log-agent-relay-rds-post" || fail "$label: post logged a WARNING or ERROR"
    for role in bulls96_read_api bulls96_session_ingest search_consumer_runtime; do
      grep -q "login ok: $role" "$MOCK_JOBS/log-agent-relay-rds-post" || fail "$label: post did not prove the $role login"
    done
    [[ "$(su -d hoopdb -c "select rolsuper or rolcreaterole or rolcreatedb or rolreplication or rolbypassrls from pg_roles where rolname in ('bulls96_read_api','bulls96_session_ingest','search_consumer_runtime','sessions_pipeline_runtime') group by 1")" == f ]] \
      || fail "$label: an activated login has a privileged attribute"
    pass "$label: post activates the read API, ingest and search logins"
  done
done
