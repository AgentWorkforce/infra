#!/usr/bin/env bash
# kind proof: Relaycast on PostgreSQL (verify-full TLS, self-signed CA) moved to
# durable-actors (`durable-actors dev` sidecar, MinIO files) with the chart's
# migration Jobs, then every read compared with the PostgreSQL state.
# docs/relaycast-postgres-to-actors-migration.md.
#
# Prerequisites: a kind cluster whose containerd resolves localhost:5051 to a
# registry (kind's local-registry setup), and these images built from the
# relaycast checkout under test, pushed there by this script:
#   relaycast-self-host:kind       docker build -f Dockerfile .
#   relaycast-actors-gateway:kind  docker build -f docker/actors-gateway.Dockerfile .
#   relaycast-actors-dev:kind      docker build -f <infra>/ci/agent-relay/kind/relaycast-actors-dev.Dockerfile .
#
#   KIND_CLUSTER=relaycast-pg-to-actors bash ci/agent-relay/kind/relaycast-pg-to-actors-proof.sh
#
# Secret values are generated here, kept in $WORK (0700) and never printed.
set -euo pipefail
cd "$(dirname "$0")/../../.."

CLUSTER=${KIND_CLUSTER:-relaycast-pg-to-actors}
CTX="kind-$CLUSTER"
NS=${NAMESPACE:-relaycast-mig}
REG=${REGISTRY:-localhost:5051}
K=(kubectl --context "$CTX" -n "$NS")
H=(helm --kube-context "$CTX" -n "$NS")
MINIO_IMAGE=${MINIO_IMAGE:-bitnamilegacy/minio:2025.4.22}
WORK=${WORK_DIR:-$(mktemp -d)}
mkdir -p "$WORK"; chmod 700 "$WORK"
RUN=${RUN_ID:-kindproof-$(date -u +%Y%m%d%H%M%S)}
# A free local port: a busy one would send the proof's requests to whatever holds it.
PORT=${LOCAL_PORT:-$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}
log() { printf '\n=== %s\n' "$*"; }
rand() { openssl rand -hex "${1:-24}"; }

log "push images to $REG"
for image in relaycast-self-host relaycast-actors-gateway relaycast-actors-dev; do
  docker tag "$image:kind" "$REG/$image:kind"
  docker push -q "$REG/$image:kind" >/dev/null
