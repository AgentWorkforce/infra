#!/usr/bin/env bash
# One-command database setup for an Agent Relay install on an existing (shared)
# RDS PostgreSQL 16+ instance, using the RDS master login.
#
# The master login (e.g. postgres) is the only credential you provide. It is
# used only for setup: it creates a dedicated owner and runtime login per
# service, with generated passwords. The services refuse to run as the master
# user. PostgreSQL 15 is refused (the HoopDb RDS security model needs 16+).
#
# Steps (each prints what it does; nothing prints passwords or URLs):
#   1. store the master login in AWS Secrets Manager (for rds-setup.sh)
#   2. optional: drop and recreate relaycontrol, relaycast and hoopdb
#      (--reset-databases; only for a failed install with no data)
#   3. rds-setup.sh pre   (pinned, downloaded and checksum-verified)
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
#   VALUES             your filled-in values file (default: values.yaml in the current folder);
#                      its image digests are updated to RELEASE_VERSION's pins (a .bak copy is kept)
#   RELEASE_VERSION    default 2026.11.18; check out the matching tag: git checkout agent-relay-2026.11.18
#   AWS_REGION         default: taken from RDS_HOST
#   RDS_ADMIN_USER     default: postgres
#   RDS_ADMIN_PASSWORD read silently from the terminal when unset
#   RDS_ADMIN_SECRET_ARN  use this existing Secrets Manager secret ({"username","password"})
#                      instead of creating agent-relay/rds-admin
#   NAMESPACE / RELEASE   default agent-relay / agent-relay
#   KUBE_CONTEXT       default: the current kubectl context
#   STATE_DIR          default $HOME/.agent-relay-install (private credential files)
#   ADMIN_EMAIL        first admin's real address (default: bootstrap.adminEmail in VALUES)
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

# rds-setup.sh with the dedicated hoopdb_owner layout (infra #485). The older
# master-owner layout cannot activate the read API and ingest logins on RDS
# (their roles end up alterable only by rdsadmin), so it is not used.
RDS_SETUP_COMMIT=3c54ec7939c905f5eb427bc96e71b1edcff5165a   # tag agent-relay-2026.11.18
RDS_SETUP_SHA256=a1d1d8efaa67656081fc090b7f9dcbb82b07310d67f36f97293c81367bb22d44
ERASE_SQL_PATH=scripts/selfhost/rds-session-erase-search.sql
RAW=https://raw.githubusercontent.com/AgentWorkforce/infra
DIAG_URL="$RAW/aea8a0edc904b6344e8ee90091f77217a2d1f352/scripts/support/diagnose-install.py"
DIAG_SHA256=11b8a5eb2f9e52bb3a7449fb8313238cecced9c15a032d2d51d522bc328c86be

log() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

RELEASE_VERSION="${RELEASE_VERSION:-2026.11.18}"
for tool in aws kubectl jq openssl curl python3; do
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

# Release pins: the values copied from examples/aws pin older image digests; mixing
# them with this release's chart breaks the install. Update them in place (backup kept).
PINS_URL="$RAW/agent-relay-$RELEASE_VERSION/releases/agent-relay-$RELEASE_VERSION/pins.json"
PINS_JSON="$(curl -fsSL "$PINS_URL")" || die "could not download the release pins for $RELEASE_VERSION"
cp "$VALUES" "$VALUES.bak-$(date +%Y%m%d%H%M%S)"
PINS_JSON="$PINS_JSON" python3 - "$VALUES" <<'PYPIN'
import json, os, re, sys
path = sys.argv[1]
pins = json.loads(os.environ["PINS_JSON"])["pins"]
lines = open(path).read().split("\n")
changed = 0
for pin in pins.values():
    repo, digest = pin["repository"], pin["digest"]
    for i, line in enumerate(lines):
        if re.search(r"repository:\s*" + re.escape(repo) + r"\b", line):
            for j in range(i, min(i + 3, len(lines))):
                m = re.search(r"sha256:[0-9a-f]{64}", lines[j])
                if m:
                    if m.group(0) != digest:
                        lines[j] = lines[j].replace(m.group(0), digest); changed += 1
                    break
open(path, "w").write("\n".join(lines))
print(f"    release pins applied: {changed} digest(s) updated")
PYPIN
if [[ -n "${HELM_CHART:-}" && -f "${HELM_CHART}/Chart.yaml" ]]; then
  want="$(curl -fsSL "$RAW/agent-relay-$RELEASE_VERSION/charts/agent-relay/Chart.yaml" | sed -nE 's/^version: *//p' | head -n1)"
  have="$(sed -nE 's/^version: *//p' "$HELM_CHART/Chart.yaml" | head -n1)"
  [[ "$want" == "$have" ]] || die "chart $HELM_CHART is $have but release $RELEASE_VERSION is $want: in your infra clone run  git fetch --tags && git checkout agent-relay-$RELEASE_VERSION"
