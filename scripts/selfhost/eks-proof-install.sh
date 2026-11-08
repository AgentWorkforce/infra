#!/usr/bin/env bash
#
# Installs the agent-relay chart on the EKS proof substrate made by
# eks-proof-sandbox.sh, then exposes it through ALB Ingresses. Run each step
# under the Pippen lease (kubectl authenticates through `aws eks get-token`):
#
#   pippen sandbox exec aws-proof -- scripts/selfhost/eks-proof-install.sh prereqs
#   pippen sandbox exec aws-proof -- scripts/selfhost/eks-proof-install.sh install
#   pippen sandbox exec aws-proof -- scripts/selfhost/eks-proof-install.sh bootstrap-org
#   pippen sandbox exec aws-proof -- scripts/selfhost/eks-proof-install.sh hoopdb-roles   # newer services images
#   pippen sandbox exec aws-proof -- scripts/selfhost/eks-proof-install.sh status
#   pippen sandbox exec aws-proof -- scripts/selfhost/eks-proof-install.sh uninstall
#
# prereqs: the CloudNativePG operator, CNPG clusters for the control API
#   and RelayHistory databases (HoopDb gets its own CNPG cluster from the
#   chart), and the release
#   Secret with freshly generated values. Secret values are generated into a
#   mode-0700 temp dir, loaded with --from-file and removed; nothing is
#   printed. Re-running keeps an existing Secret.
# install: helm install/upgrade of the published chart with values-eks.yaml
#   plus a generated proof overlay (domain origins, bucket, tenant, VPC CIDR,
#   image digests), then the ALB Ingress (one ALB, four hosts, TLS with the
#   ACM certificate from eks-proof-dns.sh cert-request). The public origins
#   are https://<domain>, api., cast. and history.<domain>, so the install is
#   a single pass; eks-proof-dns.sh alb + cf-hosts then point DNS at the ALB.
#   EKS_PROOF_INTERIM_BEARER=true sets alleyoop auth.allowInterimRelayAuthBearer
#   (ALLOW_INTERIM_RELAYAUTH_BEARER, with environment=local as the chart
#   requires) for services images that still need it to accept a courier
#   push; leave it unset otherwise.
# bootstrap-org: the control plane's one-time installation organization
#   (POST /api/v1/organizations with the bootstrap token, from inside the API
#   pod so the token never leaves it). Idempotent: skips when one exists.
# uninstall: Ingresses first (so the ALBs go), helm uninstall, the CNPG
#   clusters and their PVCs, the operator, the namespace.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
: "${PIPPEN_SANDBOX_ACCOUNT_ID:?run under pippen sandbox exec}"
ACCOUNT="$PIPPEN_SANDBOX_ACCOUNT_ID"
REGION="${AWS_REGION:-us-west-2}"
NAME="${EKS_PROOF_NAME:-pippen-sbx-eks-proof}"
NS="${EKS_PROOF_NAMESPACE:-agent-relay}"
RELEASE="${EKS_PROOF_RELEASE:-agent-relay}"
CHART="${EKS_PROOF_CHART:-oci://ghcr.io/agentworkforce/charts/agent-relay}"
CHART_VERSION="${EKS_PROOF_CHART_VERSION:-0.3.6}"
# This historical proof emits pre-rename keys. The current source chart needs
# a separately reviewed upgrade, not ignored legacy overrides.
case "$CHART_VERSION" in
  0.3.*|0.4.*) ;;
  *) printf '%s\n' 'eks-proof-install supports pre-rename chart versions only (0.3.x/0.4.x)' >&2; exit 2 ;;
