#!/usr/bin/env bash
#
# Installs one benchmark arm of charts/agent-relay into the bench cluster.
#
#   AWS_PROFILE=... bench/relaycast/infra/install-arm.sh <pg|actors> prereqs|install|post|status|uninstall
#
#   prereqs   namespace; rds-setup.sh pre against the arm's RDS instance; the
#             generated app secrets; Pod Identity associations; for actors the
#             durable_actors database and the actors Secrets.
#   install   render-arms.sh with the sandbox values, then helm upgrade
#             --install (no --wait: migrations are plain Jobs).
#   post      waits for the migrate Jobs, rds-setup.sh post, restarts the
#             session pods; for actors, creates relaycast-actor-env in the
#             sandbox namespace and re-runs the actors deploy Job.
#   status    pods and Jobs.
#   uninstall helm uninstall, namespace(s) and kept PVCs.
#
# Each arm has its own RDS instance (rds-setup.sh allows one HoopDb per
# instance and pre cannot repeat after post): relaycast-actors-bench-<arm>.
# Secrets: generated per install (as infra-environments' rehearsal does) into
# STATE (0700, under ~/.agent-tmp) and loaded with --from-file; RDS admin
# credentials come from the RDS-managed Secrets Manager secret. Nothing is
# printed and no secret value reaches argv.
set -euo pipefail
# Scratch never goes to /tmp on shared hosts.
export TMPDIR="${TMPDIR:-$HOME/.agent-tmp}"; mkdir -p "$TMPDIR"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
ARM="${1:?pg|actors}"; CMD="${2:?prereqs|install|post|status|uninstall}"
[[ "$ARM" == pg || "$ARM" == actors ]] || { echo "arm must be pg or actors" >&2; exit 2; }
REGION="${AWS_REGION:-us-west-2}"
NAME=relaycast-actors-bench
NS="arm-${ARM}"
RELEASE=agent-relay
SANDBOX_NS="${NS}-${RELEASE}"
DB_ID="${NAME}-${ARM}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
[[ "$ACCOUNT" == 805532413586 ]] || { echo "refusing: not the sandbox account" >&2; exit 2; }
BUCKET="${NAME}-${ACCOUNT}"
STATE="${BENCH_STATE:-$HOME/.agent-tmp/rcb-state}/${ARM}"
SERVICES_IMAGE="ghcr.io/agentworkforce/sessions-pipeline@sha256:77022c5b6a1d30f96f921d703eb27a1acada8ec273ad84aebdde24f8eddce305"
PSQL_IMAGE="ghcr.io/cloudnative-pg/postgresql:17-standard-trixie@sha256:ed6923f9ba2399cf9070379a353c710c29ced8a294be73986a2c3dae7e599ce3"
export KUBECONFIG="${BENCH_KUBECONFIG:-$HOME/.agent-tmp/${NAME}.kubeconfig}"
umask 077
mkdir -p "$STATE"; chmod 700 "$STATE"
K=(kubectl -n "$NS")

log() { printf '%s [%s] %s\n' "$(date -u +%H:%M:%SZ)" "$ARM" "$*" >&2; }
# Secret values carry no trailing newline (the read API and others refuse
# surrounding whitespace).
rnd_hex() { openssl rand -hex "${1:-32}" | tr -d '\n'; }
# put <secret> <key> < value : one file per key under STATE/files/<secret>/
put() { mkdir -p "$STATE/files/$1"; cat >"$STATE/files/$1/$2"; }
keep() { [[ -s "$STATE/files/$1/$2" ]]; } # generated values survive re-runs
apply_secret() { # name [namespace] [label]
  local name="$1" ns="${2:-$NS}" label="${3:-}"
  kubectl -n "$ns" create secret generic "$name" --from-file="$STATE/files/$name" --dry-run=client -o yaml \
    | { if [[ -n "$label" ]]; then kubectl label --local -f - "$label" -o yaml; else cat; fi; } \
    | kubectl -n "$ns" apply -f - >/dev/null
}

