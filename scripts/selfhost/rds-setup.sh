#!/usr/bin/env bash
# Sets up the Agent Relay databases and roles on one RDS PostgreSQL instance.
#
#   rds-setup.sh pre    Before the Helm install. Creates the databases and roles,
#                       the rds-ca ConfigMap, and the credential files.
#   rds-setup.sh post   After the HoopDb migrate Job succeeds. Activates the
#                       read API, ingest and search logins.
#   rds-setup.sh refresh-admin
#                       Legacy installs only: refreshes local files for the
#                       short-lived hoopdb-admin-jobs Secret. It never updates a
#                       long-lived Kubernetes Secret.
#   rds-setup.sh prepare-admin-jobs
#                       Legacy installs only: refreshes and creates that Secret.
#   rds-setup.sh delete-admin-jobs
#                       Deletes it after the migration/bootstrap Jobs finish.
#   rds-setup.sh prepare-rollback-admin-keys / remove-rollback-admin-keys
#                       Legacy rollback only: temporarily restores, then removes,
#                       the administrator keys required by an older chart revision.
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
case "$MODE" in pre|post|refresh-admin|prepare-admin-jobs|delete-admin-jobs|prepare-rollback-admin-keys|remove-rollback-admin-keys) ;; *) echo "usage: $0 pre|post|refresh-admin|prepare-admin-jobs|delete-admin-jobs|prepare-rollback-admin-keys|remove-rollback-admin-keys" >&2; exit 2 ;; esac

: "${AWS_REGION:?set AWS_REGION}"
: "${RDS_HOST:?set RDS_HOST (terraform output -raw database_host)}"
: "${RDS_ADMIN_SECRET_ARN:?set RDS_ADMIN_SECRET_ARN (terraform output -raw database_admin_secret_arn)}"
if [[ "$MODE" == refresh-admin || "$MODE" == prepare-admin-jobs || "$MODE" == delete-admin-jobs || "$MODE" == prepare-rollback-admin-keys || "$MODE" == remove-rollback-admin-keys ]]; then SERVICES_IMAGE="${SERVICES_IMAGE:-unused@sha256:0}"; fi
: "${SERVICES_IMAGE:?set SERVICES_IMAGE to the approved sessions-pipeline image digest}"
PSQL_IMAGE="${PSQL_IMAGE:-ghcr.io/cloudnative-pg/postgresql:17-standard-trixie@sha256:ed6923f9ba2399cf9070379a353c710c29ced8a294be73986a2c3dae7e599ce3}"
NS="${NAMESPACE:-agent-relay}"
STATE_DIR="${STATE_DIR:-$HOME/.agent-relay-install}"
PW_DIR="$STATE_DIR/passwords"
FILES="$STATE_DIR/secret-files"
LAYOUT_FILE="$STATE_DIR/hoopdb-layout"
PENDING_ACTIVATION_FILE="$STATE_DIR/.pending-hoopdb-activation"
ADMIN_JOBS_SECRET=hoopdb-admin-jobs
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

load_admin_json() {
  if ! admin_json >"$WORK/admin.json"; then
    rm -f "$WORK/admin.json"
    die "could not read the RDS administrator Secret"
  fi
  if ! jq -e 'type == "object" and (.username | type == "string" and length > 0) and (.password | type == "string" and length > 0)' \
      "$WORK/admin.json" >/dev/null; then
    rm -f "$WORK/admin.json"
    die "the RDS administrator Secret must contain non-empty username and password strings"
  fi
}

