#!/usr/bin/env bash
# One-command database setup for an Agent Relay 2026.11.16 install on an
# existing (shared) RDS PostgreSQL instance, using the RDS master login.
#
# The master login (e.g. postgres) is the only credential you provide. It is
# used for setup and as the HoopDb migration owner, exactly as release
# 2026.11.16 expects. Every running service gets its own generated login:
# the services refuse to run as the master user.
#
# Steps (each prints what it does; nothing prints passwords or URLs):
#   1. store the master login in AWS Secrets Manager (for rds-setup.sh)
#   2. optional: drop and recreate relaycontrol, relaycast and hoopdb
#      (--reset-databases; only for a failed install with no data)
#   3. rds-setup.sh pre   (2026.11.16, downloaded and checksum-verified)
#   4. merge the generated database URLs into the existing Kubernetes Secrets
#   5. helm upgrade with your values file
#   6. wait for the HoopDb migration Job
#   7. rds-setup.sh post, then restart read API, ingest edge, search indexer
#   8. run the install diagnostic (cluster scope)
#
# Run it on the network that reaches the EKS cluster; RDS is reached from
# Jobs inside the cluster, so no database VPN is needed.
#
# Usage:
#   RDS_HOST=<endpoint> HELM_CHART=<chart ref> scripts/selfhost/configure-rds.sh [--reset-databases]
#
# Environment:
#   RDS_HOST           required. RDS endpoint hostname (*.rds.amazonaws.com)
#   HELM_CHART         chart reference used for the install (e.g. ./charts/agent-relay).
#                      Unset: the script pauses and asks you to run your own helm upgrade.
#   HELM_EXTRA_VALUES  space-separated values files passed before VALUES
#                      (e.g. "charts/agent-relay/values-eks.yaml charts/agent-relay/values-eks-rds-native.yaml")
#   VALUES             your filled-in values file (default: values.yaml in the current folder)
#   AWS_REGION         default: taken from RDS_HOST
#   RDS_ADMIN_USER     default: postgres
#   RDS_ADMIN_PASSWORD read silently from the terminal when unset
#   RDS_ADMIN_SECRET_ARN  use this existing Secrets Manager secret ({"username","password"})
#                      instead of creating agent-relay/rds-admin
#   NAMESPACE / RELEASE   default agent-relay / agent-relay
#   KUBE_CONTEXT       default: the current kubectl context
#   STATE_DIR          default $HOME/.agent-relay-install (private credential files)
set -euo pipefail
umask 077

RESET=0
for arg in "$@"; do
  case "$arg" in
    --reset-databases) RESET=1 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# Release 2026.11.16 (infra tag agent-relay-2026.11.16).
RDS_SETUP_COMMIT=ece71b9df93df64cb63676d2a0ca2767eccc6599
RDS_SETUP_SHA256=d8640b397e1de7b548e8a4e94e49d8b1d6e947504fb535db0e911d205a061c32
ERASE_SQL_PATH=scripts/selfhost/rds-session-erase-search.sql
RAW=https://raw.githubusercontent.com/AgentWorkforce/infra
DIAG_URL="$RAW/aea8a0edc904b6344e8ee90091f77217a2d1f352/scripts/support/diagnose-install.py"
DIAG_SHA256=11b8a5eb2f9e52bb3a7449fb8313238cecced9c15a032d2d51d522bc328c86be

log() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

for tool in aws kubectl jq openssl curl; do
  command -v "$tool" >/dev/null || die "$tool is not installed"
done
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

