#!/usr/bin/env bash
#
# Installs Relaycast and Relayfile in durable-actors mode (S3 storage) on the
# EKS substrate made by eks-actors-sandbox.sh. Run each step under the lease:
#
#   pippen sandbox exec actors-proof -- scripts/selfhost/eks-actors-install.sh prereqs
#   pippen sandbox exec actors-proof -- scripts/selfhost/eks-actors-install.sh prepull <dockerconfigjson file>
#   pippen sandbox exec actors-proof -- scripts/selfhost/eks-actors-install.sh install
#   pippen sandbox exec actors-proof -- scripts/selfhost/eks-actors-install.sh actor-env
#   pippen sandbox exec actors-proof -- scripts/selfhost/eks-actors-install.sh status
#   pippen sandbox exec actors-proof -- scripts/selfhost/eks-actors-install.sh uninstall
#
# prereqs: the namespace, a single-replica Postgres for the durable-actors
#   control plane (emptyDir: proof only, it survives control-plane restarts but
#   not a Postgres pod restart), and every Secret with freshly generated values
#   (written to a mode-0700 temp dir, loaded with --from-file and removed;
#   nothing is printed). Re-running keeps existing Secrets, and reuses the
#   existing Postgres password so actors-credentials always matches actors-pg.
#   Postgres traffic is plaintext (sslmode=disable): accepted for this proof
#   only, because the database never leaves the release namespace. A real
#   install uses a managed Postgres (RDS) with sslmode=require or verify-full.
#   The namespace is created with label agent-relay.dev/eks-actors-proof=owned
#   when it does not exist yet; `uninstall` deletes a namespace only when it
#   carries that label, and otherwise removes just this proof's objects.
# prepull: while the images are only in a private registry, a DaemonSet that
#   pulls every image onto every node (it tolerates the actor-host taint) with
#   a short-lived pull Secret, so pods start with IfNotPresent and never need
#   the Secret. The DaemonSet and the pull Secret are deleted as soon as every
#   node has the images, so no registry credential stays in the cluster.
# install: helm upgrade --install of charts/agent-relay (CHART_DIR) with
#   values-eks-actors.yaml and the proof values file (VALUES).
# Pod Identity associations come first: eks-actors-sandbox.sh assoc.
#
# Actor storage credentials default to per-actor STS (assume-role): the control
# plane assumes eks-actors-sandbox.sh's actor-storage role
# (role/pippen/workload/<EKS_ACTORS_ROLE_PREFIX or name>-storage, or
# EKS_ACTORS_ACTOR_ROLE_ARN) with a session policy narrowed to one actor. The
# Pippen boundary allows sts:AssumeRole + sts:TagSession between
# /pippen/workload/ roles of the same account (pippen-tools #46).
# EKS_ACTORS_ACTOR_CREDENTIALS=control-plane is the fallback for an account
# without that permission (actor hosts share the control plane's S3
# credentials, prefix isolation only; first-party actors only).

set -euo pipefail

