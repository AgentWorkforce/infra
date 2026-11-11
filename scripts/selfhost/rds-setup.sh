#!/usr/bin/env bash
# Sets up the Agent Relay databases and roles on one RDS PostgreSQL instance.
#
#   rds-setup.sh pre    Before the Helm install. Creates the databases and roles,
#                       the rds-ca ConfigMap, and the credential files.
#   rds-setup.sh post   After the HoopDb migrate Job succeeds. Activates the
#                       read API, ingest and search logins.
#   rds-setup.sh refresh-admin
#                       Before every later Helm upgrade. RDS rotates the admin
#                       password (7 days by default), and the HoopDb migration
#                       owner URL carries it. Rewrites only the two admin-derived
#                       credential files; touches no database role. pre cannot be
#                       re-run once post has given the session roles LOGIN.
#
# RDS is private, so the SQL runs in short-lived Jobs inside your cluster. The
# script needs aws, kubectl, jq, openssl and curl, and access to the cluster.
#
# Required environment:
#   AWS_REGION             region of the RDS instance
#   RDS_HOST               terraform output -raw database_host
#   RDS_ADMIN_SECRET_ARN   terraform output -raw database_admin_secret_arn
#   SERVICES_IMAGE         approved sessions-pipeline services image, pinned by digest
# Optional:
#   PSQL_IMAGE             <repository>@sha256:... the PostgreSQL client image
#   NAMESPACE              default agent-relay
#   STATE_DIR              default $HOME/.agent-relay-install (mode 0700)
#   KUBE_CONTEXT           kubectl context; empty uses the current context
#   RELEASE                required in post mode; exact Helm release name
#   MIGRATION_JOB          required in post mode; current rendered migrate Job
#   PROVISION_ERASE_SEARCH_LOGIN  default 0; 1 activates the optional Postgres
#                         eraser login after search bootstrap (not an erase flag)
#
# It is safe to run again: existing roles, databases and generated passwords are
# reused. It prints no passwords or connection strings. Credentials are written
# only under STATE_DIR, one file per Kubernetes Secret key.
#
# One HoopDb per RDS instance: the role session_directory_search_worker is
# server-wide, so a second install needs its own RDS instance.
set -euo pipefail
umask 077

MODE="${1:-}"
case "$MODE" in pre|post|refresh-admin) ;; *) echo "usage: $0 pre|post|refresh-admin" >&2; exit 2 ;; esac

: "${AWS_REGION:?set AWS_REGION}"
: "${RDS_HOST:?set RDS_HOST (terraform output -raw database_host)}"
: "${RDS_ADMIN_SECRET_ARN:?set RDS_ADMIN_SECRET_ARN (terraform output -raw database_admin_secret_arn)}"
if [[ "$MODE" == refresh-admin ]]; then SERVICES_IMAGE="${SERVICES_IMAGE:-unused@sha256:0}"; fi
: "${SERVICES_IMAGE:?set SERVICES_IMAGE to the approved sessions-pipeline image digest}"
PSQL_IMAGE="${PSQL_IMAGE:-ghcr.io/cloudnative-pg/postgresql:17-standard-trixie@sha256:ed6923f9ba2399cf9070379a353c710c29ced8a294be73986a2c3dae7e599ce3}"
NS="${NAMESPACE:-agent-relay}"
STATE_DIR="${STATE_DIR:-$HOME/.agent-relay-install}"
PW_DIR="$STATE_DIR/passwords"
FILES="$STATE_DIR/secret-files"
JOB_TIMEOUT_SECONDS="${JOB_TIMEOUT_SECONDS:-600}"
SQL_DIR=/app/supabase/bootstrap
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
PROVISION_ERASE_SEARCH_LOGIN="${PROVISION_ERASE_SEARCH_LOGIN:-0}"
[[ "$PROVISION_ERASE_SEARCH_LOGIN" == 0 || "$PROVISION_ERASE_SEARCH_LOGIN" == 1 ]] || { echo "PROVISION_ERASE_SEARCH_LOGIN must be 0 or 1" >&2; exit 2; }

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

for tool in aws kubectl jq openssl curl; do
  command -v "$tool" >/dev/null || die "$tool is not installed"
