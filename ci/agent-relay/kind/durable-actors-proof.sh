#!/usr/bin/env bash
# kind proof: Relaycast and Relayfile in runtime.backend=durable-actors, each
# with a `durable-actors dev` sidecar (upstream's Kubernetes provider needs GKE
# Sandbox + GCS, which kind cannot provide), MinIO for both object stores.
#
# Prerequisites: a kind cluster and these local images (tag `kind`):
#   relayfile-actors, relayfile-actors-workspace   relayfile repo:
#     docker build -f docker/actors.Dockerfile -t relayfile-actors:kind .
#     docker build -f docker/actors-workspace.Dockerfile -t relayfile-actors-workspace:kind .
#   relaycast-actors-gateway                         relaycast repo:
#     docker build -f docker/actors-gateway.Dockerfile -t relaycast-actors-gateway:kind .
#   relaycast-actors-dev                             relaycast repo, this directory's Dockerfile:
#     docker build -f <infra>/ci/agent-relay/kind/relaycast-actors-dev.Dockerfile -t relaycast-actors-dev:kind .
#
#   KIND_CLUSTER=aw-durable-actors MOUNT_BIN=/path/to/relayfile-mount \
#   RELAYFILE_E2E=/path/to/relayfile/packages/durable-actors/test/e2e/mount-e2e.sh \
#     bash ci/agent-relay/kind/durable-actors-proof.sh
#
# Secret values are generated here and never printed.
set -euo pipefail
cd "$(dirname "$0")/../../.."

CLUSTER=${KIND_CLUSTER:-aw-durable-actors}
CTX="kind-$CLUSTER"
NS=agent-relay
K=(kubectl --context "$CTX" -n "$NS")
MINIO_IMAGE=${MINIO_IMAGE:-bitnamilegacy/minio:2025.4.22}
WORK=${WORK_DIR:-$(mktemp -d)}
mkdir -p "$WORK"
log() { printf '\n=== %s\n' "$*"; }

log "load images into kind/$CLUSTER"
# MinIO is pulled by the kind node itself (kind load of a multi-arch pull fails on missing platform layers).
for image in relayfile-actors:kind relayfile-actors-workspace:kind relaycast-actors-gateway:kind relaycast-actors-dev:kind; do
  kind load docker-image --name "$CLUSTER" "$image" >/dev/null
done

log "namespace, MinIO, secrets"
kubectl --context "$CTX" create namespace "$NS" --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
rand() { openssl rand -hex "${1:-24}"; }
# Reuse a value already in the cluster so re-runs match what running pods loaded.
existing() { "${K[@]}" get secret "$1" -o "jsonpath={.data.$2}" 2>/dev/null | base64 -d 2>/dev/null || true; }
keep() { local v; v=$(existing "$1" "$2"); [ -n "$v" ] && printf '%s' "$v" || rand "${3:-24}"; }
MINIO_USER=relayfile-proof
MINIO_PASS=$(keep minio-root password)
"${K[@]}" create secret generic minio-root --from-literal=user="$MINIO_USER" --from-literal=password="$MINIO_PASS" \
  --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
"${K[@]}" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: { name: minio, labels: { app: minio } }
spec:
  replicas: 1
  selector: { matchLabels: { app: minio } }
  template:
    metadata: { labels: { app: minio } }
    spec:
      containers:
        - name: minio
          image: $MINIO_IMAGE
          imagePullPolicy: IfNotPresent
          env:
            - { name: MINIO_ROOT_USER, valueFrom: { secretKeyRef: { name: minio-root, key: user } } }
            - { name: MINIO_ROOT_PASSWORD, valueFrom: { secretKeyRef: { name: minio-root, key: password } } }
            - { name: MINIO_DEFAULT_BUCKETS, value: "relaycast,relayfile" }
          ports: [{ containerPort: 9000 }]
          readinessProbe: { httpGet: { path: /minio/health/ready, port: 9000 }, periodSeconds: 3 }
---
apiVersion: v1
kind: Service
metadata: { name: minio }
spec:
  selector: { app: minio }
  ports: [{ port: 9000, targetPort: 9000 }]
EOF
for name in relaycast-minio relayfile-minio; do
  "${K[@]}" create secret generic "$name" --from-literal=AWS_ACCESS_KEY_ID="$MINIO_USER" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$MINIO_PASS" --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