db_host() { aws --region "$REGION" rds describe-db-instances --db-instance-identifier "$DB_ID" --query 'DBInstances[0].Endpoint.Address' --output text; }
db_admin_arn() { aws --region "$REGION" rds describe-db-instances --db-instance-identifier "$DB_ID" --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text; }

assoc() { "$HERE/cluster.sh" assoc "$NS" "$1" "$2"; }

# psql_job <name> <script-file> : runs SQL as the RDS admin in a Job. The admin
# URL reaches the pod through a Secret built from Secrets Manager via stdin.
psql_job() {
  local job="$1" script="$2" host
  host="$(db_host)"
  aws --region "$REGION" secretsmanager get-secret-value --secret-id "$(db_admin_arn)" --query SecretString --output text \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);process.stdout.write(`postgresql://${encodeURIComponent(j.username)}:${encodeURIComponent(j.password)}@${process.argv[1]}:5432/postgres?sslmode=require`)})' "$host" \
    | "${K[@]}" create secret generic rcb-pgadmin --from-file=url=/dev/stdin --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
  "${K[@]}" create configmap "$job" --from-file=run.sh="$script" --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
  "${K[@]}" delete job "$job" --ignore-not-found >/dev/null
  "${K[@]}" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata: {name: ${job}, labels: {purpose: relaycast-actors-bench}}
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      containers:
        - name: psql
          image: ${PSQL_IMAGE}
          command: [sh, /run/run.sh]
          env:
            - {name: ADMIN_URL, valueFrom: {secretKeyRef: {name: rcb-pgadmin, key: url}}}
            - {name: ACTORS_PW, valueFrom: {secretKeyRef: {name: rcb-actors-db, key: password, optional: true}}}
          volumeMounts: [{name: run, mountPath: /run}]
      volumes: [{name: run, configMap: {name: ${job}}}]
EOF
  "${K[@]}" wait --for=condition=complete "job/$job" --timeout=10m >/dev/null || { "${K[@]}" logs "job/$job" | tail -5 >&2; exit 1; }
  "${K[@]}" delete secret rcb-pgadmin >/dev/null
}

gen_app_secrets() {
  keep agent-relay-secrets relaycast-internal-secret || rnd_hex | put agent-relay-secrets relaycast-internal-secret
  keep agent-relay-secrets relaycast-workspace-bootstrap-secret || rnd_hex | put agent-relay-secrets relaycast-workspace-bootstrap-secret
  keep agent-relay-secrets relaycontrol-introspect-secret || rnd_hex | put agent-relay-secrets relaycontrol-introspect-secret
  keep agent-relay-secrets selfhost-bootstrap-token || rnd_hex | put agent-relay-secrets selfhost-bootstrap-token
  keep agent-relay-secrets selfhost-encryption-key || rnd_hex | put agent-relay-secrets selfhost-encryption-key
  keep agent-relay-secrets selfhost-setup-key || rnd_hex | put agent-relay-secrets selfhost-setup-key
  keep agent-relay-secrets session-read-api-secret || rnd_hex | put agent-relay-secrets session-read-api-secret
  keep agent-relay-secrets SUMMARY_MASTER_KEYS || printf 'eks1:%s' "$(rnd_hex)" | put agent-relay-secrets SUMMARY_MASTER_KEYS
  # Ingest edge introspection must equal relay-control's.
  put agent-relay-ingest-edge-runtime introspect-secret <"$STATE/files/agent-relay-secrets/relaycontrol-introspect-secret"
}

