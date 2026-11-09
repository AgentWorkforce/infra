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
#
# Native session ingest (off by default; EKS_ALB_INGEST=true, which needs
# EKS_ALB_HISTORY=true) shares the history.<domain> origin, so it needs no new
# name on the certificate. The four public ingest paths in
# docs/self-hosted-native-ingest.md go to the ingest edge Service as Exact
# paths, everything else on that host goes to the read API instead of
# RelayHistory, and /internal is denied as on api and cast. Exact paths match
# any method: the ingest edge refuses the wrong one. Services without their own
# health-check annotation use /healthz from an Ingress-level default, which a
# Service annotation overrides; it is the one path both new backends serve.
#
# EKS_ALB_HISTORY_LEGACY_SERVICE (default empty, with EKS_ALB_INGEST=true) keeps
# a standalone RelayHistory answering on that origin during a migration: the
# read API receives only bearers carrying its own rth_at_read_/rth_rt_read_
# prefixes, plus OPTIONS preflights on its CORS routes, and every other request
# goes to the named Service. EKS_ALB_HISTORY_LEGACY_PORT defaults to 8080.
#
# Flows on relayfile-control (off by default; EKS_ALB_RELAYFILE_CONTROL=true)
# route /api/v1/{flows,workers,workflows} on api.<domain> and the
# /cloud/api/v1/{flows,workers,workflows} aliases on <domain> and api.<domain>
# to that Service instead of the control API. EKS_ALB_RELAYFILE_CONTROL_SERVICE
# defaults to relayfile-control and EKS_ALB_RELAYFILE_CONTROL_PORT to 3100. The
# Service needs its own alb.ingress.kubernetes.io/healthcheck-path annotation.

