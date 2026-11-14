#!/usr/bin/env bash
# Sets up the Agent Relay databases and roles on the in-cluster CloudNativePG
# HoopDb (database mode `selfhosted`). The AKS counterpart of
# rds-setup.sh and cloud-sql-setup.sh, with the same phases and the same
# credential-file layout under STATE_DIR.
#
#   postgres-setup.sh pre       Before the Helm install. Creates the relaycontrol
#                               database and its roles, the HoopDb bootstrap roles,
#                               the postgres-ca ConfigMap and the credential files.
#   postgres-setup.sh post      After the HoopDb migrate Job succeeds. Activates the
#                               read API, ingest and search logins.
#   postgres-setup.sh finalize  After the search-indexer bootstrap Job succeeds.
#                               Takes CREATEROLE back from the migration owner.
#
# SQL runs as the CNPG superuser `postgres` by `kubectl exec` into the primary
# (peer authentication on the local socket), the way the chart's own privileged
# Jobs do: no superuser Secret, enableSuperuserAccess stays false. The bootstrap
# SQL files come from the pinned services image.
#
# Required environment:
#   SERVICES_IMAGE   approved sessions-pipeline services image, pinned by digest
# Optional:
#   NAMESPACE        default agent-relay
#   CLUSTER          CloudNativePG Cluster name, default hoopdb
#   CA_SECRET        Secret holding the server CA as ca.crt, default postgres-ca
#   STATE_DIR        default $HOME/.agent-relay-install (mode 0700)
#   KUBE_CONTEXT     kubectl context; empty uses the current context
#
# Safe to run again: existing roles, databases and generated passwords are
# reused. It prints no passwords or connection strings. Credentials are written
# only under STATE_DIR, one file per Kubernetes Secret key.
set -euo pipefail
umask 077

MODE="${1:-}"
case "$MODE" in pre|post|finalize) ;; *) echo "usage: $0 pre|post|finalize" >&2; exit 2 ;; esac

if [[ "$MODE" == finalize ]]; then SERVICES_IMAGE="${SERVICES_IMAGE:-unused@sha256:0}"; fi
: "${SERVICES_IMAGE:?set SERVICES_IMAGE to the approved sessions-pipeline image digest}"
NS="${NAMESPACE:-agent-relay}"
CLUSTER="${CLUSTER:-hoopdb}"
CA_SECRET="${CA_SECRET:-postgres-ca}"
STATE_DIR="${STATE_DIR:-$HOME/.agent-relay-install}"
PW_DIR="$STATE_DIR/passwords"
FILES="$STATE_DIR/secret-files"
SQL_DIR=/app/supabase/bootstrap
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
DB_HOST="$CLUSTER-rw.$NS.svc.cluster.local"
OWNER=hoop
RUNTIME=sessions_pipeline_runtime

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

for tool in kubectl jq openssl tar; do
  command -v "$tool" >/dev/null || die "$tool is not installed"
done
KUBECTL_CONTEXT_ARGS=()
if [[ -n "$KUBE_CONTEXT" ]]; then KUBECTL_CONTEXT_ARGS=(--context "$KUBE_CONTEXT"); fi
kubectl() { command kubectl ${KUBECTL_CONTEXT_ARGS[@]+"${KUBECTL_CONTEXT_ARGS[@]}"} "$@"; }
[[ "$SERVICES_IMAGE" == *@sha256:* ]] || die "SERVICES_IMAGE must be pinned by digest"