esac
SECRET="${EKS_PROOF_SECRET:-agent-relay-eks-proof}"
ORG_ID="${EKS_PROOF_ORG_ID:-org_eks_proof}"
VPC_CIDR="${EKS_PROOF_VPC_CIDR:-10.42.0.0/16}"
BUCKET="${NAME}-${ACCOUNT}"
DOMAIN="${EKS_PROOF_DOMAIN:-aws-proof.agentrelay.com}"
# Public GHCR images by digest: sessions-pipeline f1c2672 (with #204,
# no interim bearer needed; run hoopdb-roles before its first migrate, the
# sessions-pipeline 0.6.0 chart does not bootstrap its newer roles) and
# relayhistory-cloud 53c3333. No ECR copy or pull secret.
SERVICES_REPO="${EKS_PROOF_SERVICES_REPO:-ghcr.io/agentworkforce/96bulls-services}"
SERVICES_DIGEST="${EKS_PROOF_SERVICES_DIGEST:-sha256:070fe6fd46ecd1e1f9db32ff22379f6df9b9e6c4d48ede5312c8fb986a95f3a9}"
HISTORY_REPO="${EKS_PROOF_HISTORY_REPO:-ghcr.io/agentworkforce/relayhistory}"
HISTORY_DIGEST="${EKS_PROOF_HISTORY_DIGEST:-sha256:d3166bb14e1d6043426a4dd8cc05408b94574c8d79ad5fd6e789e0de00ab371b}"
INTERIM_BEARER="${EKS_PROOF_INTERIM_BEARER:-false}"
# Run hoopdb-roles during install (needed for the default services image).
HOOPDB_ROLES="${EKS_PROOF_HOOPDB_ROLES:-true}"
INGRESS="${EKS_ALB_INGRESS_NAME:-agent-relay}"
CNPG_CHART_VERSION="${EKS_PROOF_CNPG_CHART_VERSION:-0.26.1}"
PG_IMAGE="ghcr.io/cloudnative-pg/postgresql:17-standard-trixie@sha256:ed6923f9ba2399cf9070379a353c710c29ced8a294be73986a2c3dae7e599ce3"
STATE_DIR="${EKS_PROOF_STATE_DIR:-$ROOT/.eks-proof}"

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }

KUBECONFIG_FILE="$(mktemp)"
# Secret material is generated into SECRET_TMP or WORK_TMP (both mode 0700);
# the EXIT trap removes them even when a kubectl call fails part-way.
WORK_TMP="$(mktemp -d)"; chmod 700 "$WORK_TMP"
SECRET_TMP=""
trap 'rm -f "$KUBECONFIG_FILE"; rm -rf "$WORK_TMP"; [[ -n "$SECRET_TMP" ]] && rm -rf "$SECRET_TMP"' EXIT
aws --region "$REGION" eks update-kubeconfig --name "$NAME" --kubeconfig "$KUBECONFIG_FILE" >/dev/null
export KUBECONFIG="$KUBECONFIG_FILE"
mkdir -p "$STATE_DIR"

# patch_secret_key <key> <value>: add one key to $SECRET through a 0600 patch
# file in WORK_TMP (removed by the EXIT trap if the patch fails), so the value
# never appears in a process's argument list.
patch_secret_key() {
  local f="$WORK_TMP/patch-$1.json"
  (umask 077; python3 -c 'import json, sys; json.dump({"stringData": {sys.argv[1]: sys.stdin.read().rstrip("\n")}}, open(sys.argv[2], "w"))' "$1" "$f" <<<"$2")
  kubectl -n "$NS" patch secret "$SECRET" --type merge --patch-file "$f" >/dev/null
  rm -f "$f"
}