set -euo pipefail
NS="${1:-agent-relay}"
CLASS="${EKS_INGRESS_CLASS:-alb}"
DOMAIN="${EKS_ALB_DOMAIN:?EKS_ALB_DOMAIN=<base domain> is required}"
CERT="${EKS_ALB_CERT_ARN:?EKS_ALB_CERT_ARN=<ACM certificate ARN> is required}"
HISTORY="${EKS_ALB_HISTORY:-true}"
INGEST="${EKS_ALB_INGEST:-false}"
INGEST_SVC="${EKS_ALB_INGEST_SERVICE:-agent-relay-ingest-edge}"
INGEST_PORT="${EKS_ALB_INGEST_PORT:-80}"
READ_API_SVC="${EKS_ALB_READ_API_SERVICE:-agent-relay-read-api}"
READ_API_PORT="${EKS_ALB_READ_API_PORT:-80}"
LEGACY_SVC="${EKS_ALB_HISTORY_LEGACY_SERVICE:-}"
LEGACY_PORT="${EKS_ALB_HISTORY_LEGACY_PORT:-8080}"
RELAYFILE_CONTROL="${EKS_ALB_RELAYFILE_CONTROL:-false}"
RELAYFILE_CONTROL_SVC="${EKS_ALB_RELAYFILE_CONTROL_SERVICE:-relayfile-control}"
RELAYFILE_CONTROL_PORT="${EKS_ALB_RELAYFILE_CONTROL_PORT:-3100}"
NAME="${EKS_ALB_INGRESS_NAME:-agent-relay}"
CONTROL_SVC="${EKS_ALB_CONTROL_SERVICE:-relay-control}"
WEBAPP_SVC="${EKS_ALB_WEBAPP_SERVICE:-relay-webapp}"
for service in "$CONTROL_SVC" "$WEBAPP_SVC"; do
  [[ ${#service} -le 63 && "$service" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
    { printf '%s\n' 'Control/Webapp Service overrides must be DNS labels' >&2; exit 2; }
done
[[ "$INGEST" == true || "$INGEST" == false ]] ||
  { printf '%s\n' 'EKS_ALB_INGEST must be true or false' >&2; exit 2; }
[[ "$RELAYFILE_CONTROL" == true || "$RELAYFILE_CONTROL" == false ]] ||
  { printf '%s\n' 'EKS_ALB_RELAYFILE_CONTROL must be true or false' >&2; exit 2; }
if [[ "$RELAYFILE_CONTROL" == true ]]; then
  [[ ${#RELAYFILE_CONTROL_SVC} -le 63 && "$RELAYFILE_CONTROL_SVC" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
    { printf '%s\n' 'EKS_ALB_RELAYFILE_CONTROL_SERVICE must be a DNS label' >&2; exit 2; }
  [[ "$RELAYFILE_CONTROL_PORT" =~ ^[1-9][0-9]{0,4}$ && "$RELAYFILE_CONTROL_PORT" -le 65535 ]] ||
    { printf '%s\n' 'EKS_ALB_RELAYFILE_CONTROL_PORT must be 1-65535' >&2; exit 2; }
fi
INGEST_HEALTHCHECK=""
if [[ "$INGEST" == true ]]; then
  [[ "$HISTORY" == true ]] ||
    { printf '%s\n' 'EKS_ALB_INGEST=true needs the history host (EKS_ALB_HISTORY=true)' >&2; exit 2; }
  for service in "$INGEST_SVC" "$READ_API_SVC"; do
    [[ ${#service} -le 63 && "$service" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
      { printf '%s\n' 'Ingest/read API Service overrides must be DNS labels' >&2; exit 2; }
  done
  for port in "$INGEST_PORT" "$READ_API_PORT"; do
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ && "$port" -le 65535 ]] ||
      { printf '%s\n' 'Ingest/read API ports must be 1-65535' >&2; exit 2; }
  done
  INGEST_HEALTHCHECK=$'\n    alb.ingress.kubernetes.io/healthcheck-path: /healthz'
fi
LEGACY_ANNOTATIONS=""
if [[ -n "$LEGACY_SVC" ]]; then
  [[ "$INGEST" == true ]] ||
    { printf '%s\n' 'EKS_ALB_HISTORY_LEGACY_SERVICE needs EKS_ALB_INGEST=true' >&2; exit 2; }
  [[ ${#LEGACY_SVC} -le 63 && "$LEGACY_SVC" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
    { printf '%s\n' 'EKS_ALB_HISTORY_LEGACY_SERVICE must be a DNS label' >&2; exit 2; }
  [[ "$LEGACY_PORT" =~ ^[1-9][0-9]{0,4}$ && "$LEGACY_PORT" -le 65535 ]] ||
    { printf '%s\n' 'EKS_ALB_HISTORY_LEGACY_PORT must be 1-65535' >&2; exit 2; }
  forward="{\"type\":\"forward\",\"forwardConfig\":{\"targetGroups\":[{\"serviceName\":\"${READ_API_SVC}\",\"servicePort\":${READ_API_PORT}}]}}"
  LEGACY_ANNOTATIONS="
    alb.ingress.kubernetes.io/actions.read-api-token: '${forward}'
    alb.ingress.kubernetes.io/conditions.read-api-token: '[{\"field\":\"http-header\",\"httpHeaderConfig\":{\"httpHeaderName\":\"Authorization\",\"values\":[\"Bearer rth_at_read_*\",\"Bearer rth_rt_read_*\"]}}]'
    alb.ingress.kubernetes.io/actions.read-api-cors: '${forward}'
    alb.ingress.kubernetes.io/conditions.read-api-cors: '[{\"field\":\"http-request-method\",\"httpRequestMethodConfig\":{\"Values\":[\"OPTIONS\"]}}]'"
fi

deny() {
  printf '%s\n' \
    "          - path: $1" \
    "            pathType: $2" \
    "            backend: { service: { name: edge-deny, port: { name: use-annotation } } }"
}

action() { # path pathType action-name
  printf '%s\n' \
    "          - path: $1" \
    "            pathType: $2" \
    "            backend: { service: { name: $3, port: { name: use-annotation } } }"
}

route() { # path service port [pathType]
  printf '%s\n' \
    "          - path: $1" \
    "            pathType: ${4:-Prefix}" \
    "            backend: { service: { name: $2, port: { number: $3 } } }"
}

flows_routes() { # base path; a no-op unless EKS_ALB_RELAYFILE_CONTROL=true
  [[ "$RELAYFILE_CONTROL" == true ]] || return 0
  local resource
  for resource in flows workers workflows; do
    route "$1/$resource" "$RELAYFILE_CONTROL_SVC" "$RELAYFILE_CONTROL_PORT"
  done
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
  annotations:${INGEST_HEALTHCHECK}${LEGACY_ANNOTATIONS}
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
flows_routes /cloud/api/v1
route /cloud/api "$CONTROL_SVC" 80
route /login "$CONTROL_SVC" 80
route / "$WEBAPP_SVC" 8080

host "api.$DOMAIN"
deny /internal Prefix
deny '"//internal*"' ImplementationSpecific
flows_routes /cloud/api/v1
flows_routes /api/v1
route '"/*"' "$CONTROL_SVC" 80 ImplementationSpecific

host "cast.$DOMAIN"
deny /internal Prefix
deny '"//internal*"' ImplementationSpecific
deny /v1/workspaces Exact
deny /v1/workspaces/ Exact
route '"/*"' relaycast 8787 ImplementationSpecific

if [[ "$HISTORY" == true ]]; then
  host "history.$DOMAIN"
  if [[ "$INGEST" == true ]]; then
    for path in /v1/delivery/batches /v1/turns/batches /v1/delivery/limits /v1/auth/token/refresh; do
      route "$path" "$INGEST_SVC" "$INGEST_PORT" Exact
    done
    deny /internal Prefix
    deny '"//internal*"' ImplementationSpecific
    if [[ -n "$LEGACY_SVC" ]]; then
      action /v1/sessions Prefix read-api-token
      action /v1/sessions Prefix read-api-cors
      action /v1/events Exact read-api-token
      action /v1/events Exact read-api-cors
      action /v1/auth/token/revoke Exact read-api-token
      route '"/*"' "$LEGACY_SVC" "$LEGACY_PORT" ImplementationSpecific
    else
      route '"/*"' "$READ_API_SVC" "$READ_API_PORT" ImplementationSpecific
    fi
  else
    route / relayhistory 8080
  fi
fi