# run_job NAME SCRIPT [password-name ...]: runs SCRIPT as the RDS admin in a Job
# that has the SQL files from the services image at /sql and the RDS CA at /ca.
run_job() {
  local name="$1" script="$2"; shift 2
  JOB_SECRET="$name-secret"
  local secret_dir="$WORK/$name-secret"
  mkdir -p "$secret_dir"
  if [[ "${RUN_JOB_AS_OWNER:-0}" == 1 ]]; then
    printf '%s' hoopdb_owner >"$secret_dir/PGUSER"
    cp "$PW_DIR/hoopdb_owner" "$secret_dir/PGPASSWORD"
  else
    load_admin_json
    jq -jr .username "$WORK/admin.json" > "$secret_dir/PGUSER"
    jq -jr .password "$WORK/admin.json" > "$secret_dir/PGPASSWORD"
    rm -f "$WORK/admin.json"
  fi
  local p
  for p in "$@"; do cp "$PW_DIR/$p" "$secret_dir/$p"; done

  kubectl -n "$NS" delete job "$name" --ignore-not-found >/dev/null
  # Delete and create, never apply: apply would copy the admin password into a last-applied annotation.
  kubectl -n "$NS" delete secret "$JOB_SECRET" --ignore-not-found >/dev/null
  kubectl -n "$NS" create secret generic "$JOB_SECRET" --from-file="$secret_dir" >/dev/null
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
    | grep -v -i -E 'password|postgres(ql)?://' | cut -c1-240 | tee "$WORK/$name.log" || true
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
  load_admin_json
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

}

# A legacy HoopDb migration owner is the RDS admin, whose password RDS rotates.
# These files feed only the short-lived hoopdb-admin-jobs Secret.
write_admin_files() {
  local owner
  owner="$(admin_url hoopdb)" || die "could not build the RDS administrator URL"
  write_file "$ADMIN_JOBS_SECRET" HOOPDB_MIGRATION_URL < <(printf '%s' "$owner")
  write_file "$ADMIN_JOBS_SECRET" RELAYHISTORY_PIPELINE_CONSUMER_SECRET < <(json_url hoopdb_url "$owner")
  rm -f "$FILES/agent-relay-secrets/HOOPDB_MIGRATION_URL" \
    "$FILES/search-indexer-owner/RELAYHISTORY_PIPELINE_CONSUMER_SECRET"
}

write_owner_files() {
  local owner; owner="$(url postgresql hoopdb_owner "$(pw hoopdb_owner)" hoopdb)"
  write_file agent-relay-secrets HOOPDB_MIGRATION_URL < <(printf '%s' "$owner")
  write_file search-indexer-owner RELAYHISTORY_PIPELINE_CONSUMER_SECRET < <(json_url hoopdb_url "$owner")
}

write_layout_values() {
  local layout="$1" migration_secret=agent-relay-secrets search_secret=search-indexer-owner
  local rds_layout=separate-database
  if [[ "$layout" == legacy-admin ]]; then
    migration_secret="$ADMIN_JOBS_SECRET"; search_secret="$ADMIN_JOBS_SECRET"; rds_layout=master-owner
  fi
  printf '%s\n' \
    'sessions-pipeline:' \
    '  worker:' \
    '    migrations:' \
    '      hoopdb:' \
    "        existingSecret: $migration_secret" \
    '        key: HOOPDB_MIGRATION_URL' \
    "      rdsLayout: $rds_layout" \
    '  searchIndexer:' \
    '    bootstrap:' \
    "      existingSecret: $search_secret" \
    '      key: RELAYHISTORY_PIPELINE_CONSUMER_SECRET' >"$STATE_DIR/hoopdb-layout-values.yaml"
  chmod 600 "$STATE_DIR/hoopdb-layout-values.yaml"
}

do_refresh-admin() {
  [[ -s "$LAYOUT_FILE" && "$(<"$LAYOUT_FILE")" == legacy-admin ]] || die "refresh-admin is only for an existing administrator-owned install; run '$0 pre' first"
  write_admin_files
  log "legacy administrator Job credential files refreshed under $FILES/$ADMIN_JOBS_SECRET; no Kubernetes Secret was changed"
}

