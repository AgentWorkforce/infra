#!/usr/bin/env bash
#
# End-to-end proof of the agent-relay suite on AWS EKS (values-eks.yaml, the
# layout eks-proof-install.sh creates). It runs the same cases as the GKE
# proof (e2e-gcp-proof.sh) with the ALB edge (--edge alb), then adds the
# AWS-specific checks:
#
#   EKS|PASS|FAIL|<check>|<non-secret detail>
#     eks.pod_identity       worker/alleyoop ServiceAccounts have Pod Identity
#                            associations
#     eks.s3_locker_*        Pod Identity -> S3: put/head/get/list/delete through
#                            the services image's Locker adapter, in the alleyoop
#                            pod (e2e-eks-proof-s3.ts)
#     eks.alb_targets        every target group of the ALB has healthy targets
#     eks.acm_certificate    the HTTPS listener's ACM certificate is ISSUED and
#                            names all four hosts
#     eks.tls.<host>         public DNS -> ALB, the certificate verifies with the
#                            system trust store, http:// redirects to https://
#     eks.cnpg               the expected CNPG clusters are healthy. Defaults to
#                            control-api-pg, hoopdb and relayhistory-pg; set
#                            EKS_PROOF_CNPG_CLUSTERS (space separated) when
#                            some databases are external, such as RDS
#
# Run it under the Pippen lease, so kubectl and aws use the session role:
#
#   pippen sandbox exec aws-proof -- scripts/selfhost/e2e-eks-proof.sh [e2e-gcp-proof.sh options]
#
# Options it sets itself: --context (a temporary kubeconfig), --namespace,
# --sessions-namespace (the same namespace: the umbrella installs the
# Sessions Pipeline next to the rest), --secret, --edge alb and the four
# https origins (from the observed Control SELFHOST_PUBLIC_URL = https://api.<domain>),
# --require-public, and --relayauth-url (RelayAuth runs in the release
# namespace under the umbrella). Any other option is passed through, e.g.
# --skip-flows, --allow-known-gap NAME or --no-cleanup.
#
# --eks-checks-only runs only the EKS checks (no e2e-gcp-proof.sh cases).
#
# Exit status: e2e-gcp-proof.sh's status, or 1 if an EKS check failed.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REGION="${AWS_REGION:-us-west-2}"
NAME="${EKS_PROOF_NAME:-pippen-sbx-eks-proof}"
NS="${EKS_PROOF_NAMESPACE:-agent-relay}"
RELEASE="${EKS_PROOF_RELEASE:-agent-relay}"
SECRET="${EKS_PROOF_SECRET:-agent-relay-eks-proof}"
ACCOUNT="${PIPPEN_SANDBOX_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
BUCKET="${EKS_PROOF_BUCKET:-${NAME}-${ACCOUNT}}"

KUBECONFIG_FILE="$(mktemp)"
trap 'rm -f "$KUBECONFIG_FILE"' EXIT
aws --region "$REGION" eks update-kubeconfig --name "$NAME" --alias eks-proof \
  --kubeconfig "$KUBECONFIG_FILE" >/dev/null || { echo "E2E_RESULT=FAIL"; echo "reason: no kubeconfig for $NAME"; exit 1; }
export KUBECONFIG="$KUBECONFIG_FILE"
K=(kubectl --context eks-proof -n "$NS")

# Public origins: the HTTPS hosts the control API was installed with
# (Control SELFHOST_PUBLIC_URL = https://api.<domain>). An explicit
# EKS_PROOF_CONTROL_DEPLOYMENT is tried first; otherwise relay-control is tried,
# followed by the retained pre-rename relay-cloud-api Deployment.
api_url=""
if [[ -z "${EKS_PROOF_DOMAIN:-}" ]]; then
  for control_deployment in "${EKS_PROOF_CONTROL_DEPLOYMENT:-relay-control}" relay-cloud-api; do
    api_url="$("${K[@]}" get deploy "$control_deployment" \
      -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SELFHOST_PUBLIC_URL")].value}' 2>/dev/null || true)"
    [[ -n "$api_url" ]] && break
  done
fi
DOMAIN="${EKS_PROOF_DOMAIN:-${api_url#https://api.}}"
DOMAIN="${DOMAIN%/}"
if [[ -z "$DOMAIN" || "$DOMAIN" == "$api_url" ]]; then
  echo "E2E_RESULT=FAIL"; echo "reason: installed Control SELFHOST_PUBLIC_URL is not https://api.<domain> (got ${api_url:-none})"; exit 1
fi
if [[ -n "${EKS_PROOF_CONTROL_DEPLOYMENT:-}" && -z "${E2E_CONTROL_DEPLOYMENT:-}" ]]; then
  export E2E_CONTROL_DEPLOYMENT="$EKS_PROOF_CONTROL_DEPLOYMENT"