mkdir -p "$STATE_DIR" "$PW_DIR" "$FILES"
chmod 700 "$STATE_DIR" "$PW_DIR" "$FILES"
WORK="$(mktemp -d "$STATE_DIR/.work.XXXXXX")"
SQL_POD=""
cleanup() {
  [[ -n "$SQL_POD" ]] && kubectl -n "$NS" delete pod "$SQL_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

password_for() {
  [[ -s "$PW_DIR/$1" ]] || openssl rand -hex 24 | tr -d '\n' > "$PW_DIR/$1"
  chmod 600 "$PW_DIR/$1"
}
pw() { cat "$PW_DIR/$1"; }
write_file() { # secret key  (content on stdin)
  mkdir -p "$FILES/$1"; chmod 700 "$FILES/$1"
  cat > "$FILES/$1/$2"; chmod 600 "$FILES/$1/$2"
}
url() { # role password database
  printf 'postgresql://%s:%s@%s:5432/%s?sslmode=verify-full' "$1" "$2" "$DB_HOST" "$3"
}
json_url() { jq -cn --arg k "$1" --arg v "$2" '{($k): $v}'; }

PRIMARY=""
primary() {
  [[ -n "$PRIMARY" ]] || PRIMARY="$(kubectl -n "$NS" get cluster.postgresql.cnpg.io "$CLUSTER" -o jsonpath='{.status.currentPrimary}')"
  [[ -n "$PRIMARY" ]] || die "CloudNativePG cluster $CLUSTER has no primary yet"
  printf '%s' "$PRIMARY"
}
# psql_su DATABASE: runs the SQL on stdin as the superuser. Passwords travel on
# stdin only, never in an argument, and never reach the server log.
psql_su() {
  local rc=0 out="$WORK/psql.out"
  kubectl -n "$NS" exec -i "$(primary)" -c postgres -- \
    psql -X -q -v ON_ERROR_STOP=1 -d "$1" > "$out" 2>&1 || rc=$?
  grep -v -i -E 'password|postgres(ql)?://' "$out" | cut -c1-240 || true
  rm -f "$out"
  return "$rc"
}
query_su() { # database sql
  kubectl -n "$NS" exec -i "$(primary)" -c postgres -- psql -X -A -t -v ON_ERROR_STOP=1 -d "$1" -c "$2"
}
quiet() { printf "SET log_statement='none'; SET log_min_error_statement='panic';\n"; }

# The bootstrap SQL of the pinned services image, copied to $WORK/sql.
fetch_sql() {
  [[ -d "$WORK/sql" ]] && return 0
  SQL_POD="agent-relay-sql-files-$(openssl rand -hex 3)"
  kubectl -n "$NS" run "$SQL_POD" --image="$SERVICES_IMAGE" --restart=Never \
    --overrides='{"spec":{"automountServiceAccountToken":false,"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}}}}' \
    --command -- sleep 600 >/dev/null
  kubectl -n "$NS" wait --for=condition=Ready "pod/$SQL_POD" --timeout=300s >/dev/null
  mkdir -p "$WORK/sql"
  kubectl -n "$NS" exec "$SQL_POD" -- tar -C "$SQL_DIR" -cf - . | tar -C "$WORK/sql" -xf -
  kubectl -n "$NS" delete pod "$SQL_POD" --wait=false >/dev/null; SQL_POD=""
  [[ -s "$WORK/sql/session_ingest_roles.sql" ]] || die "the services image has no bootstrap SQL under $SQL_DIR"
}
# The SQL is piped to psql, which cannot resolve a relative include from stdin,
# so `\ir <file>` lines are expanded here.
expand_sql() {
  local line include_re='^\\ir[[:space:]]+([A-Za-z0-9_.-]+)[[:space:]]*$'
  [[ -f "$WORK/sql/$1" ]] || die "the services image has no bootstrap SQL file $1"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $include_re ]]; then expand_sql "${BASH_REMATCH[1]}"; else printf '%s\n' "$line"; fi
  done < "$WORK/sql/$1"
}
sql_file() { # name [psql variable assignments...]  -> SQL on stdout
  local name="$1"; shift
  local v
  for v in "$@"; do printf '\\set %s %s\n' "${v%%=*}" "${v#*=}"; done
  expand_sql "$name"
}

ensure_ca() {
  local bundle="$STATE_DIR/postgres-ca.pem"
  kubectl -n "$NS" get secret "$CA_SECRET" -o json | jq -er '.data["ca.crt"]' | openssl base64 -d -A > "$bundle" \
    || die "Secret $CA_SECRET has no ca.crt (apply postgres-tls.yaml first)"
  [[ "$(grep -c 'BEGIN CERTIFICATE' "$bundle")" -gt 0 ]] || die "the Postgres CA bundle is empty"
  kubectl -n "$NS" create configmap postgres-ca --from-file=ca.crt="$bundle" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  sha256 "$bundle" > "$STATE_DIR/postgres-ca.sha256"
  log "postgres-ca ConfigMap applied; sha256 $(cat "$STATE_DIR/postgres-ca.sha256") (value for __POSTGRES_CA_SHA256__)"
}

