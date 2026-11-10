#!/usr/bin/env bash
# Sets up the native Agent Relay databases and roles on one private Cloud SQL
# for PostgreSQL instance.
#
#   cloud-sql-setup.sh pre   Before Helm. Creates databases, owner/runtime
#                            roles, extensions, the CA ConfigMap and credential
#                            files.
#   cloud-sql-setup.sh post  After the HoopDb migrate Job. Activates the read,
#                            ingest and search logins.
#
# SQL runs in short-lived Jobs inside GKE, so the instance needs no public IP.
# Required environment:
#   GCP_PROJECT_ID              project that owns the Cloud SQL instance
#   CLOUD_SQL_INSTANCE          Cloud SQL instance name
#   CLOUD_SQL_HOST              terraform output postgres.dns_name
#   CLOUD_SQL_ADMIN_USER        terraform output postgres.admin_username
#   CLOUD_SQL_ADMIN_SECRET_ID   terraform output postgres.admin_password_secret_id
#   SERVICES_IMAGE              sessions-pipeline image pinned by digest
# Optional:
#   CLOUD_SQL_CA_FILE           shared-CA PEM bundle (otherwise fetched by gcloud)
#   PSQL_IMAGE                  PostgreSQL client image pinned by digest
#   NAMESPACE                   default agent-relay
#   HELM_RELEASE                default agent-relay
#   STATE_DIR                   default $HOME/.agent-relay-install (mode 0700)
#
# The Terraform example uses GOOGLE_MANAGED_CAS_CA and private Cloud DNS. This
# script requires the certificate DNS name and verifies it with verify-full.
# It is idempotent and never prints passwords or connection strings.
set -euo pipefail
umask 077

MODE="${1:-}"
case "$MODE" in pre|post) ;; *) echo "usage: $0 pre|post" >&2; exit 2 ;; esac

: "${GCP_PROJECT_ID:?set GCP_PROJECT_ID}"
: "${CLOUD_SQL_INSTANCE:?set CLOUD_SQL_INSTANCE}"
: "${CLOUD_SQL_HOST:?set CLOUD_SQL_HOST (terraform output postgres.dns_name)}"
: "${CLOUD_SQL_ADMIN_USER:?set CLOUD_SQL_ADMIN_USER}"
: "${CLOUD_SQL_ADMIN_SECRET_ID:?set CLOUD_SQL_ADMIN_SECRET_ID}"
: "${SERVICES_IMAGE:?set SERVICES_IMAGE to the sessions-pipeline image from images.md}"
PSQL_IMAGE="${PSQL_IMAGE:-ghcr.io/cloudnative-pg/postgresql:17-standard-trixie@sha256:ed6923f9ba2399cf9070379a353c710c29ced8a294be73986a2c3dae7e599ce3}"
NS="${NAMESPACE:-agent-relay}"
HELM_RELEASE="${HELM_RELEASE:-agent-relay}"
STATE_DIR="${STATE_DIR:-$HOME/.agent-relay-install}"
PW_DIR="$STATE_DIR/passwords"
FILES="$STATE_DIR/secret-files"
JOB_TIMEOUT_SECONDS="${JOB_TIMEOUT_SECONDS:-600}"
SQL_DIR=/app/supabase/bootstrap

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

for tool in gcloud helm kubectl jq openssl; do
  command -v "$tool" >/dev/null || die "$tool is not installed"