do_prepare-admin-jobs() {
  do_refresh-admin
  kubectl -n "$NS" delete secret "$ADMIN_JOBS_SECRET" --ignore-not-found >/dev/null
  kubectl -n "$NS" create secret generic "$ADMIN_JOBS_SECRET" \
    --from-file="$FILES/$ADMIN_JOBS_SECRET" >/dev/null
  log "$ADMIN_JOBS_SECRET created for migration/bootstrap Jobs only; delete it as soon as those Jobs finish"
}

do_delete-admin-jobs() {
  kubectl -n "$NS" delete secret "$ADMIN_JOBS_SECRET" --ignore-not-found >/dev/null
  log "$ADMIN_JOBS_SECRET deleted; long-running pods are unaffected"
}

secret_is_external() {
  local secret="$1" json managed
  json="$(kubectl -n "$NS" get secret "$secret" -o json)" || die "could not read Secret $secret"
  managed="$(jq -er '
    if (any(.metadata.ownerReferences[]?; .kind == "ExternalSecret") or
        ((.metadata.labels // {}) | has("reconcile.external-secrets.io/managed")))
    then "yes" else "no" end' <<<"$json")" \
    || die "could not parse Secret $secret while checking its owner"
  [[ "$managed" == yes ]]
}

do_prepare-rollback-admin-keys() {
  do_refresh-admin
  local secret key source patch
  for secret in agent-relay-secrets search-indexer-owner; do
    if secret_is_external "$secret"; then
      die "Secret $secret is managed by External Secrets; restore the rollback key through the release values, ExternalSecret and backing store instead of patching it"
    fi
  done
  for secret in agent-relay-secrets search-indexer-owner; do
    if [[ "$secret" == agent-relay-secrets ]]; then key=HOOPDB_MIGRATION_URL; else key=RELAYHISTORY_PIPELINE_CONSUMER_SECRET; fi
    source="$FILES/$ADMIN_JOBS_SECRET/$key"; patch="$WORK/$secret-rollback.json"
    jq -n --rawfile value "$source" --arg key "$key" '{data:{($key):($value|@base64)}}' >"$patch"
    kubectl -n "$NS" patch secret "$secret" --type=merge --patch-file "$patch" >/dev/null
  done
  log "temporarily restored the administrator keys required by an older rollback revision; remove them immediately after rollback Jobs and workloads succeed"
}

do_remove-rollback-admin-keys() {
  local secret key patch
  for secret in agent-relay-secrets search-indexer-owner; do
    kubectl -n "$NS" get secret "$secret" --ignore-not-found -o json >"$WORK/$secret.json" \
      || die "could not read Secret $secret while removing rollback keys"
    [[ -s "$WORK/$secret.json" ]] || continue
    if [[ "$secret" == agent-relay-secrets ]]; then key=HOOPDB_MIGRATION_URL; else key=RELAYHISTORY_PIPELINE_CONSUMER_SECRET; fi
    [[ "$(jq -r --arg key "$key" 'if .data[$key] == null then "no" else "yes" end' "$WORK/$secret.json")" == yes ]] || continue
    secret_is_external "$secret" && die "Secret $secret became managed by External Secrets; remove $key through its release values, ExternalSecret and backing store"
    patch="$WORK/$secret-remove.json"
    jq -n --arg path "/data/$key" '[{"op":"remove","path":$path}]' >"$patch"
    kubectl -n "$NS" patch secret "$secret" --type=json --patch-file "$patch" >/dev/null
  done
  log "temporary legacy rollback administrator keys removed"
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
  load_admin_json
  rm -f "$WORK/admin.json"
  kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null
  ensure_ca

  local p
  local password_roles=(control_owner control_api_runtime hoopdb_owner sessions_pipeline_runtime relaycast_owner
    relaycast_runtime bulls96_read_api bulls96_session_ingest search_consumer_runtime bulls96_session_erase_search
    buffered_search_feed_runtime bulls96_acquisition_installer bulls96_analysis_admit
    bulls96_digest_narrative bulls96_legacy_export_privacy bulls96_privacy_eraser bulls96_project_events)

  cat >"$WORK/probe.sh" <<'EOS'
set -eu
Q="psql -X -A -t -v ON_ERROR_STOP=1"
version="$($Q -d postgres -c "select current_setting('server_version_num')::integer")" \
  || { echo 'could not read the PostgreSQL server version; refusing' >&2; exit 3; }
hoopdb_exists="$($Q -d postgres -c "select 1 from pg_database where datname='hoopdb'")" \
  || { echo 'could not inspect the HoopDb database; refusing' >&2; exit 3; }
if [ -z "$hoopdb_exists" ]; then
  if [ "$version" -ge 160000 ]; then echo 'HOOPDB_LAYOUT=fresh-dedicated'; else echo 'HOOPDB_LAYOUT=fresh-legacy'; fi
  exit 0
fi
owner="$($Q -d postgres -c "select pg_get_userbyid(datdba) from pg_database where datname='hoopdb'")" \
  || { echo 'could not inspect the HoopDb owner; refusing' >&2; exit 3; }
if [ "$owner" = hoopdb_owner ]; then
  echo 'HOOPDB_LAYOUT=dedicated-owner'; exit 0
fi
if [ "$owner" != "$PGUSER" ]; then
  echo 'HOOPDB_LAYOUT=unknown-owner'; exit 0
fi
pristine="$($Q -d hoopdb -c "
select 1 where
 to_regnamespace('sessions') is null
 and not exists (select 1 from pg_roles where rolname in ('hoopdb_owner','sessions_pipeline_runtime','search_consumer_runtime','session_directory_search_worker'))")" \
  || { echo 'could not inspect whether HoopDb is pristine; refusing' >&2; exit 3; }
if [ -n "$pristine" ]; then
  if [ "$version" -ge 160000 ]; then echo 'HOOPDB_LAYOUT=pristine-admin'; else echo 'HOOPDB_LAYOUT=fresh-legacy'; fi
  exit 0
fi
echo 'HOOPDB_LAYOUT=legacy-admin'
EOS
  run_job agent-relay-rds-layout-probe "$WORK/probe.sh"
  local layout
  layout="$(sed -n 's/^HOOPDB_LAYOUT=//p' "$WORK/agent-relay-rds-layout-probe.log" | tail -n 1)"
  if [[ "$layout" == pristine-admin ]]; then
    layout=fresh-dedicated
    log "pristine administrator-owned HoopDb detected; activating the fresh dedicated-owner layout"
  fi
  case "$layout" in
    legacy-admin)
      rm -f "$PENDING_ACTIVATION_FILE"
      printf '%s\n' "$layout" >"$LAYOUT_FILE"; chmod 600 "$LAYOUT_FILE"
      write_admin_files; write_layout_values "$layout"
      log "existing administrator-owned HoopDb detected; database and roles were left unchanged"
      log "use '$0 prepare-admin-jobs' immediately before an upgrade or guide Job, then '$0 delete-admin-jobs'"
      return
      ;;
    dedicated-owner)
      local missing_passwords=""
      for p in "${password_roles[@]}"; do [[ -s "$PW_DIR/$p" ]] || missing_passwords+=" $p"; done
      [[ -z "$missing_passwords" ]] \
        || die "dedicated-owner HoopDb exists but STATE_DIR lacked saved passwords for:${missing_passwords}; database and Secrets were left unchanged"
      rm -f "$PENDING_ACTIVATION_FILE"
      printf '%s\n' "$layout" >"$LAYOUT_FILE"; chmod 600 "$LAYOUT_FILE"
      write_credential_files; write_owner_files; write_layout_values "$layout"
      log "dedicated-owner HoopDb already active; database and roles were left unchanged"
      return
      ;;
    fresh-dedicated)
      printf 'fresh activation in progress\n' >"$PENDING_ACTIVATION_FILE"
      chmod 600 "$PENDING_ACTIVATION_FILE"
      ;;
    fresh-legacy)
      die "PostgreSQL 16 or later is required for a fresh dedicated-owner install; no database or role was changed. Existing PostgreSQL 15 installs stay on the legacy temporary-Secret path."
      ;;
    unknown-owner) die "HoopDb is owned by neither the RDS administrator nor hoopdb_owner; refusing" ;;
    *) die "layout probe returned no recognised result; database was left unchanged" ;;
  esac

  for p in "${password_roles[@]}"; do password_for "$p"; done

  printf 'hoopdb_layout=%q\n' "$layout" >"$WORK/run.sh"
  cat >> "$WORK/run.sh" <<'EOS'
