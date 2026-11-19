#!/usr/bin/env bash
# Sets up the native Agent Relay databases and roles on one private Cloud SQL
# for PostgreSQL instance.
#
#   cloud-sql-setup.sh pre   Before Helm. Creates databases, owner/runtime
#                            roles, extensions, the CA ConfigMap and credential
#                            files.
#   cloud-sql-setup.sh post  After the HoopDb migrate Job. Activates the read,
#                            ingest and search logins.
#   cloud-sql-setup.sh prepare-admin-jobs
#                            Existing installs only: creates the short-lived
#                            hoopdb-admin-jobs Secret for an upgrade/guide Job.
#   cloud-sql-setup.sh remove-legacy-secret-keys
#                            After Helm, Jobs and Deployments succeed, removes
#                            the two old administrator-derived long-lived keys.
#   cloud-sql-setup.sh delete-admin-jobs
#                            Deletes the short-lived Secret on success or failure.
#
# SQL runs in short-lived Jobs inside GKE, so the instance needs no public IP.
# Required environment:
#   GCP_PROJECT_ID              project that owns the Cloud SQL instance
#   CLOUD_SQL_INSTANCE          Cloud SQL instance name
#   CLOUD_SQL_HOST              terraform output postgres.dns_name
#   CLOUD_SQL_ADMIN_USER        terraform output postgres.admin_username
#   CLOUD_SQL_ADMIN_SECRET_ID   terraform output postgres.admin_password_secret_id
#                               (a secret id, or projects/<project>/secrets/<id>)
#   SERVICES_IMAGE              sessions-pipeline image pinned by digest
# Optional:
#   CLOUD_SQL_CA_FILE           shared-CA PEM bundle (otherwise fetched by gcloud)
#   CLOUD_SQL_CA_SHA256         expected bundle sha256 (the caSha256 in Terraform's
#                               chart_values); pre fails if the bundle differs
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
case "$MODE" in pre|post|prepare-admin-jobs|remove-legacy-secret-keys|delete-admin-jobs) ;; *) echo "usage: $0 pre|post|prepare-admin-jobs|remove-legacy-secret-keys|delete-admin-jobs" >&2; exit 2 ;; esac

: "${GCP_PROJECT_ID:?set GCP_PROJECT_ID}"
: "${CLOUD_SQL_INSTANCE:?set CLOUD_SQL_INSTANCE}"
: "${CLOUD_SQL_HOST:?set CLOUD_SQL_HOST (terraform output postgres.dns_name)}"
: "${CLOUD_SQL_ADMIN_USER:?set CLOUD_SQL_ADMIN_USER}"
: "${CLOUD_SQL_ADMIN_SECRET_ID:?set CLOUD_SQL_ADMIN_SECRET_ID}"
if [[ "$MODE" == pre || "$MODE" == post ]]; then
  : "${SERVICES_IMAGE:?set SERVICES_IMAGE to the sessions-pipeline image from images.md}"
else
  SERVICES_IMAGE="${SERVICES_IMAGE:-unused@sha256:0}"