done
RELAYCAST_INTERNAL=$(keep relaycast-secrets internal-secret 32)
"${K[@]}" create secret generic relaycast-secrets \
  --from-literal=internal-secret="$RELAYCAST_INTERNAL" \
  --from-literal=workspace-bootstrap-secret="$(keep relaycast-secrets workspace-bootstrap-secret)" \
  --from-literal=credential-keyring="$(v=$(existing relaycast-secrets credential-keyring); [ -n "$v" ] && printf '%s' "$v" || printf '{"current":"a","keys":{"a":"%s"}}' "$(rand)")" \
  --from-literal=file-signing-secret="$(keep relaycast-secrets file-signing-secret)" \
  --from-literal=durable-actors-dev-secret="$(keep relaycast-secrets durable-actors-dev-secret)" \
  --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
RELAYFILE_JWT=$(keep relayfile-actors RELAYFILE_JWT_SECRET 32)
"${K[@]}" create secret generic relayfile-actors \
  --from-literal=RELAYFILE_JWT_SECRET="$RELAYFILE_JWT" \
  --from-literal=DURABLE_ACTORS_SECRET="$(keep relayfile-actors DURABLE_ACTORS_SECRET)" \
  --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
# Restart so MinIO always runs with the credentials in minio-root.
"${K[@]}" rollout restart deploy/minio >/dev/null
"${K[@]}" rollout status deploy/minio --timeout=180s

log "helm install (umbrella, kind values)"
# Helm does not recursively vendor file:// dependency children.
helm dependency build charts/sessions-pipeline >/dev/null
helm dependency build charts/agent-relay >/dev/null
helm --kube-context "$CTX" upgrade --install agent-relay charts/agent-relay -n "$NS" \
  -f ci/agent-relay/kind-durable-actors-values.yaml --wait --timeout 10m
"${K[@]}" get pods -o wide

