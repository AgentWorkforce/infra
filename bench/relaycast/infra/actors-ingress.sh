#!/usr/bin/env bash
#
# In-cluster stand-in for the durable-actors public ingress on the actors arm.
#
#   bench/relaycast/infra/actors-ingress.sh up|down
#
# Why: the actors gateway bridges every /v1/ws and /v1/node/ws socket through
# a URL that the control plane builds from durable-actors.publicUrl (https,
# schema-enforced). In production an Ingress/ALB with a real certificate fronts
# that host and forwards to the control-plane Service on :7100
# (charts/durable-actors/templates/ingress.yaml). The bench account has no
# usable public zone (option (b)), so without this the actors arm has NO
# realtime delivery at all: the gateway logs socket.upstream_failed
# getaddrinfo ENOTFOUND and clients see close code 1011.
#
# What `up` does (namespace arm-actors, all labelled purpose=relaycast-actors-bench):
#   - a bench-only CA and a certificate for the publicUrl host (generated into
#     the 0700 state dir; the CA key never leaves it);
#   - nginx (TLS, websocket upgrade, long timeouts) -> the control plane :7100,
#     on the app node group, sized like a small ALB target;
#   - a CoreDNS rewrite of the publicUrl host to the nginx Service;
#   - the gateway Deployment trusts the bench CA (NODE_EXTRA_CA_CERTS). This
#     is a kubectl patch on top of the Helm release, recorded in the report.
# `down` reverts the CoreDNS rewrite and deletes the objects.
set -euo pipefail
# Scratch never goes to /tmp on shared hosts.
export TMPDIR="${TMPDIR:-$HOME/.agent-tmp}"; mkdir -p "$TMPDIR"
NS=arm-actors
HOST="${ACTORS_HOST:-actors.relaycast-bench.agentrelay.com}"
STATE="${BENCH_STATE:-$HOME/.agent-tmp/rcb-state}/actors/ingress"
export KUBECONFIG="${BENCH_KUBECONFIG:-$HOME/.agent-tmp/relaycast-actors-bench.kubeconfig}"
NGINX_IMAGE="${NGINX_IMAGE:-public.ecr.aws/nginx/nginx:1.29-alpine}"
SVC="rcb-actors-ingress.${NS}.svc.cluster.local"
umask 077
log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }

cmd_up() {
  mkdir -p "$STATE"; chmod 700 "$STATE"
  if [[ ! -s "$STATE/ca.key" ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 7 -subj "/CN=relaycast-actors-bench CA" \
      -keyout "$STATE/ca.key" -out "$STATE/ca.crt" 2>/dev/null
    openssl req -newkey rsa:2048 -nodes -subj "/CN=${HOST}" -keyout "$STATE/tls.key" -out "$STATE/tls.csr" 2>/dev/null
    printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$HOST" >"$STATE/ext"
    openssl x509 -req -in "$STATE/tls.csr" -CA "$STATE/ca.crt" -CAkey "$STATE/ca.key" -CAcreateserial \
      -days 7 -extfile "$STATE/ext" -out "$STATE/tls.crt" 2>/dev/null
  fi
  kubectl -n "$NS" create secret tls rcb-actors-ingress-tls --cert="$STATE/tls.crt" --key="$STATE/tls.key" \
    --dry-run=client -o yaml | kubectl -n "$NS" apply -f - >/dev/null
  kubectl -n "$NS" create configmap rcb-bench-ca --from-file=ca.crt="$STATE/ca.crt" --dry-run=client -o yaml \
    | kubectl -n "$NS" apply -f - >/dev/null
  kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: rcb-actors-ingress, labels: {purpose: relaycast-actors-bench}}
data:
  default.conf: |
    map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
    server {
      listen 8443 ssl;
      server_name ${HOST};
      ssl_certificate /tls/tls.crt;
      ssl_certificate_key /tls/tls.key;
      client_max_body_size 128m;
      location / {
        proxy_pass http://agent-relay-durable-actors.${NS}.svc.cluster.local:7100;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: rcb-actors-ingress, labels: {purpose: relaycast-actors-bench}}
spec:
  replicas: 2
  selector: {matchLabels: {app: rcb-actors-ingress}}
  template:
    metadata: {labels: {app: rcb-actors-ingress, purpose: relaycast-actors-bench}}
    spec:
      nodeSelector: {bench/role: app}
      automountServiceAccountToken: false
      containers:
        - name: nginx
          image: ${NGINX_IMAGE}
          ports: [{containerPort: 8443}]
          resources: {requests: {cpu: 250m, memory: 128Mi}, limits: {memory: 512Mi}}
          volumeMounts:
            - {name: conf, mountPath: /etc/nginx/conf.d}
            - {name: tls, mountPath: /tls, readOnly: true}
      volumes:
        - {name: conf, configMap: {name: rcb-actors-ingress}}
        - {name: tls, secret: {secretName: rcb-actors-ingress-tls}}
---
apiVersion: v1
kind: Service
metadata: {name: rcb-actors-ingress, labels: {purpose: relaycast-actors-bench}}
spec:
  selector: {app: rcb-actors-ingress}
  ports: [{name: https, port: 443, targetPort: 8443}]
EOF
  kubectl -n "$NS" rollout status deploy/rcb-actors-ingress --timeout=5m >/dev/null

  # CoreDNS: rewrite the public host to the in-cluster Service (idempotent).
  local cf
  cf="$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')"
  if ! grep -q "rewrite name ${HOST}" <<<"$cf"; then
    cf="$(sed "0,/ready/s//ready\n    rewrite name ${HOST} ${SVC}/" <<<"$cf")"
    kubectl -n kube-system create configmap coredns --from-literal=Corefile="$cf" --dry-run=client -o yaml \
      | kubectl -n kube-system apply -f - >/dev/null 2>&1
    kubectl -n kube-system rollout restart deploy/coredns >/dev/null
    kubectl -n kube-system rollout status deploy/coredns --timeout=3m >/dev/null
  fi

  # Gateway trusts the bench CA.
  kubectl -n "$NS" patch deploy relaycast --type strategic -p '{"spec":{"template":{"spec":{
    "volumes":[{"name":"rcb-bench-ca","configMap":{"name":"rcb-bench-ca"}}],
    "containers":[{"name":"'"$(kubectl -n "$NS" get deploy relaycast -o jsonpath='{.spec.template.spec.containers[0].name}')"'",
      "env":[{"name":"NODE_EXTRA_CA_CERTS","value":"/etc/rcb-bench-ca/ca.crt"}],
      "volumeMounts":[{"name":"rcb-bench-ca","mountPath":"/etc/rcb-bench-ca","readOnly":true}]}]}}}}' >/dev/null
  kubectl -n "$NS" rollout status deploy/relaycast --timeout=5m >/dev/null
  log "actors ingress stand-in up: ${HOST} -> ${SVC} -> control plane :7100"
}

cmd_down() {
  local cf
  cf="$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' 2>/dev/null || true)"
  if grep -q "rewrite name ${HOST}" <<<"$cf"; then
    cf="$(grep -v "rewrite name ${HOST}" <<<"$cf")"
    kubectl -n kube-system create configmap coredns --from-literal=Corefile="$cf" --dry-run=client -o yaml \
      | kubectl -n kube-system apply -f - >/dev/null 2>&1
    kubectl -n kube-system rollout restart deploy/coredns >/dev/null
  fi
  kubectl -n "$NS" delete deploy/rcb-actors-ingress svc/rcb-actors-ingress configmap/rcb-actors-ingress --ignore-not-found >/dev/null
  kubectl -n "$NS" delete secret rcb-actors-ingress-tls --ignore-not-found >/dev/null
  kubectl -n "$NS" delete configmap rcb-bench-ca --ignore-not-found >/dev/null
  log "actors ingress stand-in removed"
}

case "${1:-}" in
  up) cmd_up ;;
  down) cmd_down ;;
  *) echo "usage: $0 up|down" >&2; exit 2 ;;
esac