done
# Pin by digest: a reused tag can resolve to an image a kind node cached earlier.
digest_of() { docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$REG/$1:kind" | grep "^$REG/" | head -1 | cut -d@ -f2; }
SELFHOST_DIGEST=$(digest_of relaycast-self-host); GATEWAY_DIGEST=$(digest_of relaycast-actors-gateway); DEV_DIGEST=$(digest_of relaycast-actors-dev)
for d in "$SELFHOST_DIGEST" "$GATEWAY_DIGEST" "$DEV_DIGEST"; do
  [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "no registry digest for an image"; exit 1; }
done

log "namespace, TLS PostgreSQL ($NS), MinIO, secrets"
# A namespace left by an earlier run of this proof must be gone first (its pods
# would answer the port-forward with old secrets). Any other namespace of that
# name is not ours: refuse rather than delete it.
MARK=agentworkforce.dev/relaycast-pg-to-actors-proof
if kubectl --context "$CTX" get namespace "$NS" >/dev/null 2>&1; then
  [ "$(kubectl --context "$CTX" get namespace "$NS" -o jsonpath="{.metadata.labels.agentworkforce\.dev/relaycast-pg-to-actors-proof}")" = "true" ] \
    || { echo "namespace $NS exists and was not created by this proof: choose another NAMESPACE"; exit 1; }
  kubectl --context "$CTX" delete namespace "$NS" --wait=true --timeout=5m >/dev/null
fi
kubectl --context "$CTX" create namespace "$NS" >/dev/null
kubectl --context "$CTX" label namespace "$NS" "$MARK=true" >/dev/null
(
  cd "$WORK"; umask 077
  openssl req -x509 -newkey rsa:2048 -nodes -days 7 -subj "/CN=relaycast-proof-ca" -keyout ca.key -out ca.crt 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -subj "/CN=postgres" -keyout server.key -out server.csr 2>/dev/null
  printf 'subjectAltName=DNS:postgres.%s.svc,DNS:postgres.%s.svc.cluster.local\n' "$NS" "$NS" > san.ext
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 7 -extfile san.ext -out server.crt 2>/dev/null
  for f in owner runtime super internal bootstrap filesig devsecret minio; do rand | tr -d "\n" > "$f.pw"; done
  printf '{"current":"a","keys":{"a":"%s"}}' "$(rand 32)" > keyring
)
PG="postgres.$NS.svc"
"${K[@]}" create secret generic pg-tls --from-file=server.crt="$WORK/server.crt" --from-file=server.key="$WORK/server.key" \
  --from-file=super.pw="$WORK/super.pw" --from-literal=init.sql="CREATE ROLE relaycast_owner LOGIN PASSWORD '$(cat "$WORK/owner.pw")';
CREATE ROLE relaycast_runtime LOGIN PASSWORD '$(cat "$WORK/runtime.pw")';
ALTER SCHEMA public OWNER TO relaycast_owner;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO relaycast_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE relaycast_owner IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO relaycast_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE relaycast_owner IN SCHEMA public GRANT SELECT, USAGE, UPDATE ON SEQUENCES TO relaycast_runtime;
REVOKE TEMP, CREATE ON DATABASE app FROM PUBLIC;
GRANT TEMP ON DATABASE app TO relaycast_owner;" --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
"${K[@]}" create configmap postgres-ca-bundle --from-file=ca.crt="$WORK/ca.crt" --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
"${K[@]}" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: { name: postgres }
spec:
  replicas: 1
  selector: { matchLabels: { app: postgres } }
  template:
    metadata: { labels: { app: postgres } }
    spec:
      containers:
        - name: postgres
          image: postgres:16
          command: [bash, -c]
          args:
            - >-
              install -o postgres -m 0600 /tls/server.key /tmp/server.key &&
              install -o postgres -m 0644 /tls/server.crt /tmp/server.crt &&
              install -o postgres -m 0600 /tls/super.pw /tmp/super.pw &&
              install -m 0644 /tls/init.sql /docker-entrypoint-initdb.d/init.sql &&
              exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/tmp/server.crt -c ssl_key_file=/tmp/server.key
          env:
            - { name: POSTGRES_DB, value: app }
            - { name: POSTGRES_PASSWORD_FILE, value: /tmp/super.pw }
          ports: [{ containerPort: 5432 }]
          readinessProbe: { exec: { command: [pg_isready, -U, postgres, -d, app] }, periodSeconds: 3 }
          volumeMounts: [{ name: tls, mountPath: /tls, readOnly: true }]
      volumes: [{ name: tls, secret: { secretName: pg-tls } }]
---
apiVersion: v1
kind: Service
metadata: { name: postgres }
spec: { selector: { app: postgres }, ports: [{ port: 5432 }] }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: minio }
spec:
  replicas: 1
  selector: { matchLabels: { app: minio } }
  template:
    metadata: { labels: { app: minio } }
    spec:
      containers:
        - name: minio
          image: $MINIO_IMAGE
          env:
            - { name: MINIO_ROOT_USER, value: relaycast-proof }
            - { name: MINIO_ROOT_PASSWORD, valueFrom: { secretKeyRef: { name: relaycast-minio, key: AWS_SECRET_ACCESS_KEY } } }
            - { name: MINIO_DEFAULT_BUCKETS, value: relaycast }
          ports: [{ containerPort: 9000 }]
          readinessProbe: { httpGet: { path: /minio/health/ready, port: 9000 }, periodSeconds: 3 }
---
apiVersion: v1
kind: Service
metadata: { name: minio }
spec: { selector: { app: minio }, ports: [{ port: 9000 }] }
EOF
"${K[@]}" create secret generic relaycast-minio --from-literal=AWS_ACCESS_KEY_ID=relaycast-proof \
  --from-file=AWS_SECRET_ACCESS_KEY="$WORK/minio.pw" --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
url() { printf 'postgres://relaycast_%s:%s@%s:5432/app?sslmode=verify-full' "$1" "$(cat "$WORK/$1.pw")" "$PG"; }
"${K[@]}" create secret generic relaycast-secrets \
  --from-file=internal-secret="$WORK/internal.pw" --from-file=workspace-bootstrap-secret="$WORK/bootstrap.pw" \
  --from-file=credential-keyring="$WORK/keyring" --from-file=file-signing-secret="$WORK/filesig.pw" \
  --from-file=durable-actors-dev-secret="$WORK/devsecret.pw" \
  --from-literal=database-owner-url="$(url owner)" --from-literal=database-runtime-url="$(url runtime)" \
  --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
cp "$WORK/internal.pw" "$WORK/internal-secret"
"${K[@]}" rollout status deploy/postgres --timeout 5m >/dev/null
"${K[@]}" rollout status deploy/minio --timeout 5m >/dev/null

common="fullnameOverride: relaycast
baseUrl: http://relaycast.$NS.svc:8787
allowInsecureBaseUrl: true
existingSecret: relaycast-secrets
secretKeys:
  credentialKeyring: credential-keyring
  workspaceBootstrapSecret: workspace-bootstrap-secret
credentials:
  format: ar
  authority: self"
cat > "$WORK/values-pg.yaml" <<EOF
$common
runtime:
  backend: postgres
  postgres:
    image: { repository: $REG/relaycast-self-host, digest: "$SELFHOST_DIGEST" }