fi
PSQL_IMAGE="${PSQL_IMAGE:-ghcr.io/cloudnative-pg/postgresql:17-standard-trixie@sha256:ed6923f9ba2399cf9070379a353c710c29ced8a294be73986a2c3dae7e599ce3}"
NS="${NAMESPACE:-agent-relay}"
HELM_RELEASE="${HELM_RELEASE:-agent-relay}"
STATE_DIR="${STATE_DIR:-$HOME/.agent-relay-install}"
PW_DIR="$STATE_DIR/passwords"
FILES="$STATE_DIR/secret-files"
LAYOUT_FILE="$STATE_DIR/hoopdb-layout"
PENDING_PASSWORDS_FILE="$STATE_DIR/.pending-hoopdb-passwords"
PENDING_ACTIVATION_FILE="$STATE_DIR/.pending-hoopdb-activation"
ADMIN_JOBS_SECRET=hoopdb-admin-jobs
OWNER=hoopdb_owner
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
  # Terraform outputs the full resource name; gcloud --secret wants the id.
  local project="$GCP_PROJECT_ID" id="$CLOUD_SQL_ADMIN_SECRET_ID"
  if [[ "$id" =~ ^projects/([^/]+)/secrets/([^/]+)$ ]]; then
    project="${BASH_REMATCH[1]}"; id="${BASH_REMATCH[2]}"
  fi
  gcloud secrets versions access latest --project "$project" --secret "$id" --quiet
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
  # Exactly one trailing newline, the same bytes as Terraform's server_ca_cert,
  # so the caSha256 pins in its chart_values match this ConfigMap.
  local normalized; normalized="$(cat "$bundle")"
  printf '%s\n' "$normalized" >"$bundle"
  chmod 600 "$bundle"
  if [[ -n "${CLOUD_SQL_CA_SHA256:-}" ]]; then
    [[ "$(sha256sum "$bundle" | cut -d' ' -f1)" == "$CLOUD_SQL_CA_SHA256" ]] || \
      die "Cloud SQL CA bundle sha256 differs from CLOUD_SQL_CA_SHA256 (re-run terraform output chart_values)"
  fi

  actual_host="$(gcloud sql instances describe "$CLOUD_SQL_INSTANCE" --project "$GCP_PROJECT_ID" \
    --format=json --quiet | jq -r '(.dnsNames // []) | map(select(.connectionType == "PRIVATE_SERVICES_ACCESS")) | first | .name // empty')"
  [[ -n "$actual_host" ]] || die "Cloud SQL instance has no private-services-access DNS name; use GOOGLE_MANAGED_CAS_CA"
  [[ "$actual_host" == "$CLOUD_SQL_HOST" ]] || die "CLOUD_SQL_HOST does not match the instance DNS name"

  kubectl -n "$NS" create configmap cloud-sql-ca --from-file=ca.crt="$bundle" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  sha256sum "$bundle" | cut -d' ' -f1 >"$STATE_DIR/cloud-sql-ca.sha256"
  log "cloud-sql-ca ConfigMap applied; sha256 $(cat "$STATE_DIR/cloud-sql-ca.sha256")"
}

# run_job NAME SCRIPT MISSING_STATE_NAMES [password-name ...]
run_job() {
  local name="$1" script="$2" missing_state_names="$3"; shift 3
  JOB_SECRET="$name-secret"
  local secret_dir="$WORK/$name-secret" p
  mkdir -p "$secret_dir"
  printf '%s' "$CLOUD_SQL_ADMIN_USER" >"$secret_dir/PGUSER"
  admin_password >"$secret_dir/PGPASSWORD"
  # Names only: the in-cluster classifier must refuse an existing dedicated
  # owner before it uses any newly generated credential value.
  printf '%s' "$missing_state_names" >"$secret_dir/MISSING_STATE_NAMES"
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
    | grep -v -i -E 'password|postgres(ql)?://' | cut -c1-240 | tee "$WORK/$name.log" || true
  kubectl -n "$NS" delete secret "$JOB_SECRET" --ignore-not-found >/dev/null
  JOB_SECRET=""
  kubectl -n "$NS" delete configmap "$name-run" --ignore-not-found >/dev/null
  if [[ "$ok" != 1 ]]; then
    if [[ "$name" == agent-relay-cloud-sql-pre ]] && \
       grep -qx 'HOOPDB_STATE=dedicated-owner-missing' "$WORK/$name.log"; then
      if [[ ! -s "$PENDING_ACTIVATION_FILE" ]]; then
        for p in $missing_state_names; do rm -f "$PW_DIR/$p"; done
        rm -f "$PENDING_PASSWORDS_FILE"
      fi
      die "dedicated-owner HoopDb exists but STATE_DIR lacked saved passwords for:${missing_state_names}; database and Secrets were left unchanged"
    fi
    die "job $name did not succeed (inspect the retained Job)"
  fi
  log "job $name succeeded"
}