set -eu
P="psql -X -q -v ON_ERROR_STOP=1"
Q="psql -X -A -t -v ON_ERROR_STOP=1"

# One HoopDb per RDS instance: this role is server-wide.
hoopdb_exists="$($Q -d postgres -c "select 1 from pg_database where datname='hoopdb'")" \
  || { echo 'could not inspect the HoopDb database; refusing' >&2; exit 3; }
search_worker_exists="$($Q -d postgres -c "select 1 from pg_roles where rolname='session_directory_search_worker'")" \
  || { echo 'could not inspect the search Worker role; refusing' >&2; exit 3; }
if [ -z "$hoopdb_exists" ] && [ -n "$search_worker_exists" ]; then
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

# HoopDb. PostgreSQL 16+ fresh installs use a disposable infra-owned role
# creator, then hand ownership to hoopdb_owner and drop the creator. Existing
# installs and fresh PG15 installs retain the administrator-owned layout.
export PGDATABASE=hoopdb
$P -c 'CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public; CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public; CREATE EXTENSION IF NOT EXISTS btree_gin WITH SCHEMA public;'
echo "extensions ready"
$P -f /sql/rds_owner_function_default_revoke.sql
echo "rds_owner_function_default_revoke ok"
$P -c 'ALTER DEFAULT PRIVILEGES FOR ROLE rds_superuser REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC'
echo "rds_superuser default revoke ok"
$P \
    -v owner_password="$hoopdb_owner" \
    -v runtime_password="$sessions_pipeline_runtime" \
    -v search_password="$search_consumer_runtime" \
    -v read_password="$bulls96_read_api" \
    -v ingest_password="$bulls96_session_ingest" \
    -v buffered_password="$buffered_search_feed_runtime" \
    -v acquisition_password="$bulls96_acquisition_installer" \
    -v analysis_password="$bulls96_analysis_admit" \
    -v digest_password="$bulls96_digest_narrative" \
    -v legacy_password="$bulls96_legacy_export_privacy" \
    -v privacy_password="$bulls96_privacy_eraser" \
    -v project_password="$bulls96_project_events" <<'SQL'
