#!/usr/bin/env bash
#
# Public DNS and TLS for the EKS proof: an ACM certificate for the four proof
# hosts (default <d>, api.<d>, cast.<d>, history.<d> with d =
# aws-proof.agentrelay.com), DNS-validated, and CNAMEs from the hosts to the
# ALB, all in the parent zone on Cloudflare.
#
# Why Cloudflare and not a Route53 zone delegated from Cloudflare: the Pippen
# sandbox's agent-session policy grants ACM (tagged pippen:sandbox) but no
# Route53 writes, so the sandbox cannot own a hosted zone. The 96bulls
# aws-proof-sandbox stage validates ACM through Cloudflare DNS the same way.
# A customer with Route53 creates the same records there (docs/self-hosted-eks.md).
#
#   # in the sandbox (Pippen lease):
#   pippen sandbox exec aws-proof -- scripts/selfhost/eks-proof-dns.sh cert-request
#   # on the operator machine, with the Cloudflare DNS edit token in the env:
#   CF_API_TOKEN=... scripts/selfhost/eks-proof-dns.sh cf-validation
#   pippen sandbox exec aws-proof -- scripts/selfhost/eks-proof-dns.sh cert-wait
#   pippen sandbox exec aws-proof -- scripts/selfhost/eks-proof-dns.sh alb       # once the Ingress has an ALB
#   CF_API_TOKEN=... scripts/selfhost/eks-proof-dns.sh cf-hosts
#   ...
#   CF_API_TOKEN=... scripts/selfhost/eks-proof-dns.sh cf-remove
#   pippen sandbox exec aws-proof -- scripts/selfhost/eks-proof-dns.sh cert-delete   # after the ALB is gone
#
# Every Cloudflare record this script creates is a name under the proof
# domain (never the parent's own records), unproxied (TLS is the ACM
# certificate on the ALB, end to end), carries an ownership comment, and has
# its id appended to $STATE_DIR/cloudflare-records.txt. Existing records
# without that comment are never adopted. cf-remove deletes exactly the
# recorded ids (keeping any that failed for a retry) and then checks that
# nothing is left under the proof domain. Only a certificate tagged
# pippen:sandbox=true that covers all four hosts is reused or deleted. The
# token is read from the environment, passed to curl on a pipe, never printed.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DOMAIN="${EKS_PROOF_DOMAIN:-aws-proof.agentrelay.com}"
CF_ZONE="${EKS_PROOF_CF_ZONE_ID:-34afb0e8fc19f2b6fd025668e880a889}"
REGION="${AWS_REGION:-us-west-2}"
NAME="${EKS_PROOF_NAME:-pippen-sbx-eks-proof}"
NS="${EKS_PROOF_NAMESPACE:-agent-relay}"
INGRESS="${EKS_ALB_INGRESS_NAME:-agent-relay}"
STATE_DIR="${EKS_PROOF_STATE_DIR:-$ROOT/.eks-proof}"
HOSTS=("$DOMAIN" "api.$DOMAIN" "cast.$DOMAIN" "history.$DOMAIN")
TAG_KEY="pippen:sandbox"
RECORDS="$STATE_DIR/cloudflare-records.txt"
mkdir -p "$STATE_DIR"

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
aws_() { aws --region "$REGION" "$@"; }

# cert_arn: an existing certificate this proof owns: tagged pippen:sandbox=true
# and covering every proof host. Anything else is never adopted (nor deleted).
# Prints nothing and succeeds only when a completed search found no match; an
# AWS lookup failure returns non-zero, so callers never request a duplicate.
cert_arn() {
  local arns arn names tag h ok
  arns="$(aws_ acm list-certificates --certificate-statuses PENDING_VALIDATION ISSUED \
    --query "CertificateSummaryList[?DomainName=='${DOMAIN}'].CertificateArn" --output text)" || return 1
  for arn in $arns; do
    tag="$(aws_ acm list-tags-for-certificate --certificate-arn "$arn" \
      --query "Tags[?Key=='${TAG_KEY}'].Value | [0]" --output text)" || return 1
    [[ "$tag" == true ]] || continue
    names="$(aws_ acm describe-certificate --certificate-arn "$arn" \
      --query 'join(`,`, Certificate.SubjectAlternativeNames)' --output text)" || return 1
    names=",${names},"
    ok=true
    for h in "${HOSTS[@]}"; do [[ "$names" == *",$h,"* ]] || ok=false; done
    $ok && { echo "$arn"; return 0; }
  done
  # None found: empty output, success.
  return 0
}