cmd_prereqs() {
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log "CloudNativePG operator (chart $CNPG_CHART_VERSION)"
  helm upgrade --install cnpg cloudnative-pg --repo https://cloudnative-pg.github.io/charts \
    --version "$CNPG_CHART_VERSION" --namespace cnpg-system --create-namespace --wait --timeout 10m >/dev/null

  if ! kubectl -n "$NS" get secret "$SECRET" >/dev/null 2>&1; then
    log "generate Secret $SECRET (values never printed)"
    local d; d="$(mktemp -d)"; chmod 700 "$d"; SECRET_TMP="$d"
    # A failed earlier run can leave the runtime-role Secrets without the
    # umbrella Secret: reuse their passwords so the URLs match what CNPG has.
    local rs
    for rs in control-api-runtime relayhistory-runtime; do
      if kubectl -n "$NS" get secret "$rs" >/dev/null 2>&1; then
        (umask 077; kubectl -n "$NS" get secret "$rs" -o jsonpath='{.data.password}' | base64 -d > "$d/$rs-password")
      fi
    done
    (
      umask 077; cd "$d"
      openssl rand -hex 32 > relaycast-internal-secret
      openssl rand -hex 32 > relaycast-workspace-bootstrap-secret
      openssl rand -hex 32 > relayauth-internal-secret
      openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out relayauth-signing-key.pem 2>/dev/null
      printf 'rak_%s' "$(openssl rand -hex 24)" > relayauth-bootstrap-api-key
      cp relayauth-bootstrap-api-key relayauth-api-key
      openssl rand -hex 32 > selfhost-bootstrap-token
      openssl rand -hex 32 > selfhost-encryption-key
      printf 'eks1:%s' "$(openssl rand -hex 32)" > SUMMARY_MASTER_KEYS
      # No trailing newline: CNPG and the URLs below must see the same bytes.
      [[ -s control-api-runtime-password ]] || printf '%s' "$(openssl rand -hex 24)" > control-api-runtime-password
      [[ -s relayhistory-runtime-password ]] || printf '%s' "$(openssl rand -hex 24)" > relayhistory-runtime-password
      printf 'postgresql://relayhistory_runtime:%s@relayhistory-pg-rw.%s.svc:5432/relayhistory?sslmode=disable' \
        "$(cat relayhistory-runtime-password)" "$NS" > DATABASE_URL
      # The control API database: the CNPG app user owns it and runs the
      # migrations; the runtime role gets only what the migrations grant.
      printf 'postgresql://control_api_runtime:%s@control-api-pg-rw.%s.svc:5432/control_api?sslmode=disable' \
        "$(cat control-api-runtime-password)" "$NS" > database-url
    )
    for rs in control-api-runtime relayhistory-runtime; do
      kubectl -n "$NS" create secret generic "$rs" --type kubernetes.io/basic-auth \
        --from-literal=username="${rs//-/_}" --from-file=password="$d/$rs-password" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
      kubectl -n "$NS" label --overwrite secret "$rs" cnpg.io/reload=true >/dev/null
    done
    kubectl -n "$NS" create secret generic "$SECRET" \
      --from-file="$d/relaycast-internal-secret" --from-file="$d/relaycast-workspace-bootstrap-secret" \
      --from-file="$d/relayauth-internal-secret" --from-file="$d/relayauth-signing-key.pem" \
      --from-file="$d/relayauth-bootstrap-api-key" --from-file="$d/relayauth-api-key" \
      --from-file="$d/selfhost-bootstrap-token" --from-file="$d/selfhost-encryption-key" \
      --from-file="$d/SUMMARY_MASTER_KEYS" --from-file="$d/database-url" --from-file="$d/DATABASE_URL" >/dev/null
    rm -rf "$d"; SECRET_TMP=""
  fi

  log "CNPG cluster control-api-pg"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: control-api-pg
  namespace: ${NS}
spec:
  instances: 1
  imageName: ${PG_IMAGE}
  storage:
    size: 5Gi
  bootstrap:
    initdb:
      database: control_api
      owner: control_api
  managed:
    roles:
      - name: control_api_runtime
        ensure: present
        login: true
        passwordSecret:
          name: control-api-runtime
EOF
  log "CNPG cluster relayhistory-pg (vector, pg_trgm)"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: relayhistory-pg
  namespace: ${NS}
spec:
  instances: 1
  imageName: ${PG_IMAGE}
  storage:
    size: 5Gi
  bootstrap:
    initdb:
      database: relayhistory
      owner: relayhistory
      # The migrations create these; vector is not a trusted extension, so
      # they are created here as superuser and the migrations' IF NOT EXISTS
      # finds them.
      postInitApplicationSQL:
        - CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public
        - CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public
  managed:
    roles:
      - name: relayhistory_runtime
        ensure: present
        login: true
        passwordSecret:
          name: relayhistory-runtime
EOF
  kubectl -n "$NS" wait cluster/control-api-pg --for=condition=Ready --timeout=15m >/dev/null
  kubectl -n "$NS" wait cluster/relayhistory-pg --for=condition=Ready --timeout=15m >/dev/null
  # database-migrations-url = the CNPG app user's URI (owner of control_api).
  if ! kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.database-migrations-url}' | grep -q .; then
    local uri
    uri="$(kubectl -n "$NS" get secret control-api-pg-app -o jsonpath='{.data.uri}' | base64 -d)"
    patch_secret_key database-migrations-url "${uri}?sslmode=disable"
    unset uri
  fi
  # DATABASE_MIGRATIONS_URL = the relayhistory owner (CNPG app user).
  if ! kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.DATABASE_MIGRATIONS_URL}' | grep -q .; then
    local huri
    huri="$(kubectl -n "$NS" get secret relayhistory-pg-app -o jsonpath='{.data.uri}' | base64 -d)"
    patch_secret_key DATABASE_MIGRATIONS_URL "${huri}?sslmode=disable"
    unset huri
  fi
  log "prereqs ready"
}