: "${PIPPEN_SANDBOX_ACCOUNT_ID:?run under pippen sandbox exec}"
REGION="${AWS_REGION:-us-west-2}"
NAME="${EKS_ACTORS_NAME:-pippen-sbx-actors-proof}"
NS="${EKS_ACTORS_NAMESPACE:-agent-relay}"
RELEASE="${EKS_ACTORS_RELEASE:-agent-relay}"
CHART_DIR="${EKS_ACTORS_CHART_DIR:?path to charts/agent-relay}"
VALUES="${EKS_ACTORS_VALUES:-}"
# postgres:16.10-bookworm, pinned by index digest so a restart runs the same image.
PG_IMAGE="${EKS_ACTORS_PG_IMAGE:-postgres:16.10-bookworm@sha256:38471f330eb885e04de130b768d6db4e10469e2311879c7e5c699f6d2d8a1c74}"
[[ "$PG_IMAGE" == *@sha256:* ]] || { echo "EKS_ACTORS_PG_IMAGE must be pinned by digest (…@sha256:…)" >&2; exit 2; }
OWNER_LABEL="agent-relay.dev/eks-actors-proof"
ACTOR_CREDENTIALS="${EKS_ACTORS_ACTOR_CREDENTIALS:-assume-role}"
HELM_SET=(--set "durable-actors.storage.s3.actorCredentials=${ACTOR_CREDENTIALS}")
case "$ACTOR_CREDENTIALS" in
  assume-role)
    # Precedence: EKS_ACTORS_ACTOR_ROLE_ARN, then a real actorRoleArn from the
    # values files, then the storage role eks-actors-sandbox.sh creates.
    # (values-eks-actors.yaml only carries an <...> placeholder.) The values
    # lookup is best-effort: a render that fails here (e.g. an empty ARN) only
    # means none is configured; the real render reports chart errors.
    if [[ -n "${EKS_ACTORS_ACTOR_ROLE_ARN:-}" ]]; then
      HELM_SET+=(--set "durable-actors.storage.s3.actorRoleArn=${EKS_ACTORS_ACTOR_ROLE_ARN}")
    else
      configured_role_arn="$(helm template "$RELEASE" "$CHART_DIR" -n "$NS" -f "$CHART_DIR/values-eks-actors.yaml" ${VALUES:+-f "$VALUES"} \
        --set durable-actors.storage.s3.actorCredentials=assume-role 2>/dev/null \
        | grep -oE 'name: DURABLE_ACTORS_S3_ACTOR_ROLE_ARN, value: "[^"]*"' | head -1 | sed -E 's/.*value: "([^"]*)"/\1/' || true)"
      if [[ -z "$configured_role_arn" || "$configured_role_arn" == *"<"* ]]; then
        HELM_SET+=(--set "durable-actors.storage.s3.actorRoleArn=arn:aws:iam::${PIPPEN_SANDBOX_ACCOUNT_ID}:role/pippen/workload/${EKS_ACTORS_ROLE_PREFIX:-$NAME}-storage")
      fi
    fi ;;
  control-plane) HELM_SET+=(--set "durable-actors.storage.s3.actorRoleArn=") ;;
  *) echo "EKS_ACTORS_ACTOR_CREDENTIALS must be assume-role or control-plane" >&2; exit 2 ;;
esac

render() {
  helm template "$RELEASE" "$CHART_DIR" -n "$NS" -f "$CHART_DIR/values-eks-actors.yaml" ${VALUES:+-f "$VALUES"} "${HELM_SET[@]}"
}
# The actor sandbox namespace exactly as the chart computes it
# (durable-actors.sandboxNamespace, or <ns>-<release> shortened to 63 characters).
sandbox_ns() {
  local ns
  ns="$(render | grep -oE 'name: DURABLE_ACTORS_GKE_NAMESPACE, value: "[^"]+"' | head -1 | sed -E 's/.*value: "([^"]+)"/\1/')"
  [[ -n "$ns" ]] || { echo "could not derive the sandbox namespace from the chart render" >&2; exit 1; }
  printf '%s' "$ns"
}

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }

KUBECONFIG_FILE="$(mktemp)"
trap 'rm -f "$KUBECONFIG_FILE"' EXIT
aws --region "$REGION" eks update-kubeconfig --name "$NAME" --kubeconfig "$KUBECONFIG_FILE" >/dev/null
export KUBECONFIG="$KUBECONFIG_FILE"

# owned <kind> <name>: the object carries OWNER_LABEL=owned (this script made it).
owned() {
  [[ "$(kubectl -n "$NS" get "$1" "$2" -o jsonpath="{.metadata.labels['agent-relay\.dev/eks-actors-proof']}" 2>/dev/null)" == owned ]]
}

ensure_secret() {
  local ns="$1" name="$2"; shift 2
  if kubectl -n "$ns" get secret "$name" >/dev/null 2>&1; then log "secret $ns/$name exists (kept, not owned)"; return; fi
  kubectl -n "$ns" create secret generic "$name" "$@" >/dev/null
  # Marks it as this script's, so uninstall removes only what the script made.
  kubectl -n "$ns" label secret "$name" "${OWNER_LABEL}=owned" >/dev/null
  log "secret $ns/$name created"
}