done
[[ "$SERVICES_IMAGE" == *@sha256:* ]] || die "SERVICES_IMAGE must be pinned by digest"
[[ "$PSQL_IMAGE" == *@sha256:* ]] || die "PSQL_IMAGE must be pinned by digest"
[[ "$CLOUD_SQL_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "CLOUD_SQL_HOST must be a DNS hostname"
[[ "$CLOUD_SQL_HOST" != *: ]] || die "CLOUD_SQL_HOST must not include a port"

mkdir -p "$STATE_DIR" "$PW_DIR" "$FILES"
chmod 700 "$STATE_DIR" "$PW_DIR" "$FILES"
WORK="$(mktemp -d "$STATE_DIR/.work.XXXXXX")"
JOB_SECRET=""
cleanup() {
  rm -rf "$WORK"
  if [[ -n "$JOB_SECRET" ]]; then
    kubectl -n "$NS" delete secret "$JOB_SECRET" --ignore-not-found >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

password_for() {
  local f="$PW_DIR/$1"
  if [[ ! -s "$f" ]]; then openssl rand -hex 24 | tr -d '\n' >"$f"; fi
  chmod 600 "$f"
}

write_file() {
  mkdir -p "$FILES/$1"; chmod 700 "$FILES/$1"
  cat >"$FILES/$1/$2"; chmod 600 "$FILES/$1/$2"
}

admin_password() {
  gcloud secrets versions access latest --project "$GCP_PROJECT_ID" \
    --secret "$CLOUD_SQL_ADMIN_SECRET_ID" --quiet
}

ensure_ca() {
  local bundle="$STATE_DIR/cloud-sql-ca.pem" actual_host
  if [[ -n "${CLOUD_SQL_CA_FILE:-}" ]]; then
    [[ -s "$CLOUD_SQL_CA_FILE" ]] || die "CLOUD_SQL_CA_FILE is empty or missing"
    cp "$CLOUD_SQL_CA_FILE" "$bundle"
  elif ! gcloud sql ssl server-ca-certs list --project "$GCP_PROJECT_ID" \
      --instance "$CLOUD_SQL_INSTANCE" --format=json --quiet 2>/dev/null \
      | jq -er '.[].cert' >"$bundle"; then
    gcloud sql instances describe "$CLOUD_SQL_INSTANCE" --project "$GCP_PROJECT_ID" \
      --format=json --quiet | jq -er '.serverCaCert.cert' >"$bundle"
  fi
  [[ "$(grep -c 'BEGIN CERTIFICATE' "$bundle")" -gt 0 ]] || die "Cloud SQL CA bundle is empty"
  chmod 600 "$bundle"

  actual_host="$(gcloud sql instances describe "$CLOUD_SQL_INSTANCE" --project "$GCP_PROJECT_ID" \
    --format=json --quiet | jq -r '(.dnsNames // []) | map(select(.connectionType == "PRIVATE_SERVICES_ACCESS")) | first | .name // empty')"
  [[ -n "$actual_host" ]] || die "Cloud SQL instance has no private-services-access DNS name; use GOOGLE_MANAGED_CAS_CA"
  [[ "$actual_host" == "$CLOUD_SQL_HOST" ]] || die "CLOUD_SQL_HOST does not match the instance DNS name"

  kubectl -n "$NS" create configmap cloud-sql-ca --from-file=ca.crt="$bundle" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  sha256sum "$bundle" | cut -d' ' -f1 >"$STATE_DIR/cloud-sql-ca.sha256"
  log "cloud-sql-ca ConfigMap applied; sha256 $(cat "$STATE_DIR/cloud-sql-ca.sha256")"
}

# run_job NAME SCRIPT [password-name ...]
run_job() {
  local name="$1" script="$2"; shift 2
  JOB_SECRET="$name-secret"
  local secret_dir="$WORK/$name-secret" p
  mkdir -p "$secret_dir"
  printf '%s' "$CLOUD_SQL_ADMIN_USER" >"$secret_dir/PGUSER"
  admin_password >"$secret_dir/PGPASSWORD"
  for p in "$@"; do cp "$PW_DIR/$p" "$secret_dir/$p"; done

  kubectl -n "$NS" delete job "$name" --ignore-not-found >/dev/null
  # This Secret is deliberately create-only. `kubectl apply` would persist the
  # database credentials a second time in last-applied-configuration.
  kubectl -n "$NS" delete secret "$JOB_SECRET" --ignore-not-found >/dev/null
  kubectl -n "$NS" create secret generic "$JOB_SECRET" --from-file="$secret_dir" >/dev/null
  rm -rf "$secret_dir"
  kubectl -n "$NS" create configmap "$name-run" --from-file=run.sh="$script" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  jq -n --arg ns "$NS" --arg name "$name" --arg psql "$PSQL_IMAGE" --arg services "$SERVICES_IMAGE" \
    --arg host "$CLOUD_SQL_HOST" --arg secret "$JOB_SECRET" --arg sql "$SQL_DIR" '
    def hardened: {allowPrivilegeEscalation:false,readOnlyRootFilesystem:true,capabilities:{drop:["ALL"]}};
    {apiVersion:"batch/v1",kind:"Job",metadata:{name:$name,namespace:$ns},spec:{backoffLimit:0,
      ttlSecondsAfterFinished:1800,template:{spec:{restartPolicy:"Never",automountServiceAccountToken:false,
      securityContext:{runAsNonRoot:true,runAsUser:26,runAsGroup:26,fsGroup:26,seccompProfile:{type:"RuntimeDefault"}},
      volumes:[{name:"sql",emptyDir:{}},{name:"tmp",emptyDir:{}},{name:"run",configMap:{name:($name+"-run")}},{name:"ca",configMap:{name:"cloud-sql-ca"}}],
      initContainers:[{name:"sql-files",image:$services,command:["cp","-R",($sql+"/."),"/sql/"],securityContext:hardened,volumeMounts:[{name:"sql",mountPath:"/sql"}]}],
      containers:[{name:"psql",image:$psql,securityContext:hardened,
        volumeMounts:[{name:"sql",mountPath:"/sql",readOnly:true},{name:"tmp",mountPath:"/tmp"},{name:"run",mountPath:"/run-script",readOnly:true},{name:"ca",mountPath:"/ca",readOnly:true}],
        envFrom:[{secretRef:{name:$secret}}],env:[{name:"PGHOST",value:$host},{name:"PGPORT",value:"5432"},{name:"PGSSLMODE",value:"verify-full"},{name:"PGSSLROOTCERT",value:"/ca/ca.crt"},{name:"HOME",value:"/tmp"}],
        command:["sh","/run-script/run.sh"]}]}}}}' | kubectl apply -f - >/dev/null

  log "job $name started"
  local waited=0 ok="" failed=""
  while (( waited < JOB_TIMEOUT_SECONDS )); do
    ok="$(kubectl -n "$NS" get job "$name" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
    failed="$(kubectl -n "$NS" get job "$name" -o jsonpath='{.status.failed}' 2>/dev/null || true)"
    if [[ -n "$ok" || -n "$failed" ]]; then break; fi
    sleep 5; waited=$((waited + 5))
  done
  kubectl -n "$NS" logs "job/$name" --tail=80 2>/dev/null \
    | grep -v -i -E 'password|postgres(ql)?://' | cut -c1-240 || true
  kubectl -n "$NS" delete secret "$JOB_SECRET" --ignore-not-found >/dev/null
  JOB_SECRET=""
  kubectl -n "$NS" delete configmap "$name-run" --ignore-not-found >/dev/null
  [[ "$ok" == 1 ]] || die "job $name did not succeed (inspect the retained Job)"
  log "job $name succeeded"
}

url() { printf '%s://%s:%s@%s:5432/%s?sslmode=verify-full' "$1" "$2" "$3" "$CLOUD_SQL_HOST" "$4"; }
pw() { cat "$PW_DIR/$1"; }
json_url() { jq -cn --arg k "$1" --arg v "$2" '{($k):$v}'; }
admin_url() { url postgresql "$CLOUD_SQL_ADMIN_USER" "$(admin_password)" "$1"; }

write_credential_files() {
  write_file agent-relay-secrets database-migrations-url < <(url postgresql control_owner "$(pw control_owner)" relaycontrol)
  write_file agent-relay-secrets database-url < <(url postgresql control_api_runtime "$(pw control_api_runtime)" relaycontrol)
  write_file agent-relay-secrets HOOPDB_URL < <(url postgresql sessions_pipeline_runtime "$(pw sessions_pipeline_runtime)" hoopdb)
  write_file agent-relay-secrets database-owner-url < <(url postgres relaycast_owner "$(pw relaycast_owner)" relaycast)
  write_file agent-relay-secrets database-runtime-url < <(url postgres relaycast_runtime "$(pw relaycast_runtime)" relaycast)
  write_file agent-relay-read-api RELAYHISTORY_READ_API_SECRET < <(json_url supabase_url "$(url postgresql bulls96_read_api "$(pw bulls96_read_api)" hoopdb)")
  write_file agent-relay-ingest-edge-runtime database-url < <(url postgresql bulls96_session_ingest "$(pw bulls96_session_ingest)" hoopdb)
  write_file search-indexer-runtime RELAYHISTORY_PIPELINE_CONSUMER_SECRET < <(json_url hoopdb_url "$(url postgresql search_consumer_runtime "$(pw search_consumer_runtime)" hoopdb)")
  local owner; owner="$(admin_url hoopdb)"
  write_file agent-relay-secrets HOOPDB_MIGRATION_URL < <(printf '%s' "$owner")
  write_file search-indexer-owner RELAYHISTORY_PIPELINE_CONSUMER_SECRET < <(json_url hoopdb_url "$owner")
}

do_pre() {
  kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null
  ensure_ca
  local p
  for p in control_owner control_api_runtime sessions_pipeline_runtime relaycast_owner relaycast_runtime \
           bulls96_read_api bulls96_session_ingest search_consumer_runtime; do password_for "$p"; done

  cat >"$WORK/run.sh" <<'EOS'
set -eu
P="psql -X -q -v ON_ERROR_STOP=1"
Q="psql -X -A -t -v ON_ERROR_STOP=1"

if [ -z "$($Q -d postgres -c "select 1 from pg_database where datname='hoopdb'")" ] && \
   [ -n "$($Q -d postgres -c "select 1 from pg_roles where rolname='session_directory_search_worker'")" ]; then
  echo "this Cloud SQL instance already belongs to another HoopDb install" >&2; exit 3
fi
for db in relaycontrol hoopdb relaycast; do
  printf '%s\n' "SELECT 'CREATE DATABASE $db' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='$db') \\gexec" | $P -d postgres
done
echo "databases ready"

$P -d relaycontrol -v p1="$control_owner" -v p2="$control_api_runtime" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', r) FROM unnest(ARRAY['control_owner','control_api_runtime']) r WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=r) \gexec
ALTER ROLE control_owner PASSWORD :'p1'; ALTER ROLE control_api_runtime PASSWORD :'p2';
GRANT control_owner TO CURRENT_USER WITH SET TRUE;
ALTER DATABASE relaycontrol OWNER TO control_owner;
GRANT CONNECT ON DATABASE relaycontrol TO control_api_runtime;
SQL
echo "relaycontrol ready"

$P -d relaycast -v p1="$relaycast_owner" -v p2="$relaycast_runtime" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', r) FROM unnest(ARRAY['relaycast_owner','relaycast_runtime']) r WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=r) \gexec
ALTER ROLE relaycast_owner PASSWORD :'p1'; ALTER ROLE relaycast_runtime PASSWORD :'p2';
GRANT relaycast_owner TO CURRENT_USER WITH SET TRUE;
-- Keep the database owned by the Cloud SQL administrator. PostgreSQL grants
-- every database owner implicit pg_database_owner membership and CREATE;
-- Relaycast's production owner-boundary check deliberately rejects both.
-- This assignment also repairs installs made with the earlier script.
ALTER DATABASE relaycast OWNER TO CURRENT_USER;
ALTER SCHEMA public OWNER TO relaycast_owner;
REVOKE CREATE ON SCHEMA public FROM PUBLIC; GRANT USAGE ON SCHEMA public TO relaycast_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE relaycast_owner IN SCHEMA public GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO relaycast_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE relaycast_owner IN SCHEMA public GRANT SELECT,USAGE,UPDATE ON SEQUENCES TO relaycast_runtime;
REVOKE TEMP,CREATE ON DATABASE relaycast FROM PUBLIC; GRANT TEMP ON DATABASE relaycast TO relaycast_owner;
GRANT CONNECT ON DATABASE relaycast TO relaycast_owner,relaycast_runtime;
SQL
echo "relaycast ready"

export PGDATABASE=hoopdb
printf '%s\n' "SELECT format('ALTER DATABASE hoopdb OWNER TO %I', current_user) \\gexec" | $P
$P -c 'CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public; CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public; CREATE EXTENSION IF NOT EXISTS btree_gin WITH SCHEMA public;'
$P -f /sql/cloudsql_owner_function_default_revoke.sql
$P -f /sql/cloudsql_migration_roles.sql
echo "Cloud SQL owner boundary and migration roles ready"

$P -v p1="$sessions_pipeline_runtime" <<'SQL'
-- \gset consumes the row locally; the password must never reach Job logs.
SELECT set_config('agent_relay.runtime_password', :'p1', false) AS ignored \gset
DO $runtime$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='sessions_pipeline_runtime') THEN
    CREATE ROLE agent_relay_runtime_seed NOLOGIN NOINHERIT CREATEROLE NOSUPERUSER NOCREATEDB NOREPLICATION NOBYPASSRLS;
    GRANT agent_relay_runtime_seed TO CURRENT_USER WITH INHERIT FALSE, SET TRUE;
    SET LOCAL ROLE agent_relay_runtime_seed;
    CREATE ROLE sessions_pipeline_runtime LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
    EXECUTE format('ALTER ROLE sessions_pipeline_runtime PASSWORD %L', current_setting('agent_relay.runtime_password'));
    RESET ROLE;
    DROP ROLE agent_relay_runtime_seed;
  ELSE
    EXECUTE format('ALTER ROLE sessions_pipeline_runtime PASSWORD %L', current_setting('agent_relay.runtime_password'));
  END IF;
END $runtime$;
RESET agent_relay.runtime_password;
REVOKE TEMPORARY ON DATABASE hoopdb FROM PUBLIC;
GRANT CONNECT ON DATABASE hoopdb TO sessions_pipeline_runtime;
SQL
echo "sessions runtime ready"

for f in session_directory_search_worker session_token_verifier session_ingest_roles session_read_api_roles; do
  $P -f "/sql/$f.sql"; echo "$f ok"
done
$Q -c "select 'hoopdb owner: '||pg_get_userbyid(datdba) from pg_database where datname='hoopdb'"
$Q -c "select 'tls: '||ssl from pg_stat_ssl where pid=pg_backend_pid()"
$Q -c "select 'extensions: '||string_agg(extname,',' order by extname) from pg_extension"
EOS
  run_job agent-relay-cloud-sql-pre "$WORK/run.sh" control_owner control_api_runtime sessions_pipeline_runtime relaycast_owner relaycast_runtime
  write_credential_files
  log "pre done; credential files are under $FILES"
}

do_post() {
  local p
  for p in bulls96_read_api bulls96_session_ingest search_consumer_runtime; do
    [[ -s "$PW_DIR/$p" ]] || die "missing $p password: run '$0 pre' first"
  done
  local migration_job migration_json
  migration_job="$(helm -n "$NS" get manifest "$HELM_RELEASE" | awk '
    function emit() { if (kind == "Job" && name != "" && migrate) print name }
    /^---[[:space:]]*$/ { emit(); kind=""; name=""; migrate=0; next }
    /^kind:[[:space:]]+Job[[:space:]]*$/ { kind="Job"; next }
    /^  name:[[:space:]]+/ && name == "" { name=$2; next }
    /^[[:space:]]+- name:[[:space:]]+migrate[[:space:]]*$/ { migrate=1 }
    END { emit() }
  ')"
  [[ -n "$migration_job" && "$migration_job" != *$'\n'* ]] || \
    die "could not resolve exactly one current HoopDb migrate Job from Helm release $HELM_RELEASE"
  migration_json="$(kubectl -n "$NS" get job "$migration_job" -o json)"
  [[ "$(jq -r '[.status.conditions[]? | select(.type == "Failed" and .status == "True")] | length' <<<"$migration_json")" == 0 ]] || \
    die "current HoopDb migrate Job $migration_job failed"
  [[ "$(jq -r '[.status.conditions[]? | select(.type == "Complete" and .status == "True")] | length' <<<"$migration_json")" == 1 ]] || \
    die "current HoopDb migrate Job $migration_job has not completed"

  cat >"$WORK/run.sh" <<'EOS'
set -eu
export PGDATABASE=hoopdb
P="psql -X -q -v ON_ERROR_STOP=1"; Q="psql -X -A -t -v ON_ERROR_STOP=1"
$P -f /sql/session_read_api_role.sql
printf '%s\n' "ALTER ROLE bulls96_read_api PASSWORD :'p1';" | $P -v p1="$bulls96_read_api"
$P -c 'GRANT CONNECT ON DATABASE hoopdb TO bulls96_read_api'
$P -f /sql/session_read_api_role_verify.sql
echo "read API role ok"
$P -f /sql/session_ingest_role.sql
printf '%s\n' "ALTER ROLE bulls96_session_ingest PASSWORD :'p1';" | $P -v p1="$bulls96_session_ingest"
$P -c 'GRANT CONNECT ON DATABASE hoopdb TO bulls96_session_ingest'
$P -f /sql/session_ingest_role_verify.sql
$P -f /sql/session_ingest_verify.sql
echo "ingest role ok"
if [ -z "$($Q -c "select 1 from pg_roles where rolname='search_consumer_runtime'")" ]; then
  echo "search_consumer_runtime missing: migrations have not completed" >&2; exit 3
fi
printf '%s\n' "ALTER ROLE search_consumer_runtime LOGIN NOINHERIT PASSWORD :'p1'; ALTER ROLE search_consumer_runtime SET statement_timeout='60s';" | $P -v p1="$search_consumer_runtime"
echo "search consumer role ok"
for role in bulls96_read_api bulls96_session_ingest search_consumer_runtime; do
  eval "secret=\$$role"
  PGUSER="$role" PGPASSWORD="$secret" $Q -c "select 'login ok: '||session_user||' tls='||(select ssl from pg_stat_ssl where pid=pg_backend_pid())"
done
EOS
  run_job agent-relay-cloud-sql-post "$WORK/run.sh" bulls96_read_api bulls96_session_ingest search_consumer_runtime
  log "post done; restart the read API, ingest edge and search indexer"
}

"do_$MODE"