done
KUBECTL_CONTEXT_ARGS=()
if [[ -n "$KUBE_CONTEXT" ]]; then KUBECTL_CONTEXT_ARGS=(--context "$KUBE_CONTEXT"); fi
kubectl() { command kubectl "${KUBECTL_CONTEXT_ARGS[@]}" "$@"; }
[[ "$SERVICES_IMAGE" == *@sha256:* ]] || die "SERVICES_IMAGE must be pinned by digest"
[[ "$PSQL_IMAGE" == *@sha256:* ]] || die "PSQL_IMAGE must be pinned by digest"
if [[ "$SERVICES_IMAGE" == *__* ]]; then die "SERVICES_IMAGE still holds a placeholder"; fi

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

# 48 hex characters: safe in a URL with no encoding.
password_for() {
  local f="$PW_DIR/$1"
  if [[ ! -s "$f" ]]; then openssl rand -hex 24 | tr -d '\n' > "$f"; fi
  chmod 600 "$f"
}

write_file() { # secret-name key content-on-stdin
  mkdir -p "$FILES/$1"; chmod 700 "$FILES/$1"
  cat > "$FILES/$1/$2"; chmod 600 "$FILES/$1/$2"
}

admin_json() {
  aws secretsmanager get-secret-value --region "$AWS_REGION" \
    --secret-id "$RDS_ADMIN_SECRET_ARN" --query SecretString --output text
}

# run_job NAME SCRIPT [password-name ...]: runs SCRIPT as the RDS admin in a Job
# that has the SQL files from the services image at /sql and the RDS CA at /ca.
run_job() {
  local name="$1" script="$2"; shift 2
  JOB_SECRET="$name-secret"
  local secret_dir="$WORK/$name-secret"
  mkdir -p "$secret_dir"
  admin_json > "$WORK/admin.json"
  jq -jr .username "$WORK/admin.json" > "$secret_dir/PGUSER"
  jq -jr .password "$WORK/admin.json" > "$secret_dir/PGPASSWORD"
  rm -f "$WORK/admin.json"
  local p
  for p in "$@"; do cp "$PW_DIR/$p" "$secret_dir/$p"; done

  kubectl -n "$NS" delete job "$name" --ignore-not-found >/dev/null
  kubectl -n "$NS" create secret generic "$JOB_SECRET" --from-file="$secret_dir" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  rm -rf "$secret_dir"
  kubectl -n "$NS" create configmap "$name-run" --from-file=run.sh="$script" \
    --from-file=session-erase-search.sql="$SCRIPT_DIR/rds-session-erase-search.sql" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  jq -n --arg ns "$NS" --arg name "$name" --arg psql "$PSQL_IMAGE" --arg services "$SERVICES_IMAGE" \
    --arg host "$RDS_HOST" --arg secret "$JOB_SECRET" --arg sql "$SQL_DIR" '
    def hardened: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } };
    { apiVersion: "batch/v1", kind: "Job", metadata: { name: $name, namespace: $ns },
      spec: { backoffLimit: 0, ttlSecondsAfterFinished: 1800, template: { spec: {
        restartPolicy: "Never",
        automountServiceAccountToken: false,
        securityContext: { runAsNonRoot: true, runAsUser: 26, runAsGroup: 26, fsGroup: 26, seccompProfile: { type: "RuntimeDefault" } },
        volumes: [
          { name: "sql", emptyDir: {} }, { name: "tmp", emptyDir: {} },
          { name: "run", configMap: { name: ($name + "-run") } },
          { name: "ca", configMap: { name: "rds-ca" } } ],
        initContainers: [ { name: "sql-files", image: $services,
          command: ["cp", "-R", ($sql + "/."), "/sql/"],
          securityContext: hardened, volumeMounts: [ { name: "sql", mountPath: "/sql" } ] } ],
        containers: [ { name: "psql", image: $psql,
          securityContext: hardened,
          volumeMounts: [ { name: "sql", mountPath: "/sql", readOnly: true }, { name: "tmp", mountPath: "/tmp" },
            { name: "run", mountPath: "/run-script", readOnly: true }, { name: "ca", mountPath: "/ca", readOnly: true } ],
          envFrom: [ { secretRef: { name: $secret } } ],
          env: [ { name: "PGHOST", value: $host }, { name: "PGPORT", value: "5432" },
            { name: "PGSSLMODE", value: "verify-full" }, { name: "PGSSLROOTCERT", value: "/ca/ca.crt" },
            { name: "HOME", value: "/tmp" } ],
          command: ["sh", "/run-script/run.sh"] } ] } } } }' | kubectl apply -f - >/dev/null

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

  if [[ "$ok" != "1" ]]; then
    die "job $name did not succeed (see kubectl -n $NS describe job $name)"
  fi
  log "job $name succeeded"
}