# proof_overlay: the non-secret proof overlay.
proof_overlay() {
  local dash="https://${DOMAIN}" api="https://api.${DOMAIN}" cast="https://cast.${DOMAIN}" history="https://history.${DOMAIN}"
  # The chart allows the interim bearer only with environment=local (which
  # otherwise only labels logs and error events).
  local alleyoop_env=production
  [[ "$INTERIM_BEARER" == true ]] && alleyoop_env=local
  cat > "$STATE_DIR/values-eks-proof.yaml" <<EOF
# Generated by eks-proof-install.sh: proof-specific, non-secret.
# ALLOW_INTERIM_RELAYAUTH_BEARER on the ingest: ${INTERIM_BEARER}
global:
  tenant:
    orgId: ${ORG_ID}
relaycast:
  baseUrl: ${cast}
  existingSecret: ${SECRET}
  resources: { requests: { cpu: 50m, memory: 128Mi } }
  networkPolicy:
    ingressFrom:
      - podSelector: {}
      - ipBlock: { cidr: ${VPC_CIDR} }
relayauth:
  existingSecret: ${SECRET}
sessions-pipeline:
  worker:
    image: { repository: ${SERVICES_REPO}, digest: "${SERVICES_DIGEST}" }
    existingSecret: ${SECRET}
    summaryEncryption: { existingSecret: ${SECRET} }
    locker: { bucket: ${BUCKET}, region: ${REGION} }
  alleyoop:
    image: { repository: ${SERVICES_REPO}, digest: "${SERVICES_DIGEST}" }
    existingSecret: ${SECRET}
    locker: { bucket: ${BUCKET}, region: ${REGION} }
    auth:
      jwksUrl: http://relayauth.${NS}.svc:8787/.well-known/jwks.json
      historyOrigin: ${history}
      allowInterimRelayAuthBearer: ${INTERIM_BEARER}
    environment: ${alleyoop_env}
  privilegedSql:
    sqlImage: { repository: ${SERVICES_REPO}, digest: "${SERVICES_DIGEST}" }
relayhistory:
  image: { repository: ${HISTORY_REPO}, digest: "${HISTORY_DIGEST}" }
  database:
    existingSecret: ${SECRET}
    runtimeRole: relayhistory_runtime
  relayauth:
    historyOrigin: ${history}
  networkPolicy:
    ingressFrom:
      - podSelector: {}
      - ipBlock: { cidr: ${VPC_CIDR} }
relay-cloud-api:
  existingSecret: ${SECRET}
  publicUrl: ${api}
  dashboardUrl: ${dash}/
  services:
    relaycastPublicUrl: ${cast}
    relayhistoryPublicUrl: ${history}
  networkPolicy:
    ingressFrom:
      - podSelector: {}
      - ipBlock: { cidr: ${VPC_CIDR} }
relay-dashboard:
  runtime:
    publicUrl: ${dash}
  networkPolicy:
    ingressFrom:
      - podSelector: {}
      - ipBlock: { cidr: ${VPC_CIDR} }
EOF
}

