#!/usr/bin/env bash
# churn.sh start|result: runs harness/churn.mjs in pod rcb-churn on the loadgen node group.
#   RCB_ACTORS, RCB_SLOTS, RCB_MESSAGES, RCB_VISIT_S, RCB_DURATION_S pass through.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; BENCH="$(cd "$HERE/.." && pwd)"
NS="${NS:?NS}"; K=(kubectl -n "$NS")
RELAYCAST_URL="${RELAYCAST_URL:-http://relaycast.${NS}.svc.cluster.local:8787}"
INTERNAL_SECRET="${INTERNAL_SECRET:-agent-relay-secrets/relaycast-internal-secret}"
NODE_IMAGE="${NODE_IMAGE:-public.ecr.aws/docker/library/node:22-alpine}"
case "${1:?start|result}" in
  start)
    "${K[@]}" create configmap rcb-churn --dry-run=client -o yaml \
      --from-file="$BENCH/harness/lib.mjs" --from-file="$BENCH/harness/churn.mjs" | "${K[@]}" apply -f - >/dev/null
    "${K[@]}" delete pod rcb-churn --ignore-not-found >/dev/null
    "${K[@]}" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: rcb-churn, labels: {app: rcb-churn, purpose: relaycast-actors-bench}}
spec:
  nodeSelector: {bench/role: loadgen}
  tolerations: [{key: bench/loadgen, operator: Exists, effect: NoSchedule}]
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: churn
      image: ${NODE_IMAGE}
      command: [sh, -c, 'node --max-old-space-size=3072 /bench/churn.mjs; sleep infinity']
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
      env:
        - {name: RCB_BASE_URL, value: "${RELAYCAST_URL}"}
        - {name: RCB_INTERNAL_SECRET_FILE, value: /secrets/internal}
        - {name: RCB_RUN, value: "churn$(date +%H%M%S)"}
        - {name: RCB_ACTORS, value: "${RCB_ACTORS:-10000}"}
        - {name: RCB_SLOTS, value: "${RCB_SLOTS:-120}"}
        - {name: RCB_MESSAGES, value: "${RCB_MESSAGES:-3}"}
        - {name: RCB_VISIT_S, value: "${RCB_VISIT_S:-30}"}
        - {name: RCB_DURATION_S, value: "${RCB_DURATION_S:-7200}"}
        - {name: RCB_CONCURRENCY, value: "${RCB_CONCURRENCY:-64}"}
        - {name: RCB_OUT, value: /work/churn.json}
      resources: {requests: {cpu: "2", memory: 2Gi}, limits: {memory: 4Gi}}
      volumeMounts:
        - {name: harness, mountPath: /bench}
        - {name: internal, mountPath: /secrets, readOnly: true}
        - {name: work, mountPath: /work}
  volumes:
    - {name: harness, configMap: {name: rcb-churn}}
    - {name: internal, secret: {secretName: ${INTERNAL_SECRET%%/*}, items: [{key: ${INTERNAL_SECRET#*/}, path: internal}]}}
    - {name: work, emptyDir: {}}
YAML
    "${K[@]}" wait --for=condition=Ready pod/rcb-churn --timeout=5m >/dev/null; echo "rcb-churn started" ;;
  result)
    "${K[@]}" exec rcb-churn -- cat /work/churn.json ;;
esac