BEGIN;
CREATE ROLE agent_relay_hoopdb_role_creator NOLOGIN NOINHERIT CREATEROLE NOSUPERUSER NOCREATEDB NOREPLICATION NOBYPASSRLS;
GRANT agent_relay_hoopdb_role_creator TO CURRENT_USER WITH INHERIT FALSE, SET TRUE;
SET LOCAL ROLE agent_relay_hoopdb_role_creator;

CREATE ROLE anon NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE authenticated NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE service_role NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE session_directory_search_worker NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE session_directory_search_worker SET statement_timeout = '2s';
CREATE ROLE session_token_verifier NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE bulls96_session_ingest_seeder NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE bulls96_canonical_feature_producer NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE bulls96_babysitter_retention NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE bulls96_babysitter_retention SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE bulls96_babysitter_retention SET lock_timeout = '2s';
ALTER ROLE bulls96_babysitter_retention SET statement_timeout = '5s';
CREATE ROLE bulls96_session_erase_search NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE bulls96_session_erase_search SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE bulls96_session_erase_search SET lock_timeout = '2s';
ALTER ROLE bulls96_session_erase_search SET statement_timeout = '5s';

CREATE ROLE hoopdb_owner LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'owner_password';
CREATE ROLE sessions_pipeline_runtime LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'runtime_password';
CREATE ROLE search_consumer_runtime LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'search_password';
ALTER ROLE search_consumer_runtime SET statement_timeout = '60s';
CREATE ROLE bulls96_read_api LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'read_password';
ALTER ROLE bulls96_read_api SET default_transaction_read_only = 'on';
ALTER ROLE bulls96_read_api SET statement_timeout = '2s';
CREATE ROLE bulls96_session_ingest LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'ingest_password';
ALTER ROLE bulls96_session_ingest SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE bulls96_session_ingest SET lock_timeout = '2s';
ALTER ROLE bulls96_session_ingest SET statement_timeout = '5s';
CREATE ROLE buffered_search_feed_runtime LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'buffered_password';
ALTER ROLE buffered_search_feed_runtime SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE buffered_search_feed_runtime SET lock_timeout = '2s';
ALTER ROLE buffered_search_feed_runtime SET statement_timeout = '5s';
CREATE ROLE bulls96_acquisition_installer LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'acquisition_password';
ALTER ROLE bulls96_acquisition_installer SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE bulls96_acquisition_installer SET lock_timeout = '2s';
ALTER ROLE bulls96_acquisition_installer SET statement_timeout = '5s';
CREATE ROLE bulls96_analysis_admit LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'analysis_password';
ALTER ROLE bulls96_analysis_admit SET default_transaction_read_only = 'off';
ALTER ROLE bulls96_analysis_admit SET statement_timeout = '2s';
CREATE ROLE bulls96_digest_narrative LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'digest_password';
ALTER ROLE bulls96_digest_narrative SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE bulls96_digest_narrative SET lock_timeout = '2s';
ALTER ROLE bulls96_digest_narrative SET statement_timeout = '5s';
CREATE ROLE bulls96_legacy_export_privacy LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'legacy_password';
ALTER ROLE bulls96_legacy_export_privacy SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE bulls96_legacy_export_privacy SET lock_timeout = '5s';
ALTER ROLE bulls96_legacy_export_privacy SET statement_timeout = '20s';
CREATE ROLE bulls96_privacy_eraser LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'privacy_password';
ALTER ROLE bulls96_privacy_eraser SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE bulls96_privacy_eraser SET lock_timeout = '2s';
ALTER ROLE bulls96_privacy_eraser SET statement_timeout = '5s';
CREATE ROLE bulls96_project_events LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'project_password';
ALTER ROLE bulls96_project_events SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE bulls96_project_events SET lock_timeout = '2s';
ALTER ROLE bulls96_project_events SET statement_timeout = '5s';