url() { printf '%s://%s:%s@%s:5432/%s?sslmode=verify-full' "$1" "$2" "$3" "$CLOUD_SQL_HOST" "$4"; }
pw() { cat "$PW_DIR/$1"; }
json_url() { jq -cn --arg k "$1" --arg v "$2" '{($k):$v}'; }
admin_url() {
  local password
  password="$(admin_password)" || die "could not read the Cloud SQL administrator password"
  [[ -n "$password" ]] || die "the Cloud SQL administrator password is empty"
  url postgresql "$CLOUD_SQL_ADMIN_USER" "$password" "$1"
}

write_legacy_admin_files() {
  local owner
  owner="$(admin_url hoopdb)" || die "could not build the Cloud SQL administrator URL"
  write_file "$ADMIN_JOBS_SECRET" HOOPDB_MIGRATION_URL < <(printf '%s' "$owner")
  write_file "$ADMIN_JOBS_SECRET" RELAYHISTORY_PIPELINE_CONSUMER_SECRET < <(json_url hoopdb_url "$owner")
  rm -f "$FILES/agent-relay-secrets/HOOPDB_MIGRATION_URL" \
    "$FILES/search-indexer-owner/RELAYHISTORY_PIPELINE_CONSUMER_SECRET"
}

write_layout_values() {
  local migration_secret=agent-relay-secrets search_secret=search-indexer-owner
  if [[ "$1" == legacy-admin ]]; then
    migration_secret="$ADMIN_JOBS_SECRET"; search_secret="$ADMIN_JOBS_SECRET"
  fi
  printf '%s\n' \
    'sessions-pipeline:' \
    '  worker:' \
    '    migrations:' \
    '      hoopdb:' \
    "        existingSecret: $migration_secret" \
    '        key: HOOPDB_MIGRATION_URL' \
    '  searchIndexer:' \
    '    bootstrap:' \
    "      existingSecret: $search_secret" \
    '      key: RELAYHISTORY_PIPELINE_CONSUMER_SECRET' >"$STATE_DIR/hoopdb-layout-values.yaml"
  chmod 600 "$STATE_DIR/hoopdb-layout-values.yaml"
}