cmd_cert_request() {
  local arn out=""
  arn="$(cert_arn)" || { log "ACM certificate lookup failed; not requesting a new one"; exit 1; }
  if [[ -z "$arn" ]]; then
    log "request ACM certificate for ${HOSTS[*]}"
    arn="$(aws_ acm request-certificate --domain-name "$DOMAIN" \
      --subject-alternative-names "${HOSTS[@]:1}" --validation-method DNS \
      --key-algorithm RSA_2048 --tags "Key=${TAG_KEY},Value=true" \
      --query CertificateArn --output text)"
  fi
  echo "$arn" > "$STATE_DIR/acm-cert-arn"
  # The validation records appear a few seconds after the request.
  for _ in $(seq 1 30); do
    out="$(aws_ acm describe-certificate --certificate-arn "$arn" --output json | python3 -c '
import json, sys
opts = json.load(sys.stdin)["Certificate"].get("DomainValidationOptions", [])
if not opts or any("ResourceRecord" not in o for o in opts):
    sys.exit(0)
for name, value in sorted({(o["ResourceRecord"]["Name"].rstrip("."), o["ResourceRecord"]["Value"].rstrip(".")) for o in opts}):
    print(name, value)
')"
    [[ -n "$out" ]] && break
    sleep 5
  done
  [[ -n "$out" ]] || { log "ACM validation records did not appear"; exit 1; }
  printf '%s\n' "$out" > "$STATE_DIR/acm-validation.txt"
  log "certificate $arn: $(wc -l < "$STATE_DIR/acm-validation.txt" | tr -d ' ') validation CNAMEs in $STATE_DIR/acm-validation.txt"
}

cmd_cert_wait() {
  local arn; arn="$(cat "$STATE_DIR/acm-cert-arn")"
  log "waiting for $arn to be ISSUED"
  aws_ acm wait certificate-validated --certificate-arn "$arn"
  aws_ acm describe-certificate --certificate-arn "$arn" \
    --query 'Certificate.{status:Status,names:SubjectAlternativeNames,notAfter:NotAfter}' --output json
}

cmd_alb() {
  local kc alb
  kc="$(mktemp)"
  aws_ eks update-kubeconfig --name "$NAME" --kubeconfig "$kc" >/dev/null
  alb="$(KUBECONFIG="$kc" kubectl -n "$NS" get ingress "$INGRESS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
  rm -f "$kc"
  [[ -n "$alb" ]] || { log "ingress $NS/$INGRESS has no ALB hostname yet"; exit 1; }
  echo "$alb" > "$STATE_DIR/alb-hostname"
  log "ALB $alb"
}

cmd_cert_delete() {
  local arn
  arn="$(cat "$STATE_DIR/acm-cert-arn" 2>/dev/null || cert_arn)" || { log "ACM certificate lookup failed"; exit 1; }
  [[ -n "$arn" ]] || { log "no certificate"; return 0; }
  [[ "$(aws_ acm list-tags-for-certificate --certificate-arn "$arn" --query "Tags[?Key=='${TAG_KEY}'].Value | [0]" --output text 2>/dev/null)" == true ]] ||
    { log "refusing to delete $arn: not tagged ${TAG_KEY}=true"; exit 1; }
  aws_ acm describe-certificate --certificate-arn "$arn" >/dev/null 2>&1 || { log "certificate already gone"; return 0; }
  log "delete ACM certificate $arn"
  # In use until the ALB is gone; retry for a few minutes.
  local try
  for try in $(seq 1 20); do
    aws_ acm delete-certificate --certificate-arn "$arn" 2>/dev/null && break
    ((try == 20)) && aws_ acm delete-certificate --certificate-arn "$arn"
    sleep 15
  done
  rm -f "$STATE_DIR/acm-cert-arn" "$STATE_DIR/acm-validation.txt"
}