GRANT hoopdb_owner TO agent_relay_hoopdb_role_creator WITH INHERIT FALSE, SET TRUE;
RESET ROLE;
ALTER DATABASE hoopdb OWNER TO hoopdb_owner;
SET LOCAL ROLE hoopdb_owner;
REVOKE CREATE, TEMPORARY ON DATABASE hoopdb FROM PUBLIC;
GRANT CONNECT ON DATABASE hoopdb TO sessions_pipeline_runtime,
  bulls96_read_api, bulls96_session_ingest, buffered_search_feed_runtime,
  bulls96_acquisition_installer, bulls96_analysis_admit, bulls96_digest_narrative,
  bulls96_legacy_export_privacy, bulls96_privacy_eraser, bulls96_project_events;
CREATE SCHEMA sessions;
CREATE SCHEMA search_index;
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
RESET ROLE;
DROP ROLE agent_relay_hoopdb_role_creator;
COMMIT;
SQL
echo "dedicated HoopDb owner and membership-free roles ready"
protected_edges="$($Q -c "with protected(name) as (values
  ('anon'),('authenticated'),('service_role'),('session_directory_search_worker'),
  ('session_token_verifier'),('bulls96_session_ingest_seeder'),
  ('bulls96_canonical_feature_producer'),('bulls96_babysitter_retention'),
  ('bulls96_session_erase_search'),('hoopdb_owner'),('sessions_pipeline_runtime'),
  ('search_consumer_runtime'),('bulls96_read_api'),('bulls96_session_ingest'),
  ('buffered_search_feed_runtime'),('bulls96_acquisition_installer'),
  ('bulls96_analysis_admit'),('bulls96_digest_narrative'),
  ('bulls96_legacy_export_privacy'),('bulls96_privacy_eraser'),
  ('bulls96_project_events'))