url() { # scheme role password database
  printf '%s://%s:%s@%s:5432/%s?sslmode=verify-full' "$1" "$2" "$3" "$RDS_HOST" "$4"
}
pw() { cat "$PW_DIR/$1"; }
json_url() { # key url
  jq -cn --arg k "$1" --arg v "$2" '{($k): $v}'
}

admin_url() { # database
  admin_json > "$WORK/admin.json"
  local user pass
  user="$(jq -jr '.username | @uri' "$WORK/admin.json")"
  pass="$(jq -jr '.password | @uri' "$WORK/admin.json")"
  rm -f "$WORK/admin.json"
  url postgresql "$user" "$pass" "$1"
}

write_credential_files() {
  write_file agent-relay-secrets database-migrations-url < <(url postgresql control_owner "$(pw control_owner)" relaycontrol)
  write_file agent-relay-secrets database-url < <(url postgresql control_api_runtime "$(pw control_api_runtime)" relaycontrol)
  write_file agent-relay-secrets HOOPDB_URL < <(url postgresql sessions_pipeline_runtime "$(pw sessions_pipeline_runtime)" hoopdb)
  write_file agent-relay-secrets database-owner-url < <(url postgres relaycast_owner "$(pw relaycast_owner)" relaycast)
  write_file agent-relay-secrets database-runtime-url < <(url postgres relaycast_runtime "$(pw relaycast_runtime)" relaycast)
  write_file agent-relay-read-api RELAYHISTORY_READ_API_SECRET \
    < <(json_url supabase_url "$(url postgresql bulls96_read_api "$(pw bulls96_read_api)" hoopdb)")
  write_file agent-relay-ingest-edge-runtime database-url \
    < <(url postgresql bulls96_session_ingest "$(pw bulls96_session_ingest)" hoopdb)
  write_file search-indexer-runtime RELAYHISTORY_PIPELINE_CONSUMER_SECRET \
    < <(json_url hoopdb_url "$(url postgresql search_consumer_runtime "$(pw search_consumer_runtime)" hoopdb)")

  # Optional operator hard-delete uses a separate delete-only login. Creating
  # this private input does not mount it into a workload or enable the feature.
  write_file session-erase-search-runtime SESSION_ERASE_SEARCH_POSTGRES_URL \
    < <(url postgresql bulls96_session_erase_search "$(pw bulls96_session_erase_search)" hoopdb)

  write_admin_files
}

# The HoopDb migration owner is the RDS admin, whose password RDS rotates. Run
# refresh-admin (not pre) before a later Helm upgrade to refresh these two inputs.
write_admin_files() {
  local owner; owner="$(admin_url hoopdb)"
  write_file agent-relay-secrets HOOPDB_MIGRATION_URL < <(printf '%s' "$owner")
  write_file search-indexer-owner RELAYHISTORY_PIPELINE_CONSUMER_SECRET < <(json_url hoopdb_url "$owner")
}

do_refresh-admin() {
  [[ -d "$FILES/agent-relay-secrets" && -d "$FILES/search-indexer-owner" ]] || die "no credential files under $FILES: run '$0 pre' first, on the host that holds STATE_DIR"
  write_admin_files
  log "admin credential files refreshed under $FILES; update the agent-relay-secrets and search-indexer-owner Secrets from them"
}

ensure_ca() {
  local bundle="$STATE_DIR/rds-ca.pem"
  curl -fsS --max-time 60 -o "$bundle" "https://truststore.pki.rds.amazonaws.com/$AWS_REGION/$AWS_REGION-bundle.pem" \
    || die "could not download the RDS CA bundle for $AWS_REGION"
  [[ "$(grep -c 'BEGIN CERTIFICATE' "$bundle")" -gt 0 ]] || die "the RDS CA bundle is empty"
  kubectl -n "$NS" create configmap rds-ca --from-file=ca.crt="$bundle" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  sha256sum "$bundle" | cut -d' ' -f1 > "$STATE_DIR/rds-ca.sha256"
  log "rds-ca ConfigMap applied; sha256 $(cat "$STATE_DIR/rds-ca.sha256") (value for __RDS_CA_SHA256__)"
}

