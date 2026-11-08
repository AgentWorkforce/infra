#!/usr/bin/env bash
#
# Prints the ALB Ingress for an agent-relay release on EKS (Auto Mode's
# built-in ALB controller, IngressClass "alb", or the AWS Load Balancer
# Controller with the same annotations). The chart ships only the GKE edge
# (gkeIngress), so on EKS the edge is applied next to the release:
#
#   EKS_ALB_DOMAIN=relay.example.com EKS_ALB_CERT_ARN=arn:aws:acm:... \
#     scripts/selfhost/eks-alb-ingress.sh agent-relay | kubectl apply -f -
#
# One internet-facing ALB with host rules, the same layout as the GKE edge:
#
#   <domain>          dashboard, with /cloud/api and /login routed to the
#                     control API
#   api.<domain>      control API
#   cast.<domain>     Relaycast
#   history.<domain>  RelayHistory (only with EKS_ALB_HISTORY=true, the default)
#
# TLS terminates at the ALB with the ACM certificate EKS_ALB_CERT_ARN (it must
# cover all four names); port 80 redirects to 443. Health-check paths come
# from each Service's alb.ingress.kubernetes.io/healthcheck-path annotation
# (values-eks.yaml), so each target group checks its backend on its own path.
#
# The edge denials of the GKE Ingress answer at the ALB with a fixed 404:
# /internal on api and cast, and Relaycast's workspace-create paths. The ALB
# does not collapse a leading "//" and an Exact/Prefix Ingress path may not
# contain "//", so "//internal*" is denied with an ImplementationSpecific
# path (the ALB's own wildcard syntax). The controller orders a host's rules
# Exact, then Prefix, then ImplementationSpecific (in spec order), so the api
# and cast catch-alls are ImplementationSpecific "/*" listed after it; a
# Prefix "/" catch-all would win first.

set -euo pipefail
NS="${1:-agent-relay}"
CLASS="${EKS_INGRESS_CLASS:-alb}"
DOMAIN="${EKS_ALB_DOMAIN:?EKS_ALB_DOMAIN=<base domain> is required}"
CERT="${EKS_ALB_CERT_ARN:?EKS_ALB_CERT_ARN=<ACM certificate ARN> is required}"
HISTORY="${EKS_ALB_HISTORY:-true}"
NAME="${EKS_ALB_INGRESS_NAME:-agent-relay}"

deny() {
  printf '%s\n' \
    "          - path: $1" \
    "            pathType: $2" \
    "            backend: { service: { name: edge-deny, port: { name: use-annotation } } }"
}

route() { # path service port [pathType]
  printf '%s\n' \
    "          - path: $1" \
    "            pathType: ${4:-Prefix}" \
    "            backend: { service: { name: $2, port: { number: $3 } } }"
}

host() {
  printf '%s\n' "    - host: $1" "      http:" "        paths:"
}

cat <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${NAME}
  namespace: ${NS}
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/certificate-arn: ${CERT}
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
    alb.ingress.kubernetes.io/load-balancer-attributes: idle_timeout.timeout_seconds=3600
    alb.ingress.kubernetes.io/actions.edge-deny: >-
      {"type":"fixed-response","fixedResponseConfig":{"contentType":"text/plain","statusCode":"404","messageBody":"not found"}}
spec:
  ingressClassName: ${CLASS}
  tls:
    - hosts: [${DOMAIN}, api.${DOMAIN}, cast.${DOMAIN}$([[ "$HISTORY" == true ]] && printf ', history.%s' "$DOMAIN")]
  rules:
EOF

host "$DOMAIN"
route /cloud/api relay-control 80
route /login relay-control 80
route / relay-webapp 8080

host "api.$DOMAIN"
deny /internal Prefix
deny '"//internal*"' ImplementationSpecific
route '"/*"' relay-control 80 ImplementationSpecific

host "cast.$DOMAIN"
deny /internal Prefix
deny '"//internal*"' ImplementationSpecific
deny /v1/workspaces Exact
deny /v1/workspaces/ Exact
route '"/*"' relaycast 8787 ImplementationSpecific

if [[ "$HISTORY" == true ]]; then
  host "history.$DOMAIN"
  route / relayhistory 8080
fi