PF_PIDS=()
cleanup() { for pid in "${PF_PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done; }
trap cleanup EXIT
"${K[@]}" port-forward svc/relayfile-server 28581:8080 >"$WORK/pf-relayfile.log" 2>&1 & PF_PIDS+=($!)
"${K[@]}" port-forward svc/relaycast 28587:8787 >"$WORK/pf-relaycast.log" 2>&1 & PF_PIDS+=($!)
# Poll both forwards instead of sleeping: fail if they never answer.
ready=
for _ in $(seq 60); do
  if curl -fsS http://127.0.0.1:28581/health >/dev/null 2>&1 && curl -fsS http://127.0.0.1:28587/healthz >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
[ -n "$ready" ] || { echo "FAIL port-forwards not ready after 60s"; cat "$WORK"/pf-*.log; exit 1; }

log "relayfile: health and Go relayfile-mount e2e through the chart"
curl -fsS http://127.0.0.1:28581/health; echo
curl -fsS http://127.0.0.1:28581/readyz; echo
TOKEN=$(node --input-type=module -e '
  import { createHmac } from "node:crypto";
  const b = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const h = b({ alg: "HS256", typ: "JWT" });
  const p = b({ wks: "ws_kind", sub: "kind-proof", aud: "relayfile", scopes: ["fs:read", "fs:write", "ops:read", "sync:read", "sync:trigger"], exp: Math.floor(Date.now() / 1e3) + 3600 });
  console.log(`${h}.${p}.${createHmac("sha256", process.argv[1]).update(`${h}.${p}`).digest("base64url")}`);
' "$RELAYFILE_JWT")
if [ -n "${MOUNT_BIN:-}" ] && [ -n "${RELAYFILE_E2E:-}" ]; then
  BASE_URL=http://127.0.0.1:28581 TOKEN="$TOKEN" WORKSPACE=ws_kind MOUNT_BIN="$MOUNT_BIN" WORK_DIR="$WORK/mount" bash "$RELAYFILE_E2E"
else
  echo "MOUNT_BIN/RELAYFILE_E2E unset: skipping the mount e2e"
fi
H=(-H "authorization: Bearer $TOKEN" -H "x-correlation-id: kind")
big=$(head -c 120000 /dev/urandom | base64 | tr -d '\n')
printf '{"content":"%s"}' "$big" >"$WORK/big.json"
curl -fsS -X PUT "${H[@]}" -H 'if-match: *' -H 'content-type: application/json' --data-binary @"$WORK/big.json" \
  "http://127.0.0.1:28581/v1/workspaces/ws_kind/fs/file?path=/kind/big.txt" >/dev/null
got=$(curl -fsS "${H[@]}" "http://127.0.0.1:28581/v1/workspaces/ws_kind/fs/file?path=/kind/big.txt" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).content))')
if [ "$got" = "$big" ]; then echo "PASS relayfile large file round trip through the chart"; else echo "FAIL large file"; exit 1; fi
# The 120 KB body is above blobStore.inlineMaxBytes, so its bytes must be a
# content-addressed object in the relayfile MinIO bucket, not actor SQLite.
blob_sha=$(printf '%s' "$big" | shasum -a 256 | cut -d' ' -f1)
objects=$("${K[@]}" exec deploy/minio -- sh -c "mc alias set m http://127.0.0.1:9000 \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" >/dev/null 2>&1 && mc ls -r m/relayfile") \
  || { echo "FAIL listing the relayfile MinIO bucket"; exit 1; }
if grep -q "$blob_sha" <<<"$objects"; then
  echo "PASS relayfile large file stored in MinIO (blobs/sha256/${blob_sha:0:2}/$blob_sha)"
else
  echo "FAIL relayfile large file (sha256 $blob_sha) not found in the relayfile MinIO bucket"; exit 1
fi

log "relaycast: health, internal workspace create, agent + message round trip"
curl -fsS http://127.0.0.1:28587/healthz; echo
curl -fsS http://127.0.0.1:28587/readyz; echo
WS=$(curl -fsS -X POST -H "authorization: Bearer $RELAYCAST_INTERNAL" -H 'content-type: application/json' \
  http://127.0.0.1:28587/internal/workspaces -d '{"name":"kind-proof"}')
API_KEY=$(node -e 'const j=JSON.parse(process.argv[1]); const d=j.data??j; process.stdout.write(d.api_key??d.apiKey??d.key??"")' "$WS")
[ -n "$API_KEY" ] && echo "PASS relaycast workspace created in a Workspace actor (ar_ key issued)" || { echo "FAIL relaycast workspace: $(node -e 'console.log(Object.keys(JSON.parse(process.argv[1])))' "$WS")"; exit 1; }
RC=(-H "authorization: Bearer $API_KEY" -H 'content-type: application/json')
if curl -fsS "${RC[@]}" http://127.0.0.1:28587/v1/workspace >/dev/null; then echo "PASS relaycast GET /v1/workspace"; else echo "FAIL relaycast GET /v1/workspace"; exit 1; fi
# Agent round trip through the Workspace actor: register two agents, one sends
# a channel message, the other reads it back.
B=http://127.0.0.1:28587 KEY="$API_KEY" node --input-type=module -e '
  const { B, KEY } = process.env;
  const j = async (method, path, tok, body) => {
    const r = await fetch(B + path, { method, headers: { "content-type": "application/json", authorization: "Bearer " + tok }, body: body ? JSON.stringify(body) : undefined });
    const text = await r.text();
    let d; try { d = JSON.parse(text); } catch { d = text; }
    return { s: r.status, d };
  };
  const fail = (m) => { console.log("FAIL " + m); process.exit(1); };
  const suffix = Date.now().toString(36);
  const alice = await j("POST", "/v1/agents", KEY, { name: "alice-" + suffix });
  const bob = await j("POST", "/v1/agents", KEY, { name: "bob-" + suffix });
  const at = alice.d?.data?.token, bt = bob.d?.data?.token;
  if (!at || !bt) fail(`agent registration (status ${alice.s}/${bob.s})`);
  console.log("PASS relaycast registered two agents");
  const marker = "kind-roundtrip-" + suffix;
  const sent = await j("POST", "/v1/channels/general/messages", at, { text: marker });
  if (sent.s !== 201) fail(`send (status ${sent.s})`);
  console.log("PASS relaycast agent sent a channel message");
  const read = await j("GET", "/v1/channels/general/messages?limit=50", bt);
  if (read.s !== 200 || !JSON.stringify(read.d).includes(marker)) fail(`receive (status ${read.s}): the other agent did not read the message`);
  console.log("PASS relaycast agent received the message (send/receive round trip)");
'
# Informational only: report a log read failure instead of aborting.
if dev_logs=$("${K[@]}" logs deploy/relaycast -c durable-actors-dev --tail=500 2>&1); then
  echo "relaycast actor invocations logged: $(grep -c "invoke" <<<"$dev_logs" || true)"
else
  echo "WARN could not read the relaycast durable-actors-dev logs: $dev_logs"
fi

echo
echo "KIND PROOF PASS"