fi
if [[ -n "${EKS_ALB_CONTROL_SERVICE:-}" && -z "${E2E_CONTROL_SERVICE:-}" ]]; then
  export E2E_CONTROL_SERVICE="$EKS_ALB_CONTROL_SERVICE"
fi
DASHBOARD="https://$DOMAIN"
API="https://api.$DOMAIN"
CAST="https://cast.$DOMAIN"
HISTORY="https://history.$DOMAIN"
ALB="$("${K[@]}" get ingress "${EKS_ALB_INGRESS_NAME:-agent-relay}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
[[ -n "$ALB" ]] || { echo "E2E_RESULT=FAIL"; echo "reason: the ALB Ingress has no hostname (eks-alb-ingress.sh applied?)"; exit 1; }

rc=0
EKS_ONLY=false
if [[ "${1:-}" == --eks-checks-only ]]; then EKS_ONLY=true; shift; fi
$EKS_ONLY || bash "$HERE/e2e-gcp-proof.sh" --context eks-proof --namespace "$NS" --sessions-namespace "$NS" \
  --secret "$SECRET" --edge alb --dashboard-origin "$DASHBOARD" --api-origin "$API" \
  --cast-origin "$CAST" --history-origin "$HISTORY" --relayauth-url http://relayauth:8787 --require-public "$@" || rc=$?

printf '\n== EKS checks (%s)\n' "$(date -u +%FT%TZ)"
EKS_FAILS=0
eks() { # result check detail
  printf 'EKS|%s|%s|%s\n' "$1" "$2" "$3"
  [[ "$1" == FAIL ]] && EKS_FAILS=$((EKS_FAILS + 1))
  return 0
}

assoc="$(aws --region "$REGION" eks list-pod-identity-associations --cluster-name "$NAME" --namespace "$NS" \
  --query 'associations[].serviceAccount' --output text 2>/dev/null | tr '\t' ' ')"
missing=""
# Use the installed release's service accounts, including name overrides and
# legacy compatibility mode. Do not infer them from chart package names.
apps="$("${K[@]}" get deploy -l "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/part-of=sessions-pipeline" -o json 2>/dev/null)"
accounts="$(printf %s "$apps" | python3 "$HERE/session-identities.py" service-accounts)"
[[ -n "$accounts" ]] || missing="no installed app ServiceAccounts discovered "
for sa in $accounts; do
  [[ " $assoc " == *" $sa "* ]] || missing+="$sa "
done
[[ -z "$missing" ]] && eks PASS eks.pod_identity "associations=${assoc}" || eks FAIL eks.pod_identity "missing=${missing% }"

alleyoop="$("${K[@]}" get pods -l "app.kubernetes.io/instance=${RELEASE}" --field-selector=status.phase=Running -o json 2>/dev/null | python3 "$HERE/session-identities.py" ingest-pod)"
s3_out=""
[[ -n "$alleyoop" ]] && s3_out="$("${K[@]}" exec -i "$alleyoop" -- sh -c \
  'umask 077; cat > /tmp/e2e-eks-proof-s3.ts && cd /app && bun run /tmp/e2e-eks-proof-s3.ts; rm -f /tmp/e2e-eks-proof-s3.ts' \
  <"$HERE/e2e-eks-proof-s3.ts" 2>/dev/null)"
while IFS='|' read -r _ result check detail; do eks "$result" "$check" "$detail"; done < <(grep '^EKS|' <<<"$s3_out")
grep -q '^EKS|PASS|eks.s3_locker_delete|' <<<"$s3_out" || grep -q '^EKS|FAIL|eks.s3_locker_delete|' <<<"$s3_out" || eks FAIL eks.s3_locker_delete "no result from the probe"
grep -q '^EKS|PASS|eks.s3_locker_roundtrip|' <<<"$s3_out" || eks FAIL eks.s3_locker_roundtrip "no PASS from the probe (pod=${alleyoop:-none} bucket=$BUCKET)"

unhealthy=""
healthy=0
for lb in $(aws --region "$REGION" elbv2 describe-load-balancers \
  --query "LoadBalancers[?DNSName=='${ALB}'].LoadBalancerArn" --output text 2>/dev/null); do
  for tg in $(aws --region "$REGION" elbv2 describe-target-groups --load-balancer-arn "$lb" --query 'TargetGroups[].TargetGroupArn' --output text); do
    states="$(aws --region "$REGION" elbv2 describe-target-health --target-group-arn "$tg" --query 'TargetHealthDescriptions[].TargetHealth.State' --output text | tr '\t' ' ')"
    if [[ " $states " == *" healthy "* ]]; then healthy=$((healthy + 1)); else unhealthy+="${tg##*/}=${states:-none} "; fi
  done