helm_apply() {
  local chart_dir
  chart_dir="$(mktemp -d "$STATE_DIR/chart-${CHART_VERSION}.XXXXXX")"
  helm pull "$CHART" --version "$CHART_VERSION" --untar --untardir "$chart_dir"
  local base_values="$chart_dir/agent-relay/values-eks.yaml"
  [[ -f "$base_values" ]] || { log 'selected chart does not ship values-eks.yaml'; return 1; }
  helm upgrade --install "$RELEASE" "$CHART" --version "$CHART_VERSION" --namespace "$NS" \
    -f "$base_values" -f "$STATE_DIR/values-eks-proof.yaml" \
    --wait --timeout 20m
}

cmd_install() {
  local cert
  cert="$(cat "$STATE_DIR/acm-cert-arn" 2>/dev/null)" ||
    { log "no $STATE_DIR/acm-cert-arn: run eks-proof-dns.sh cert-request first"; exit 1; }
  proof_overlay
  log "helm upgrade --install $CHART $CHART_VERSION (domain $DOMAIN, interim bearer $INTERIM_BEARER)"
  if [[ "$HOOPDB_ROLES" == true ]]; then
    # The HoopDb cluster is created by this install; its migrate Job verifies
    # the newer roles and retries only 3 times, so bootstrap them as soon as
    # the cluster is Ready, and re-apply if the Job had already given up.
    helm_apply & local hp=$!
    for _ in $(seq 1 90); do kubectl -n "$NS" get cluster/hoopdb >/dev/null 2>&1 && break; sleep 10; done
    cmd_hoopdb_roles
    local rc=0; wait "$hp" || rc=$?
    local failed
    failed="$(kubectl -n "$NS" get jobs -o jsonpath='{range .items[?(@.status.failed)]}{.metadata.name}{"\n"}{end}' | grep -- '-worker-migrate-' || true)"
    if ((rc != 0)) || [[ -n "$failed" ]]; then
      [[ -n "$failed" ]] && kubectl -n "$NS" delete job $failed --ignore-not-found >/dev/null
      log "re-apply after the role bootstrap (helm rc=$rc, failed migrate jobs: ${failed:-none})"
      helm_apply
    fi
  else
    helm_apply
  fi
  EKS_ALB_DOMAIN="$DOMAIN" EKS_ALB_CERT_ARN="$cert" \
    EKS_ALB_CONTROL_SERVICE=relay-cloud-api EKS_ALB_WEBAPP_SERVICE=relay-dashboard \
    "$HERE/eks-alb-ingress.sh" "$NS" | kubectl apply -f -
  log "waiting for the ALB hostname"
  local alb=""
  for _ in $(seq 1 60); do
    alb="$(kubectl -n "$NS" get ingress "$INGRESS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    [[ -n "$alb" ]] && break
    sleep 10
  done
  [[ -n "$alb" ]] || { log "the ALB hostname did not appear"; kubectl -n "$NS" describe ingress "$INGRESS" | tail -20; exit 1; }
  log "ALB $alb"
  cmd_status
}

