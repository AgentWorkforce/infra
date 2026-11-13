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
#   history.<domain>  native History: the Sessions read API and the ingest edge
#                     (only with EKS_ALB_HISTORY=true, the default)
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
# The history.<domain> origin routes only to native History (the standalone
# RelayHistory server was removed). Native session ingest (EKS_ALB_INGEST,
# default true whenever the history host is on and not read-only) shares that
# origin, so it needs no new name on the certificate. The four public ingest
# paths in docs/self-hosted-native-ingest.md go to the ingest edge Service as
# Exact paths and /internal is denied as on api and cast. The ingest edge
# receives all of /v1/delivery (delivery records stay on the read API),
# /v1/turns and /v1/onboarding; the read API receives its read paths, and
# anything else on that host is a fixed 404 at the edge
# (docs/self-hosted-no-relayauth.md). Exact paths match any method: the ingest
# edge refuses the wrong one. Services without their own health-check
# annotation use /healthz from an Ingress-level default, which a Service
# annotation overrides; it is the one path both backends serve.
# EKS_ALB_HISTORY_READ_ONLY=true (with EKS_ALB_INGEST unset or false) publishes
# only the read API on that host. EKS_ALB_HISTORY_LEGACY_SERVICE, which kept a
# standalone RelayHistory behind the origin, is refused.
#
# Flows on relayfile-control (off by default; EKS_ALB_RELAYFILE_CONTROL=true)
# route /api/v1/{flows,workers,workflows} on api.<domain> and the
# /cloud/api/v1/{flows,workers,workflows} aliases on <domain> and api.<domain>
# to that Service instead of the control API. EKS_ALB_RELAYFILE_CONTROL_SERVICE
# defaults to relayfile-control and EKS_ALB_RELAYFILE_CONTROL_PORT to 3100. The
# Service needs its own alb.ingress.kubernetes.io/healthcheck-path annotation.
#
# EKS_ALB_CHIEF_SERVICE (default empty) sends the dashboard's Chief calls on
# <domain> to a separately installed relaychief-control Service, port
# EKS_ALB_CHIEF_PORT (default 3200), ahead of the control API. Those routes need
# a wildcard for the workspace id, and wildcards are ImplementationSpecific, so
# with Chief on, this host's Prefix paths become Exact plus ordered wildcards.