gen_actors_secrets() {
  local f="$STATE/files"
  # One internal secret everywhere: relay-control, the gateway and the actors.
  put relaycast-secrets relaycast-internal-secret <"$f/agent-relay-secrets/relaycast-internal-secret"
  # The gateway and the actors must hold the same bootstrap secret (derived ids).
  put relaycast-secrets relaycast-workspace-bootstrap-secret <"$f/agent-relay-secrets/relaycast-workspace-bootstrap-secret"
  put relaycast-actor-env RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET <"$f/agent-relay-secrets/relaycast-workspace-bootstrap-secret"
  keep relaycast-secrets file-signing-secret || rnd_hex | put relaycast-secrets file-signing-secret
  keep relaycast-secrets credential-keyring || printf '{"current":"a","keys":{"a":"%s"}}' "$(rnd_hex)" | put relaycast-secrets credential-keyring
  keep actors-credentials api-key || rnd_hex | put actors-credentials api-key
  keep actors-credentials invoke-api-key || rnd_hex | put actors-credentials invoke-api-key
  keep actors-credentials jwt-signing-key || openssl genpkey -algorithm ED25519 -outform DER | openssl base64 -A | tr -d '\n' | put actors-credentials jwt-signing-key
  put relaycast-durable-actors-invoke durable-actors-invoke-key <"$f/actors-credentials/invoke-api-key"
  keep relayfile-actors RELAYFILE_JWT_SECRET || rnd_hex | put relayfile-actors RELAYFILE_JWT_SECRET
  keep relayfile-actors RELAYFILE_ACTORS_BROKER_TOKEN || rnd_hex | put relayfile-actors RELAYFILE_ACTORS_BROKER_TOKEN
  keep rcb-actors-db password || rnd_hex 24 | put rcb-actors-db password
  # The control plane mounts no CA and its TLS client refuses the RDS chain even
  # with sslmode=require ("error performing TLS handshake"); the actors RDS runs
  # rds.force_ssl=0 (cluster.sh db-nossl actors) and this URL disables TLS.
  node -e 'process.stdout.write(`postgresql://durable_actors_owner:${require("fs").readFileSync(process.argv[1],"utf8").trim()}@${process.argv[2]}:5432/durable_actors?sslmode=disable`)' \
    "$f/rcb-actors-db/password" "$(db_host)" | put actors-credentials postgres-url
  # Workspace actor env (sandbox namespace, created by the chart in `install`).
  printf 'https://cast.%s' "${BENCH_DOMAIN}" | put relaycast-actor-env RELAYCAST_PUBLIC_URL
  put relaycast-actor-env RELAYCAST_FILE_SIGNING_SECRET <"$f/relaycast-secrets/file-signing-secret"
  put relaycast-actor-env RELAYCAST_INTERNAL_SECRET <"$f/agent-relay-secrets/relaycast-internal-secret"
  printf '20000' | put relaycast-actor-env RELAYCAST_MAILBOX_DEPTH_CAP
}

BENCH_DOMAIN="${BENCH_DOMAIN:-relaycast-bench.agentrelay.com}"