remove_legacy_secret_keys() {
  local pair secret key secret_json secret_error key_present externally_managed
  for pair in agent-relay-secrets:HOOPDB_MIGRATION_URL \
              search-indexer-owner:RELAYHISTORY_PIPELINE_CONSUMER_SECRET; do
    secret="${pair%%:*}"; key="${pair#*:}"
    secret_json="$WORK/$secret.json"; secret_error="$WORK/$secret.err"
    if ! kubectl -n "$NS" get secret "$secret" -o json >"$secret_json" 2>"$secret_error"; then
      grep -qi 'not[[:space:]]*found' "$secret_error" && continue
      die "could not read Secret $secret while removing legacy administrator keys"
    fi
    key_present="$(jq -r --arg key "$key" 'if .data[$key] == null then "no" else "yes" end' "$secret_json")" \
      || die "could not parse Secret $secret while removing legacy administrator keys"
    [[ "$key_present" == no ]] && continue
    externally_managed="$(jq -r '
      any(.metadata.ownerReferences[]?; .kind == "ExternalSecret") or
      ((.metadata.labels // {}) | has("reconcile.external-secrets.io/managed"))' "$secret_json")" \
      || die "could not parse Secret $secret while checking its owner"
    if [[ "$externally_managed" == true ]]; then
      die "Secret $secret is managed by External Secrets: remove the $key mapping from its ExternalSecret and delete the backing-store value, wait for reconciliation, then rerun cleanup; $ADMIN_JOBS_SECRET was retained"
    fi
    kubectl -n "$NS" patch secret "$secret" --type=merge \
      -p "{\"data\":{\"$key\":null}}" >/dev/null
    log "removed legacy administrator key $secret/$key"
  done
}

write_credential_files() {
  write_file agent-relay-secrets database-migrations-url < <(url postgresql control_owner "$(pw control_owner)" relaycontrol)
  write_file agent-relay-secrets database-url < <(url postgresql control_api_runtime "$(pw control_api_runtime)" relaycontrol)
  # Native brief workers require the mounted CA path in the URL in addition to
  # NODE_EXTRA_CA_CERTS; keep this query parameter on every generated copy.
  write_file agent-relay-secrets HOOPDB_URL \
    < <(printf '%s&sslrootcert=/etc/postgres-ca/ca.crt' "$(url postgresql sessions_pipeline_runtime "$(pw sessions_pipeline_runtime)" hoopdb)")
  write_file agent-relay-secrets database-owner-url < <(url postgres relaycast_owner "$(pw relaycast_owner)" relaycast)
  write_file agent-relay-secrets database-runtime-url < <(url postgres relaycast_runtime "$(pw relaycast_runtime)" relaycast)
  write_file agent-relay-read-api RELAYHISTORY_READ_API_SECRET < <(json_url supabase_url "$(url postgresql bulls96_read_api "$(pw bulls96_read_api)" hoopdb)")
  write_file agent-relay-ingest-edge-runtime database-url < <(url postgresql bulls96_session_ingest "$(pw bulls96_session_ingest)" hoopdb)
  write_file search-indexer-runtime RELAYHISTORY_PIPELINE_CONSUMER_SECRET < <(json_url hoopdb_url "$(url postgresql search_consumer_runtime "$(pw search_consumer_runtime)" hoopdb)")
  local owner; owner="$(url postgresql "$OWNER" "$(pw "$OWNER")" hoopdb)"
  write_file agent-relay-secrets HOOPDB_MIGRATION_URL < <(printf '%s' "$owner")
  write_file search-indexer-owner RELAYHISTORY_PIPELINE_CONSUMER_SECRET < <(json_url hoopdb_url "$owner")
}

do_pre() {
  local admin_probe
  admin_probe="$(admin_password)" || die "could not read the Cloud SQL administrator password"
  [[ -n "$admin_probe" ]] || die "the Cloud SQL administrator password is empty"
  unset admin_probe
  kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null
  ensure_ca

  # Classify before generating any password. The durable activation marker
  # distinguishes a fresh setup interrupted after creating the database (or
  # committing ownership) from a genuinely pre-existing administrator-owned
  # or dedicated-owner install whose saved state is incomplete.
  cat >"$WORK/probe.sh" <<'EOS'
set -eu
Q="psql -X -A -t -v ON_ERROR_STOP=1"
hoopdb_exists="$($Q -d postgres -c "select 1 from pg_database where datname='hoopdb'")" \
  || { echo 'could not inspect the HoopDb database; refusing' >&2; exit 3; }
if [ -z "$hoopdb_exists" ]; then
  echo 'HOOPDB_LAYOUT=fresh-dedicated'; exit 0
fi
owner="$($Q -d postgres -c "select pg_get_userbyid(datdba) from pg_database where datname='hoopdb'")" \
  || { echo 'could not inspect the HoopDb owner; refusing' >&2; exit 3; }
if [ "$owner" = hoopdb_owner ]; then
  echo 'HOOPDB_LAYOUT=dedicated-owner'
elif [ "$owner" = "$PGUSER" ]; then
  pristine="$($Q -d hoopdb -c "
select 1 where
 to_regnamespace('sessions') is null
 and not exists (select 1 from pg_roles where rolname in ('hoopdb_owner','sessions_pipeline_runtime','search_consumer_runtime','session_directory_search_worker'))")" \
    || { echo 'could not inspect whether HoopDb is pristine; refusing' >&2; exit 3; }
  if [ -n "$pristine" ]; then echo 'HOOPDB_LAYOUT=pristine-admin'; else echo 'HOOPDB_LAYOUT=legacy-admin'; fi
else
  echo 'HOOPDB_LAYOUT=unknown-owner'
fi
EOS
  run_job agent-relay-cloud-sql-probe "$WORK/probe.sh" ""
  local probed_layout
  probed_layout="$(sed -n 's/^HOOPDB_LAYOUT=//p' "$WORK/agent-relay-cloud-sql-probe.log" | tail -n 1)"
  if [[ ( "$probed_layout" == legacy-admin || "$probed_layout" == pristine-admin ) && -s "$PENDING_ACTIVATION_FILE" ]]; then
    probed_layout=fresh-dedicated
    log "resuming an interrupted fresh activation"
  fi
  if [[ "$probed_layout" == pristine-admin ]]; then
    probed_layout=fresh-dedicated
    log "pristine administrator-owned HoopDb detected; activating the fresh dedicated-owner layout"
  fi
  case "$probed_layout" in
    legacy-admin)
      rm -f "$PENDING_PASSWORDS_FILE" "$PENDING_ACTIVATION_FILE"
      printf '%s\n' "$probed_layout" >"$LAYOUT_FILE"; chmod 600 "$LAYOUT_FILE"
      write_legacy_admin_files; write_layout_values "$probed_layout"
      log "existing administrator-owned HoopDb detected; database and roles were left unchanged"
      log "use '$0 prepare-admin-jobs' before an upgrade/guide Job; after success run '$0 remove-legacy-secret-keys', then always '$0 delete-admin-jobs'"
      return
      ;;
    fresh-dedicated|dedicated-owner) ;;
    *) die "HoopDb owner is neither the Cloud SQL administrator nor hoopdb_owner; refusing" ;;
  esac

  local p pending_passwords="" pending_candidates="" missing_passwords="" generated_passwords="" untrusted_passwords=""
  [[ ! -s "$PENDING_PASSWORDS_FILE" ]] || pending_passwords="$(<"$PENDING_PASSWORDS_FILE")"
  for p in control_owner control_api_runtime "$OWNER" sessions_pipeline_runtime relaycast_owner relaycast_runtime \
           bulls96_read_api bulls96_session_ingest search_consumer_runtime; do
    if [[ ! -s "$PW_DIR/$p" ]]; then
      missing_passwords+=" $p"; generated_passwords+=" $p"
    elif [[ " $pending_passwords " == *" $p "* ]]; then
      pending_candidates+=" $p"
    fi
    password_for "$p"
  done
  if [[ -s "$PENDING_ACTIVATION_FILE" && -n "$missing_passwords" ]]; then
    for p in $generated_passwords; do rm -f "$PW_DIR/$p"; done
    die "an interrupted activation lacks saved passwords for:${missing_passwords}; generated replacements were removed and the database and Secrets were left unchanged"
  fi
  untrusted_passwords="$missing_passwords$pending_candidates"
  if [[ -n "$untrusted_passwords" ]]; then
    printf '%s\n' "${untrusted_passwords# }" >"$PENDING_PASSWORDS_FILE"; chmod 600 "$PENDING_PASSWORDS_FILE"
  fi
  if [[ "$probed_layout" == dedicated-owner && -n "$untrusted_passwords" && ! -s "$PENDING_ACTIVATION_FILE" ]]; then
    for p in $generated_passwords; do rm -f "$PW_DIR/$p"; done
    rm -f "$PENDING_PASSWORDS_FILE"
    die "dedicated-owner HoopDb exists but STATE_DIR lacked trusted saved passwords for:${untrusted_passwords}; database and Secrets were left unchanged"
  fi
  if [[ "$probed_layout" == fresh-dedicated && ! -s "$PENDING_ACTIVATION_FILE" ]]; then
    printf 'fresh activation in progress\n' >"$PENDING_ACTIVATION_FILE"
    chmod 600 "$PENDING_ACTIVATION_FILE"
  fi
  local missing_for_job="$untrusted_passwords"
  if [[ "$probed_layout" == dedicated-owner && -s "$PENDING_ACTIVATION_FILE" ]]; then
    missing_for_job=""
  fi

  cat >"$WORK/run.sh" <<'EOS'