: "${RDS_HOST:?set RDS_HOST to the RDS endpoint hostname}"
[[ "$RDS_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "RDS_HOST must be a hostname"
if [[ -z "${AWS_REGION:-}" ]]; then
  AWS_REGION="$(sed -nE 's/.*\.([a-z]{2}(-gov)?-[a-z]+-[0-9])\.rds\.amazonaws\.com$/\1/p' <<<"$RDS_HOST")"
  [[ -n "$AWS_REGION" ]] || die "could not read the region from RDS_HOST; set AWS_REGION"
fi
export AWS_REGION RDS_HOST
NAMESPACE="${NAMESPACE:-agent-relay}"; RELEASE="${RELEASE:-agent-relay}"
export NAMESPACE RELEASE
VALUES="${VALUES:-values.yaml}"
[[ -f "$VALUES" ]] || die "values file $VALUES not found; run from the folder that holds it or set VALUES=<path>"
STATE_DIR="${STATE_DIR:-$HOME/.agent-relay-install}"; export STATE_DIR
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
if [[ -z "${KUBE_CONTEXT:-}" ]]; then KUBE_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"; fi
[[ -n "$KUBE_CONTEXT" ]] || die "no kubectl context; connect to the cluster VPN and set up kubeconfig first"
export KUBE_CONTEXT
k() { kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" "$@"; }

SERVICES_IMAGE="$(sed -nE 's/.*services-image:.*repository: *([^ ,}]+).*digest: *"?(sha256:[0-9a-f]{64}).*/\1@\2/p' "$VALUES" | head -n1)"
[[ "$SERVICES_IMAGE" == *@sha256:* ]] || die "could not find the services-image repository and digest in $VALUES"
export SERVICES_IMAGE

log "Settings"
info "kube context : $KUBE_CONTEXT"
info "namespace    : $NAMESPACE (release $RELEASE)"
info "RDS host     : $RDS_HOST ($AWS_REGION)"
info "values file  : $VALUES"
info "services img : $SERVICES_IMAGE"
info "state dir    : $STATE_DIR"
k get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl --context "$KUBE_CONTEXT" get namespace "$NAMESPACE" >/dev/null \
  || die "cannot reach namespace $NAMESPACE with context $KUBE_CONTEXT (cluster VPN on?)"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# 1. Master login in Secrets Manager -----------------------------------------
if [[ -z "${RDS_ADMIN_SECRET_ARN:-}" ]]; then
  log "1/8 Storing the RDS master login in AWS Secrets Manager (agent-relay/rds-admin)"
  user="${RDS_ADMIN_USER:-postgres}"
  if [[ -z "${RDS_ADMIN_PASSWORD:-}" ]]; then
    read -r -s -p "    Password for RDS user $user: " RDS_ADMIN_PASSWORD; echo
  fi
  [[ -n "$RDS_ADMIN_PASSWORD" ]] || die "empty password"
  jq -n --arg u "$user" --arg p "$RDS_ADMIN_PASSWORD" '{username:$u,password:$p}' > "$WORK/admin.json"
  unset RDS_ADMIN_PASSWORD
  if RDS_ADMIN_SECRET_ARN="$(aws secretsmanager describe-secret --region "$AWS_REGION" --secret-id agent-relay/rds-admin --query ARN --output text 2>/dev/null)"; then
    aws secretsmanager put-secret-value --region "$AWS_REGION" --secret-id "$RDS_ADMIN_SECRET_ARN" \
      --secret-string "file://$WORK/admin.json" >/dev/null
    info "updated existing secret"
  else
    RDS_ADMIN_SECRET_ARN="$(aws secretsmanager create-secret --region "$AWS_REGION" --name agent-relay/rds-admin \
      --secret-string "file://$WORK/admin.json" --query ARN --output text)"
    info "created secret"
  fi
  rm -f "$WORK/admin.json"
else
  log "1/8 Using existing Secrets Manager secret"
fi
export RDS_ADMIN_SECRET_ARN

# rds-setup.sh 2026.11.16, verified -------------------------------------------
mkdir -p "$WORK/selfhost"
curl -fsSL "$RAW/$RDS_SETUP_COMMIT/scripts/selfhost/rds-setup.sh" -o "$WORK/selfhost/rds-setup.sh"
[[ "$(sha256 "$WORK/selfhost/rds-setup.sh")" == "$RDS_SETUP_SHA256" ]] || die "rds-setup.sh checksum mismatch; not running it"
curl -fsSL "$RAW/$RDS_SETUP_COMMIT/$ERASE_SQL_PATH" -o "$WORK/selfhost/rds-session-erase-search.sql"
chmod 700 "$WORK/selfhost/rds-setup.sh"
RDS_SETUP="$WORK/selfhost/rds-setup.sh"

# 2. Optional reset ---------------------------------------------------------
if [[ "$RESET" == 1 ]]; then
  log "2/8 Resetting databases relaycontrol, relaycast and hoopdb"
  info "This DROPS those three databases on $RDS_HOST. Only do this for an install with no data."
  read -r -p "    Type RESET to continue: " answer
  [[ "$answer" == RESET ]] || die "not confirmed"
  info "Scaling the release's deployments to 0 so nothing reconnects"
  k scale deployment -l "app.kubernetes.io/instance=$RELEASE" --replicas=0 >/dev/null 2>&1 || true
  PSQL_IMAGE="$(sed -nE 's/^PSQL_IMAGE="\$\{PSQL_IMAGE:-(.*)\}"$/\1/p' "$RDS_SETUP" | head -n1)"
  [[ "$PSQL_IMAGE" == *@sha256:* ]] || die "could not read the pinned psql image from rds-setup.sh"
  if ! k get configmap rds-ca >/dev/null 2>&1; then
    curl -fsS -o "$WORK/rds-ca.pem" "https://truststore.pki.rds.amazonaws.com/$AWS_REGION/$AWS_REGION-bundle.pem"
    k create configmap rds-ca --from-file=ca.crt="$WORK/rds-ca.pem" >/dev/null
  fi
  aws secretsmanager get-secret-value --region "$AWS_REGION" --secret-id "$RDS_ADMIN_SECRET_ARN" \
    --query SecretString --output text > "$WORK/admin.json"
  mkdir -p "$WORK/reset-secret"
  jq -jr .username "$WORK/admin.json" > "$WORK/reset-secret/PGUSER"
  jq -jr .password "$WORK/admin.json" > "$WORK/reset-secret/PGPASSWORD"
  rm -f "$WORK/admin.json"
  k delete job agent-relay-db-reset --ignore-not-found >/dev/null
  k delete secret agent-relay-db-reset --ignore-not-found >/dev/null
  k create secret generic agent-relay-db-reset --from-file="$WORK/reset-secret" >/dev/null
  rm -rf "$WORK/reset-secret"
  jq -n --arg ns "$NAMESPACE" --arg img "$PSQL_IMAGE" --arg host "$RDS_HOST" '
    { apiVersion: "batch/v1", kind: "Job", metadata: { name: "agent-relay-db-reset", namespace: $ns },
      spec: { backoffLimit: 0, ttlSecondsAfterFinished: 1800, template: { spec: {
        restartPolicy: "Never", automountServiceAccountToken: false,
        securityContext: { runAsNonRoot: true, runAsUser: 26, runAsGroup: 26, seccompProfile: { type: "RuntimeDefault" } },
        volumes: [ { name: "ca", configMap: { name: "rds-ca" } }, { name: "tmp", emptyDir: {} } ],
        containers: [ { name: "psql", image: $img,
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } },
          volumeMounts: [ { name: "ca", mountPath: "/ca", readOnly: true }, { name: "tmp", mountPath: "/tmp" } ],
          envFrom: [ { secretRef: { name: "agent-relay-db-reset" } } ],
          env: [ { name: "PGHOST", value: $host }, { name: "PGPORT", value: "5432" }, { name: "PGDATABASE", value: "postgres" },
                 { name: "PGSSLMODE", value: "verify-full" }, { name: "PGSSLROOTCERT", value: "/ca/ca.crt" }, { name: "HOME", value: "/tmp" } ],
          command: ["sh", "-c", "set -e; for db in relaycontrol relaycast hoopdb; do psql -X -v ON_ERROR_STOP=1 -c \"DROP DATABASE IF EXISTS $db WITH (FORCE)\"; echo dropped $db; done"] } ] } } } }' \
    | k apply -f - >/dev/null
  k wait --for=condition=complete job/agent-relay-db-reset --timeout=300s >/dev/null \
    || { k logs job/agent-relay-db-reset --tail=20 | grep -v -i password || true; k delete secret agent-relay-db-reset --ignore-not-found >/dev/null; die "database reset failed"; }
  k logs job/agent-relay-db-reset --tail=10 | grep -v -i password || true
  k delete secret agent-relay-db-reset --ignore-not-found >/dev/null
  info "Old failed Jobs from earlier attempts are removed so Helm can re-run them"
  k delete job -l "app.kubernetes.io/instance=$RELEASE" --ignore-not-found >/dev/null || true
else
  log "2/8 Keeping existing databases (pass --reset-databases to start clean)"
fi

# 3. pre ----------------------------------------------------------------------
log "3/8 Creating databases, service logins and credential files (rds-setup.sh pre, 2026.11.16)"
NAMESPACE="$NAMESPACE" "$RDS_SETUP" pre
FILES="$STATE_DIR/secret-files"
[[ -d "$FILES" ]] || die "rds-setup.sh pre wrote no credential files under $FILES"

# 4. Secrets ------------------------------------------------------------------
log "4/8 Merging the generated database URLs into the Kubernetes Secrets"
for dir in "$FILES"/*/; do
  secret="$(basename "$dir")"
  [[ "$secret" == session-erase-search-runtime ]] && continue   # optional feature, not mounted
  args=()
  for f in "$dir"*; do [[ -f "$f" ]] && args+=(--from-file="$(basename "$f")=$f"); done
  [[ ${#args[@]} -gt 0 ]] || continue
  if k get secret "$secret" >/dev/null 2>&1; then
    k create secret generic "$secret" "${args[@]}" --dry-run=client -o json | jq '{data}' > "$WORK/patch.json"
    k patch secret "$secret" --type merge --patch-file "$WORK/patch.json" >/dev/null
    rm -f "$WORK/patch.json"
    info "updated $secret (${#args[@]} key(s); other keys kept)"
  else
    k create secret generic "$secret" "${args[@]}" >/dev/null
    info "created $secret"
  fi
done
info "rds-ca hash for values.yaml (every caSha256/sha256 under rds-ca): $(cat "$STATE_DIR/rds-ca.sha256" 2>/dev/null || echo unknown)"

# 5. helm upgrade -------------------------------------------------------------
# The RDS master user owns HoopDb and runs its migrations (PostgreSQL 15 works
# only this way). Newer charts default to rdsLayout: separate-database (PG16+,
# dedicated hoopdb_owner); this overlay selects the master-owner layout.
LAYOUT_VALUES="$STATE_DIR/rds-master-owner-values.yaml"
printf '%s\n' 'sessions-pipeline:' '  worker:' '    migrations:' '      rdsLayout: master-owner' > "$LAYOUT_VALUES"
log "5/8 Helm upgrade"
info "add this overlay LAST in your -f list: $LAYOUT_VALUES (rdsLayout: master-owner)"
if [[ -n "${HELM_CHART:-}" ]]; then
  command -v helm >/dev/null || die "helm is not installed"
  extra=()
  if [[ -n "${HELM_EXTRA_VALUES:-}" ]]; then
    for f in $HELM_EXTRA_VALUES; do extra+=(-f "$f"); done
  fi
  helm --kube-context "$KUBE_CONTEXT" upgrade --install "$RELEASE" "$HELM_CHART" -n "$NAMESPACE" \
    "${extra[@]}" -f "$VALUES" -f "$LAYOUT_VALUES"
else
  info "HELM_CHART is not set. In another terminal run the same helm upgrade you used for the install,"
  info "with the overlay added at the end, e.g.:"
  info "  helm upgrade $RELEASE <chart> -n $NAMESPACE <your -f files> -f $VALUES -f $LAYOUT_VALUES"
  read -r -p "    Press Enter once helm upgrade has finished... " _
fi

# 6. Wait for the HoopDb migration -------------------------------------------
log "6/8 Waiting for the HoopDb migration Job"
MIGRATION_JOB=""
for _ in $(seq 1 60); do
  MIGRATION_JOB="$(k get jobs -l "app.kubernetes.io/instance=$RELEASE" -o json \
    | jq -r '[.items[] | select(.metadata.name | test("worker-migrate"))] | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty')"
  [[ -n "$MIGRATION_JOB" ]] && break
  sleep 5
done
[[ -n "$MIGRATION_JOB" ]] || die "no worker-migrate Job appeared for release $RELEASE"
info "job: $MIGRATION_JOB"
if ! k wait --for=condition=complete "job/$MIGRATION_JOB" --timeout=1200s >/dev/null; then
  k logs "job/$MIGRATION_JOB" --tail=30 2>/dev/null | grep -v -i -E 'password|postgres(ql)?://' || true
  die "HoopDb migration Job $MIGRATION_JOB did not complete; the diagnostic below explains why: python3 diagnose-install.py --scope cluster"
fi
info "migration complete"

# 7. post + restart ------------------------------------------------------------
log "7/8 Activating read API, ingest and search logins (rds-setup.sh post)"
NAMESPACE="$NAMESPACE" RELEASE="$RELEASE" MIGRATION_JOB="$MIGRATION_JOB" "$RDS_SETUP" post
for d in read-api ingest-edge search-indexer; do
  k rollout restart "deployment/$RELEASE-$d" >/dev/null 2>&1 && info "restarted $RELEASE-$d" || info "no deployment $RELEASE-$d (skipped)"
done

# 8. Diagnostic -----------------------------------------------------------------
log "8/8 Install diagnostic (cluster scope)"
if command -v python3 >/dev/null && curl -fsSL "$DIAG_URL" -o "$WORK/diagnose-install.py" \
   && [[ "$(sha256 "$WORK/diagnose-install.py")" == "$DIAG_SHA256" ]]; then
  info "waiting 60s for pods to restart..."; sleep 60
  python3 "$WORK/diagnose-install.py" --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" --release "$RELEASE" \
    --scope cluster --values "$VALUES" || true
else
  info "skipped (python3 or download unavailable); run diagnose-install.py --scope cluster yourself"
fi

log "Done. Credential files are private under $FILES; keep them, never commit or share them."
info "RDS rotates the master password if it is RDS-managed: before a later helm upgrade run rds-setup.sh refresh-admin"