done
[[ -z "$unhealthy" && $healthy -gt 0 ]] && eks PASS eks.alb_targets "alb=${ALB} healthy_target_groups=$healthy" ||
  eks FAIL eks.alb_targets "alb=${ALB} healthy=$healthy unhealthy=${unhealthy% }"

# ACM: the listener certificate is ISSUED and covers every public host.
cert="$(aws --region "$REGION" elbv2 describe-listeners --load-balancer-arn \
  "$(aws --region "$REGION" elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='${ALB}'].LoadBalancerArn | [0]" --output text)" \
  --query "Listeners[?Port==\`443\`].Certificates[0].CertificateArn | [0]" --output text 2>/dev/null)"
acm="$(aws --region "$REGION" acm describe-certificate --certificate-arn "$cert" \
  --query 'Certificate.[Status, join(`,`, SubjectAlternativeNames), NotAfter]' --output text 2>/dev/null)"
read -r acm_status acm_names acm_after <<<"$acm"
acm_missing=""
for h in "$DOMAIN" "api.$DOMAIN" "cast.$DOMAIN" "history.$DOMAIN"; do
  [[ ",$acm_names," == *",$h,"* ]] || acm_missing+="$h "
done
[[ "$acm_status" == ISSUED && -z "$acm_missing" ]] &&
  eks PASS eks.acm_certificate "status=$acm_status names=$acm_names not_after=$acm_after" ||
  eks FAIL eks.acm_certificate "status=${acm_status:-none} missing=${acm_missing% } cert=${cert:-none}"

# TLS from the public internet: each host resolves to the ALB, the
# certificate verifies against the system trust store, and port 80 redirects.
# The ALB's current addresses: the HTTPS connection must land on one of them.
alb_ips=" $(python3 -c 'import socket, sys; print(" ".join(sorted({a[4][0] for a in socket.getaddrinfo(sys.argv[1], 443, socket.AF_INET)})))' "$ALB" 2>/dev/null) "
for h in "$DOMAIN" "api.$DOMAIN" "cast.$DOMAIN" "history.$DOMAIN"; do
  tls="$(curl --disable -sS -o /dev/null --max-time 20 -w '%{http_code} %{ssl_verify_result} %{remote_ip}' "https://$h/healthz" 2>&1)"
  redirect="$(curl --disable -sS -o /dev/null --max-time 20 -w '%{http_code} %{redirect_url}' "http://$h/" 2>&1)"
  issuer="$(openssl s_client -connect "$h:443" -servername "$h" </dev/null 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
  read -r tls_code tls_verify tls_ip <<<"$tls"
  read -r r_code r_url <<<"$redirect"
  label="${h%.$DOMAIN}"; [[ "$h" == "$DOMAIN" ]] && label=dashboard
  if [[ "$tls_verify" == 0 && "$tls_code" =~ ^[1-4][0-9][0-9]$ && "$alb_ips" == *" $tls_ip "* && "$r_code" == 301 &&
        ( "$r_url" == "https://$h/"* || "$r_url" == "https://$h:443/"* ) ]]; then
    eks PASS "eks.tls.$label" "host=$h verify=ok https_status=$tls_code ip=$tls_ip http_redirect=$r_code issuer=\"$issuer\""
  else
    eks FAIL "eks.tls.$label" "host=$h tls=\"$tls\" alb_ips=\"${alb_ips# }\" redirect=\"$redirect\" issuer=\"$issuer\""
  fi
done

# Every expected CNPG cluster must exist and be healthy. External databases are
# proven by the application cases, which read and write through them.
read -r -a cnpg_wanted <<<"${EKS_PROOF_CNPG_CLUSTERS:-control-api-pg hoopdb relayhistory-pg}"
cnpg="$("${K[@]}" get cluster.postgresql.cnpg.io -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase}{";"}{end}' 2>/dev/null)"
cnpg_ok=true
cnpg_detail=""
# A blank override names nothing, and a check of nothing must not pass.
if ((${#cnpg_wanted[@]} == 0)); then
  cnpg_ok=false
  cnpg_detail="EKS_PROOF_CNPG_CLUSTERS names no clusters;"
fi
for want in ${cnpg_wanted[@]+"${cnpg_wanted[@]}"}; do
  phase="$(tr ';' '\n' <<<"$cnpg" | sed -n "s/^${want}=//p")"
  cnpg_detail+="${want}=${phase:-missing};"
  [[ "$phase" == "Cluster in healthy state" ]] || cnpg_ok=false
done
$cnpg_ok && eks PASS eks.cnpg "${cnpg_detail%;}" || eks FAIL eks.cnpg "${cnpg_detail%;}"

if ((EKS_FAILS)); then
  printf 'EKS_RESULT=FAIL\n'
  ((rc == 0)) && rc=1
else
  printf 'EKS_RESULT=PASS\n'
fi
exit "$rc"