set -eu
P="psql -X -q -v ON_ERROR_STOP=1"
Q="psql -X -A -t -v ON_ERROR_STOP=1"

hoopdb_exists="$($Q -d postgres -c "select 1 from pg_database where datname='hoopdb'")" \
  || { echo 'could not inspect the HoopDb database; refusing' >&2; exit 3; }
if [ -z "$hoopdb_exists" ]; then
  search_worker_exists="$($Q -d postgres -c "select 1 from pg_roles where rolname='session_directory_search_worker'")" \
    || { echo 'could not inspect the search Worker role; refusing' >&2; exit 3; }
  if [ -n "$search_worker_exists" ]; then
    echo "this Cloud SQL instance already belongs to another HoopDb install" >&2; exit 3
  fi
  owner="$PGUSER"
else
  owner="$($Q -d postgres -c "select pg_get_userbyid(datdba) from pg_database where datname='hoopdb'")" \
    || { echo 'could not inspect the HoopDb owner; refusing' >&2; exit 3; }
  export PGDATABASE=hoopdb
fi
existing_dedicated=0
if [ -n "$hoopdb_exists" ] && [ "$owner" = "$PGUSER" ]; then
  sessions_schema="$($Q -c "select to_regnamespace('sessions')")" \
    || { echo 'could not inspect the HoopDb sessions schema; refusing' >&2; exit 3; }
  runtime_role="$($Q -c "select 1 from pg_roles where rolname='sessions_pipeline_runtime'")" \
    || { echo 'could not inspect the HoopDb runtime role; refusing' >&2; exit 3; }
  if [ -n "$sessions_schema" ] || [ -n "$runtime_role" ]; then
    echo 'HOOPDB_LAYOUT=legacy-admin'
    exit 0
  fi