cf() { # method path [json]
  : "${CF_API_TOKEN:?CF_API_TOKEN (Cloudflare DNS edit token for the parent zone) is required}"
  # The token goes through a curl config on a pipe, never the argument list.
  curl -fsS -X "$1" --config <(printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN") \
    -H 'content-type: application/json' ${3:+--data "$3"} "https://api.cloudflare.com/client/v4/zones/${CF_ZONE}$2"
}

# cf_cname <name> <target>: create one unproxied CNAME under the proof domain
# and record its id. A record that already exists is updated only when this
# proof owns it (its comment carries OWNER_MARK); anything else is refused, so
# cf-remove never deletes a record the proof did not create.
OWNER_MARK="${NAME} EKS proof (remove at teardown)"
cf_cname() {
  local name="$1" target="$2" id owned body
  [[ "$name" == "$DOMAIN" || "$name" == *".$DOMAIN" ]] || { log "refusing $name: not under $DOMAIN"; exit 1; }
  body="{\"type\":\"CNAME\",\"name\":\"${name}\",\"content\":\"${target}\",\"ttl\":300,\"proxied\":false,\"comment\":\"${OWNER_MARK}\"}"
  read -r id owned < <(cf GET "/dns_records?name=${name}&per_page=100" | python3 -c '
import json, sys
mark = sys.argv[1]
recs = json.load(sys.stdin)["result"]
if not recs:
    print("- -")
elif len(recs) == 1 and recs[0]["type"] == "CNAME":
    print(recs[0]["id"], "yes" if recs[0].get("comment") == mark else "no")
else:
    print("- conflict")' "$OWNER_MARK")
  case "$owned" in
    yes)
      cf PUT "/dns_records/$id" "$body" >/dev/null
      log "updated proof-owned CNAME $name -> $target (id $id)" ;;
    -)
      id="$(cf POST /dns_records "$body" | python3 -c 'import json, sys; print(json.load(sys.stdin)["result"]["id"])')"
      log "added CNAME $name -> $target (id $id)" ;;
    *)
      log "refusing $name: a record not created by this proof already exists there"; exit 1 ;;
  esac
  grep -q "^$id " "$RECORDS" 2>/dev/null || printf '%s CNAME %s\n' "$id" "$name" >> "$RECORDS"
}

cmd_cf_validation() {
  [[ -s "$STATE_DIR/acm-validation.txt" ]] || { log "run cert-request first"; exit 1; }
  local name value
  while read -r name value; do cf_cname "$name" "$value"; done < "$STATE_DIR/acm-validation.txt"
}

cmd_cf_hosts() {
  [[ -s "$STATE_DIR/alb-hostname" ]] || { log "run alb first"; exit 1; }
  local alb h; alb="$(cat "$STATE_DIR/alb-hostname")"
  for h in "${HOSTS[@]}"; do cf_cname "$h" "$alb"; done
}

cmd_cf_remove() {
  local id rest left=""
  if [[ -f "$RECORDS" ]]; then
    while read -r id rest; do
      [[ -z "$id" ]] && continue
      if cf DELETE "/dns_records/$id" >/dev/null; then
        log "deleted Cloudflare record $id ($rest)"
      else
        log "could not delete $id ($rest); kept for a retry"
        left+="$id $rest"$'\n'
      fi
    done < "$RECORDS"
    if [[ -n "$left" ]]; then printf '%s' "$left" > "$RECORDS"; exit 1; fi
    rm -f "$RECORDS"
  fi
  # Nothing left under the proof domain (the parent's own records are not listed).
  cf GET "/dns_records?per_page=500&name.endswith=${DOMAIN}" | python3 -c '
import json, sys
left = [r["type"] + " " + r["name"] for r in json.load(sys.stdin)["result"]]
print("cloudflare records left under the proof domain: %d %s" % (len(left), " ".join(left)))
sys.exit(1 if left else 0)'
}

case "${1:-}" in
  cert-request) cmd_cert_request ;;
  cert-wait) cmd_cert_wait ;;
  alb) cmd_alb ;;
  cert-delete) cmd_cert_delete ;;
  cf-validation) cmd_cf_validation ;;
  cf-hosts) cmd_cf_hosts ;;
  cf-remove) cmd_cf_remove ;;
  *) echo "usage: $0 cert-request|cert-wait|alb|cert-delete|cf-validation|cf-hosts|cf-remove" >&2; exit 2 ;;
esac