cmd_bootstrap_org() {
  local owner="${EKS_PROOF_OWNER_EMAIL:-owner@${DOMAIN}}"
  kubectl -n "$NS" exec -i deploy/relay-cloud-api -- node --input-type=module - "$owner" <<'JS'
import { readFileSync } from "node:fs";
const token = readFileSync("/var/run/agent-relay/secrets/selfhost-bootstrap-token", "utf8").trim();
const api = "http://127.0.0.1:3000/api/v1/organizations";
const headers = { authorization: `Bearer ${token}`, "content-type": "application/json" };
const list = await (await fetch(api, { headers })).json();
if ((list.organizations ?? []).length > 0) {
  console.log(`organization exists: ${list.organizations[0].id}`);
} else {
  const res = await fetch(api, { method: "POST", headers,
    body: JSON.stringify({ name: "EKS Proof", ownerEmail: process.argv[2], ownerName: "EKS Proof Owner" }) });
  const body = await res.json();
  console.log(`create organization: status=${res.status} id=${body.id ?? body.organization?.id ?? "-"} error=${body.error?.code ?? body.error ?? "-"}`);
  if (!res.ok) process.exit(1);
}
JS
}

# hoopdb-roles: the privileged role bootstraps that services images newer
# than sessions-pipeline 0.6.0's audited build (7d7229b) verify before they
# migrate (session_token_verifier, the session ingest roles) and that the
# sessions-pipeline 0.6.0 chart does not run. Each SQL file comes from the
# services image itself and runs as the CNPG superuser over the hoopdb pod's
# local socket; both are idempotent and never alter an existing role. Run it
# after the HoopDb cluster exists and before an install or upgrade with such
# an image (EKS_PROOF_SERVICES_DIGEST).
cmd_hoopdb_roles() {
  local f pod="hoopdb-roles-$$"
  kubectl -n "$NS" wait cluster/hoopdb --for=condition=Ready --timeout=15m >/dev/null
  # The current primary, not hoopdb-1: CNPG may have failed over.
  local primary; primary="$(kubectl -n "$NS" get cluster/hoopdb -o jsonpath='{.status.currentPrimary}')"
  [[ -n "$primary" ]] || { log "hoopdb has no current primary"; exit 1; }
  for f in session_directory_search_worker session_token_verifier session_ingest_roles; do
    log "HoopDb bootstrap $f.sql (services ${SERVICES_DIGEST:0:19}...) as the CNPG superuser"
    kubectl -n "$NS" run "$pod" --rm -i --quiet --restart=Never --pod-running-timeout=10m --image="${SERVICES_REPO}@${SERVICES_DIGEST}" \
      --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"c","image":"'"${SERVICES_REPO}@${SERVICES_DIGEST}"'","command":["cat","/app/supabase/bootstrap/'"$f"'.sql"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' |
      kubectl -n "$NS" exec -i "$primary" -c postgres -- psql -X -q -v ON_ERROR_STOP=1 -d hoopdb
  done
}

cmd_status() {
  helm -n "$NS" status "$RELEASE" 2>/dev/null | sed -n '1,8p' || true
  kubectl -n "$NS" get pods,ingress,cluster.postgresql.cnpg.io -o wide 2>/dev/null || true
}

cmd_uninstall() {
  kubectl -n "$NS" delete ingress --all --wait=true --timeout=10m || true
  helm -n "$NS" uninstall "$RELEASE" --wait --timeout 10m || true
  kubectl -n "$NS" delete cluster.postgresql.cnpg.io --all --wait=true --timeout=10m || true
  kubectl -n "$NS" delete secret control-api-runtime relayhistory-runtime "$SECRET" --ignore-not-found || true
  kubectl -n "$NS" delete pvc --all --wait=true --timeout=10m || true
  helm -n cnpg-system uninstall cnpg --wait --timeout 10m || true
  kubectl delete namespace "$NS" cnpg-system --wait=true --timeout=10m || true
  kubectl get pv 2>/dev/null || true
}

case "${1:-}" in
  prereqs) cmd_prereqs ;;
  install) cmd_install ;;
  bootstrap-org) cmd_bootstrap_org ;;
  hoopdb-roles) cmd_hoopdb_roles ;;
  status) cmd_status ;;
  uninstall) cmd_uninstall ;;
  *) echo "usage: $0 prereqs|install|bootstrap-org|hoopdb-roles|status|uninstall" >&2; exit 2 ;;
esac