set -euo pipefail
NS="${1:-agent-relay}"
CLASS="${EKS_INGRESS_CLASS:-alb}"
DOMAIN="${EKS_ALB_DOMAIN:?EKS_ALB_DOMAIN=<base domain> is required}"
CERT="${EKS_ALB_CERT_ARN:?EKS_ALB_CERT_ARN=<ACM certificate ARN> is required}"
HISTORY="${EKS_ALB_HISTORY:-true}"
# Read API only on history.<domain>, for installs with no ingest edge yet. Upload
# paths then answer the fixed 404 rather than a missing backend.
HISTORY_READ_ONLY="${EKS_ALB_HISTORY_READ_ONLY:-false}"
# The ingest edge is on whenever the history host is published and not read-only.
INGEST_DEFAULT=false
[[ "$HISTORY" == true && "$HISTORY_READ_ONLY" != true ]] && INGEST_DEFAULT=true
INGEST="${EKS_ALB_INGEST:-$INGEST_DEFAULT}"
INGEST_SVC="${EKS_ALB_INGEST_SERVICE:-agent-relay-ingest-edge}"
INGEST_PORT="${EKS_ALB_INGEST_PORT:-80}"
READ_API_SVC="${EKS_ALB_READ_API_SERVICE:-agent-relay-read-api}"
READ_API_PORT="${EKS_ALB_READ_API_PORT:-80}"
RELAYFILE_CONTROL="${EKS_ALB_RELAYFILE_CONTROL:-false}"
RELAYFILE_CONTROL_SVC="${EKS_ALB_RELAYFILE_CONTROL_SERVICE:-relayfile-control}"
RELAYFILE_CONTROL_PORT="${EKS_ALB_RELAYFILE_CONTROL_PORT:-3100}"
NAME="${EKS_ALB_INGRESS_NAME:-agent-relay}"
CONTROL_SVC="${EKS_ALB_CONTROL_SERVICE:-relay-control}"
WEBAPP_SVC="${EKS_ALB_WEBAPP_SERVICE:-relay-webapp}"
CHIEF_SVC="${EKS_ALB_CHIEF_SERVICE:-}"
CHIEF_PORT="${EKS_ALB_CHIEF_PORT:-3200}"
if [[ -n "$CHIEF_SVC" ]]; then
  [[ ${#CHIEF_SVC} -le 63 && "$CHIEF_SVC" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
    { printf '%s\n' 'EKS_ALB_CHIEF_SERVICE must be a DNS label' >&2; exit 2; }
  [[ "$CHIEF_PORT" =~ ^[1-9][0-9]{0,4}$ && "$CHIEF_PORT" -le 65535 ]] ||
    { printf '%s\n' 'EKS_ALB_CHIEF_PORT must be 1-65535' >&2; exit 2; }
fi
for service in "$CONTROL_SVC" "$WEBAPP_SVC"; do
  [[ ${#service} -le 63 && "$service" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
    { printf '%s\n' 'Control/Webapp Service overrides must be DNS labels' >&2; exit 2; }
done
[[ "$INGEST" == true || "$INGEST" == false ]] ||
  { printf '%s\n' 'EKS_ALB_INGEST must be true or false' >&2; exit 2; }
[[ -z "${EKS_ALB_HISTORY_LEGACY_SERVICE:-}" ]] ||
  { printf '%s\n' 'EKS_ALB_HISTORY_LEGACY_SERVICE was removed: the history host routes only to native History (read API and ingest edge)' >&2; exit 2; }
if [[ "$HISTORY" == true && "$HISTORY_READ_ONLY" != true && "$INGEST" != true ]]; then
  printf '%s\n' 'EKS_ALB_INGEST=false needs EKS_ALB_HISTORY_READ_ONLY=true: the history host has no standalone RelayHistory backend' >&2
  exit 2
fi
[[ "$RELAYFILE_CONTROL" == true || "$RELAYFILE_CONTROL" == false ]] ||
  { printf '%s\n' 'EKS_ALB_RELAYFILE_CONTROL must be true or false' >&2; exit 2; }
if [[ "$RELAYFILE_CONTROL" == true ]]; then
  [[ ${#RELAYFILE_CONTROL_SVC} -le 63 && "$RELAYFILE_CONTROL_SVC" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
    { printf '%s\n' 'EKS_ALB_RELAYFILE_CONTROL_SERVICE must be a DNS label' >&2; exit 2; }
  [[ "$RELAYFILE_CONTROL_PORT" =~ ^[1-9][0-9]{0,4}$ && "$RELAYFILE_CONTROL_PORT" -le 65535 ]] ||
    { printf '%s\n' 'EKS_ALB_RELAYFILE_CONTROL_PORT must be 1-65535' >&2; exit 2; }
fi
[[ "$HISTORY_READ_ONLY" == true || "$HISTORY_READ_ONLY" == false ]] ||
  { printf '%s\n' 'EKS_ALB_HISTORY_READ_ONLY must be true or false' >&2; exit 2; }
if [[ "$HISTORY_READ_ONLY" == true ]]; then
  [[ "$HISTORY" == true && "$INGEST" == false ]] ||
    { printf '%s\n' 'EKS_ALB_HISTORY_READ_ONLY=true needs EKS_ALB_HISTORY=true and EKS_ALB_INGEST=false' >&2; exit 2; }
  [[ ${#READ_API_SVC} -le 63 && "$READ_API_SVC" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
    { printf '%s\n' 'Read API Service override must be a DNS label' >&2; exit 2; }
  [[ "$READ_API_PORT" =~ ^[1-9][0-9]{0,4}$ && "$READ_API_PORT" -le 65535 ]] ||
    { printf '%s\n' 'Read API port must be 1-65535' >&2; exit 2; }
fi
INGEST_HEALTHCHECK=""
if [[ "$HISTORY_READ_ONLY" == true ]]; then
  INGEST_HEALTHCHECK=$'\n    alb.ingress.kubernetes.io/healthcheck-path: /healthz'
fi
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
  annotations:${INGEST_HEALTHCHECK}
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
if [[ -n "$CHIEF_SVC" ]]; then
  route /cloud/api "$CONTROL_SVC" 80 Exact
  route /login "$CONTROL_SVC" 80 Exact
  for prefix in /cloud/api/v1 /api/v1; do
    route "\"$prefix/workspaces/*/chiefs\"" "$CHIEF_SVC" "$CHIEF_PORT" ImplementationSpecific
    route "\"$prefix/workspaces/*/chiefs/*\"" "$CHIEF_SVC" "$CHIEF_PORT" ImplementationSpecific
  done
  route '"/cloud/api/*"' "$CONTROL_SVC" 80 ImplementationSpecific
  route '"/login/*"' "$CONTROL_SVC" 80 ImplementationSpecific
  route '"/*"' "$WEBAPP_SVC" 8080 ImplementationSpecific
else
  route /cloud/api "$CONTROL_SVC" 80
  route /login "$CONTROL_SVC" 80
  route / "$WEBAPP_SVC" 8080
fi

host "api.$DOMAIN"
deny /internal Prefix
deny '"//internal*"' ImplementationSpecific
flows_routes /cloud/api/v1
flows_routes /api/v1
if [[ -n "$CHIEF_SVC" ]]; then
  for prefix in /cloud/api/v1 /api/v1; do
    route "\"$prefix/workspaces/*/chiefs\"" "$CHIEF_SVC" "$CHIEF_PORT" ImplementationSpecific
    route "\"$prefix/workspaces/*/chiefs/*\"" "$CHIEF_SVC" "$CHIEF_PORT" ImplementationSpecific
  done
fi
route '"/*"' "$CONTROL_SVC" 80 ImplementationSpecific

host "cast.$DOMAIN"
deny /internal Prefix
deny '"//internal*"' ImplementationSpecific
deny /v1/workspaces Exact
deny /v1/workspaces/ Exact
route '"/*"' relaycast 8787 ImplementationSpecific

if [[ "$HISTORY" == true ]]; then
  host "history.$DOMAIN"
  if [[ "$HISTORY_READ_ONLY" == true ]]; then
    for path in /v1/delivery/records /v1/cli/login /v1/events /v1/auth/token/revoke; do
      route "$path" "$READ_API_SVC" "$READ_API_PORT" Exact
    done
    route /v1/sessions "$READ_API_SVC" "$READ_API_PORT" Prefix
    route /v1/digest "$READ_API_SVC" "$READ_API_PORT" Prefix
    deny /internal Prefix
    deny '"//internal*"' ImplementationSpecific
    deny '"/*"' ImplementationSpecific
  else
    for path in /v1/delivery/batches /v1/turns/batches /v1/delivery/limits /v1/auth/token/refresh; do
      route "$path" "$INGEST_SVC" "$INGEST_PORT" Exact
    done
    # The ingest edge owns /v1/delivery/*, /v1/turns/* and /v1/onboarding/*,
    # except delivery records, which the read API serves (relayhistory-pipeline
    # docs/selfhost-composition.md section 2). The controller orders Exact
    # before Prefix.
    for path in /v1/delivery/records /v1/cli/login /v1/events /v1/auth/token/revoke; do
      route "$path" "$READ_API_SVC" "$READ_API_PORT" Exact
    done
    route /v1/sessions "$READ_API_SVC" "$READ_API_PORT" Prefix
    route /v1/digest "$READ_API_SVC" "$READ_API_PORT" Prefix
    for path in /v1/delivery /v1/turns /v1/onboarding; do
      route "$path" "$INGEST_SVC" "$INGEST_PORT" Prefix
    done
    deny /internal Prefix
    deny '"//internal*"' ImplementationSpecific
    # Everything not named above is a fixed 404 at the edge, probes included.
    deny '"/*"' ImplementationSpecific
  fi
fi