cmd_prereqs() {
  if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
    kubectl create namespace "$NS" >/dev/null
    kubectl label namespace "$NS" "${OWNER_LABEL}=owned" >/dev/null
    log "namespace $NS created (owned by this proof)"
  fi
  local dir; dir="$(mktemp -d)"; chmod 700 "$dir"
  # shellcheck disable=SC2064
  trap "rm -rf '$dir' '$KUBECONFIG_FILE'" EXIT
  # Values must have no trailing newline: the control plane rejects surrounding whitespace.
  rnd() { openssl rand -hex "$1" | tr -d '\n'; }
  ( umask 077
    # Reuse the live password on a rerun, so a partial earlier run cannot leave
    # actors-credentials pointing at a password actors-pg does not have.
    if kubectl -n "$NS" get secret actors-pg >/dev/null 2>&1; then
      kubectl -n "$NS" get secret actors-pg -o jsonpath='{.data.password}' | base64 -d > "$dir/pg-password"
    else
      rnd 24 > "$dir/pg-password"
    fi
    printf 'postgresql://actors:%s@actors-pg.%s.svc:5432/actors?sslmode=disable' "$(cat "$dir/pg-password")" "$NS" > "$dir/postgres-url"
    openssl genpkey -algorithm ED25519 -outform DER | openssl base64 -A | tr -d '\n' > "$dir/jwt-signing-key"
    rnd 32 > "$dir/api-key"
    rnd 32 > "$dir/invoke-api-key"
    rnd 32 > "$dir/internal-secret"
    rnd 32 > "$dir/workspace-bootstrap-secret"
    rnd 32 > "$dir/file-signing-secret"
    printf '{"current":"a","keys":{"a":"%s"}}' "$(rnd 32)" > "$dir/credential-keyring"
    rnd 32 > "$dir/RELAYFILE_JWT_SECRET"
    rnd 32 > "$dir/RELAYFILE_ACTORS_BROKER_TOKEN"
  )
  ensure_secret "$NS" actors-pg --from-file=password="$dir/pg-password"
  ensure_secret "$NS" actors-credentials --from-file=postgres-url="$dir/postgres-url" \
    --from-file=jwt-signing-key="$dir/jwt-signing-key" --from-file=api-key="$dir/api-key" \
    --from-file=invoke-api-key="$dir/invoke-api-key"
  # The gateway's invocation key is the control plane's invoke-only key.
  if ! kubectl -n "$NS" get secret relaycast-durable-actors-invoke >/dev/null 2>&1; then
    kubectl -n "$NS" get secret actors-credentials -o jsonpath='{.data.invoke-api-key}' | base64 -d > "$dir/invoke"
    ensure_secret "$NS" relaycast-durable-actors-invoke --from-file=durable-actors-invoke-key="$dir/invoke"
  fi
  ensure_secret "$NS" relaycast-secrets --from-file=internal-secret="$dir/internal-secret" \
    --from-file=workspace-bootstrap-secret="$dir/workspace-bootstrap-secret" \
    --from-file=credential-keyring="$dir/credential-keyring" \
    --from-file=file-signing-secret="$dir/file-signing-secret"
  ensure_secret "$NS" relayfile-actors --from-file=RELAYFILE_JWT_SECRET="$dir/RELAYFILE_JWT_SECRET" \
    --from-file=RELAYFILE_ACTORS_BROKER_TOKEN="$dir/RELAYFILE_ACTORS_BROKER_TOKEN"
  rm -rf "$dir"
  # Never adopt a same-named Postgres someone else runs: apply would label it
  # owned and uninstall would then delete it.
  local kind
  for kind in service statefulset; do
    if kubectl -n "$NS" get "$kind" actors-pg >/dev/null 2>&1 && ! owned "$kind" actors-pg; then
      echo "$NS $kind/actors-pg exists but was not created by this script: refusing to change it" >&2; exit 1
    fi
  done
  kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata: {name: actors-pg, labels: {${OWNER_LABEL}: owned}}
spec:
  selector: {app: actors-pg}
  ports: [{port: 5432, targetPort: 5432}]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: actors-pg, labels: {${OWNER_LABEL}: owned}}