fi
SERVICES_IMAGE="$(sed -nE 's/.*services-image:.*repository: *([^ ,}]+).*digest: *"?(sha256:[0-9a-f]{64}).*/\1@\2/p' "$VALUES" | head -n1)"
[[ "$SERVICES_IMAGE" == *@sha256:* ]] || die "could not find the services-image repository and digest in $VALUES"
export SERVICES_IMAGE

log "Settings"
info "kube context : $KUBE_CONTEXT"
info "namespace    : $NAMESPACE (release $RELEASE)"
info "RDS host     : $RDS_HOST ($AWS_REGION)"
info "release      : $RELEASE_VERSION"
info "values file  : $VALUES"
info "services img : $SERVICES_IMAGE"
info "state dir    : $STATE_DIR"
ADMIN_EMAIL_IN_VALUES="$(sed -nE 's/^[[:space:]]+adminEmail:[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/p' "$VALUES" | head -n1)"
ADMIN_EMAIL="${ADMIN_EMAIL:-$ADMIN_EMAIL_IN_VALUES}"
info "first admin  : ${ADMIN_EMAIL:-<not set>}"
case "$ADMIN_EMAIL" in
  ""|*@example.com|*"<"*)
    printf '\n    WARNING: the first admin (relay-control.bootstrap.adminEmail) is "%s".\n' "${ADMIN_EMAIL:-unset}"
    printf '    That address becomes the owner. Set ADMIN_EMAIL=<real address> (or fix it in %s) and rerun.\n' "$VALUES"
    read -r -p "    Continue anyway? [y/N] " ok; [[ "$ok" == y || "$ok" == Y ]] || die "set ADMIN_EMAIL first";;
esac
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
          command: ["sh", "-c", "set -e; v=$(psql -XAtc \"select current_setting(\u0027server_version_num\u0027)\"); if [ \"$v\" -lt 160000 ]; then echo PG_TOO_OLD $((v/10000)); exit 3; fi; for db in relaycontrol relaycast hoopdb; do psql -X -v ON_ERROR_STOP=1 -c \"DROP DATABASE IF EXISTS $db WITH (FORCE)\"; echo dropped $db; done"] } ] } } } }' \
    | k apply -f - >/dev/null
  if ! k wait --for=condition=complete job/agent-relay-db-reset --timeout=300s >/dev/null; then
    out="$(k logs job/agent-relay-db-reset --tail=20 2>/dev/null | grep -v -i password || true)"
    k delete secret agent-relay-db-reset --ignore-not-found >/dev/null
    if grep -q PG_TOO_OLD <<<"$out"; then
      die "the RDS instance runs PostgreSQL $(sed -n 's/.*PG_TOO_OLD //p' <<<"$out" | head -n1); Agent Relay needs PostgreSQL 16 or later. Nothing was dropped. Use a PostgreSQL 16+ RDS instance (a small dedicated one is fine) and rerun with its RDS_HOST."
    fi
    printf '%s\n' "$out"; die "database reset failed"
  fi
  k logs job/agent-relay-db-reset --tail=10 | grep -v -i password || true
  k delete secret agent-relay-db-reset --ignore-not-found >/dev/null
  info "Old failed Jobs from earlier attempts are removed so Helm can re-run them"
  k delete job -l "app.kubernetes.io/instance=$RELEASE" --ignore-not-found >/dev/null || true
else
  log "2/8 Keeping existing databases (pass --reset-databases to start clean)"
fi

