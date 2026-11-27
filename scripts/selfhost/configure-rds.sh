#!/usr/bin/env bash
# The Agent Relay installer for EKS + RDS: the primary install path. One command
# creates the database logins, writes every install Secret with the right
# shapes, pins the CA and image digests in values, runs helm and checks the
# result, on a new or existing (shared) RDS PostgreSQL 16+ instance (17 or 18
# recommended), using the RDS master login.
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
#   3. rds-setup.sh pre: databases, one owner and runtime login per service,
#      the rds-ca ConfigMap, every database URL in its Secret's shape
#   4. generate the application keys (only those missing), then write the five
#      install Secrets (examples/aws/secrets/01-05): database URLs replace
#      what is there, existing keys are never overwritten; pin the CA sha256
#   5. helm upgrade with your values file (the chart's databaseGuard checks
#      every login before anything is applied)
#   6. wait for the HoopDb migration Job
#   7. rds-setup.sh post, restart read API, ingest edge, search indexer, and
#      rerun the search bootstrap Job
#   8. helm test: one healthy/unhealthy table (and the support diagnostic)
#
# Run it on the network that reaches the EKS cluster; RDS is reached from
# Jobs inside the cluster, so no database VPN is needed.
#
# Usage (the published chart; no infra checkout or dependency build):
#   RDS_HOST=<endpoint> HELM_CHART=oci://ghcr.io/agentworkforce/charts/agent-relay \
#   HELM_EXTRA_VALUES="values-eks.yaml values-eks-native.yaml" \
#     bash configure-rds.sh [--reset-databases]
#
# Environment:
#   RDS_HOST           required. RDS endpoint hostname (*.rds.amazonaws.com)
#   HELM_CHART         chart used for the install. Either the published chart,
#                      oci://ghcr.io/agentworkforce/charts/agent-relay, which is pulled at
#                      RELEASE_VERSION's chart version (from the release's release-manifest.json)
#                      and needs no checkout, or a chart directory in an infra checkout of tag
#                      agent-relay-<RELEASE_VERSION> (e.g. ./charts/agent-relay).
#                      Unset: the script pauses and asks you to run your own helm upgrade.
#   HELM_CHART_VERSION optional, OCI chart only: must equal RELEASE_VERSION's chart version
#   HELM_EXTRA_VALUES  space-separated values files passed before VALUES. A path that doesn't
#                      exist is looked up in the chart, so with the OCI chart name the bundled
#                      files: "values-eks.yaml values-eks-native.yaml" (or values-eks-rds-native.yaml).
#                      charts/agent-relay/values-eks.yaml means the same file.
#   VALUES             your filled-in values file (default: values.yaml in the current folder);
#                      its image digests are updated to RELEASE_VERSION's pins (a .bak copy is kept)
#   RELEASE_VERSION    default 2026.11.18 (agent-relay-2026.11.18). With a chart directory, check
#                      out the matching tag: git checkout agent-relay-2026.11.18
#                      "checkout": use this infra checkout as it is (its chart, its
#                      rds-setup.sh and diagnose-install.py, the digests in VALUES)
#   POD_IDENTITY_ROLES opt-in "sa=roleArn,..." : create the EKS Pod Identity associations
#                      that are missing (e.g. agent-relay-worker=arn:aws:iam::123:role/x), then
#                      restart their pods. Unset: a missing association stops the run before
#                      anything changes, with the exact aws eks create-pod-identity-association line.
#   POD_IDENTITY_STRICT 1: also stop when the associations can't be checked (no AWS
#                      credentials, not EKS). Default 0: report and continue.
#   STATUS_RBAC        1 (default) lets helm test read Jobs/Deployments/Pods through a
#                      read-only Role; 0 if you may not create Roles in the namespace
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
    -h|--help) awk 'NR > 1 && /^set -euo/ { exit } NR > 1' "$0"; exit 0 ;;
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
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECKOUT=0; [[ "$RELEASE_VERSION" == checkout ]] && CHECKOUT=1
STATUS_RBAC="${STATUS_RBAC:-1}"
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
# wait_job <job> <seconds>: 0 once the Job completes; 1 as soon as it fails or
# the time is up. (kubectl wait --for=condition=complete keeps waiting on a
# failed Job until its timeout, then says only "timed out waiting for the condition".)
wait_job() {
  local job="${1#job/}" deadline=$((SECONDS + $2)) state
  while (( SECONDS < deadline )); do
    state="$(k get job "$job" -o json 2>/dev/null | jq -r '[.status.conditions[]? | select(.status == "True") | .type] | map(select(. == "Complete" or . == "Failed")) | first // empty')"
    [[ "$state" == Complete ]] && return 0
    [[ "$state" == Failed ]] && return 1
    sleep 5
  done
  return 1
}