spec:
  serviceName: actors-pg
  replicas: 1
  selector: {matchLabels: {app: actors-pg}}
  template:
    metadata: {labels: {app: actors-pg}}
    spec:
      securityContext: {runAsUser: 999, runAsGroup: 999, fsGroup: 999, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: postgres
          image: ${PG_IMAGE}
          env:
            - {name: POSTGRES_USER, value: actors}
            - {name: POSTGRES_DB, value: actors}
            - {name: PGDATA, value: /var/lib/postgresql/data/pgdata}
            - name: POSTGRES_PASSWORD
              valueFrom: {secretKeyRef: {name: actors-pg, key: password}}
          ports: [{containerPort: 5432}]
          readinessProbe: {exec: {command: [pg_isready, -U, actors, -d, actors]}, periodSeconds: 5}
          resources: {requests: {cpu: 100m, memory: 256Mi}, limits: {memory: 512Mi}}
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
          volumeMounts: [{name: data, mountPath: /var/lib/postgresql/data}, {name: run, mountPath: /var/run/postgresql}]
      volumes: [{name: data, emptyDir: {}}, {name: run, emptyDir: {}}]
EOF
  # The control plane's NetworkPolicy allows egress to Postgres only where it
  # is told to; this proof keeps Postgres in the release namespace.
  kubectl -n "$NS" rollout status statefulset/actors-pg --timeout=300s >/dev/null
  log "postgres ready"
}

cmd_prepull() {
  local config="${1:?dockerconfigjson file}" kind
  for kind in secret/image-pull daemonset/image-prepull; do
    if kubectl -n "$NS" get "$kind" >/dev/null 2>&1 && ! owned "${kind%%/*}" "${kind#*/}"; then
      echo "$NS $kind exists but was not created by this script: refusing to change it" >&2; exit 1
    fi
  done
  # The pull credential must not outlive this command, whether it succeeds or not.
  # shellcheck disable=SC2064
  trap "kubectl -n '$NS' delete daemonset/image-prepull secret/image-pull --ignore-not-found >/dev/null 2>&1; rm -f '$KUBECONFIG_FILE'" EXIT
  kubectl -n "$NS" create secret generic image-pull --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson="$config" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$NS" label secret image-pull "${OWNER_LABEL}=owned" --overwrite >/dev/null
  local images; images="$(render \
    | grep -oE '(image|value): "?[a-z0-9.-]+\.[a-z]+/[^" ]+@sha256:[0-9a-f]{64}' \
    | sed -E 's/^(image|value): "?//' | sort -u)"
  local init="" i=0
  for image in $images; do
    init+="        - {name: pull-$i, image: \"$image\", command: [sh, -c, 'exit 0'], resources: {requests: {cpu: 10m, memory: 16Mi}}}"$'\n'
    i=$((i + 1))
  done
  kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: image-prepull, labels: {${OWNER_LABEL}: owned}}
spec:
  selector: {matchLabels: {app: image-prepull}}
  template:
    metadata: {labels: {app: image-prepull}}
    spec:
      imagePullSecrets: [{name: image-pull}]
      automountServiceAccountToken: false
      tolerations: [{key: durable-actors/actor-host, operator: Exists, effect: NoSchedule}]
      initContainers:
${init}      containers:
        - {name: pause, image: "registry.k8s.io/pause:3.10", resources: {requests: {cpu: 1m, memory: 8Mi}}}
EOF
  kubectl -n "$NS" rollout status daemonset/image-prepull --timeout=900s >/dev/null
  log "pre-pulled $i images onto every node"
  # The images are cached on the nodes (pods use IfNotPresent): drop the
  # registry credential now instead of keeping it until uninstall.
  kubectl -n "$NS" delete daemonset/image-prepull --wait=true >/dev/null
  kubectl -n "$NS" delete secret/image-pull --ignore-not-found >/dev/null
  log "prepull DaemonSet and pull Secret deleted"
}

cmd_install() {
  helm upgrade --install "$RELEASE" "$CHART_DIR" -n "$NS" \
    -f "$CHART_DIR/values-eks-actors.yaml" ${VALUES:+-f "$VALUES"} "${HELM_SET[@]}" --wait=false >/dev/null
  log "helm release $RELEASE installed"
}