# 3. pre ----------------------------------------------------------------------
log "3/8 Creating databases, service logins and credential files (rds-setup.sh pre)"
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
# rds-setup.sh pre writes the HoopDb layout overlay (which Secret holds the
# migration owner, and rdsLayout). It must be the last -f.
LAYOUT_VALUES="$STATE_DIR/hoopdb-layout-values.yaml"
[[ -s "$LAYOUT_VALUES" ]] || die "rds-setup.sh pre did not write $LAYOUT_VALUES"
log "5/8 Helm upgrade"
info "add this overlay LAST in your -f list: $LAYOUT_VALUES"
if [[ -n "${HELM_CHART:-}" ]]; then
  command -v helm >/dev/null || die "helm is not installed"
  if [[ -d "$HELM_CHART" ]]; then
    info "refreshing chart dependencies, nested charts first (stale or missing subcharts drop workloads)"
    # Public chart repositories the nested charts depend on; added only if missing.
    known="$(helm repo list -o json 2>/dev/null | jq -r '.[].url' 2>/dev/null || true)"
    while read -r url; do
      [[ -z "$url" ]] && continue
      grep -qxF "${url%/}" <<<"$(sed 's#/$##' <<<"$known")" && continue
      name="$(sed -E 's#https?://##; s#[^A-Za-z0-9]+#-#g; s#-+$##' <<<"$url")"
      helm repo add "$name" "$url" >/dev/null && info "added chart repository $url"
    done < <(cat "$HELM_CHART"/Chart.yaml "$HELM_CHART"/../*/Chart.yaml 2>/dev/null \
             | sed -nE 's/^[[:space:]]*repository:[[:space:]]*"?(https:\/\/[^"[:space:]]+)"?.*/\1/p' | sort -u)
    while read -r dep; do
      d="$HELM_CHART/${dep#file://}"
      if [[ -f "$d/Chart.yaml" ]] && grep -q 'repository: file://' "$d/Chart.yaml"; then
        helm dependency build "$d" >/dev/null
      fi
    done < <(sed -nE 's/^[[:space:]]*repository:[[:space:]]*"?(file:\/\/[^"[:space:]]+)"?.*/\1/p' "$HELM_CHART/Chart.yaml")
    helm dependency build "$HELM_CHART" >/dev/null
  fi
  extra=()
  if [[ -n "${HELM_EXTRA_VALUES:-}" ]]; then
    for f in $HELM_EXTRA_VALUES; do extra+=(-f "$f"); done
  fi
  helm --kube-context "$KUBE_CONTEXT" upgrade --install "$RELEASE" "$HELM_CHART" -n "$NAMESPACE" \
    "${extra[@]}" -f "$VALUES" -f "$LAYOUT_VALUES" --set-string "relay-control.bootstrap.adminEmail=$ADMIN_EMAIL"
else
  info "HELM_CHART is not set. In another terminal, from your infra clone, refresh the chart dependencies"
  info "and run the same helm upgrade you used for the install with the overlay added at the end, e.g.:"
  info "  helm repo add cnpg https://cloudnative-pg.github.io/charts; helm repo add minio https://charts.min.io/"
  info "  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts"
  info "  helm dependency build charts/sessions-pipeline && helm dependency build charts/agent-relay"
  info "  helm upgrade $RELEASE <chart> -n $NAMESPACE <your -f files> -f $VALUES -f $LAYOUT_VALUES \\"
  info "    --set-string relay-control.bootstrap.adminEmail=$ADMIN_EMAIL"
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

# First sign-in ----------------------------------------------------------------
log "First sign-in"
DASHBOARD="$(sed -nE 's/^[[:space:]]+dashboardUrl:[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/p' "$VALUES" | head -n1)"
SVC="$(k get svc -l app.kubernetes.io/name=relay-control -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
PORT="$(k get svc "$SVC" -o jsonpath='{.spec.ports[?(@.name=="http")].port}' 2>/dev/null || true)"
TOKEN="$(k get secret agent-relay-secrets -o jsonpath='{.data.selfhost-bootstrap-token}' 2>/dev/null | base64 -d 2>/dev/null || true)"
MINTED="" code=""
if [[ -n "$SVC" && -n "$PORT" && -n "$TOKEN" ]] && k rollout status "deployment/$SVC" --timeout=300s >/dev/null 2>&1; then
  k port-forward "svc/$SVC" 18787:"$PORT" >/dev/null 2>&1 & PF=$!
  sleep 4
  code="$(curl -sS -o "$WORK/setup-key.json" -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" \
    http://127.0.0.1:18787/api/v1/installation/setup-key || true)"
  kill "$PF" 2>/dev/null || true
  unset TOKEN
  if [[ "$code" == 201 ]]; then MINTED="$(jq -r .setupKey "$WORK/setup-key.json")"; EXP="$(jq -r .expiresAt "$WORK/setup-key.json")"
  elif [[ "$code" == 409 ]]; then info "the first admin has already signed in; use your password (or Okta)"; fi
  rm -f "$WORK/setup-key.json"
fi
if [[ -n "$MINTED" ]]; then
  info "1. Open ${DASHBOARD:-<your dashboard URL>}login"
  info "2. Choose \"First-time setup: enter setup key\" and sign in as ${ADMIN_EMAIL:-the bootstrap admin}"
  info "   Setup key (single use, expires $EXP):"
  info "     $MINTED"
  info "3. Set a password (12+ characters). Then add people from Settings (temporary passwords) or Okta."
  info "Desktop app: click Sign in; the browser opens ${DASHBOARD:-the site}; sign in there and it returns to the app."
  info "On WSL without a browser, the app shows a URL and code to approve from any device."
elif [[ "$code" != 409 ]]; then
  info "Could not mint a setup key automatically. Read the configured one with:"
  info "  kubectl -n $NAMESPACE get secret agent-relay-secrets -o jsonpath='{.data.selfhost-setup-key}' | base64 -d"
fi

log "Done. Credential files are private under $FILES; keep them, never commit or share them."
info "RDS rotates the master password if it is RDS-managed: before a later helm upgrade run rds-setup.sh refresh-admin"