owner_password() {
  kubectl -n "$NS" get secret "$CLUSTER-app" -o json | jq -er '.data.password' | openssl base64 -d -A
}

write_credential_files() {
  local owner; owner="$(url "$OWNER" "$(owner_password)" hoopdb)"
  write_file agent-relay-secrets database-migrations-url < <(url control_owner "$(pw control_owner)" relaycontrol)
  write_file agent-relay-secrets database-url < <(url control_api_runtime "$(pw control_api_runtime)" relaycontrol)
  write_file agent-relay-secrets HOOPDB_URL < <(url "$RUNTIME" "$(pw "$RUNTIME")" hoopdb)
  write_file agent-relay-secrets HOOPDB_MIGRATION_URL < <(printf '%s' "$owner")
  write_file agent-relay-read-api RELAYHISTORY_READ_API_SECRET \
    < <(json_url supabase_url "$(url bulls96_read_api "$(pw bulls96_read_api)" hoopdb)")
  write_file agent-relay-ingest-edge-runtime database-url \
    < <(url bulls96_session_ingest "$(pw bulls96_session_ingest)" hoopdb)
  write_file search-indexer-runtime RELAYHISTORY_PIPELINE_CONSUMER_SECRET \
    < <(json_url hoopdb_url "$(url search_consumer_runtime "$(pw search_consumer_runtime)" hoopdb)")
  write_file search-indexer-owner RELAYHISTORY_PIPELINE_CONSUMER_SECRET < <(json_url hoopdb_url "$owner")
}

do_pre() {
  kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null
  [[ "$(query_su postgres 'select rolsuper from pg_roles where rolname=current_user')" == t ]] \
    || die "kubectl exec into $(primary) is not a Postgres superuser session"
  ensure_ca
  fetch_sql

  local p
  for p in control_owner control_api_runtime "$RUNTIME" bulls96_read_api bulls96_session_ingest search_consumer_runtime; do
    password_for "$p"
  done

  # Control: its own database. The owner runs migrations, the runtime role
  # serves requests.
  printf '%s\n' "SELECT 'CREATE DATABASE relaycontrol' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='relaycontrol') \\gexec" | psql_su postgres
  {
    quiet
    cat <<SQL
SELECT format('CREATE ROLE %I LOGIN', r) FROM unnest(ARRAY['control_owner','control_api_runtime']) r WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=r) \\gexec
ALTER ROLE control_owner PASSWORD '$(pw control_owner)';
ALTER ROLE control_api_runtime PASSWORD '$(pw control_api_runtime)';
ALTER DATABASE relaycontrol OWNER TO control_owner;
REVOKE ALL ON DATABASE relaycontrol FROM PUBLIC;
GRANT CONNECT ON DATABASE relaycontrol TO control_api_runtime;
SQL
  } | psql_su relaycontrol
  log "relaycontrol ready"

  # HoopDb, selfhosted mode, in the order the kind and EKS installers use.
  psql_su hoopdb <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS btree_gin WITH SCHEMA public;