select count(*) from pg_auth_members m
join pg_roles granted on granted.oid=m.roleid
join pg_roles member on member.oid=m.member
where granted.rolname in (select name from protected)
   or member.rolname in (select name from protected)")" \
  || { echo 'could not inspect protected role memberships; refusing' >&2; exit 3; }
echo "protected role membership edges: $protected_edges"
[ "$protected_edges" = 0 ] || { echo 'protected HoopDb roles have membership edges; refusing' >&2; exit 3; }
$Q -c "select 'hoopdb owner: '||pg_get_userbyid(datdba) from pg_database where datname='hoopdb'"
$Q -c "select 'rdsadmin superuser: '||rolsuper from pg_roles where rolname='rdsadmin'"
$Q -c "select 'extensions: '||string_agg(extname,',' order by extname) from pg_extension"
EOS

  run_job agent-relay-rds-pre "$WORK/run.sh" control_owner control_api_runtime hoopdb_owner \
    sessions_pipeline_runtime search_consumer_runtime relaycast_owner relaycast_runtime \
    bulls96_read_api bulls96_session_ingest buffered_search_feed_runtime bulls96_acquisition_installer \
    bulls96_analysis_admit bulls96_digest_narrative bulls96_legacy_export_privacy \
    bulls96_privacy_eraser bulls96_project_events
  write_credential_files
  layout=dedicated-owner
  write_owner_files
  log "pre done; dedicated hoopdb_owner credentials are under $FILES"
  printf '%s\n' "$layout" >"$LAYOUT_FILE"; chmod 600 "$LAYOUT_FILE"
  write_layout_values "$layout"
  rm -f "$PENDING_ACTIVATION_FILE"
}