cmd_prereqs() {
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl label --local -f - purpose=relaycast-actors-bench -o yaml | kubectl apply -f - >/dev/null
  log "rds-setup pre on $DB_ID"
  AWS_REGION="$REGION" RDS_HOST="$(db_host)" RDS_ADMIN_SECRET_ARN="$(db_admin_arn)" SERVICES_IMAGE="$SERVICES_IMAGE" \
    NAMESPACE="$NS" STATE_DIR="$STATE/rds" "$ROOT/scripts/selfhost/rds-setup.sh" pre >&2
  mkdir -p "$STATE/files"
  local d
  for d in "$STATE/rds/secret-files"/*/; do
    d="${d%/}"; mkdir -p "$STATE/files/$(basename "$d")"; cp -p "$d"/* "$STATE/files/$(basename "$d")/"
  done
  gen_app_secrets
  if [[ "$ARM" == actors ]]; then
    gen_actors_secrets
    apply_secret rcb-actors-db
    cat >"$STATE/actors-db.sh" <<'EOS'
set -eu
P="psql -X -q -v ON_ERROR_STOP=1 $ADMIN_URL"
$P -v pw="$ACTORS_PW" <<'SQL'
SELECT 'CREATE ROLE durable_actors_owner LOGIN' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='durable_actors_owner') \gexec
ALTER ROLE durable_actors_owner PASSWORD :'pw';
GRANT durable_actors_owner TO CURRENT_USER;
SELECT 'CREATE DATABASE durable_actors OWNER durable_actors_owner' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='durable_actors') \gexec
SQL
echo actors db ok
EOS
    log "durable_actors database"
    psql_job rcb-actors-db "$STATE/actors-db.sh"
    "${K[@]}" delete secret rcb-actors-db >/dev/null
    for d in relaycast-secrets actors-credentials relaycast-durable-actors-invoke relayfile-actors; do apply_secret "$d"; done
  fi
  for d in agent-relay-secrets agent-relay-ingest-edge-runtime agent-relay-read-api search-indexer-runtime search-indexer-owner; do
    [[ -d "$STATE/files/$d" ]] && apply_secret "$d"
  done
  log "pod identity"
  local sa
  for sa in agent-relay-worker agent-relay-session-ingest-api agent-relay-session-read agent-relay-search-indexer; do assoc "$sa" sessions; done
  if [[ "$ARM" == actors ]]; then
    assoc agent-relay-durable-actors cp
    assoc relaycast-actors-deploy deployer
    assoc agent-relay-relayfile-actors-deploy deployer
    assoc relaycast files
    assoc agent-relay-relayfile files
  fi
  log "prereqs done"
}

cmd_install() {
  local out="$STATE/values" args
  BENCH_DOMAIN="$BENCH_DOMAIN" BUCKET="$BUCKET" RDS_CA_SHA256="$(cat "$STATE/rds/rds-ca.sha256")" \
    NS_PG=arm-pg NS_ACTORS=arm-actors REGION="$REGION" \
    ACTOR_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${NAME}/${NAME}-storage" \
    "$ROOT/bench/relaycast/scripts/render-arms.sh" "$out" --check >&2
  args="$(cat "$out/$ARM/helm-args")"
  # EXTRA_VALUES: space-separated extra -f files (e.g. an image override).
  local f; for f in ${EXTRA_VALUES:-}; do args+=" -f $f"; done
  log "helm upgrade --install ($args)"
  # shellcheck disable=SC2086
  helm upgrade --install "$RELEASE" "$ROOT/charts/agent-relay" -n "$NS" $args >&2 || { log "helm upgrade FAILED"; exit 1; }
}

cmd_post() {
  local mig
  log "waiting for migrate Jobs"
  for _ in $(seq 1 120); do
    mig="$("${K[@]}" get jobs -l app.kubernetes.io/component=hoopdb-migrate -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [[ -n "$mig" ]] && "${K[@]}" wait --for=condition=complete "job/$mig" --timeout=10s >/dev/null 2>&1 && break
    sleep 10
  done
  [[ -n "$mig" ]] || { log "no hoopdb-migrate Job"; exit 1; }
  AWS_REGION="$REGION" RDS_HOST="$(db_host)" RDS_ADMIN_SECRET_ARN="$(db_admin_arn)" SERVICES_IMAGE="$SERVICES_IMAGE" \
    NAMESPACE="$NS" STATE_DIR="$STATE/rds" RELEASE="$RELEASE" MIGRATION_JOB="$mig" "$ROOT/scripts/selfhost/rds-setup.sh" post >&2
  "${K[@]}" rollout restart deployment -l app.kubernetes.io/instance="$RELEASE" >/dev/null 2>&1 || true
  if [[ "$ARM" == actors ]]; then
    log "relaycast-actor-env in $SANDBOX_NS; re-run the actors deploy Job"
    apply_secret relaycast-actor-env "$SANDBOX_NS" terse.ai/customer-secret=true
    local job
    job="$("${K[@]}" get jobs -o name | grep relaycast-actors-deploy || true)"
    [[ -n "$job" ]] && "${K[@]}" delete "$job" >/dev/null
    cmd_install
  fi
  cmd_status
}

# fresh-db <name> (pg arm): a new, empty Relaycast database on the arm's RDS,
# with the same roles and grants rds-setup.sh gives `relaycast`, and the
# relaycast URLs in agent-relay-secrets repointed at it. A run against it starts
# from an empty schema (the migrate Job creates it), like a fresh install.
cmd_fresh_db() {
  local db="${1:?database name}"
  [[ "$ARM" == pg && "$db" =~ ^[a-z][a-z0-9_]{2,40}$ ]] || { echo "pg arm and a simple lowercase name only" >&2; exit 2; }
  cat >"$STATE/fresh-db.sh" <<EOS
set -eu
P="psql -X -q -v ON_ERROR_STOP=1"
\$P "\$ADMIN_URL" -c "GRANT relaycast_owner TO CURRENT_USER WITH SET TRUE" 
# The admin owns the database and relaycast_owner owns only the schema, as
# rds-setup.sh does: the migrate Job refuses an owner identity that owns the
# database (pg_database_owner membership, CREATE on the database).
\$P "\$ADMIN_URL" -tAc "SELECT 1 FROM pg_database WHERE datname='${db}'" | grep -q 1 || \$P "\$ADMIN_URL" -c "CREATE DATABASE ${db}"
\$P "\$ADMIN_URL" -c "ALTER DATABASE ${db} OWNER TO CURRENT_USER"
DB_URL=\$(echo "\$ADMIN_URL" | sed 's#/postgres?#/${db}?#')
\$P "\$DB_URL" <<'SQL'
ALTER SCHEMA public OWNER TO relaycast_owner;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO relaycast_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE relaycast_owner IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO relaycast_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE relaycast_owner IN SCHEMA public GRANT SELECT, USAGE, UPDATE ON SEQUENCES TO relaycast_runtime;
REVOKE TEMP, CREATE ON DATABASE ${db} FROM PUBLIC;
GRANT TEMP ON DATABASE ${db} TO relaycast_owner;
GRANT CONNECT ON DATABASE ${db} TO relaycast_owner, relaycast_runtime;
SQL
echo "${db} ready"
EOS
  psql_job rcb-fresh-db "$STATE/fresh-db.sh"
  local k
  for k in database-owner-url database-runtime-url; do
    sed -E "s#(@[^/]+/)relaycast([?]|$)#\1${db}\2#" "$STATE/files/agent-relay-secrets/$k" >"$STATE/files/agent-relay-secrets/$k.new"
    mv "$STATE/files/agent-relay-secrets/$k.new" "$STATE/files/agent-relay-secrets/$k"
  done
  apply_secret agent-relay-secrets
  log "relaycast now points at database ${db}"
}

cmd_status() {
  "${K[@]}" get pods -o wide
  "${K[@]}" get jobs
  [[ "$ARM" == actors ]] && kubectl -n "$SANDBOX_NS" get pods 2>/dev/null || true
}

cmd_uninstall() {
  helm uninstall "$RELEASE" -n "$NS" --wait --timeout 10m >&2 || true
  "${K[@]}" delete pvc --all --wait=true --timeout=5m >/dev/null || true
  kubectl delete namespace "$NS" --wait=true --timeout=10m >/dev/null || true
  [[ "$ARM" == actors ]] && kubectl delete namespace "$SANDBOX_NS" --ignore-not-found --wait=true --timeout=10m >/dev/null || true
  log "uninstalled; generated secrets in $STATE are removed with: rm -rf $STATE"
}

case "$CMD" in
  prereqs) cmd_prereqs ;;
  install) cmd_install ;;
  post) cmd_post ;;
  status) cmd_status ;;
  fresh-db) cmd_fresh_db "${3:-}" ;;
  uninstall) cmd_uninstall ;;
  *) echo "usage: $0 <pg|actors> prereqs|install|post|status|uninstall" >&2; exit 2 ;;
esac