SQL
  log "extensions ready"

  # Phase-1 roles a migration only verifies: created by the superuser.
  local f
  for f in session_directory_search_worker session_token_verifier session_ingest_roles session_read_api_roles; do
    sql_file "$f.sql" | psql_su hoopdb
    log "$f ok"
  done

  # The migration owner creates the bare search consumer role, so that it (and
  # not only a superuser) may promote it later: on PostgreSQL 16+ a CREATEROLE
  # role can alter only the roles it created. It keeps CREATEROLE until
  # `finalize`.
  if [[ -z "$(query_su hoopdb "select 1 from pg_roles where rolname='search_consumer_runtime'")" ]]; then
    {
      printf 'ALTER ROLE %s CREATEROLE;\nBEGIN;\nSET LOCAL ROLE %s;\nSET LOCAL createrole_self_grant = %s;\n' "$OWNER" "$OWNER" "''"
      printf 'CREATE SCHEMA IF NOT EXISTS sessions;\nCREATE SCHEMA IF NOT EXISTS search_index;\n'
      sql_file session_consumer_roles.sql
      printf 'RESET ROLE;\nCOMMIT;\n'
    } | psql_su hoopdb
  fi
  log "session_consumer_roles ok"

  sql_file hoopdb_runtime_role.sql "runtime_role=$RUNTIME" runtime_login=true | psql_su hoopdb
  { quiet; printf "ALTER ROLE %s PASSWORD '%s';\n" "$RUNTIME" "$(pw "$RUNTIME")"; } | psql_su hoopdb
  log "hoopdb_runtime_role ok"
  sql_file hoopdb_function_default_revoke.sql "migration_owner=$OWNER" | psql_su hoopdb
  log "hoopdb_function_default_revoke ok"

  query_su hoopdb "select 'hoopdb owner: '||pg_get_userbyid(datdba) from pg_database where datname='hoopdb'"
  query_su hoopdb "select 'extensions: '||string_agg(extname,',' order by extname) from pg_extension"
  write_credential_files
  log "pre done; credential files are under $FILES"
}

do_post() {
  local p
  for p in bulls96_read_api bulls96_session_ingest search_consumer_runtime; do
    [[ -s "$PW_DIR/$p" ]] || die "missing $p password: run '$0 pre' first"
  done
  local migrated
  migrated="$(kubectl -n "$NS" get jobs -o json | jq -r \
    '[.items[] | select(.metadata.name | contains("worker-migrate")) | .status.succeeded // 0] | add // 0')"
  [[ "$migrated" -ge 1 ]] || die "the HoopDb migrate Job has not succeeded yet"
  fetch_sql

  sql_file session_read_api_role.sql | psql_su hoopdb
  { quiet; printf "ALTER ROLE bulls96_read_api PASSWORD '%s';\nGRANT CONNECT ON DATABASE hoopdb TO bulls96_read_api;\n" "$(pw bulls96_read_api)"; } | psql_su hoopdb
  sql_file session_read_api_role_verify.sql | psql_su hoopdb
  log "read API role ok"

  sql_file session_ingest_role.sql | psql_su hoopdb
  { quiet; printf "ALTER ROLE bulls96_session_ingest PASSWORD '%s';\nGRANT CONNECT ON DATABASE hoopdb TO bulls96_session_ingest;\n" "$(pw bulls96_session_ingest)"; } | psql_su hoopdb
  sql_file session_ingest_role_verify.sql | psql_su hoopdb
  sql_file session_ingest_verify.sql | psql_su hoopdb
  log "ingest role ok"

  [[ -n "$(query_su hoopdb "select 1 from pg_roles where rolname='search_consumer_runtime'")" ]] \
    || die "search_consumer_runtime does not exist: run '$0 pre' first"
  { quiet; printf "ALTER ROLE search_consumer_runtime LOGIN NOINHERIT PASSWORD '%s';\nALTER ROLE search_consumer_runtime SET statement_timeout = '60s';\n" "$(pw search_consumer_runtime)"; } | psql_su hoopdb
  log "search consumer role ok"

  # Each runtime login, over the network path the services use, with TLS.
  local role
  for role in bulls96_read_api bulls96_session_ingest search_consumer_runtime; do
    printf '\\connect "host=%s port=5432 dbname=hoopdb user=%s password=%s sslmode=require"\n%s\n' \
      "$DB_HOST" "$role" "$(pw "$role")" \
      "select 'login ok: '||session_user||' tls='||(select ssl from pg_stat_ssl where pid=pg_backend_pid());" \
      | kubectl -n "$NS" exec -i "$(primary)" -c postgres -- psql -X -A -t -q -v ON_ERROR_STOP=1 -d postgres 2>&1 \
      | grep -E '^login ok' || die "$role could not log in over TLS"
  done
  log "post done; restart the read API, ingest edge and search indexer"
}

do_finalize() {
  printf 'ALTER ROLE %s NOCREATEROLE;\n' "$OWNER" | psql_su hoopdb
  query_su hoopdb "select 'owner createrole: '||rolcreaterole from pg_roles where rolname='$OWNER'"
  log "finalize done"
}

"do_$MODE"