do_pre() {
  kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null
  ensure_ca

  local p
  for p in control_owner control_api_runtime sessions_pipeline_runtime relaycast_owner \
           relaycast_runtime bulls96_read_api bulls96_session_ingest search_consumer_runtime bulls96_session_erase_search; do
    password_for "$p"
  done

  cat > "$WORK/run.sh" <<'EOS'
set -eu
P="psql -X -q -v ON_ERROR_STOP=1"
Q="psql -X -A -t -v ON_ERROR_STOP=1"

# One HoopDb per RDS instance: this role is server-wide.
if [ -z "$($Q -d postgres -c "select 1 from pg_database where datname='hoopdb'")" ] && \
   [ -n "$($Q -d postgres -c "select 1 from pg_roles where rolname='session_directory_search_worker'")" ]; then
  echo "this RDS instance already belongs to another HoopDb install; use a separate instance" >&2
  exit 3
fi

for db in relaycontrol hoopdb relaycast; do
  printf '%s\n' "SELECT 'CREATE DATABASE $db' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='$db') \\gexec" | $P -d postgres
done
echo "databases ready"

# Control: the owner runs migrations, the runtime role serves requests.
$P -d relaycontrol -v p1="$control_owner" -v p2="$control_api_runtime" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', r) FROM unnest(ARRAY['control_owner','control_api_runtime']) r WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=r) \gexec
ALTER ROLE control_owner PASSWORD :'p1';
ALTER ROLE control_api_runtime PASSWORD :'p2';
GRANT control_owner TO CURRENT_USER WITH SET TRUE;
ALTER DATABASE relaycontrol OWNER TO control_owner;
GRANT CONNECT ON DATABASE relaycontrol TO control_api_runtime;
SQL
echo "relaycontrol ready"

# Relaycast.
$P -d relaycast -v p1="$relaycast_owner" -v p2="$relaycast_runtime" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', r) FROM unnest(ARRAY['relaycast_owner','relaycast_runtime']) r WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=r) \gexec
ALTER ROLE relaycast_owner PASSWORD :'p1';
ALTER ROLE relaycast_runtime PASSWORD :'p2';
GRANT relaycast_owner TO CURRENT_USER WITH SET TRUE;
ALTER SCHEMA public OWNER TO relaycast_owner;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO relaycast_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE relaycast_owner IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO relaycast_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE relaycast_owner IN SCHEMA public GRANT SELECT, USAGE, UPDATE ON SEQUENCES TO relaycast_runtime;
REVOKE TEMP, CREATE ON DATABASE relaycast FROM PUBLIC;
GRANT TEMP ON DATABASE relaycast TO relaycast_owner;
GRANT CONNECT ON DATABASE relaycast TO relaycast_owner, relaycast_runtime;
SQL
echo "relaycast ready"

# HoopDb, rds mode, in the required order, as the migration owner (the RDS admin).
export PGDATABASE=hoopdb
$P -c 'CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public; CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public; CREATE EXTENSION IF NOT EXISTS btree_gin WITH SCHEMA public;'
echo "extensions ready"
$P -f /sql/rds_owner_function_default_revoke.sql
echo "rds_owner_function_default_revoke ok"
$P -c 'ALTER DEFAULT PRIVILEGES FOR ROLE rds_superuser REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC'
echo "rds_superuser default revoke ok"
$P -f /sql/rds_migration_roles.sql
echo "rds_migration_roles ok"
$P -v migration_owner="$PGUSER" -v runtime_role=sessions_pipeline_runtime -v runtime_login=true -f /sql/hoopdb_runtime_role_rds.sql
echo "hoopdb_runtime_role_rds ok"
printf '%s\n' "ALTER ROLE sessions_pipeline_runtime PASSWORD :'p1';" | $P -v p1="$sessions_pipeline_runtime"
for f in session_directory_search_worker session_token_verifier session_ingest_roles session_read_api_roles session_consumer_roles; do
  $P -f "/sql/$f.sql"
  echo "$f ok"
done
$P -v post=false -f /run-script/session-erase-search.sql
echo "erase search identity ready (no new login until post)"
$Q -c "select 'hoopdb owner: '||pg_get_userbyid(datdba) from pg_database where datname='hoopdb'"
$Q -c "select 'rdsadmin superuser: '||rolsuper from pg_roles where rolname='rdsadmin'"
$Q -c "select 'extensions: '||string_agg(extname,',' order by extname) from pg_extension"
EOS

  run_job agent-relay-rds-pre "$WORK/run.sh" control_owner control_api_runtime \
    sessions_pipeline_runtime relaycast_owner relaycast_runtime
  write_credential_files
  log "pre done; credential files are under $FILES"
}