fi
if [ "$owner" = 'hoopdb_owner' ]; then
  existing_dedicated=1
  if [ -n "$MISSING_STATE_NAMES" ]; then
    echo 'HOOPDB_STATE=dedicated-owner-missing'
    echo "dedicated-owner HoopDb exists but saved credential state lacks:$MISSING_STATE_NAMES; refusing before database changes" >&2
    exit 3
  fi
elif [ "$owner" != "$PGUSER" ]; then
  echo "HoopDb owner is neither the Cloud SQL administrator nor hoopdb_owner; refusing" >&2
  exit 3
fi
unset PGDATABASE

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

$P -c 'CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public; CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public; CREATE EXTENSION IF NOT EXISTS btree_gin WITH SCHEMA public;'
$P -f /sql/cloudsql_migration_roles.sql
if [ "$existing_dedicated" = 0 ]; then
  $P -v owner_password="$hoopdb_owner" -v runtime_password="$sessions_pipeline_runtime" -v search_password="$search_consumer_runtime" <<'SQL'
BEGIN;
CREATE ROLE agent_relay_hoopdb_role_creator NOLOGIN NOINHERIT CREATEROLE NOSUPERUSER NOCREATEDB NOREPLICATION NOBYPASSRLS;
GRANT agent_relay_hoopdb_role_creator TO CURRENT_USER WITH INHERIT FALSE, SET TRUE;
SET LOCAL ROLE agent_relay_hoopdb_role_creator;
CREATE ROLE hoopdb_owner LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'owner_password';
CREATE ROLE sessions_pipeline_runtime LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'runtime_password';
CREATE ROLE search_consumer_runtime LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'search_password';
ALTER ROLE search_consumer_runtime SET statement_timeout = '60s';
GRANT hoopdb_owner TO agent_relay_hoopdb_role_creator WITH INHERIT FALSE, SET TRUE;
RESET ROLE;
ALTER DATABASE hoopdb OWNER TO hoopdb_owner;
SET LOCAL ROLE hoopdb_owner;
CREATE SCHEMA sessions;
CREATE SCHEMA search_index;
\i /sql/cloudsql_owner_function_default_revoke.sql
REVOKE TEMPORARY ON DATABASE hoopdb FROM PUBLIC;
GRANT CONNECT ON DATABASE hoopdb TO sessions_pipeline_runtime;
RESET ROLE;
DROP ROLE agent_relay_hoopdb_role_creator;
COMMIT;
SQL
  echo "dedicated HoopDb owner and runtime roles ready"
  echo 'HOOPDB_STATE=fresh-credentials-committed'
else
  echo "dedicated HoopDb ownership already committed; finishing prerequisites"
fi

for f in session_directory_search_worker session_token_verifier session_ingest_roles session_read_api_roles; do
  $P -f "/sql/$f.sql"; echo "$f ok"