# The chart. The published OCI chart is pulled once, at the release's chart version,
# into a private folder, and installed from there: it already contains every
# subchart, so nothing is built and no checkout is needed. A chart directory must
# be the release's own (its tag checked out).
CHART_DIR="" CHART_PULLED=0
if [[ "${HELM_CHART:-}" == oci://* ]]; then
  [[ "$CHECKOUT" == 0 ]] || die "RELEASE_VERSION=checkout installs this checkout's chart directory; set HELM_CHART=<infra>/charts/agent-relay, not an OCI chart"
  command -v helm >/dev/null || die "helm is not installed"
  [[ "${HELM_CHART#oci://}" != *[:@]* ]] || die "set HELM_CHART without a tag or digest ($HELM_CHART); RELEASE_VERSION picks the chart version"
  MANIFEST_URL="https://github.com/AgentWorkforce/infra/releases/download/agent-relay-$RELEASE_VERSION/release-manifest.json"
  want="$(curl -fsSL "$MANIFEST_URL" | jq -r '.chart.version // empty')" || want=""
  [[ "$want" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "could not read the chart version of release $RELEASE_VERSION from $MANIFEST_URL"
  if [[ -n "${HELM_CHART_VERSION:-}" && "$HELM_CHART_VERSION" != "$want" ]]; then
    die "HELM_CHART_VERSION is $HELM_CHART_VERSION but release $RELEASE_VERSION ships chart $want; unset HELM_CHART_VERSION or set RELEASE_VERSION to the release you install"
  fi
  CHART_DIR="$(mktemp -d)"; trap 'rm -rf "$CHART_DIR"' EXIT
  helm pull "$HELM_CHART" --version "$want" --untar --untardir "$CHART_DIR" >/dev/null \
    || die "helm pull $HELM_CHART --version $want failed"
  HELM_CHART="$CHART_DIR/${HELM_CHART##*/}"
  have="$(sed -nE 's/^version: *//p' "$HELM_CHART/Chart.yaml" 2>/dev/null | head -n1)"
  [[ "$have" == "$want" ]] || die "pulled chart is version ${have:-unknown}, expected $want"
  CHART_PULLED=1
  info "chart: ${HELM_CHART##*/} $want (release $RELEASE_VERSION), pulled from the OCI registry"
elif [[ "$CHECKOUT" == 0 && -n "${HELM_CHART:-}" && -f "${HELM_CHART}/Chart.yaml" ]]; then
  want="$(curl -fsSL "$RAW/agent-relay-$RELEASE_VERSION/charts/agent-relay/Chart.yaml" | sed -nE 's/^version: *//p' | head -n1)"
  have="$(sed -nE 's/^version: *//p' "$HELM_CHART/Chart.yaml" | head -n1)"
  [[ "$want" == "$have" ]] || die "chart $HELM_CHART is $have but release $RELEASE_VERSION is $want: install from oci://ghcr.io/agentworkforce/charts/agent-relay, or in your infra clone run  git fetch --tags && git checkout agent-relay-$RELEASE_VERSION"
fi
# Extra values files, checked now so a typo stops before anything changes. A path
# that doesn't exist is looked up in the chart (values-eks.yaml, or the checkout
# path charts/agent-relay/values-eks.yaml).
extra=()
for f in ${HELM_EXTRA_VALUES:-}; do
  if [[ -f "$f" ]]; then extra+=(-f "$f")
  elif [[ -n "${HELM_CHART:-}" && -f "$HELM_CHART/${f#charts/agent-relay/}" ]]; then extra+=(-f "$HELM_CHART/${f#charts/agent-relay/}")
  else die "values file $f not found (here or in the chart)"; fi
done
# Release pins: the values copied from examples/aws pin older image digests; mixing
# them with this release's chart breaks the install. Update them in place (backup kept).
cp "$VALUES" "$VALUES.bak-$(date +%Y%m%d%H%M%S)"
if [[ "$CHECKOUT" == 0 ]]; then
PINS_URL="$RAW/agent-relay-$RELEASE_VERSION/releases/agent-relay-$RELEASE_VERSION/pins.json"
PINS_JSON="$(curl -fsSL "$PINS_URL")" || die "could not download the release pins for $RELEASE_VERSION"
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
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" ${CHART_DIR:+"$CHART_DIR"}' EXIT

# The install diagnostic (scripts/support/diagnose-install.py): the copy next to
# this script (a release checkout), else the release's own, else the old pin.
# Its --only sections need a release that has them; older copies skip those steps.
DIAG="$WORK/diagnose-install.py"
if [[ -f "$SCRIPT_DIR/../support/diagnose-install.py" ]]; then
  cp "$SCRIPT_DIR/../support/diagnose-install.py" "$DIAG"
elif ! curl -fsSL "$RAW/agent-relay-$RELEASE_VERSION/scripts/support/diagnose-install.py" -o "$DIAG" 2>/dev/null; then
  if ! { curl -fsSL "$DIAG_URL" -o "$DIAG" && [[ "$(sha256 "$DIAG")" == "$DIAG_SHA256" ]]; }; then rm -f "$DIAG"; fi
fi
DIAG_SECTIONS=0
if [[ -s "$DIAG" ]] && python3 "$DIAG" --help 2>/dev/null | grep -q -- '--only'; then DIAG_SECTIONS=1; fi
# One bearer token for every kubectl/helm call. With an exec credential plugin
# (aws eks get-token behind a slow credential_process) each kubectl call runs the
# plugin: ~14s a call against 0.2s with a token. The diagnostic runs the plugin
# once and writes a kubeconfig holding the token to $WORK (mode 0600, removed at
# exit, never printed, never exported); it is refreshed before it expires. No exec
# plugin, an older diagnostic, or NO_TOKEN_CACHE=1: kubectl keeps its own auth.
TOKEN_KC="$WORK/kubeconfig-token"
refresh_token() {
  [[ -e "$WORK/token-off" || ! -s "$DIAG" || "${NO_TOKEN_CACHE:-0}" == 1 ]] && return 0
  local due out
  due="$(cat "$WORK/token-refresh" 2>/dev/null || echo 0)"
  (( $(date +%s) < due )) && return 0
  if out="$(python3 "$DIAG" --context "$KUBE_CONTEXT" --write-token-kubeconfig "$TOKEN_KC" 2>/dev/null)" \
      && [[ "$out" =~ ^TOKEN_KUBECONFIG\ ([0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}" >"$WORK/token-refresh"
    if [[ ! -e "$WORK/token-on" ]]; then : >"$WORK/token-on"; info "using one cached cluster token for kubectl and helm (exec credential plugin)"; fi
  else
    # No exec plugin, an older diagnostic, or the plugin failed here: kubectl's own
    # auth from now on (state in files, so a failure inside $(...) sticks too).
    : >"$WORK/token-off"
  fi
}
# KUBECONFIG is chosen per call, never exported: a fallback decided inside a
# $(...) subshell then applies to every later call as well.
with_kube_auth() {
  refresh_token
  if [[ -e "$WORK/token-on" && ! -e "$WORK/token-off" ]]; then KUBECONFIG="$TOKEN_KC" "$@"; else "$@"; fi
}
kubectl() { with_kube_auth command kubectl "$@"; }
helm() { with_kube_auth command helm "$@"; }
# Waits that can outlast one cached token (rollout status, helm test) keep
# kubectl's own auth, like rds-setup.sh: the exec plugin renews as they run.
k_long() { command kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" "$@"; }
# The diagnostic reads the context's own exec config (the EKS cluster name) and
# caches its own token, so it gets the original kubeconfig.
diag() { python3 "$DIAG" --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" --release "$RELEASE" "$@"; }
refresh_token

if ! ns_err="$(kubectl --context "$KUBE_CONTEXT" get namespace "$NAMESPACE" -o name 2>&1)"; then
  # A fresh install: the cluster answered and the namespace isn't there yet.
  if grep -q '(NotFound)' <<<"$ns_err"; then
    kubectl --context "$KUBE_CONTEXT" create namespace "$NAMESPACE" >/dev/null || die "could not create namespace $NAMESPACE"
    info "created namespace $NAMESPACE"
  else
    die "cannot reach namespace $NAMESPACE with context $KUBE_CONTEXT (cluster VPN on?)"
  fi
fi

CREATED_ASSOCIATIONS=""
# Restarts still owed for associations created earlier (this run or a previous one,
# whose rollout restart failed): kept in STATE_DIR until they succeed.
PENDING_RESTARTS_FILE="$STATE_DIR/pending-pod-identity-restarts"
RESTART_DEPLOYMENTS="$(cat "$PENDING_RESTARTS_FILE" 2>/dev/null || true)"
# pod_identity <when>: check (and with POD_IDENTITY_ROLES create) the EKS Pod Identity
# association of every ServiceAccount the release's workloads use for S3 or OpenSearch.
pod_identity() {
  local rc=0 out
  if [[ "$DIAG_SECTIONS" != 1 ]]; then
    [[ "${POD_IDENTITY_STRICT:-0}" == 1 ]] && die "Pod Identity can't be checked ($1): this release's diagnostic has no --only, and POD_IDENTITY_STRICT=1"
    info "Pod Identity: not checked ($1): this release's diagnostic has no --only"
    return 0
  fi
  # Associations only here; the final diagnostic also simulates each role's IAM policy.
  out="$(diag --only pod-identity --no-iam-simulate ${POD_IDENTITY_ROLES:+--create-pod-identity "$POD_IDENTITY_ROLES"} 2>&1)" || rc=$?
  { grep -vE '^(CREATED|RESULT)' <<<"$out" | sed 's/^/    /'; } || true
  while read -r _ sa role deps; do
    info "created the Pod Identity association for $sa ($role)"
    CREATED_ASSOCIATIONS="$CREATED_ASSOCIATIONS $sa"
    RESTART_DEPLOYMENTS="$RESTART_DEPLOYMENTS ${deps//,/ }"
  done < <(grep '^CREATED ' <<<"$out" || true)
  case "$rc" in
    0) info "Pod Identity: every ServiceAccount that needs AWS has an association ($1)" ;;
    1) restart_created   # what was created is kept: restart its pods before stopping
       local done_note="Nothing has been changed yet."
       [[ -z "$CREATED_ASSOCIATIONS" ]] || done_note="Only Pod Identity associations have been created so far:$CREATED_ASSOCIATIONS."
       [[ "$1" == "before any change" ]] || done_note="helm has already installed the release; the run stops before the migration wait.${CREATED_ASSOCIATIONS:+ Created in this run:$CREATED_ASSOCIATIONS.}"
       die "Pod Identity associations are missing ($1). $done_note Run each 'Next:' line above (the role needs the access listed), or rerun with POD_IDENTITY_ROLES=\"<sa>=<role ARN>,...\" to create them, then rerun this script." ;;
    *) if [[ "${POD_IDENTITY_STRICT:-0}" == 1 ]]; then die "Pod Identity could not be checked ($1) and POD_IDENTITY_STRICT=1"; fi
       info "Pod Identity: could not be checked ($1); the lines above say how to check by hand. Continuing (POD_IDENTITY_STRICT=1 to stop)." ;;
  esac
}
restart_created() {
  local d failed=""
  for d in $RESTART_DEPLOYMENTS; do
    if k rollout restart "deployment/$d" >/dev/null 2>&1; then
      info "restarted $d (new Pod Identity association)"
    else
      info "could not restart $d: kubectl --context $KUBE_CONTEXT -n $NAMESPACE rollout restart deployment/$d"
      failed="$failed $d"
    fi
  done
  RESTART_DEPLOYMENTS="$failed"   # still pending: the final table fails until they restart
  if [[ -n "${failed// /}" ]]; then printf '%s\n' "$failed" >"$PENDING_RESTARTS_FILE"; else rm -f "$PENDING_RESTARTS_FILE"; fi
}

# 0. Pod Identity preflight: before anything destructive (including --reset-databases).
log "0/8 Pod Identity preflight"
pod_identity "before any change"
restart_created

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

# rds-setup.sh: pinned and verified, or this checkout's own -----------------------
mkdir -p "$WORK/selfhost"
if [[ "$CHECKOUT" == 1 ]]; then
  cp "$SCRIPT_DIR/rds-setup.sh" "$SCRIPT_DIR/rds-session-erase-search.sql" "$WORK/selfhost/"
else
curl -fsSL "$RAW/$RDS_SETUP_COMMIT/scripts/selfhost/rds-setup.sh" -o "$WORK/selfhost/rds-setup.sh"
[[ "$(sha256 "$WORK/selfhost/rds-setup.sh")" == "$RDS_SETUP_SHA256" ]] || die "rds-setup.sh checksum mismatch; not running it"
curl -fsSL "$RAW/$RDS_SETUP_COMMIT/$ERASE_SQL_PATH" -o "$WORK/selfhost/rds-session-erase-search.sql"
fi
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
          command: ["sh", "-c", "set -e; v=$(psql -XAtc \"select current_setting(\u0027server_version_num\u0027)\"); if [ \"$v\" -lt 160000 ]; then echo PG_TOO_OLD $((v/10000)); exit 3; fi; for db in relaycontrol relaycast hoopdb; do o=$(psql -XAtc \"select pg_has_role(current_user, datdba, \u0027MEMBER\u0027) from pg_database where datname = \u0027$db\u0027\"); if [ \"$o\" = f ]; then echo NOT_OWNER $db; exit 4; fi; done; for db in relaycontrol relaycast hoopdb; do psql -X -v ON_ERROR_STOP=1 -c \"DROP DATABASE IF EXISTS $db WITH (FORCE)\"; echo dropped $db; done"] } ] } } } }' \
    | k apply -f - >/dev/null
  if ! wait_job agent-relay-db-reset 300; then
    out="$(k logs job/agent-relay-db-reset --tail=20 2>/dev/null | grep -v -i password || true)"
    k delete secret agent-relay-db-reset --ignore-not-found >/dev/null
    if grep -q NOT_OWNER <<<"$out"; then
      die "database $(sed -n 's/.*NOT_OWNER //p' <<<"$out" | head -n1) is owned by a login the RDS master cannot act as (the dedicated hoopdb_owner layout from an earlier run of this script). Nothing was dropped. --reset-databases only resets an install whose databases the master owns; rerun without it (existing logins and keys are kept), or use a fresh RDS instance."
    fi
    if grep -q PG_TOO_OLD <<<"$out"; then
      die "the RDS instance runs PostgreSQL $(sed -n 's/.*PG_TOO_OLD //p' <<<"$out" | head -n1); Agent Relay needs PostgreSQL 16 or later. Nothing was dropped. Use a PostgreSQL 16+ RDS instance, 17 or 18 recommended (a small dedicated one is fine) and rerun with its RDS_HOST."
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
# rds-setup.sh keeps kubectl's own auth: its Jobs can outlast one cached token.
NAMESPACE="$NAMESPACE" "$RDS_SETUP" pre
# With global.rdsCa.bundle the chart renders rds-ca and pins its hash, and
# refuses an rds-ca it does not own. pre (re)creates rds-ca for its own Jobs, so
# step 5 deletes that copy just before helm upgrade creates the chart's
# (running pods keep their mounted copy). Whether the values turn it on is
# decided there, from the rendered chart with every values file.
release_rds_ca() { # $@: helm template args; prints the bundle the chart would render, or nothing
  # The full render, errors shown: a values mistake stops here with the chart's message.
  local out
  out="$(helm template "$RELEASE" "$@")" || die "helm template failed with these values (see above); nothing was upgraded"
  sed -n 's/^[[:space:]]*agentworkforce.dev\/rds-ca-bundle:[[:space:]]*"\{0,1\}\([a-z0-9-]*\)"\{0,1\}.*/\1/p' <<<"$out" | head -n1
}
# Clears the way for the chart's rds-ca: deletes the copy rds-setup.sh pre made,
# keeps this release's own (unless pre rewrote its bytes), refuses another release's.
clear_rds_ca() {
  local live owner pinned actual
  live="$(k get configmap rds-ca -o json --ignore-not-found)"
  [[ -n "$live" ]] || return 0
  owner="$(jq -r '.metadata.annotations["meta.helm.sh/release-name"] // empty' <<<"$live")"
  pinned="$(jq -r '.metadata.annotations["agentworkforce.dev/rds-ca-sha256"] // empty' <<<"$live")"
  if [[ -n "$pinned" ]]; then
    [[ "$owner" == "$RELEASE" ]] || die "rds-ca in $NAMESPACE belongs to Helm release '$owner', not $RELEASE"
    actual="$(sha256 <(jq -j '.data["ca.crt"] // empty' <<<"$live"))"
    if [[ "$actual" == "$pinned" ]]; then info "rds-ca: already managed by this release; kept"; return 0; fi
  fi
  k delete configmap rds-ca >/dev/null
  info "rds-ca: removed the copy rds-setup.sh pre wrote, so helm creates the chart's (running pods keep theirs)"
}
FILES="$STATE_DIR/secret-files"
[[ -d "$FILES" ]] || die "rds-setup.sh pre wrote no credential files under $FILES"