do_post() {
  : "${RELEASE:?set RELEASE to the exact Helm release name}"
  : "${MIGRATION_JOB:?set MIGRATION_JOB to the current rendered migrate Job name}"
  [[ "$MIGRATION_JOB" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "MIGRATION_JOB must be a DNS-1123 label"
  local p
  local post_passwords=(bulls96_read_api bulls96_session_ingest search_consumer_runtime)
  for p in "${post_passwords[@]}"; do
    [[ -s "$PW_DIR/$p" ]] || die "missing $p password: run '$0 pre' first"
  done

  # Refuse evidence from an older content-addressed Job or another release.
  # MIGRATION_JOB comes from the selected release's current Helm manifest.
  local migration_json
  migration_json="$(kubectl -n "$NS" get job "$MIGRATION_JOB" -o json)" \
    || die "current HoopDb migrate Job $MIGRATION_JOB does not exist"
  jq -e --arg release "$RELEASE" '
    .metadata.labels["app.kubernetes.io/instance"] == $release and
    .metadata.labels["app.kubernetes.io/component"] == "hoopdb-migrate" and
    (.status.succeeded // 0) >= 1
  ' <<<"$migration_json" >/dev/null \
    || die "current HoopDb migrate Job $MIGRATION_JOB has not succeeded for release $RELEASE"

  if [[ "$PROVISION_ERASE_SEARCH_LOGIN" == 1 ]]; then
    # Existing installs use refresh-admin, not pre. The optional SQL can create
    # this one identity after search bootstrap without re-running core role SQL.
    password_for bulls96_session_erase_search
    post_passwords+=(bulls96_session_erase_search)
  fi
  printf 'provision_erase_search_login=%s\n' "$PROVISION_ERASE_SEARCH_LOGIN" > "$WORK/run.sh"
  cat >> "$WORK/run.sh" <<'EOS'
set -eu
export PGDATABASE=hoopdb
P="psql -X -q -v ON_ERROR_STOP=1"
Q="psql -X -A -t -v ON_ERROR_STOP=1"

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
  echo "search_consumer_runtime does not exist: the migrations have not created it" >&2
  exit 3
fi
printf '%s\n' "ALTER ROLE search_consumer_runtime LOGIN NOINHERIT PASSWORD :'p1'; ALTER ROLE search_consumer_runtime SET statement_timeout = '60s';" | $P -v p1="$search_consumer_runtime"
echo "search consumer role ok"

# Both search tables are created by the separate search-indexer bootstrap Job.
# A missing/incomplete schema refuses activation; rerun after it completes.
if [ "$provision_erase_search_login" = 1 ]; then
  $P -v post=true -v p1="$bulls96_session_erase_search" -f /run-script/session-erase-search.sql
  PGUSER=bulls96_session_erase_search PGPASSWORD="$bulls96_session_erase_search" $Q -c "select 'erase search login ok: '||session_user||' tls='||(select ssl from pg_stat_ssl where pid=pg_backend_pid())"
  echo "erase search role ok"
else
  echo "erase search login activation not requested"
fi

for role in bulls96_read_api bulls96_session_ingest search_consumer_runtime; do
  eval "secret=\$$role"
  PGUSER="$role" PGPASSWORD="$secret" $Q -c "select 'login ok: '||session_user||' tls='||(select ssl from pg_stat_ssl where pid=pg_backend_pid())"
done
EOS

  run_job agent-relay-rds-post "$WORK/run.sh" "${post_passwords[@]}"
  if [[ "$PROVISION_ERASE_SEARCH_LOGIN" == 1 ]]; then
    write_file session-erase-search-runtime SESSION_ERASE_SEARCH_POSTGRES_URL \
      < <(url postgresql bulls96_session_erase_search "$(pw bulls96_session_erase_search)" hoopdb)
  fi
  log "post done; restart the read API, ingest edge and search indexer"
}

"do_$MODE"