postgresCa: { enabled: true, configMap: postgres-ca-bundle, key: ca.crt }
EOF
cat > "$WORK/values-actors.yaml" <<EOF
$common
postgresCa: { enabled: false, configMap: "", secret: "" }
persistence: { retainForMigration: true }
runtime:
  backend: durable-actors
  durableActors:
    gateway:
      image: { repository: $REG/relaycast-actors-gateway, digest: "$GATEWAY_DIGEST" }
    fileStore:
      driver: s3
      bucket: relaycast
      s3: { endpoint: http://minio:9000, forcePathStyle: true, existingSecret: relaycast-minio }
    devRuntime:
      enabled: true
      acknowledgeNonProduction: true
      image: { repository: $REG/relaycast-actors-dev, digest: "$DEV_DIGEST" }
EOF

forward() { # (re)start a port-forward to the Relaycast Service
  [ -n "${PF:-}" ] && kill "$PF" 2>/dev/null || true
  "${K[@]}" port-forward svc/relaycast "$PORT:8787" >/dev/null 2>&1 & PF=$!
  for _ in $(seq 60); do
    kill -0 "$PF" 2>/dev/null || { echo "port-forward on $PORT exited (port busy?)"; return 1; }
    curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && return 0; sleep 1
  done
  echo "Relaycast did not answer on the port-forward"; return 1
}
trap '[ -n "${PF:-}" ] && kill "$PF" 2>/dev/null || true' EXIT
seedjs() { node ci/agent-relay/kind/relaycast-pg-to-actors.mjs "$1" "http://127.0.0.1:$PORT" "$WORK" "${@:2}"; }
step() { # step [values file]: render one migration Job, run it, print its log
  local step=$1 values=$2 job
  helm template relaycast charts/relaycast -n "$NS" -f "$values" --show-only templates/migration-job.yaml \
    --set migration.enabled=true --set migration.step="$step" --set migration.runId="$RUN" "${@:3}" > "$WORK/job-$step.yaml"
  job=$(yq -r '.metadata.name' "$WORK/job-$step.yaml")
  "${K[@]}" delete job "$job" --ignore-not-found >/dev/null
  "${K[@]}" apply -f "$WORK/job-$step.yaml" >/dev/null
  if ! "${K[@]}" wait --for=condition=complete "job/$job" --timeout=20m >/dev/null 2>&1; then
    echo "Job $job failed:"; "${K[@]}" logs "job/$job" --tail=80; return 1
  fi
  "${K[@]}" logs "job/$job" --tail=-1 | tee "$WORK/job-$step.log" | grep -v '^{' | sed 's/^/   /' | tail -25
}

log "install Relaycast on PostgreSQL (verify-full TLS)"
date -u +%s > "$WORK/ar-since"   # credentials phase: everything below is ar_ from birth
"${H[@]}" upgrade --install relaycast charts/relaycast -f "$WORK/values-pg.yaml" --wait --timeout 10m >/dev/null
PG_REV=$("${H[@]}" history relaycast -o json | jq -r 'last.revision')
forward
log "seed (low channel rate: relaycast#651)"
seedjs seed
seedjs snapshot before

log "preflight (read-only)"
step preflight "$WORK/values-pg.yaml" --set migration.arSince="$(cat "$WORK/ar-since")"
grep '^{' "$WORK/job-preflight.log" | jq -c '{workspace_id, messages: .counts.messages, files: .counts.files, missing_files, legacy_principals}'

log "quiesce and export from one snapshot"
kill "$PF" 2>/dev/null || true; PF=
"${K[@]}" scale deploy/relaycast --replicas=0 >/dev/null
"${K[@]}" wait --for=delete pod -l app.kubernetes.io/name=relaycast --timeout=5m >/dev/null 2>&1 || true
step export "$WORK/values-pg.yaml"

log "cutover: helm upgrade onto durable-actors"
"${H[@]}" upgrade relaycast charts/relaycast -f "$WORK/values-actors.yaml" --wait --timeout 10m >/dev/null
"${K[@]}" get pvc relaycast-data -o name   # the data claim survived the upgrade

log "copy files, then import every workspace"
step files "$WORK/values-actors.yaml"
step import "$WORK/values-actors.yaml"
step verify "$WORK/values-actors.yaml"
step open "$WORK/values-actors.yaml"

log "verify: every read identical, messaging works with the old credentials"
forward
seedjs snapshot after
seedjs compare before after
seedjs write
seedjs realtime

log "rollback drill: helm rollback to the PostgreSQL revision $PG_REV"
kill "$PF" 2>/dev/null || true; PF=
"${H[@]}" rollback relaycast "$PG_REV" --wait --timeout 10m >/dev/null
"${K[@]}" scale deploy/relaycast --replicas=1 >/dev/null
"${K[@]}" rollout status deploy/relaycast --timeout 5m >/dev/null
forward
seedjs snapshot rollback
seedjs compare before rollback

log "PROOF PASSED (run $RUN, work dir $WORK)"