done
protected_edges="$($Q -c "with protected(name) as (values
  ('anon'),('authenticated'),('service_role'),('session_directory_search_worker'),
  ('session_token_verifier'),('bulls96_session_ingest_seeder'),
  ('bulls96_canonical_feature_producer'),('bulls96_babysitter_retention'),
  ('hoopdb_owner'),('sessions_pipeline_runtime'),('search_consumer_runtime'),
  ('bulls96_read_api'),('bulls96_session_ingest'),('buffered_search_feed_runtime'),
  ('bulls96_acquisition_installer'),('bulls96_analysis_admit'),
  ('bulls96_digest_narrative'),('bulls96_legacy_export_privacy'),
  ('bulls96_privacy_eraser'),('bulls96_project_events'))
select count(*) from pg_auth_members m
join pg_roles granted on granted.oid=m.roleid
join pg_roles member on member.oid=m.member
where granted.rolname in (select name from protected)
   or member.rolname in (select name from protected)")" \
  || { echo 'could not inspect protected role memberships; refusing' >&2; exit 3; }
echo "protected role membership edges: $protected_edges"
[ "$protected_edges" = 0 ] || { echo 'protected HoopDb roles have membership edges; refusing' >&2; exit 3; }
$Q -c "select 'hoopdb owner: '||pg_get_userbyid(datdba) from pg_database where datname='hoopdb'"
$Q -c "select 'tls: '||ssl from pg_stat_ssl where pid=pg_backend_pid()"
$Q -c "select 'extensions: '||string_agg(extname,',' order by extname) from pg_extension"
if [ "$existing_dedicated" = 1 ]; then
  echo 'HOOPDB_LAYOUT=dedicated-owner'
else
  echo 'HOOPDB_LAYOUT=fresh-dedicated'
fi
EOS
  run_job agent-relay-cloud-sql-pre "$WORK/run.sh" "$missing_for_job" \
    control_owner control_api_runtime "$OWNER" sessions_pipeline_runtime \
    search_consumer_runtime relaycast_owner relaycast_runtime
  local layout
  layout="$(sed -n 's/^HOOPDB_LAYOUT=//p' "$WORK/agent-relay-cloud-sql-pre.log" | tail -n 1)"
  case "$layout" in
    dedicated-owner)
      if [[ -n "$missing_passwords" && ! -s "$PENDING_ACTIVATION_FILE" ]]; then
        for p in $missing_passwords; do rm -f "$PW_DIR/$p"; done
        die "dedicated-owner HoopDb exists but STATE_DIR lacked saved passwords for:${missing_passwords}; database and Secrets were left unchanged"
      fi
      rm -f "$PENDING_PASSWORDS_FILE" "$PENDING_ACTIVATION_FILE"
      printf '%s\n' "$layout" >"$LAYOUT_FILE"; chmod 600 "$LAYOUT_FILE"
      write_credential_files; write_layout_values "$layout"
      log "dedicated hoopdb_owner layout already active; passwords and database were left unchanged"
      ;;
    fresh-dedicated)
      layout=dedicated-owner
      rm -f "$PENDING_PASSWORDS_FILE" "$PENDING_ACTIVATION_FILE"
      printf '%s\n' "$layout" >"$LAYOUT_FILE"; chmod 600 "$LAYOUT_FILE"
      write_credential_files; write_layout_values "$layout"
      log "pre done; dedicated hoopdb_owner credentials are under $FILES"
      ;;
    legacy-admin)
      for p in $missing_passwords; do rm -f "$PW_DIR/$p"; done
      rm -f "$PENDING_PASSWORDS_FILE" "$PENDING_ACTIVATION_FILE"
      printf '%s\n' "$layout" >"$LAYOUT_FILE"; chmod 600 "$LAYOUT_FILE"
      write_legacy_admin_files; write_layout_values "$layout"
      log "existing administrator-owned HoopDb detected; database and roles were left unchanged"
      log "use '$0 prepare-admin-jobs' before an upgrade/guide Job; after success run '$0 remove-legacy-secret-keys', then always '$0 delete-admin-jobs'"
      ;;
    *) die "setup Job returned no recognised HoopDb layout; nothing was written to install Secrets" ;;
  esac
}