do_post() {
  : "${RELEASE:?set RELEASE to the exact Helm release name}"
  : "${MIGRATION_JOB:?set MIGRATION_JOB to the current rendered migrate Job name}"
  [[ "$MIGRATION_JOB" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "MIGRATION_JOB must be a DNS-1123 label"
  local p
  local layout
  [[ -s "$LAYOUT_FILE" ]] || die "missing HoopDb layout marker: run '$0 pre' first"
  layout="$(<"$LAYOUT_FILE")"
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
    [[ "$layout" == legacy-admin ]] \
      || die "the dedicated-owner RDS layout leaves bulls96_session_erase_search NOLOGIN; no reviewed activation path exists"
    # Existing installs use refresh-admin, not pre. The optional SQL can create
    # this one identity after search bootstrap without re-running core role SQL.
    password_for bulls96_session_erase_search
    post_passwords+=(bulls96_session_erase_search)
  fi
  printf 'provision_erase_search_login=%s\nhoopdb_layout=%q\n' "$PROVISION_ERASE_SEARCH_LOGIN" "$layout" > "$WORK/run.sh"
  cat >> "$WORK/run.sh" <<'EOS'
set -eu
export PGDATABASE=hoopdb
P="psql -X -q -v ON_ERROR_STOP=1"
Q="psql -X -A -t -v ON_ERROR_STOP=1"

if [ "$hoopdb_layout" = dedicated-owner ]; then
  read_role_exists="$($Q -c "select 1 from pg_roles where rolname='bulls96_read_api'")" \
    || { echo 'could not inspect bulls96_read_api; refusing' >&2; exit 3; }
  if [ -z "$read_role_exists" ]; then
    echo 'bulls96_read_api does not exist: run rds-setup.sh pre first' >&2; exit 3
  fi
  sed '/^ALTER ROLE bulls96_read_api /d' /sql/session_read_api_role.sql > /tmp/session_read_api_role.sql
  if grep -Eq '^(ALTER|CREATE)[[:space:]]+ROLE([[:space:]]|$)' /tmp/session_read_api_role.sql; then
    echo 'filtered session_read_api_role.sql still contains ALTER ROLE or CREATE ROLE' >&2; exit 3
  fi
  $P -f /tmp/session_read_api_role.sql
else
  $P -f /sql/session_read_api_role.sql
fi
if [ "$hoopdb_layout" = legacy-admin ]; then
  printf '%s\n' "ALTER ROLE bulls96_read_api PASSWORD :'p1';" | $P -v p1="$bulls96_read_api"
fi
$P -c 'GRANT CONNECT ON DATABASE hoopdb TO bulls96_read_api'
$P -f /sql/session_read_api_role_verify.sql
echo "read API role ok"

if [ "$hoopdb_layout" = dedicated-owner ]; then
  ingest_role_exists="$($Q -c "select 1 from pg_roles where rolname='bulls96_session_ingest'")" \
    || { echo 'could not inspect bulls96_session_ingest; refusing' >&2; exit 3; }
  if [ -z "$ingest_role_exists" ]; then
    echo 'bulls96_session_ingest does not exist: run rds-setup.sh pre first' >&2; exit 3
  fi
  sed '/^ALTER ROLE bulls96_session_ingest /d' /sql/session_ingest_role.sql > /tmp/session_ingest_role.sql
  if grep -Eq '^(ALTER|CREATE)[[:space:]]+ROLE([[:space:]]|$)' /tmp/session_ingest_role.sql; then
    echo 'filtered session_ingest_role.sql still contains ALTER ROLE or CREATE ROLE' >&2; exit 3
  fi
  $P -f /tmp/session_ingest_role.sql
else
  $P -f /sql/session_ingest_role.sql
fi
if [ "$hoopdb_layout" = legacy-admin ]; then
  printf '%s\n' "ALTER ROLE bulls96_session_ingest PASSWORD :'p1';" | $P -v p1="$bulls96_session_ingest"
fi
$P -c 'GRANT CONNECT ON DATABASE hoopdb TO bulls96_session_ingest'
$P -f /sql/session_ingest_role_verify.sql
$P -f /sql/session_ingest_verify.sql
echo "ingest role ok"

search_role_exists="$($Q -c "select 1 from pg_roles where rolname='search_consumer_runtime'")" \
  || { echo 'could not inspect search_consumer_runtime; refusing' >&2; exit 3; }
if [ -z "$search_role_exists" ]; then
  echo "search_consumer_runtime does not exist: the migrations have not created it" >&2
  exit 3
fi
if [ "$hoopdb_layout" = legacy-admin ]; then
  printf '%s\n' "ALTER ROLE search_consumer_runtime LOGIN NOINHERIT PASSWORD :'p1'; ALTER ROLE search_consumer_runtime SET statement_timeout = '60s';" | $P -v p1="$search_consumer_runtime"
fi
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

  if [[ "$layout" == dedicated-owner ]]; then RUN_JOB_AS_OWNER=1 run_job agent-relay-rds-post "$WORK/run.sh" "${post_passwords[@]}"
  else run_job agent-relay-rds-post "$WORK/run.sh" "${post_passwords[@]}"
  fi
  if [[ "$PROVISION_ERASE_SEARCH_LOGIN" == 1 ]]; then
    write_file session-erase-search-runtime SESSION_ERASE_SEARCH_POSTGRES_URL \
      < <(url postgresql bulls96_session_erase_search "$(pw bulls96_session_erase_search)" hoopdb)
  fi
  log "post done; restart the read API, ingest edge and search indexer"
}

"do_$MODE"