# The Workspace actor's env Secret lives in the sandbox namespace, which the
# durable-actors chart creates (and deletes on uninstall), so it follows install.
# durable-actors only hands a Secret to actor code when it carries
# terse.ai/customer-secret=true ("secret is not marked for customer code").
# Only a Secret this script made (OWNER_LABEL=owned) is ever marked for actor
# code; a pre-existing one is refused, so nothing foreign reaches the actors.
cmd_actor_env() {
  local SANDBOX_NS; SANDBOX_NS="$(sandbox_ns)"
  if kubectl -n "$SANDBOX_NS" get secret relaycast-actor-env >/dev/null 2>&1; then
    if [[ "$(kubectl -n "$SANDBOX_NS" get secret relaycast-actor-env -o jsonpath="{.metadata.labels['agent-relay\.dev/eks-actors-proof']}")" != owned ]]; then
      echo "$SANDBOX_NS/relaycast-actor-env exists but was not created by this script: delete it or label it ${OWNER_LABEL}=owned after checking its keys" >&2
      exit 1
    fi
    kubectl -n "$SANDBOX_NS" label secret relaycast-actor-env terse.ai/customer-secret=true --overwrite >/dev/null
    log "relaycast-actor-env exists (owned; labelled terse.ai/customer-secret=true)"; return
  fi
  local dir; dir="$(mktemp -d)"; chmod 700 "$dir"
  ( umask 077
    # The Workspace actor reads uploaded files back through this origin, so it
    # must be reachable from actor pods (their NetworkPolicy allows public egress).
    printf '%s' "${RELAYCAST_PUBLIC_URL:?set RELAYCAST_PUBLIC_URL to the public Relaycast URL}" > "$dir/RELAYCAST_PUBLIC_URL"
    kubectl -n "$NS" get secret relaycast-secrets -o jsonpath='{.data.file-signing-secret}' | base64 -d > "$dir/RELAYCAST_FILE_SIGNING_SECRET"
    kubectl -n "$NS" get secret relaycast-secrets -o jsonpath='{.data.internal-secret}' | base64 -d > "$dir/RELAYCAST_INTERNAL_SECRET"
  )
  ensure_secret "$SANDBOX_NS" relaycast-actor-env --from-file=RELAYCAST_PUBLIC_URL="$dir/RELAYCAST_PUBLIC_URL" \
    --from-file=RELAYCAST_FILE_SIGNING_SECRET="$dir/RELAYCAST_FILE_SIGNING_SECRET" \
    --from-file=RELAYCAST_INTERNAL_SECRET="$dir/RELAYCAST_INTERNAL_SECRET"
  rm -rf "$dir"
  kubectl -n "$SANDBOX_NS" label secret relaycast-actor-env terse.ai/customer-secret=true "${OWNER_LABEL}=owned" --overwrite >/dev/null
}

cmd_status() {
  local SANDBOX_NS; SANDBOX_NS="$(sandbox_ns)"
  kubectl -n "$NS" get pods -o wide
  kubectl -n "$SANDBOX_NS" get pods -o wide 2>/dev/null || true
  helm -n "$NS" status "$RELEASE" 2>/dev/null | head -8 || true
}

cmd_uninstall() {
  local SANDBOX_NS; SANDBOX_NS="$(sandbox_ns)"
  helm -n "$NS" uninstall "$RELEASE" --wait 2>/dev/null || true
  # The release's own sandbox namespace (the durable-actors chart names it <ns>-<release>).
  kubectl delete namespace "$SANDBOX_NS" --wait=true --ignore-not-found >/dev/null
  if [[ "$(kubectl get namespace "$NS" -o jsonpath="{.metadata.labels['agent-relay\.dev/eks-actors-proof']}" 2>/dev/null)" == owned ]]; then
    kubectl delete namespace "$NS" --wait=true --ignore-not-found >/dev/null
    log "release, sandbox namespace and owned namespace $NS deleted"
    return
  fi
  # A namespace this script did not create: remove only objects it labelled as
  # its own (Secrets it created, Postgres); pre-existing Secrets stay.
  kubectl -n "$NS" delete statefulset,service,daemonset,secret -l "${OWNER_LABEL}=owned" --ignore-not-found --wait=true >/dev/null
  log "release, sandbox namespace and this proof's objects in $NS deleted (namespace kept: not created by this script)"
}

case "${1:-}" in
  prereqs) cmd_prereqs ;;
  prepull) shift; cmd_prepull "$@" ;;
  install) cmd_install ;;
  actor-env) cmd_actor_env ;;
  status) cmd_status ;;
  uninstall) cmd_uninstall ;;
  *) echo "usage: $0 prereqs|prepull <dockerconfigjson>|install|actor-env|status|uninstall" >&2; exit 2 ;;
esac