do_post() {
  local p
  for p in bulls96_read_api bulls96_session_ingest search_consumer_runtime; do
    [[ -s "$PW_DIR/$p" ]] || die "missing $p password: run '$0 pre' first"
  done
  local migration_job migration_json
  migration_job="$(helm -n "$NS" get manifest "$HELM_RELEASE" | awk '
    function emit() { if (kind == "Job" && name != "" && hoopdb) print name }
    /^---[[:space:]]*$/ { emit(); kind=""; name=""; hoopdb=0; next }
    /^kind:[[:space:]]+Job[[:space:]]*$/ { kind="Job"; next }
    /^  name:[[:space:]]+/ && name == "" { name=$2; next }
    /^[[:space:]]+app\.kubernetes\.io\/component:[[:space:]]+hoopdb-migrate[[:space:]]*$/ { hoopdb=1 }
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
search_role_exists="$($Q -c "select 1 from pg_roles where rolname='search_consumer_runtime'")" \
  || { echo 'could not inspect search_consumer_runtime; refusing' >&2; exit 3; }
if [ -z "$search_role_exists" ]; then
  echo "search_consumer_runtime missing: migrations have not completed" >&2; exit 3
fi
database_owner="$($Q -d postgres -c "select pg_get_userbyid(datdba) from pg_database where datname='hoopdb'")" \
  || { echo 'could not inspect the HoopDb owner; refusing' >&2; exit 3; }
if [ "$database_owner" = hoopdb_owner ]; then
  $Q -c "select 1 from pg_roles where rolname='search_consumer_runtime' and rolcanlogin and not rolsuper and not rolcreaterole and not rolcreatedb" | grep -qx 1 \
    || { echo 'dedicated search consumer role has drifted' >&2; exit 3; }
else
  printf '%s\n' "ALTER ROLE search_consumer_runtime LOGIN NOINHERIT PASSWORD :'p1'; ALTER ROLE search_consumer_runtime SET statement_timeout='60s';" | $P -v p1="$search_consumer_runtime"
fi
echo "search consumer role ok"
for role in bulls96_read_api bulls96_session_ingest search_consumer_runtime; do
  eval "secret=\$$role"
  PGUSER="$role" PGPASSWORD="$secret" $Q -c "select 'login ok: '||session_user||' tls='||(select ssl from pg_stat_ssl where pid=pg_backend_pid())"
done
EOS
  run_job agent-relay-cloud-sql-post "$WORK/run.sh" "" \
    bulls96_read_api bulls96_session_ingest search_consumer_runtime
  log "post done; restart the read API, ingest edge and search indexer"
}

do_prepare-admin-jobs() {
  [[ -s "$LAYOUT_FILE" && "$(<"$LAYOUT_FILE")" == legacy-admin ]] \
    || die "prepare-admin-jobs is only for an existing administrator-owned install; run '$0 pre' first"
  write_legacy_admin_files
  kubectl -n "$NS" delete secret "$ADMIN_JOBS_SECRET" --ignore-not-found >/dev/null
  kubectl -n "$NS" create secret generic "$ADMIN_JOBS_SECRET" \
    --from-file="$FILES/$ADMIN_JOBS_SECRET" >/dev/null
  log "$ADMIN_JOBS_SECRET created for migration/bootstrap Jobs only; retain the old keys until Helm, Jobs and Deployments succeed"
}

do_remove-legacy-secret-keys() {
  [[ -s "$LAYOUT_FILE" && "$(<"$LAYOUT_FILE")" == legacy-admin ]] \
    || die "remove-legacy-secret-keys is only for an existing administrator-owned install; run '$0 pre' first"
  kubectl -n "$NS" get secret "$ADMIN_JOBS_SECRET" -o name >/dev/null \
    || die "$ADMIN_JOBS_SECRET is absent: run '$0 prepare-admin-jobs' first"
  remove_legacy_secret_keys
  log "legacy administrator keys removed after successful Helm/guide Jobs and rollouts"
}

do_delete-admin-jobs() {
  kubectl -n "$NS" delete secret "$ADMIN_JOBS_SECRET" --ignore-not-found >/dev/null
  log "$ADMIN_JOBS_SECRET deleted; long-running pods are unaffected"
}

"do_$MODE"