# 4. Secrets ------------------------------------------------------------------
log "4/8 Writing the install Secrets (examples/aws/secrets 01-05)"
# Application keys (the install guide's step 10): generated only when neither
# the cluster Secret nor the credential files hold one. An existing key is
# never replaced: data encrypted under selfhost-encryption-key and
# SUMMARY_MASTER_KEYS is unreadable without the original.
APP_KEYS=(selfhost-bootstrap-token selfhost-setup-key selfhost-encryption-key relaycast-internal-secret
  relaycast-workspace-bootstrap-secret relaycontrol-introspect-secret session-read-api-secret SUMMARY_MASTER_KEYS)
secret_has() { # secret key
  [[ -n "$(k get secret "$1" -o jsonpath="{.data.${2//./\\.}}" 2>/dev/null)" ]]
}
mkdir -p "$FILES/agent-relay-secrets" "$FILES/agent-relay-ingest-edge-runtime"
generated=0
for key in "${APP_KEYS[@]}"; do
  f="$FILES/agent-relay-secrets/$key"
  if secret_has agent-relay-secrets "$key"; then rm -f "$f"; continue; fi   # keep the cluster's value
  if [[ ! -s "$f" ]]; then
    if [[ "$key" == SUMMARY_MASTER_KEYS ]]; then printf 'k1:%s' "$(openssl rand -hex 32)" >"$f"; else openssl rand -hex 32 | tr -d '\n' >"$f"; fi
    chmod 600 "$f"; generated=$((generated + 1))
    [[ -s "$f" ]] || die "openssl rand produced no output for $key; nothing was written to the cluster"
  fi
done
info "application keys: $generated generated, the rest kept"
# The ingest edge's introspect-secret must equal relaycontrol-introspect-secret.
if [[ -s "$FILES/agent-relay-secrets/relaycontrol-introspect-secret" ]]; then
  cp "$FILES/agent-relay-secrets/relaycontrol-introspect-secret" "$FILES/agent-relay-ingest-edge-runtime/introspect-secret"
elif ! k get secret agent-relay-secrets -o jsonpath='{.data.relaycontrol-introspect-secret}' 2>/dev/null | base64 -d >"$FILES/agent-relay-ingest-edge-runtime/introspect-secret" \
     || [[ ! -s "$FILES/agent-relay-ingest-edge-runtime/introspect-secret" ]]; then
  die "could not read relaycontrol-introspect-secret from Secret agent-relay-secrets (the ingest edge's introspect-secret must equal it)"
fi
chmod 600 "$FILES/agent-relay-ingest-edge-runtime/introspect-secret"
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
for key in selfhost-encryption-key SUMMARY_MASTER_KEYS; do
  [[ -s "$FILES/agent-relay-secrets/$key" ]] && info "BACK UP $FILES/agent-relay-secrets/$key: data encrypted with it is lost without it"
done
# Pin the CA: every caSha256/sha256 in VALUES that holds a 64-hex value takes
# the rds-ca bundle's sha256 (a chart that computes it itself has none: no-op).
CA_SHA="$(cat "$STATE_DIR/rds-ca.sha256" 2>/dev/null || true)"
if [[ "$CA_SHA" =~ ^[0-9a-f]{64}$ ]]; then
  n="$(CA_SHA="$CA_SHA" python3 - "$VALUES" <<'PYCA'
import os, re, sys
p = sys.argv[1]; sha = os.environ["CA_SHA"]
s = open(p).read()
s, n = re.subn(r'^(\s*(?:caSha256|sha256):\s*"?)[0-9a-f]{64}("?)', lambda m: m.group(1) + sha + m.group(2), s, flags=re.M)
open(p, "w").write(s); print(n)
PYCA
)"
  info "rds-ca sha256 pinned in $VALUES ($n value(s))"
fi
info "rds-ca hash, only for values without global.rdsCa.bundle (every caSha256/sha256 under rds-ca): $(cat "$STATE_DIR/rds-ca.sha256" 2>/dev/null || echo unknown)"
info "  simpler: set global.rdsCa.bundle: $AWS_REGION and drop those hashes; the chart then manages rds-ca"

# 5. helm upgrade -------------------------------------------------------------
# rds-setup.sh pre writes the HoopDb layout (which Secret holds the migration
# owner, and rdsLayout). Earlier versions passed it as an extra -f overlay plus
# --set-string flags, which a later plain helm upgrade silently dropped (the
# HoopDb migrate Job then fails with rds_profile_unproven). Write every setting
# this install needs into VALUES instead (a .bak copy is kept), so the
# documented -f files alone keep working.
LAYOUT_VALUES="$STATE_DIR/hoopdb-layout-values.yaml"
[[ -s "$LAYOUT_VALUES" ]] || die "rds-setup.sh pre did not write $LAYOUT_VALUES"
log "5/8 Helm upgrade"
layout_get() { sed -nE "s/^ *$1: *\"?([^\" #]+)\"?.*/\1/p" "$LAYOUT_VALUES" | head -n"${2:-1}" | tail -n1; }
OVERLAY_ARGS=()
if LAYOUT_SETTINGS="$(jq -n \
      --arg ms "$(layout_get existingSecret 1)" --arg mk "$(layout_get key 1)" --arg rl "$(layout_get rdsLayout)" \
      --arg bs "$(layout_get existingSecret 2)" --arg bk "$(layout_get key 2)" --arg email "$ADMIN_EMAIL" \
      --argjson rbac "$([[ "$STATUS_RBAC" == 1 ]] && echo true || echo false)" '
      [ [["sessions-pipeline","worker","migrations","hoopdb","existingSecret"], $ms],
        [["sessions-pipeline","worker","migrations","hoopdb","key"], $mk],
        [["sessions-pipeline","worker","migrations","rdsLayout"], $rl],
        [["sessions-pipeline","searchIndexer","bootstrap","existingSecret"], $bs],
        [["sessions-pipeline","searchIndexer","bootstrap","key"], $bk],
        [["relay-control","bootstrap","adminEmail"], $email],
        [["databaseGuard","statusTest","rbac","create"], $rbac] ]
      | map(select(.[1] != ""))')" \
   && LAYOUT_SETTINGS="$LAYOUT_SETTINGS" python3 - "$VALUES" <<'PYSET'
import json, os, re, sys
path = sys.argv[1]
lines = open(path).read().split("\n")
KEY = lambda k: re.compile(r"^(\s*)" + re.escape(k) + r"\s*:(\s|$)")

def scalar(v):
    if isinstance(v, bool): return "true" if v else "false"
    return json.dumps(v) if re.search(r"[:#{}\[\],&*!|>'\"%@`]|^\s|\s$", v) or v in ("", "true", "false", "null") else v

def set_path(keys, value):
    """Set keys (block-style YAML) to value; create missing keys. False if unsupported."""
    start, end, parent_indent = 0, len(lines), -1
    for depth, key in enumerate(keys):
        child_indent, found, i = None, None, start
        while i < end:
            l = lines[i]; st = l.lstrip(" ")
            if not st or st.startswith("#"): i += 1; continue
            ind = len(l) - len(st)
            if ind <= parent_indent: break
            if child_indent is None: child_indent = ind
            if ind == child_indent and KEY(key).match(l): found = i; break
            i += 1
        block_end = i if found is None else None
        if found is None:
            indent = child_indent if child_indent is not None else parent_indent + 2
            ins = start if child_indent is None else block_end
            # Insert after the parent block's last entry: before trailing blank
            # lines and before comments that belong to the next key.
            while ins > start and (not lines[ins - 1].strip() or lines[ins - 1].lstrip().startswith("#")): ins -= 1
            new = []
            for d, k in enumerate(keys[depth:]):
                pad = " " * (indent + 2 * d)
                new.append(pad + k + (": " + scalar(value) if d == len(keys) - depth - 1 else ":"))
            lines[ins:ins] = new
            return True
        rest = lines[found].split(":", 1)[1].strip()
        if depth == len(keys) - 1:
            if rest.startswith(("{", "[", "&", "*", "|", ">")): return False
            m = KEY(key).match(lines[found])
            lines[found] = m.group(1) + key + ": " + scalar(value)
            return True
        if rest and not rest.startswith("#"): return False   # flow mapping or scalar where a block is needed
        # The block of this key runs until the next line indented at or above it.
        start, parent_indent = found + 1, child_indent
        j = start
        while j < len(lines):
            l = lines[j]; st = l.lstrip(" ")
            if st and not st.startswith("#") and len(l) - len(st) <= parent_indent: break
            j += 1
        end = j
    return False

ok = all(set_path(k, v) for k, v in json.loads(os.environ["LAYOUT_SETTINGS"]))
if not ok: sys.exit(3)
open(path, "w").write("\n".join(lines))
PYSET
then
  info "wrote the HoopDb layout, first admin and status-test settings into $VALUES (backup kept):"
  info "a plain helm upgrade with your documented -f files keeps this install's settings"
else
  OVERLAY_ARGS=(-f "$LAYOUT_VALUES" --set-string "relay-control.bootstrap.adminEmail=$ADMIN_EMAIL"
    --set "databaseGuard.statusTest.rbac.create=$([[ "$STATUS_RBAC" == 1 ]] && echo true || echo false)")
  info "WARNING: could not write the layout settings into $VALUES (it uses a YAML shape this script does not edit)."
  info "Every later helm upgrade MUST end with: -f $LAYOUT_VALUES --set-string relay-control.bootstrap.adminEmail=$ADMIN_EMAIL"
  info "or the HoopDb migrate Job fails with rds_profile_unproven. Better: copy those settings into $VALUES yourself."
fi
if [[ -n "${HELM_CHART:-}" ]]; then
  command -v helm >/dev/null || die "helm is not installed"
  if [[ -d "$HELM_CHART" && "$CHART_PULLED" == 0 ]]; then
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
  bundle="$(release_rds_ca "$HELM_CHART" -n "$NAMESPACE" ${extra[@]+"${extra[@]}"} -f "$VALUES" ${OVERLAY_ARGS[@]+"${OVERLAY_ARGS[@]}"})"
  if [[ -n "$bundle" ]]; then
    info "rds-ca: managed by the chart (global.rdsCa.bundle=$bundle)"
    clear_rds_ca
  fi
  helm_upgrade() {
    helm --kube-context "$KUBE_CONTEXT" upgrade --install "$RELEASE" "$HELM_CHART" -n "$NAMESPACE" \
      ${extra[@]+"${extra[@]}"} -f "$VALUES" ${OVERLAY_ARGS[@]+"${OVERLAY_ARGS[@]}"}
  }
  if ! helm_upgrade; then
    log "helm refused or failed"
    info "An AR_DB_LOGIN message above names each Secret key whose login is wrong. If it says"
    info "a pre-install/pre-upgrade hook failed, read why with:"
    info "  kubectl --context $KUBE_CONTEXT -n $NAMESPACE logs job/$RELEASE-db-guard"
    die "helm upgrade did not complete; nothing after it ran"
  fi
else
  info "HELM_CHART is not set. In another terminal, run the same helm upgrade you used for the install."
  info "Next time, set HELM_CHART=oci://ghcr.io/agentworkforce/charts/agent-relay and this step runs it for you."
  info "From an infra clone, first refresh the chart dependencies, e.g.:"
  info "  scripts/selfhost/helm-deps.sh   # builds charts/sessions-pipeline then charts/agent-relay; no helm repo add"
  info "  (a release without scripts/selfhost/helm-deps.sh, such as agent-relay-2026.11.18 and earlier, needs instead:"
  info "   helm repo add cnpg https://cloudnative-pg.github.io/charts; helm repo add minio https://charts.min.io/"
  info "   helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts"
  info "   helm dependency build charts/sessions-pipeline && helm dependency build charts/agent-relay)"
  info "  helm upgrade $RELEASE <chart> -n $NAMESPACE <your -f files> -f $VALUES ${OVERLAY_ARGS[*]}"
  info "If your values set global.rdsCa.bundle and the install stops on rds-ca, run the"
  info "kubectl delete configmap rds-ca it prints, then helm upgrade again (the chart creates its own)."
  read -r -p "    Press Enter once helm upgrade has finished... " _
fi

# A fresh install had no workloads to check before helm (automatic or manual
# helm path): check them now, creating any POD_IDENTITY_ROLES names.
pod_identity "after helm"
restart_created

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
if ! wait_job "$MIGRATION_JOB" 1200; then
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
# The search bootstrap Job ran before post activated its login, so it may have
# failed; delete it and let helm recreate it (the install guide's step 13).
failed_boot="$(k get jobs -o json | jq -r '.items[] | select(.metadata.name | test("search-indexer-bootstrap")) | select((.status.succeeded // 0) == 0) | .metadata.name')"
if [[ -n "$failed_boot" && -n "${HELM_CHART:-}" ]]; then
  for j in $failed_boot; do
    # Keep its reason before the Job (and its Pod) is gone: the guard's one line
    # in the termination message, else the log's last lines.
    why="$(k get pods -l "job-name=$j" -o jsonpath='{range .items[*]}{.status.containerStatuses[*].state.terminated.message}{end}' 2>/dev/null | head -n1)"
    [[ -n "$why" ]] || why="$(k logs "job/$j" --tail=3 2>/dev/null | grep -v -i -E 'password|postgres(ql)?://' | tail -n1 || true)"
    [[ -n "$why" ]] && info "$j: ${why:0:300}"
    k delete job "$j" >/dev/null && info "deleted $j to rerun it"
  done
  helm_upgrade >/dev/null || die "helm upgrade (search bootstrap rerun) failed"
  boot="$(k get jobs -o name | grep search-indexer-bootstrap | head -n1)"
  state=""
  if [[ -n "$boot" ]]; then
    if wait_job "$boot" 600; then state=Complete; else state="$(k get "$boot" -o jsonpath='{.status.failed}' 2>/dev/null | grep -q . && echo Failed || echo "still running")"; fi
  fi
  if [[ "$state" == Complete ]]; then
    info "search bootstrap completed"
  else
    info "search bootstrap did not complete (${state:-still running}); its last lines:"
    k logs "$boot" --tail=8 2>/dev/null | grep -v -i -E 'password|postgres(ql)?://' | cut -c1-240 | sed 's/^/      /' || true
  fi
elif [[ -n "$failed_boot" ]]; then
  info "delete the search-indexer-bootstrap Job and run your helm upgrade again so it reruns"
fi

# 8. Diagnostic -----------------------------------------------------------------
log "8/8 Install status (helm test)"
# Crash-looping Deployments never finish rolling out; helm test says why.
k_long rollout status deployment -l "app.kubernetes.io/instance=$RELEASE" --timeout=300s >/dev/null 2>&1 || true
STATUS_VERDICT=""
command helm --kube-context "$KUBE_CONTEXT" test "$RELEASE" -n "$NAMESPACE" --logs --timeout 5m >"$WORK/status.txt" 2>&1 || true
sed -n '/^Agent Relay install status/,/^\(HEALTHY\|UNHEALTHY\)/p' "$WORK/status.txt"
STATUS_VERDICT="$(grep -oE '^(HEALTHY|UNHEALTHY)' "$WORK/status.txt" | tail -n1 || true)"
[[ -n "$STATUS_VERDICT" ]] || { info "helm test printed no status table:"; tail -n 5 "$WORK/status.txt" | sed 's/^/      /'; }
# The full diagnostic, after the rollouts: migrations, Secrets, database logins
# and CA, Pod Identity, the search bootstrap and a signed OpenSearch request
# from inside the cluster, S3, and every Deployment. Its JSON feeds the table.
DIAG_RC=""
if command -v python3 >/dev/null && [[ -s "$DIAG" ]]; then
  log "Install diagnostic (Pod Identity, search, workloads)"
  DIAG_RC=0
  diag --scope all --values "$VALUES" --output "$WORK/diagnostic.json" >"$WORK/diagnostic.txt" 2>&1 || DIAG_RC=$?
  { sed -n '/^Likely problems/,$p' "$WORK/diagnostic.txt" | grep -v '^Report written' | sed 's/^/    /'; } || true
else
  info "support diagnostic skipped (python3 or download unavailable)"
fi

# First sign-in ----------------------------------------------------------------
log "First sign-in"
DASHBOARD="$(sed -nE 's/^[[:space:]]+dashboardUrl:[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/p' "$VALUES" | head -n1)"
# Short-form values have no dashboardUrl line: site.domain derives it.
if [[ -z "$DASHBOARD" ]]; then
  SITE_DOMAIN="$(sed -nE 's/^[[:space:]]+domain:[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/p' "$VALUES" | head -n1)"
  [[ -z "$SITE_DOMAIN" ]] || DASHBOARD="https://$SITE_DOMAIN/"
fi
SVC="$(k get svc -l app.kubernetes.io/name=relay-control -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
PORT="$(k get svc "$SVC" -o jsonpath='{.spec.ports[?(@.name=="http")].port}' 2>/dev/null || true)"
TOKEN="$(k get secret agent-relay-secrets -o jsonpath='{.data.selfhost-bootstrap-token}' 2>/dev/null | base64 -d 2>/dev/null || true)"
MINTED="" code=""
# relay-control may still be rolling out (the rehearsal's port-forward to
# 127.0.0.1:18787 failed): wait for the rollout, then retry the port-forward
# and the request until the API answers.
if [[ -n "$SVC" && -n "$PORT" && -n "$TOKEN" ]]; then
  k_long rollout status "deployment/$SVC" --timeout=600s >/dev/null 2>&1 || info "relay-control is not rolled out yet; trying anyway"
  for attempt in 1 2 3 4 5 6; do
    k port-forward "svc/$SVC" 18787:"$PORT" >/dev/null 2>&1 & PF=$!
    for _ in $(seq 1 20); do
      curl -s -o /dev/null --max-time 2 http://127.0.0.1:18787/ 2>/dev/null && break
      kill -0 "$PF" 2>/dev/null || break
      sleep 1
    done
    code="$(curl -sS -o "$WORK/setup-key.json" -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" \
      http://127.0.0.1:18787/api/v1/installation/setup-key 2>/dev/null || true)"
    kill "$PF" 2>/dev/null || true; wait "$PF" 2>/dev/null || true
    [[ "$code" == 201 || "$code" == 409 ]] && break
    info "relay-control did not answer yet (attempt $attempt/6, HTTP ${code:-none}); retrying in 15s"
    sleep 15
  done
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

# Verdict --------------------------------------------------------------------
# One table by area, from the diagnostic's report and helm test. Exit 0 only when
# every row is PASS: never a clean result unless the checks ran and passed.
log "Result"
FINAL_RC=0
STATUS_VERDICT="$STATUS_VERDICT" DIAG_RC="${DIAG_RC:-none}" PENDING_RESTARTS="$RESTART_DEPLOYMENTS" python3 - "$WORK/diagnostic.json" <<'PYTABLE' || FINAL_RC=$?
import json, os, sys
AREAS = [('migrations', ('jobs.',)), ('Secrets', ('credential',)),
         ('database logins + CA', ('database', 'cast.', 'control.', 'hoop.')),
         ('Pod Identity', ('podidentity',)), ('S3', ('ingest.',)), ('search bootstrap', ('search.bootstrap',)),
         ('OpenSearch auth', ('search.opensearch',)), ('workloads', ('deployments.', 'pods.', 'persistentvolumeclaims.')),
         ('values', ('values.',)), ('cluster', ('cluster',))]
try:
    checks = json.load(open(sys.argv[1])).get('checks', [])
except (OSError, ValueError):
    checks = []
rows = []
for area, prefixes in AREAS:
    mine = [c for c in checks if c['check'].startswith(prefixes)]
    if not mine:
        continue
    status = 'FAIL' if any(c['status'] == 'FAIL' for c in mine) else 'UNKNOWN' if any(c['status'] == 'UNKNOWN' for c in mine) else 'PASS'
    bad = [c for c in mine if c['status'] == status and status != 'PASS']
    detail = '; '.join((c.get('resource') + ': ' if c.get('resource') else '') + c['detail'] for c in bad[:3]) if bad else str(len(mine))+' check(s)'
    rows.append((area, status, detail[:220]))
covered = {c['check'] for _, prefixes in AREAS for c in checks if c['check'].startswith(prefixes)}
other = [c for c in checks if c['check'] not in covered]
if other:
    status = 'FAIL' if any(c['status'] == 'FAIL' for c in other) else 'UNKNOWN' if any(c['status'] == 'UNKNOWN' for c in other) else 'PASS'
    bad = [c for c in other if c['status'] == status and status != 'PASS']
    rows.append(('other checks', status, ('; '.join(c['check']+': '+c['detail'] for c in bad[:3]) if bad else str(len(other))+' check(s)')[:220]))
verdict, diag_rc = os.environ.get('STATUS_VERDICT', ''), os.environ.get('DIAG_RC', 'none')
pending = os.environ.get('PENDING_RESTARTS', '').split()
if pending:
    rows.append(('pod restarts', 'FAIL', 'not restarted after their Pod Identity association: ' + ', '.join(pending)))
rows.append(('helm test', {'HEALTHY': 'PASS', 'UNHEALTHY': 'FAIL'}.get(verdict, 'UNKNOWN'),
             verdict or 'no status table (see above)'))
if diag_rc in ('none', '3') or not checks:
    rows.append(('diagnostic', 'UNKNOWN', 'skipped or could not reach the cluster: workload checks did not run'))
elif diag_rc not in ('0',) and all(r[1] == 'PASS' for r in rows):
    # A failed or partial diagnostic never becomes a healthy result.
    rows.append(('diagnostic', 'FAIL' if diag_rc == '1' else 'UNKNOWN', 'exited '+diag_rc+' (see its output above)'))
w = max(len(r[0]) for r in rows)
print('    %-*s  %-7s  %s' % (w, 'AREA', 'STATUS', 'DETAIL'))
for r in rows:
    print('    %-*s  %-7s  %s' % (w, r[0], r[1], r[2]))
failed = [r for r in rows if r[1] != 'PASS']
if not failed:
    print('    HEALTHY: every area passed.')
    sys.exit(0)
print('    ' + ('UNHEALTHY' if any(r[1] == 'FAIL' for r in failed) else 'INCOMPLETE') + ': ' + ', '.join(r[0] for r in failed)
      + ' (details: the diagnostic and helm test output above).')
sys.exit(1)
PYTABLE
cp "$WORK/diagnostic.json" "$STATE_DIR/last-install-diagnostic.json" 2>/dev/null && info "report kept: $STATE_DIR/last-install-diagnostic.json"
info "Next:"
if [[ "$FINAL_RC" == 0 ]]; then
  info "  1. sign in with the setup key above; 2. create the load balancer (install guide step 14)."
else
  info "  1. fix each FAIL row (S3, OpenSearch and Pod Identity are fixed in AWS: the diagnostic above gives the exact command);"
  info "  2. rerun this script without --reset-databases: it keeps existing keys and logins, reruns helm,"
  info "     and deletes and reruns a failed search bootstrap itself (read a failed migration Job's log first);"
  info "  3. check again: python3 diagnose-install.py --scope all, and helm test $RELEASE -n $NAMESPACE --logs."
fi

log "Done. Credential files are private under $FILES; keep them, never commit or share them."
info "RDS rotates the master password if it is RDS-managed: before a later helm upgrade run rds-setup.sh refresh-admin"
exit "$FINAL_RC"
