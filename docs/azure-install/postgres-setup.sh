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
#   postgres-setup.sh prepare-admin-jobs
#                               Existing installs only: creates the temporary
#                               hoopdb-admin-jobs Secret for an upgrade/guide Job.
#   postgres-setup.sh remove-legacy-secret-keys
#                               After Helm, Jobs and Deployments succeed, removes
#                               the two old administrator-derived long-lived keys.
#   postgres-setup.sh delete-admin-jobs
#                               Deletes the temporary Secret on success or failure.
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
#   RELEASE          Helm release name, default agent-relay (post checks its
#                    current HoopDb migrate Job)
#   CLUSTER          CloudNativePG Cluster name, default hoopdb. With another
#                    NAMESPACE or CLUSTER, the server certificate in
#                    postgres-tls.yaml needs the matching dnsNames; pre refuses
#                    to run until it has them.
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
case "$MODE" in pre|post|finalize|prepare-admin-jobs|remove-legacy-secret-keys|delete-admin-jobs) ;; *) echo "usage: $0 pre|post|finalize|prepare-admin-jobs|remove-legacy-secret-keys|delete-admin-jobs" >&2; exit 2 ;; esac

if [[ "$MODE" == finalize || "$MODE" == prepare-admin-jobs || "$MODE" == remove-legacy-secret-keys || "$MODE" == delete-admin-jobs ]]; then SERVICES_IMAGE="${SERVICES_IMAGE:-unused@sha256:0}"; fi
: "${SERVICES_IMAGE:?set SERVICES_IMAGE to the approved sessions-pipeline image digest}"
NS="${NAMESPACE:-agent-relay}"
RELEASE="${RELEASE:-agent-relay}"
CLUSTER="${CLUSTER:-hoopdb}"
CA_SECRET="${CA_SECRET:-postgres-ca}"
STATE_DIR="${STATE_DIR:-$HOME/.agent-relay-install}"
PW_DIR="$STATE_DIR/passwords"
FILES="$STATE_DIR/secret-files"
LAYOUT_FILE="$STATE_DIR/hoopdb-layout"
PENDING_PASSWORDS_FILE="$STATE_DIR/.pending-hoopdb-passwords"
PENDING_ACTIVATION_FILE="$STATE_DIR/.pending-hoopdb-activation"
ADMIN_JOBS_SECRET=hoopdb-admin-jobs
SQL_DIR=/app/supabase/bootstrap
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
DB_HOST="$CLUSTER-rw.$NS.svc.cluster.local"
LEGACY_OWNER=hoop
OWNER=hoopdb_owner
RUNTIME=sessions_pipeline_runtime

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

for tool in kubectl helm jq openssl tar; do
  command -v "$tool" >/dev/null || die "$tool is not installed"
done
KUBECTL_CONTEXT_ARGS=()
if [[ -n "$KUBE_CONTEXT" ]]; then KUBECTL_CONTEXT_ARGS=(--context "$KUBE_CONTEXT"); fi
kubectl() { command kubectl ${KUBECTL_CONTEXT_ARGS[@]+"${KUBECTL_CONTEXT_ARGS[@]}"} "$@"; }
selected_activation_target() {
  local context="$KUBE_CONTEXT"
  if [[ -z "$context" ]]; then
    context="$(command kubectl config current-context)" || die "could not resolve the current Kubernetes context"
    [[ -n "$context" ]] || die "kubectl has no current context"
  fi
  printf 'context=%s\nnamespace=%s\ncluster=%s\n' "$context" "$NS" "$CLUSTER"
}
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
# The URL carries a password: it goes to jq on stdin, never as an argument.
json_url() { printf '%s' "$2" | jq -Rsc --arg k "$1" '{($k): .}'; }

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
verify_saved_owner_credential() {
  local out="$WORK/owner-auth.out" rc=0
  printf '%s:5432:hoopdb:%s:%s\n' "$DB_HOST" "$OWNER" "$(pw "$OWNER")" \
    | kubectl -n "$NS" exec -i "$(primary)" -c postgres -- sh -ceu '
        passfile="$(mktemp)"
        trap '\''rm -f "$passfile"'\'' EXIT
        cat >"$passfile"
        chmod 600 "$passfile"
        PGPASSFILE="$passfile" psql -X -A -t -v ON_ERROR_STOP=1 -h "$1" -p 5432 -U "$2" -d hoopdb -c "select 1"
      ' sh "$DB_HOST" "$OWNER" >"$out" 2>&1 || rc=$?
  if [[ "$rc" != 0 || "$(tr -d '[:space:]' <"$out")" != 1 ]]; then
    rm -f "$out"
    die "saved hoopdb_owner credential does not authenticate to the selected CloudNativePG cluster; refusing before database writes"
  fi
  rm -f "$out"
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

legacy_owner_password() {
  kubectl -n "$NS" get secret "$CLUSTER-app" -o json | jq -er '.data.password' | openssl base64 -d -A
}

write_credential_files() {
  local owner; owner="$(url "$OWNER" "$(pw "$OWNER")" hoopdb)"
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

write_legacy_admin_files() {
  local password owner
  password="$(legacy_owner_password)" || die "could not read the CNPG administrator password"
  [[ -n "$password" ]] || die "the CNPG administrator password is empty"
  owner="$(url "$LEGACY_OWNER" "$password" hoopdb)"
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
    '      roleBootstrap: false' \
    '      hoopdb:' \
    "        existingSecret: $migration_secret" \
    '        key: HOOPDB_MIGRATION_URL' \
    '  searchIndexer:' \
    '    bootstrap:' \
    "      existingSecret: $search_secret" \
    '      key: RELAYHISTORY_PIPELINE_CONSUMER_SECRET' >"$STATE_DIR/hoopdb-layout-values.yaml"
  chmod 600 "$STATE_DIR/hoopdb-layout-values.yaml"
}

external_secret_mapping_active() { # target-secret key: 0 active, 1 absent, 2 unknown
  local target="$1" key="$2" json="$WORK/externalsecrets.json" error="$WORK/externalsecrets.err" rc=0
  if ! kubectl -n "$NS" get externalsecrets.external-secrets.io --ignore-not-found -o json >"$json" 2>"$error"; then
    if grep -Eqi "(doesn't have a resource type|could not find the requested resource|no matches for kind.*ExternalSecret)" "$error"; then
      return 1
    fi
    return 2
  fi
  jq -e --arg target "$target" --arg key "$key" '
    any(.items[]?;
      ((.spec.target.name // .metadata.name) == $target) and
      (any(.spec.data[]?; .secretKey == $key) or
       ((.spec.dataFrom // []) | length > 0) or
       ((.spec.target.template.data // {}) | has($key)) or
       ((.spec.target.template.templateFrom // []) | length > 0) or
       ((.spec.target.templateFrom // []) | length > 0)))' "$json" >/dev/null || rc=$?
  case "$rc" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

remove_legacy_secret_keys() {
  local pair secret key secret_json key_present externally_managed mapping_rc
  for pair in agent-relay-secrets:HOOPDB_MIGRATION_URL \
              search-indexer-owner:RELAYHISTORY_PIPELINE_CONSUMER_SECRET; do
    secret="${pair%%:*}"; key="${pair#*:}"
    secret_json="$WORK/$secret.json"
    kubectl -n "$NS" get secret "$secret" --ignore-not-found -o json >"$secret_json" \
      || die "could not read Secret $secret while removing legacy administrator keys"
    if [[ -s "$secret_json" ]]; then
      key_present="$(jq -r --arg key "$key" 'if .data[$key] == null then "no" else "yes" end' "$secret_json")" \
        || die "could not parse Secret $secret while removing legacy administrator keys"
      externally_managed="$(jq -r '
        any(.metadata.ownerReferences[]?; .kind == "ExternalSecret") or
        ((.metadata.labels // {}) | has("reconcile.external-secrets.io/managed"))' "$secret_json")" \
        || die "could not parse Secret $secret while checking its owner"
    else
      key_present=no; externally_managed=false
    fi
    mapping_rc=1
    if external_secret_mapping_active "$secret" "$key"; then mapping_rc=0; else mapping_rc=$?; fi
    if [[ "$mapping_rc" == 0 ]]; then
      die "External Secrets still maps $secret/$key: remove that mapping from the Helm release values and ExternalSecret, delete the backing-store value, and wait for reconciliation; $ADMIN_JOBS_SECRET was retained"
    elif [[ "$mapping_rc" == 2 ]]; then
      die "could not inspect ExternalSecret mappings while removing $secret/$key; $ADMIN_JOBS_SECRET was retained"
    fi
    [[ "$key_present" == no ]] && continue
    if [[ "$externally_managed" == true ]]; then
      die "Secret $secret is managed by External Secrets: remove the $key mapping from the Helm release values and ExternalSecret, delete the backing-store value, wait for reconciliation, then rerun cleanup; $ADMIN_JOBS_SECRET was retained"
    fi
    kubectl -n "$NS" patch secret "$secret" --type=merge \
      -p "{\"data\":{\"$key\":null}}" >/dev/null
    log "removed legacy administrator key $secret/$key"
  done
}

# Every generated URL uses sslmode=verify-full against DB_HOST, so the server
# certificate must carry that name. postgres-tls.yaml lists the names for the
# default CLUSTER and NAMESPACE; with other values, change its dnsNames first.
require_certificate_name() {
  # The names on the certificate the server actually presents: the Cluster's
  # status lists the names CloudNativePG would issue, not those of a
  # certificate supplied through serverTLSSecret.
  local secret names
  secret="$(kubectl -n "$NS" get cluster.postgresql.cnpg.io "$CLUSTER" -o jsonpath='{.status.certificates.serverTLSSecret}')"
  [[ -n "$secret" ]] || die "CloudNativePG cluster $CLUSTER reports no server TLS Secret yet"
  names="$(kubectl -n "$NS" get secret "$secret" -o json | jq -er '.data["tls.crt"]' | openssl base64 -d -A \
    | openssl x509 -noout -ext subjectAltName 2>/dev/null | tr ',' '\n' | sed -n 's/^[[:space:]]*DNS://p')" \
    || die "could not read the server certificate in Secret $secret"
  grep -qxF "$DB_HOST" <<<"$names" \
    || die "the server certificate in Secret $secret has no name $DB_HOST: add it to the dnsNames in postgres-tls.yaml (CLUSTER=$CLUSTER, NAMESPACE=$NS) and apply it"
}

do_pre() {
  kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null
  require_certificate_name
  [[ "$(query_su postgres 'select rolsuper from pg_roles where rolname=current_user')" == t ]] \
    || die "kubectl exec into $(primary) is not a Postgres superuser session"
  ensure_ca
  fetch_sql

  local activation_target="$WORK/activation-target"
  selected_activation_target >"$activation_target"
  if [[ -s "$PENDING_ACTIVATION_FILE" ]]; then
    cmp -s "$activation_target" "$PENDING_ACTIVATION_FILE" \
      || die "pending activation state belongs to a different Kubernetes context, namespace, or CloudNativePG cluster; refusing"
  fi

  local p pending_passwords="" pending_candidates="" missing_passwords="" untrusted_passwords=""
  [[ ! -s "$PENDING_PASSWORDS_FILE" ]] || pending_passwords="$(<"$PENDING_PASSWORDS_FILE")"
  for p in control_owner control_api_runtime "$OWNER" "$RUNTIME" bulls96_read_api bulls96_session_ingest search_consumer_runtime; do
    if [[ ! -s "$PW_DIR/$p" ]]; then
      missing_passwords+=" $p"
    elif [[ " $pending_passwords " == *" $p "* ]]; then
      pending_candidates+=" $p"
    fi
  done
  if [[ -s "$PENDING_ACTIVATION_FILE" && -n "$missing_passwords" ]]; then
    die "an interrupted activation lacks saved passwords for:${missing_passwords}; no replacements were generated and the database and Secrets were left unchanged"
  fi
  untrusted_passwords="$missing_passwords$pending_candidates"
  if [[ -n "$untrusted_passwords" ]]; then
    printf '%s\n' "${untrusted_passwords# }" >"$PENDING_PASSWORDS_FILE"; chmod 600 "$PENDING_PASSWORDS_FILE"
  fi

  local db_owner legacy_schema legacy_role existing_dedicated=false
  db_owner="$(query_su postgres "select pg_get_userbyid(datdba) from pg_database where datname='hoopdb'")"
  if [[ "$db_owner" == "$LEGACY_OWNER" && ! -s "$PENDING_ACTIVATION_FILE" ]] && \
     { legacy_schema="$(query_su hoopdb "select to_regnamespace('sessions')")" || die "could not inspect the HoopDb sessions schema";
       legacy_role="$(query_su hoopdb "select 1 from pg_roles where rolname in ('hoopdb_owner','sessions_pipeline_runtime','search_consumer_runtime','session_directory_search_worker') limit 1")" || die "could not inspect the HoopDb role graph";
       [[ -n "$legacy_schema" || -n "$legacy_role" ]]; }; then
    rm -f "$PENDING_PASSWORDS_FILE" "$PENDING_ACTIVATION_FILE"
    printf '%s\n' legacy-admin >"$LAYOUT_FILE"; chmod 600 "$LAYOUT_FILE"
    write_legacy_admin_files; write_layout_values legacy-admin
    log "existing administrator-owned HoopDb detected; database and roles were left unchanged"
    log "use '$0 prepare-admin-jobs' before an upgrade/guide Job; after success run '$0 remove-legacy-secret-keys', then always '$0 delete-admin-jobs'"
    return
  fi
  if [[ "$db_owner" == "$OWNER" ]]; then
    # A fresh activation records this durable marker before its ownership
    # transaction. If that transaction committed but a later prerequisite
    # failed, the generated files are the live credentials and must be reused.
    # An ordinary dedicated-owner rerun has no marker, so a newly generated
    # replacement for a missing saved password still fails closed.
    if [[ -n "$untrusted_passwords" && ! -s "$PENDING_ACTIVATION_FILE" ]]; then
      for p in $pending_candidates; do rm -f "$PW_DIR/$p"; done
      rm -f "$PENDING_PASSWORDS_FILE"
      die "dedicated-owner HoopDb exists but STATE_DIR lacked trusted saved passwords for:${untrusted_passwords}; database and Secrets were left unchanged"
    fi
    existing_dedicated=true
  fi
  [[ "$db_owner" == "$LEGACY_OWNER" || "$existing_dedicated" == true ]] \
    || die "HoopDb owner is neither $LEGACY_OWNER nor $OWNER; refusing"

  if [[ "$existing_dedicated" == true && -s "$PENDING_ACTIVATION_FILE" ]]; then
    verify_saved_owner_credential
  fi

  for p in control_owner control_api_runtime "$OWNER" "$RUNTIME" bulls96_read_api bulls96_session_ingest search_consumer_runtime; do
    password_for "$p"
  done
  if [[ "$existing_dedicated" == false && ! -s "$PENDING_ACTIVATION_FILE" ]]; then
    cp "$activation_target" "$PENDING_ACTIVATION_FILE"
    chmod 600 "$PENDING_ACTIVATION_FILE"
  fi

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
  for f in session_directory_search_worker session_token_verifier session_ingest_roles session_read_api_roles legacy_export_privacy_roles; do
    sql_file "$f.sql" | psql_su hoopdb
    log "$f ok"
  done

  if [[ "$existing_dedicated" == false ]]; then
    {
      quiet
      printf 'BEGIN;\n'
      printf "CREATE ROLE %s LOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD '%s';\n" "$OWNER" "$(pw "$OWNER")"
      printf 'ALTER DATABASE hoopdb OWNER TO %s;\nSET LOCAL ROLE %s;\nCREATE SCHEMA sessions;\nCREATE SCHEMA search_index;\nRESET ROLE;\n' "$OWNER" "$OWNER"
      printf "CREATE ROLE search_consumer_runtime LOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD '%s';\n" "$(pw search_consumer_runtime)"
      printf "ALTER ROLE search_consumer_runtime SET statement_timeout = '60s';\n"
      printf 'COMMIT;\n'
    } | psql_su hoopdb
    log "dedicated owner and search consumer ready"
  else
    log "dedicated HoopDb ownership already committed; finishing prerequisites"
  fi

  sql_file hoopdb_runtime_role.sql "runtime_role=$RUNTIME" runtime_login=true | psql_su hoopdb
  { quiet; printf "ALTER ROLE %s PASSWORD '%s';\n" "$RUNTIME" "$(pw "$RUNTIME")"; } | psql_su hoopdb
  log "hoopdb_runtime_role ok"
  sql_file hoopdb_function_default_revoke.sql "migration_owner=$OWNER" | psql_su hoopdb
  log "hoopdb_function_default_revoke ok"

  local protected_edges
  protected_edges="$(query_su hoopdb "with protected(name) as (values
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
     or member.rolname in (select name from protected)")"
  log "protected role membership edges: $protected_edges"
  [[ "$protected_edges" == 0 ]] || die "protected HoopDb roles have membership edges; refusing"

  query_su hoopdb "select 'hoopdb owner: '||pg_get_userbyid(datdba) from pg_database where datname='hoopdb'"
  query_su hoopdb "select 'extensions: '||string_agg(extname,',' order by extname) from pg_extension"
  rm -f "$PENDING_PASSWORDS_FILE" "$PENDING_ACTIVATION_FILE"
  write_credential_files
  printf '%s\n' dedicated-owner >"$LAYOUT_FILE"; chmod 600 "$LAYOUT_FILE"
  write_layout_values dedicated-owner
  log "pre done; dedicated hoopdb_owner credentials are under $FILES"
}

do_post() {
  local p
  for p in bulls96_read_api bulls96_session_ingest search_consumer_runtime; do
    [[ -s "$PW_DIR/$p" ]] || die "missing $p password: run '$0 pre' first"
  done
  # The migrate Job name is content-addressed, so older succeeded Jobs can
  # linger after an upgrade. Check only the one the current release renders.
  local job migrated
  job="$(helm ${KUBECTL_CONTEXT_ARGS[@]+--kube-context "$KUBE_CONTEXT"} -n "$NS" get manifest "$RELEASE" \
    | awk '/^---/{k=""} /^kind: Job$/{k=1} k && /^  name: /{print $2; k=""}' \
    | grep -E -- '-worker-migrate-[0-9a-f]+$' || true)"
  [[ -n "$job" && "$(printf '%s\n' "$job" | wc -l)" -eq 1 ]] \
    || die "cannot find exactly one HoopDb migrate Job in Helm release $RELEASE (set RELEASE)"
  migrated="$(kubectl -n "$NS" get job "$job" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
  [[ "${migrated:-0}" -ge 1 ]] || die "the HoopDb migrate Job $job of release $RELEASE has not succeeded yet"
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

  # Each runtime login, over the network path the services use, verifying the
  # server against the CA the primary holds (CloudNativePG mounts it there).
  local role ca=/controller/certificates/server-ca.crt
  kubectl -n "$NS" exec "$(primary)" -c postgres -- test -s "$ca" \
    || die "the primary has no server CA at $ca"
  for role in bulls96_read_api bulls96_session_ingest search_consumer_runtime; do
    printf '\\connect "host=%s port=5432 dbname=hoopdb user=%s password=%s sslmode=verify-full sslrootcert=%s"\n%s\n' \
      "$DB_HOST" "$role" "$(pw "$role")" "$ca" \
      "select 'login ok: '||session_user||' tls='||(select ssl from pg_stat_ssl where pid=pg_backend_pid());" \
      | kubectl -n "$NS" exec -i "$(primary)" -c postgres -- psql -X -A -t -q -v ON_ERROR_STOP=1 -d postgres 2>&1 \
      | grep -E '^login ok' || die "$role could not log in over TLS"
  done
  log "post done; restart the read API, ingest edge and search indexer"
}

do_finalize() {
  local layout
  [[ -s "$LAYOUT_FILE" ]] || die "missing HoopDb layout marker: run '$0 pre' first"
  layout="$(<"$LAYOUT_FILE")"
  if [[ "$layout" == legacy-admin ]]; then
    printf 'ALTER ROLE %s NOCREATEROLE;\n' "$LEGACY_OWNER" | psql_su hoopdb
    query_su hoopdb "select 'owner createrole: '||rolcreaterole from pg_roles where rolname='$LEGACY_OWNER'"
  else
    query_su hoopdb "select 'owner createrole: '||rolcreaterole from pg_roles where rolname='$OWNER'"
  fi
  log "finalize done"
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
