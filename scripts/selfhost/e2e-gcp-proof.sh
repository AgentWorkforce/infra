#!/usr/bin/env bash
#
# End-to-end proof of a self-hosted Agent Relay suite on GKE (the gcp-proof
# layout): Relaycast messaging, control-plane bootstrap and device auth,
# native History durable delivery (the ingest edge), dashboard reads and the
# Sessions read API, the sessions API, workspace isolation, restart
# durability, token verification at Control, the ingest edge, the read API and
# Relaycast, erasure, the public HTTPS edge, workspace admin (env vars,
# /internal edge denial), Relayflows on a registered worker, and the dashboard
# SPA.
#
# History is always the native Sessions path (relay-control
# RELAYHISTORY_BACKEND=native): the read API and the ingest edge on one
# history.<domain> origin, with no RelayAuth and no standalone RelayHistory.
#
# The control plane holds exactly one organization. Every run reuses it and
# adds two fresh, uniquely named test workspaces (A and B), each backed by its
# own Relaycast workspace and a device token bound to that workspace. Nothing
# here prints a secret: credentials are read into a mode-0700 temp directory
# that is removed on exit, passed to helpers on stdin, and never echoed.
# Output is line-oriented:
#
#   PROOF|PASS|<check>|<non-secret detail>
#   CASE|<n>|PASS|FAIL|SKIP|<name>
#   E2E_RESULT=PASS|FAIL
#
# Mutations: creates test workspaces/agents/sessions/flows/env vars in the
# installation organization, adds and removes one outsider membership, runs a
# short-lived worker Pod (plus a Secret holding its single-use enrollment
# token) in the agent-relay namespace, and (unless --skip-restart) runs
# `kubectl rollout restart` on the read API, the ingest edge and relaycast. It never changes
# Helm releases, NetworkPolicies, release Secrets or the ingress. Cleanup (case
# 15, on by default) deletes the Relaycast workspaces, revokes the device
# tokens, removes the flow, worker, Pod and Secret, and deletes the two
# e2e-<marker>-a/b workspaces. A control plane older than relay-control 0.5.0
# has no workspace delete API, so they remain there (reported as SKIP).
#
# The public edge defaults to the GKE layout (--edge gke: hosts <base>,
# api.<base>, cast.<base>, history.<base> behind a ManagedCertificate). On
# EKS (--edge alb, used by e2e-eks-proof.sh) the origins are given
# explicitly, may be plain http (an ALB hostname with no custom domain), and
# readiness is the dashboard origin answering instead of the certificate.

set -uo pipefail

PROGRAM="${0##*/}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DRIVER="$HERE/e2e-gcp-proof-driver.mjs"

CONTEXT=""
NAMESPACE="agent-relay"
SECRET_NAME=""
BASE_DOMAIN=""
SKIP_RESTART=false
SKIP_PUBLIC=false
REQUIRE_PUBLIC=false
CERT_WAIT=0
CLEANUP=true
RELAYCAST_SECRET_KEY=""
RELAYCAST_MODE=unknown
RELAYCAST_CREATE_TIMEOUT=180
SKIP_FLOWS=false
EDGE_WAIT=900
WORKER_WAIT=600
WORKER_IMAGE="node:22.23.3-bookworm-slim"
AGENT_RELAY_VERSION="12.4.1"
WORKER_POD=""
WORKER_SECRET=""
VERIFY_PUBLIC="$HERE/../../.agents/skills/setting-up-self-hosted-agent-relay-gcp/scripts/verify-public.sh"
EDGE=gke
DASHBOARD_ORIGIN=""
API_ORIGIN=""
CAST_ORIGIN=""
HISTORY_ORIGIN=""
# pipeline (native History) is the only profile; the option is kept so older
# invocations that pass it still parse.
HISTORY_PROFILE="${E2E_HISTORY_PROFILE:-pipeline}"
READ_API_URL="${E2E_READ_API_URL:-http://agent-relay-read-api}"
INGEST_URL="${E2E_INGEST_URL:-http://agent-relay-ingest-edge}"
READ_API_DEPLOY="${E2E_READ_API_DEPLOY:-agent-relay-read-api}"
INGEST_DEPLOY="${E2E_INGEST_DEPLOY:-agent-relay-ingest-edge}"

usage() {
  cat <<'EOF'
Usage:
  e2e-gcp-proof.sh --context KUBE_CONTEXT [options]

Required:
      --context NAME          kubectl context of the proof cluster

Options:
  -n, --namespace NAME        agent-relay namespace (default: agent-relay)
      --secret NAME           release Secret holding the Relaycast internal secret
                              (required; e.g. the release's existingSecret)
      --base-domain DOMAIN    public base domain (default: derived from the
                              relay-control SELFHOST_PUBLIC_URL)
      --edge gke|alb          public edge layout (default gke). alb: origins from
                              the --*-origin options, http allowed, readiness =
                              the dashboard origin answering (no ManagedCertificate)
      --dashboard-origin URL  public dashboard origin (default https://<base-domain>)
      --api-origin URL        public api origin (default https://api.<base-domain>)
      --cast-origin URL       public Relaycast origin (default https://cast.<base-domain>)
      --history-origin URL    public History origin: the read API and ingest edge
                              (default https://history.<base-domain>)
      --read-api-url URL      in-cluster read API URL for the driver
                              (default http://agent-relay-read-api)
      --ingest-url URL        in-cluster ingest edge URL for the driver
                              (default http://agent-relay-ingest-edge)
      --skip-restart          do not restart the read API/ingest edge/relaycast
                              (case 6 SKIP)
      --skip-public           skip the public HTTPS checks (case 10 SKIP)
      --require-public        fail (not skip) case 10 when the cert is not Active
      --cert-wait SECONDS     wait up to this long for the ManagedCertificate
      --skip-flows            skip the Relayflows worker case (case 13 SKIP)
      --edge-wait SECONDS     how long to poll for the api-host /internal edge
                              denial (default 900)
      --worker-wait SECONDS   how long to wait for the worker Pod to register
                              (default 600)
      --worker-image IMAGE    worker Pod image (default node:22.23.3-bookworm-slim)
      --agent-relay-version V agent-relay CLI the worker runs (default 12.4.1)
      --relaycast-secret-key K  key in --secret for Relaycast's /internal API
                              (default: detected; relaycast-actors-internal-secret
                              for the durable-actors gateway, relaycast-internal-secret
                              for the SQLite server)
      --relaycast-create-timeout SECONDS
                              per-workspace Relaycast create timeout (default 180;
                              the actor-mode create can take ~100s)
      --no-cleanup            keep the Relaycast workspaces and device tokens
                              (case 15 SKIP); --cleanup is the default
  -h, --help                  show this help

Compatibility (accepted, no effect): --history-profile pipeline (native History
is the only profile; any other value is refused), --relayauth-url URL,
--sessions-namespace/--bulls-namespace NAME, --skip-sessions-pipeline/
--skip-96bulls and --pipeline-timeout SEC. Case 8 (the RelayAuth courier path
into the Sessions Pipeline) is always SKIP: native History has no RelayAuth;
uploads are proven in cases 3 and 4 through the ingest edge.

Exit status: 0 when every case passes or is skipped, 1 on any failure,
2 on invalid usage.
EOF
}

die_usage() {
  printf '%s: %s\n' "$PROGRAM" "$1" >&2
  exit 2
}

# need_value <option> <argc>: a value-taking option must have a following
# argument; without this check `shift 2` fails, leaves $# unchanged and the
# loop never ends.
need_value() {
  (($2 >= 2)) || die_usage "$1 requires a value"
}

while (($#)); do
  case "$1" in
    --history-profile|--read-api-url|--ingest-url|--context|-n|--namespace|--sessions-namespace|--bulls-namespace|--secret|--base-domain|--edge|--dashboard-origin|--api-origin|--cast-origin|--history-origin|--relayauth-url|--cert-wait|--pipeline-timeout|--edge-wait|--worker-wait|--worker-image|--agent-relay-version|--relaycast-secret-key|--relaycast-create-timeout)
      need_value "$1" "$#" ;;
  esac
  case "$1" in
    --context) CONTEXT="$2"; shift 2 ;;
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    --secret) SECRET_NAME="$2"; shift 2 ;;
    --base-domain) BASE_DOMAIN="$2"; shift 2 ;;
    --edge) EDGE="$2"; shift 2 ;;
    --dashboard-origin) DASHBOARD_ORIGIN="${2%/}"; shift 2 ;;
    --api-origin) API_ORIGIN="${2%/}"; shift 2 ;;
    --cast-origin) CAST_ORIGIN="${2%/}"; shift 2 ;;
    --history-origin) HISTORY_ORIGIN="${2%/}"; shift 2 ;;
    --history-profile) HISTORY_PROFILE="$2"; shift 2 ;;
    --read-api-url) READ_API_URL="${2%/}"; shift 2 ;;
    --ingest-url) INGEST_URL="${2%/}"; shift 2 ;;
    --skip-restart) SKIP_RESTART=true; shift ;;
    --skip-public) SKIP_PUBLIC=true; shift ;;
    --require-public) REQUIRE_PUBLIC=true; shift ;;
    --cert-wait) CERT_WAIT="$2"; shift 2 ;;
    --cleanup) CLEANUP=true; shift ;;
    --no-cleanup) CLEANUP=false; shift ;;
    --relaycast-secret-key) RELAYCAST_SECRET_KEY="$2"; shift 2 ;;
    --relaycast-create-timeout) RELAYCAST_CREATE_TIMEOUT="$2"; shift 2 ;;
    # Compatibility no-ops from the removed legacy History profile.
    --relayauth-url|--sessions-namespace|--bulls-namespace|--pipeline-timeout) shift 2 ;;
    --skip-sessions-pipeline|--skip-96bulls) shift ;;
    --skip-flows) SKIP_FLOWS=true; shift ;;
    --edge-wait) EDGE_WAIT="$2"; shift 2 ;;
    --worker-wait) WORKER_WAIT="$2"; shift 2 ;;
    --worker-image) WORKER_IMAGE="$2"; shift 2 ;;
    --agent-relay-version) AGENT_RELAY_VERSION="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown option: $1" ;;
  esac
done

[[ -n "$CONTEXT" ]] || die_usage "--context is required"
[[ "$EDGE" == gke || "$EDGE" == alb ]] || die_usage "--edge must be gke or alb"
for origin in "$DASHBOARD_ORIGIN" "$API_ORIGIN" "$CAST_ORIGIN" "$HISTORY_ORIGIN"; do
  # https only: authenticated checks send bearer tokens to these origins.
  [[ -z "$origin" || "$origin" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || die_usage "origins must be https://host[:port] with no path"
done
[[ "$HISTORY_PROFILE" == pipeline ]] ||
  die_usage "--history-profile: only pipeline (native History) is supported; the legacy standalone RelayHistory profile was removed"
if [[ "$EDGE" == alb ]]; then
  [[ -n "$DASHBOARD_ORIGIN" && -n "$API_ORIGIN" && -n "$CAST_ORIGIN" && -n "$HISTORY_ORIGIN" ]] ||
    die_usage "--edge alb needs --dashboard-origin, --api-origin, --cast-origin and --history-origin"
fi
[[ -n "$NAMESPACE" && -n "$SECRET_NAME" ]] || die_usage "namespace and secret options must not be empty"
[[ "$CERT_WAIT" =~ ^[0-9]+$ ]] || die_usage "--cert-wait must be a non-negative integer"
[[ "$RELAYCAST_CREATE_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die_usage "--relaycast-create-timeout must be a positive integer"
[[ -z "$RELAYCAST_SECRET_KEY" || "$RELAYCAST_SECRET_KEY" =~ ^[A-Za-z0-9._-]+$ ]] || die_usage "--relaycast-secret-key is not a valid Secret key"
[[ "$EDGE_WAIT" =~ ^[0-9]+$ ]] || die_usage "--edge-wait must be a non-negative integer"
[[ "$WORKER_WAIT" =~ ^[1-9][0-9]*$ ]] || die_usage "--worker-wait must be a positive integer"
[[ "$AGENT_RELAY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die_usage "--agent-relay-version must be an exact x.y.z version"
[[ -n "$WORKER_IMAGE" ]] || die_usage "--worker-image must not be empty"
[[ -f "$DRIVER" ]] || die_usage "missing helper: $DRIVER"
for tool in kubectl python3 curl node; do
  command -v "$tool" >/dev/null 2>&1 || die_usage "missing tool: $tool"
done

K=(kubectl --context "$CONTEXT")
KN=("${K[@]}" -n "$NAMESPACE")

WORK="$(mktemp -d "${TMPDIR:-/tmp}/e2e-gcp-proof.XXXXXX")"
chmod 700 "$WORK"
umask 077
STATE="$WORK/state.json"
RCS="$WORK/relaycast-internal-secret"
: >"$STATE"

API_POD=""

remove_worker() {
  if [[ -n "$WORKER_POD" ]]; then
    "${KN[@]}" delete pod "$WORKER_POD" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
  fi
  if [[ -n "$WORKER_SECRET" ]]; then
    "${KN[@]}" delete secret "$WORKER_SECRET" --ignore-not-found >/dev/null 2>&1 || true
  fi
}

# On an interrupted or aborted run, finish the control-plane cleanup case 15
# would have done (the driver's cleanup phase is idempotent).
CLEANUP_RAN=false
cleanup_exit() {
  remove_worker
  if $CLEANUP && ! $CLEANUP_RAN && [[ -s "$STATE" ]] &&
    [[ -n "$(state_get a.relaycastWorkspaceId 2>/dev/null)$(state_get b.relaycastWorkspaceId 2>/dev/null)" ]]; then
    CLEANUP_RAN=true
    printf '\n== interrupted: cleanup (%s)\n' "$(date -u +%FT%TZ)"
    run_phase cleanup
  fi
  if [[ -n "$API_POD" ]]; then
    "${KN[@]}" exec "$API_POD" -- rm -f /tmp/e2e-gcp-proof-driver.mjs >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------- reporting

FAILS=0
CASE_LINES=()
CASE_FAILS=0
CASE_SKIPPED=""

emit() { # result check detail
  local detail="${3//$'\n'/ }"
  detail="${detail//|//}"
  printf 'PROOF|%s|%s|%s\n' "$1" "$2" "$detail"
  [[ "$1" == FAIL ]] && CASE_FAILS=$((CASE_FAILS + 1))
  return 0
}

case_begin() { CASE_FAILS=0; CASE_SKIPPED=""; printf '\n== case %s: %s (%s)\n' "$1" "$2" "$(date -u +%FT%TZ)"; }
case_skip() { CASE_SKIPPED="$1"; emit SKIP "case" "$1"; }
case_end() { # number name
  local result=PASS
  if ((CASE_FAILS > 0)); then
    result=FAIL
    FAILS=$((FAILS + 1))
  elif [[ -n "$CASE_SKIPPED" ]]; then
    result=SKIP
  fi
  CASE_LINES+=("CASE|$1|$result|$2")
}

# ---------------------------------------------------------------- helpers

ts() { date -u +%FT%TZ; }

find_pod() { # namespace selector
  "${K[@]}" -n "$1" get pods -l "$2" --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Override a custom fullname with E2E_CONTROL_DEPLOYMENT. The worker Service
# defaults to this observed name; E2E_CONTROL_SERVICE can select a retained alias.
find_control_deployment() {
  local candidate name
  for candidate in "${E2E_CONTROL_DEPLOYMENT:-relay-control}" relay-cloud-api; do
    name="$("${KN[@]}" get deploy "$candidate" -o jsonpath='{.metadata.name}' 2>/dev/null || true)"
    if [[ -n "$name" ]]; then printf '%s' "$name"; return 0; fi
  done
  return 1
}

control_worker_preflight() {
  [[ -n "$CONTROL_SERVICE" && ${#CONTROL_SERVICE} -le 63 && "$CONTROL_SERVICE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || return 1
  "${KN[@]}" get svc "$CONTROL_SERVICE" -o name >/dev/null 2>&1
}

install_driver() {
  API_POD="$(find_pod "$NAMESPACE" 'app.kubernetes.io/name=relay-control,app.kubernetes.io/component=api')"
  if [[ -z "$API_POD" ]]; then
    API_POD="$(find_pod "$NAMESPACE" 'app.kubernetes.io/name=relay-cloud-api,app.kubernetes.io/component=api')"
  fi
  [[ -n "$API_POD" ]] || return 1
  "${KN[@]}" exec -i "$API_POD" -- sh -c 'umask 077; cat > /tmp/e2e-gcp-proof-driver.mjs' <"$DRIVER"
}

# phase_input: the state plus the secrets the driver may need, on stdout.
phase_input() {
  python3 - "$STATE" "$RCS" "$WORK/enrollment-token" "$RELAYCAST_MODE" "$RELAYCAST_CREATE_TIMEOUT" "$CLEANUP" "$BASE_DOMAIN" <<'PY'
import json, sys
text = open(sys.argv[1]).read().strip()
state = json.loads(text) if text else {}
def read(path):
    try:
        return open(path).read()
    except FileNotFoundError:
        return ""
state["secrets"] = {"relaycastInternalSecret": read(sys.argv[2]), "enrollmentToken": read(sys.argv[3])}
state["relaycast"] = {"mode": sys.argv[4], "createTimeoutMs": int(sys.argv[5]) * 1000}
state["cleanup"] = sys.argv[6] == "true"
# Test users get addresses under the install's own public domain.
state["emailDomain"] = sys.argv[7]
sys.stdout.write(json.dumps(state))
PY
}

# consume_phase_output <phase> <out file> <rc>: stores the new state and emits
# only the driver's curated proof records.
consume_phase_output() {
  local phase="$1" out="$2" exec_rc="$3" parsed
  parsed="$(python3 - "$out" "$STATE" <<'PY'
import json, sys
try:
    result = json.load(open(sys.argv[1]))
    state, proofs = result["state"], result["proofs"]
    assert isinstance(state, dict) and isinstance(proofs, list)
except Exception:
    print("FAIL\tdriver.output\tunparseable driver output")
    raise SystemExit(0)
json.dump(state, open(sys.argv[2], "w"))
if not proofs:
    print("FAIL\tdriver.output\tdriver returned no proof records")
for p in proofs:
    print(f'{p["result"]}\t{p["check"]}\t{p["detail"]}')
PY
)"
  rm -f "$out"
  local result check detail
  while IFS=$'\t' read -r result check detail; do
    [[ -n "$result" ]] && emit "$result" "$check" "$detail"
  done <<<"$parsed"
  # The driver always exits 0 after writing its result, so a non-zero status
  # means the exec or the node process itself failed.
  if ((exec_rc != 0)); then
    emit FAIL "$phase.exec" "exit rc=$exec_rc"
  fi
}

# run_phase <phase>: runs the driver in the relay-control pod.
run_phase() {
  local phase="$1" out="$WORK/out.json"
  if ! install_driver; then
    emit FAIL "$phase.driver" "relay-control pod unavailable"
    return 1
  fi
  phase_input | "${KN[@]}" exec -i "$API_POD" -- env "E2E_READ_API_URL=$READ_API_URL" "E2E_INGEST_URL=$INGEST_URL" \
    node /tmp/e2e-gcp-proof-driver.mjs "$phase" >"$out" 2>/dev/null
  consume_phase_output "$phase" "$out" $?
}

# run_public_phase <phase>: runs the driver here, against the public dashboard
# origin, so the calls cross the GCE edge exactly as the SPA's do.
run_public_phase() {
  local phase="$1" out="$WORK/out.json"
  phase_input | E2E_API_URL="$DASHBOARD_ORIGIN" E2E_READ_API_URL="$READ_API_URL" E2E_INGEST_URL="$INGEST_URL" node "$DRIVER" "$phase" >"$out" 2>/dev/null
  consume_phase_output "$phase" "$out" $?
}

state_get() { # dotted.path -> value (non-secret fields only)
  python3 - "$STATE" "$1" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
for part in sys.argv[2].split("."):
    value = value.get(part) if isinstance(value, dict) else None
print("" if value is None else value)
PY
}

state_pop_to_file() { # key file : moves a secret value out of the state
  python3 - "$STATE" "$1" "$2" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
value = state.pop(sys.argv[2], "") or ""
json.dump(state, open(sys.argv[1], "w"))
open(sys.argv[3], "w").write(value)
PY
}

restart_and_wait() { # deployment
  local started
  started="$(ts)"
  if ! "${KN[@]}" rollout restart "deploy/$1" >/dev/null 2>&1; then
    emit FAIL "durability.restart_$1" "rollout restart failed"
    return 1
  fi
  if ! "${KN[@]}" rollout status "deploy/$1" --timeout=300s >/dev/null 2>&1; then
    emit FAIL "durability.restart_$1" "rollout did not become ready within 300s"
    return 1
  fi
  local pod
  pod="$("${KN[@]}" get pods -l "app.kubernetes.io/name=$1" --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null)"
  emit PASS "durability.restart_$1" "restarted_at=$started ready_at=$(ts) pods=${pod% }"
}

# ---------------------------------------------------------------- preflight

printf 'E2E_CONTEXT=%s\nE2E_NAMESPACE=%s\nE2E_STARTED=%s\n' "$CONTEXT" "$NAMESPACE" "$(ts)"
if ! "${K[@]}" get namespace "$NAMESPACE" >/dev/null 2>&1; then
  printf 'E2E_RESULT=FAIL\nreason: cannot reach namespace %s with context %s\n' "$NAMESPACE" "$CONTEXT"
  exit 1
fi
CONTROL_DEPLOYMENT="$(find_control_deployment || true)"
CONTROL_SERVICE="${E2E_CONTROL_SERVICE:-$CONTROL_DEPLOYMENT}"
if [[ -z "$BASE_DOMAIN" && -n "$CONTROL_DEPLOYMENT" ]]; then
  api_url="$("${KN[@]}" get deploy "$CONTROL_DEPLOYMENT" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SELFHOST_PUBLIC_URL")].value}' 2>/dev/null)"
  host="${api_url#https://}"
  BASE_DOMAIN="${host#api.}"
fi
if [[ -z "$BASE_DOMAIN" && "$EDGE" == alb ]]; then
  BASE_DOMAIN="${DASHBOARD_ORIGIN#*://}"
fi
printf 'E2E_BASE_DOMAIN=%s\n' "$BASE_DOMAIN"
: "${DASHBOARD_ORIGIN:=https://$BASE_DOMAIN}"
: "${API_ORIGIN:=https://api.$BASE_DOMAIN}"
: "${CAST_ORIGIN:=https://cast.$BASE_DOMAIN}"
: "${HISTORY_ORIGIN:=https://history.$BASE_DOMAIN}"
# curl --proto for public requests: https only.
PUBLIC_PROTO='=https'
printf 'E2E_EDGE=%s\nE2E_ORIGINS=dashboard=%s api=%s cast=%s history=%s\n' "$EDGE" \
  "$DASHBOARD_ORIGIN" "$API_ORIGIN" "$CAST_ORIGIN" "$HISTORY_ORIGIN"
# Relaycast runs either as the SQLite server or as the durable-actors gateway
# (same Service, same /internal/workspaces contract, different secret, and an
# actor-mode create that can take ~100s). The mode is read from the relaycast
# Deployment; the secret key is the one that Deployment mounts as its
# internal secret, falling back to the mode's default.
relaycast_json="$("${KN[@]}" get deploy relaycast -o json 2>/dev/null)"
read -r RELAYCAST_MODE mounted_key < <(python3 -c '
import json, sys
try:
    spec = json.loads(sys.stdin.read())["spec"]["template"]["spec"]
except Exception:
    print("unknown -"); raise SystemExit(0)
container = spec["containers"][0]
env = {e["name"]: e for e in container.get("env", [])}
mode = "actors" if "DURABLE_ACTORS_CONTROL_PLANE_URL" in env else "sqlite"
key = "-"
ref = env.get("RELAYCAST_INTERNAL_SECRET", {}).get("valueFrom", {}).get("secretKeyRef")
if ref:
    key = ref["key"]
else:
    target = env.get("RELAYCAST_INTERNAL_SECRET_FILE", {}).get("value", "")
    for volume in spec.get("volumes", []):
        for item in (volume.get("secret") or {}).get("items", []):
            for mount in container.get("volumeMounts", []):
                if mount["name"] == volume["name"] and target == mount["mountPath"].rstrip("/") + "/" + item["path"]:
                    key = item["key"]
print(mode, key)
' <<<"$relaycast_json")
if [[ -z "$RELAYCAST_SECRET_KEY" ]]; then
  if [[ "$mounted_key" != "-" ]]; then
    RELAYCAST_SECRET_KEY="$mounted_key"
  elif [[ "$RELAYCAST_MODE" == actors ]]; then
    RELAYCAST_SECRET_KEY=relaycast-actors-internal-secret
  else
    RELAYCAST_SECRET_KEY=relaycast-internal-secret
  fi
fi
printf 'E2E_RELAYCAST_MODE=%s\nE2E_RELAYCAST_SECRET_KEY=%s\n' "$RELAYCAST_MODE" "$RELAYCAST_SECRET_KEY"
"${KN[@]}" get secret "$SECRET_NAME" -o json 2>/dev/null |
  python3 -c 'import base64, json, sys; data = json.load(sys.stdin).get("data", {}); sys.stdout.write(base64.b64decode(data.get(sys.argv[1], "")).decode())' "$RELAYCAST_SECRET_KEY" >"$RCS" 2>/dev/null
[[ -s "$RCS" ]] || { printf 'E2E_RESULT=FAIL\nreason: %s not readable from Secret %s\n' "$RELAYCAST_SECRET_KEY" "$SECRET_NAME"; exit 1; }

# ---------------------------------------------------------------- public edge readiness

# Decided once, before any public request (case 11 runs before case 10), and
# shared by every case that crosses the public edge (10, 11, 12, 14).
cert_status() {
  if [[ "$EDGE" == alb ]]; then
    # No certificate on a plain ALB origin: ready once the dashboard answers.
    [[ "$(curl --disable -s -o /dev/null --max-time 10 -w '%{http_code}' "$DASHBOARD_ORIGIN/" 2>/dev/null)" == 200 ]] &&
      printf 'Active '
    return 0
  fi
  "${KN[@]}" get managedcertificate -o jsonpath='{range .items[*]}{.status.certificateStatus}{"\n"}{end}' 2>/dev/null |
    sort -u | tr '\n' ' '
}
PUBLIC_READY=false
PUBLIC_STATUS="--skip-public"
PUBLIC_WAITED=0
if ! $SKIP_PUBLIC; then
  status="$(cert_status)"
  while [[ "$status" != "Active " ]] && ((PUBLIC_WAITED < CERT_WAIT)); do
    step=$((CERT_WAIT - PUBLIC_WAITED))
    ((step > 30)) && step=30
    sleep "$step"
    PUBLIC_WAITED=$((PUBLIC_WAITED + step))
    status="$(cert_status)"
  done
  if [[ "$status" == "Active " ]]; then
    PUBLIC_READY=true
    PUBLIC_STATUS="status=Active"
  else
    domains="$("${KN[@]}" get managedcertificate -o jsonpath='{range .items[*].status.domainStatus[*]}{.domain}={.status}{" "}{end}' 2>/dev/null)"
    PUBLIC_STATUS="status=${status% } domains=${domains% } waited=${PUBLIC_WAITED}s"
  fi
fi
printf 'E2E_PUBLIC_READY=%s\n' "$PUBLIC_READY"

# public_gate <check prefix>: 0 when the case may use the public edge;
# otherwise records a FAIL (--require-public) or SKIPs the case.
public_gate() {
  # A certificate that turned Active since the preflight is picked up here.
  if ! $SKIP_PUBLIC && ! $PUBLIC_READY && [[ "$(cert_status)" == "Active " ]]; then
    PUBLIC_READY=true
    PUBLIC_STATUS="status=Active (became Active after the preflight)"
  fi
  if $SKIP_PUBLIC; then
    case_skip "--skip-public"
  elif $PUBLIC_READY; then
    return 0
  elif $REQUIRE_PUBLIC; then
    emit FAIL "$1.public_edge" "public edge not ready: $PUBLIC_STATUS"
  else
    case_skip "ManagedCertificate not Active"
  fi
  return 1
}

# has_capability <name>: the control plane serves that feature (detected in
# case 1 from /openapi.yaml and route probes).
has_capability() { [[ "$(state_get "capabilities.$1")" == True ]]; }

# ---------------------------------------------------------------- cases 1-5

case_begin 1 "bootstrap"
run_phase bootstrap
case_end 1 "bootstrap: single org reused, two workspaces, device auth, membership gate (not_member)"
printf 'E2E_MARKER=%s\n' "$(state_get marker)"
BOOTSTRAPPED=$([[ -n "$(state_get a.workspaceId)" && -n "$(state_get b.workspaceId)" ]] && echo true || echo false)

case_begin 2 "messaging"
if $BOOTSTRAPPED; then run_phase messaging; else emit FAIL messaging.blocked "no tenant"; fi
case_end 2 "messaging: register, roster, A->B, B->A reply in the same conversation, history"

case_begin 3 "session delivery"
if $BOOTSTRAPPED; then run_phase delivery; else emit FAIL delivery.blocked "no tenant"; fi
case_end 3 "session delivery: durable receipt, identical retry, one projection"
DELIVERED=$([[ -n "$(state_get session.receiptId)" ]] && echo true || echo false)

case_begin 4 "reads"
if $DELIVERED; then run_phase reads; else emit FAIL reads.blocked "no delivered session"; fi
case_end 4 "reads: dashboard list/replay/search and the read API direct"

# Case 11 runs here, before erasure (case 9) removes the session.
case_begin 11 "sessions API"
if ! $DELIVERED; then
  emit FAIL sessions.blocked "no delivered session"
elif ! has_capability sessions; then
  case_skip "control plane has no sessions API (activity/search/turns routes)"
elif public_gate sessions; then
  run_public_phase sessions
fi
case_end 11 "sessions API via the public /cloud/api: list, filters, transcript/turns, search, activity"

case_begin 5 "isolation"
if $DELIVERED; then run_phase isolation; else emit FAIL isolation.blocked "no delivered session"; fi
case_end 5 "isolation: B token gets 404 on A sessions/flows/env/settings, the read API/ingest edge and Relaycast"

# ---------------------------------------------------------------- case 6

case_begin 6 "durability"
if $SKIP_RESTART; then
  case_skip "--skip-restart"
elif ! $DELIVERED; then
  emit FAIL durability.blocked "no delivered session"
else
  restart_and_wait "$READ_API_DEPLOY" && restart_and_wait "$INGEST_DEPLOY" && run_phase durability-history
  restart_and_wait relaycast && run_phase durability-relaycast
fi
case_end 6 "durability: history backend and relaycast restarts"

# ---------------------------------------------------------------- case 7

case_begin 7 "auth"
# Native History's premise: no RelayAuth, no leftover standalone RelayHistory,
# Control not pointed at either.
still_present=""
for deployment in relayauth relayhistory; do
  "${KN[@]}" get deploy "$deployment" >/dev/null 2>&1 && still_present+="$deployment "
done
control_env="$("${KN[@]}" get deploy "${E2E_CONTROL_DEPLOYMENT:-relay-control}" -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' 2>/dev/null)"
[[ -n "$control_env" ]] || still_present+="control-env-unreadable "
for name in RELAYAUTH_URL RELAYHISTORY_URL; do
  [[ " $control_env " == *" $name "* ]] && still_present+="$name "
done
[[ " $control_env " == *" RELAYHISTORY_BACKEND "* ]] || still_present+="no-RELAYHISTORY_BACKEND "
if [[ -z "$still_present" ]]; then emit PASS auth.no_relayauth_or_history "no relayauth/relayhistory Deployments; Control has RELAYHISTORY_BACKEND and neither legacy URL"
else emit FAIL auth.no_relayauth_or_history "still present or wrong: ${still_present% }"; fi
if $BOOTSTRAPPED; then run_phase auth; else emit FAIL auth.blocked "no tenant"; fi
case_end 7 "auth: token verification at Control, the ingest edge, the read API and Relaycast"

# ---------------------------------------------------------------- case 8

case_begin 8 "Sessions Pipeline"
# The courier path needs a RelayAuth assertion, and native History runs no
# RelayAuth; uploads are proven in cases 3 and 4 through the ingest edge.
case_skip "native History: the courier path needs a RelayAuth assertion; uploads are proven in cases 3 and 4 through the ingest edge"
case_end 8 "Sessions Pipeline: courier push (not applicable to native History)"

# ---------------------------------------------------------------- case 9

case_begin 9 "erasure"
if $DELIVERED; then run_phase erasure; else emit FAIL erasure.blocked "no delivered session"; fi
case_end 9 "erasure: session removed from list, replay, search and turns"

# ---------------------------------------------------------------- case 10

case_begin 10 "public edge"
if ! $SKIP_PUBLIC && ! $PUBLIC_READY && [[ "$(cert_status)" == "Active " ]]; then
  PUBLIC_READY=true
fi
if $SKIP_PUBLIC; then
  case_skip "--skip-public"
elif ! $PUBLIC_READY; then
  if $REQUIRE_PUBLIC; then
    emit FAIL public.certificate "$PUBLIC_STATUS"
  else
    emit SKIP public.certificate "$PUBLIC_STATUS"
    case_skip "ManagedCertificate not Active"
  fi
else
  emit PASS public.certificate "status=Active waited=${PUBLIC_WAITED}s edge=$EDGE"
  if [[ "$EDGE" == alb ]]; then
    emit SKIP public.verify_public "GKE-only (ManagedCertificate, FrontendConfig, static IP)"
  elif [[ -x "$VERIFY_PUBLIC" || -f "$VERIFY_PUBLIC" ]]; then
    vp_out="$(BASE_DOMAIN="$BASE_DOMAIN" bash "$VERIFY_PUBLIC" 2>&1)"
    vp_rc=$?
    emit "$([[ $vp_rc -eq 0 ]] && echo PASS || echo FAIL)" public.verify_public \
      "rc=$vp_rc last=$(tail -n 1 <<<"$vp_out" | sed 's/^verify-public: //')"
    grep -E '^verify-public: ' <<<"$vp_out" | sed 's/^/  /'
  else
    emit FAIL public.verify_public "verify-public.sh not found"
  fi
  run_phase issue-public
  state_pop_to_file publicHistoryToken "$WORK/history-token"
  python3 - "$STATE" "$WORK" <<'PY'
import json, os, sys
state = json.load(open(sys.argv[1]))
work = sys.argv[2]
def header(name, token):
    with open(os.path.join(work, name), "w") as f:
        f.write(f"Authorization: Bearer {token}\n")
header("h-api", state["a"]["accessToken"])
header("h-api-b", state["b"]["accessToken"])
header("h-cast", state["a"]["relaycastKey"])
header("h-agent", state["agents"]["alpha"]["token"])
history = open(os.path.join(work, "history-token")).read()
header("h-history", history)
PY
  rm -f "$WORK/history-token"
  ws_a="$(state_get a.workspaceId)"
  pub() { # check expected header-file url
    local code
    code="$(curl --disable --silent --output /dev/null --max-time 20 --proto "$PUBLIC_PROTO" \
      --write-out '%{http_code}' ${3:+--header "@$WORK/$3"} "$4" 2>/dev/null)"
    if [[ "$code" == "$2" ]]; then emit PASS "$1" "status=$code"; else emit FAIL "$1" "status=$code expected=$2"; fi
  }
  pub public.api_whoami 200 h-api "$API_ORIGIN/api/v1/auth/whoami"
  pub public.api_resolve 200 h-api "$API_ORIGIN/api/v1/workspaces/$ws_a/resolve"
  pub public.dashboard_sessions 200 h-api "$DASHBOARD_ORIGIN/cloud/api/v1/workspaces/$ws_a/sessions"
  pub public.dashboard_cross_tenant 404 h-api-b "$DASHBOARD_ORIGIN/cloud/api/v1/workspaces/$ws_a/sessions"
  pub public.api_anonymous 401 "" "$API_ORIGIN/api/v1/auth/whoami"
  pub public.cast_roster 200 h-cast "$CAST_ORIGIN/v1/agents"
  pub public.cast_agent 200 h-agent "$CAST_ORIGIN/v1/agent"
  pub public.cast_anonymous 401 "" "$CAST_ORIGIN/v1/agents"
  code="$(curl --disable -s -o /dev/null --max-time 20 -w '%{http_code}' -X POST \
    -H 'content-type: application/json' --data '{"name":"e2e-edge-probe"}' "$CAST_ORIGIN/v1/workspaces")"
  # The chart routes this path to a selector-less Service, so the Google edge
  # answers 502 (no backend) and the request never reaches Relaycast.
  [[ "$code" == 502 || "$code" == 404 || "$code" == 403 ]] && emit PASS public.cast_workspace_create_denied "status=$code edge_denied=true" ||
    emit FAIL public.cast_workspace_create_denied "status=$code"
  code="$(curl --disable -s -o /dev/null --max-time 20 -w '%{http_code}' "$CAST_ORIGIN/internal/capabilities")"
  # The chart routes this path to a selector-less Service, so the Google edge
  # answers 502 (no backend) and the request never reaches Relaycast.
  [[ "$code" == 502 || "$code" == 404 || "$code" == 403 ]] && emit PASS public.cast_internal_denied "status=$code edge_denied=true" ||
    emit FAIL public.cast_internal_denied "status=$code"
  pub public.history_sessions 200 h-history "$HISTORY_ORIGIN/v1/sessions?workspace=$ws_a&limit=1"
  pub public.history_anonymous 401 "" "$HISTORY_ORIGIN/v1/delivery/limits"
  # The ingest edge answers on the history origin, and /internal stays private.
  edge_post() { curl --disable -s -o /dev/null --max-time 20 -w '%{http_code}' -X POST -H 'content-type: application/json' --data '{}' "$1"; }
  code="$(edge_post "$HISTORY_ORIGIN/v1/delivery/batches")"
  [[ "$code" == 401 ]] && emit PASS public.ingest_batch_anonymous "status=401" || emit FAIL public.ingest_batch_anonymous "status=$code expected=401"
  code="$(edge_post "$HISTORY_ORIGIN/v1/auth/token/refresh")"
  [[ "$code" == 401 ]] && emit PASS public.ingest_refresh_refused "status=401" || emit FAIL public.ingest_refresh_refused "status=$code expected=401"
  code="$(curl --disable -s -o /dev/null --max-time 20 -w '%{http_code}' "$HISTORY_ORIGIN/internal/v1/session-read/sessions")"
  # The chart routes this path to a selector-less Service, so the Google edge
  # answers 502 (no backend) and the request never reaches the read API.
  [[ "$code" == 502 || "$code" == 404 || "$code" == 403 ]] && emit PASS public.history_internal_denied "status=$code edge_denied=true" ||
    emit FAIL public.history_internal_denied "status=$code expected=404/403/502"
  rm -f "$WORK"/h-*
fi
case_end 10 "public: verify-public.sh and authenticated calls through the HTTPS edge"

# ---------------------------------------------------------------- case 12

case_begin 12 "admin"
if ! $BOOTSTRAPPED; then
  emit FAIL admin.blocked "no tenant"
elif ! has_capability admin; then
  case_skip "control plane has no workspace admin API (secrets routes)"
else
  # The in-cluster half does not need the public edge.
  run_phase admin-internal
fi
if $BOOTSTRAPPED && has_capability admin && public_gate admin; then
  run_public_phase admin
  # /internal/* is the runtime contract (env and integration tokens for
  # workers). On the public api host the edge must answer it itself (the
  # chart routes the prefix to a selector-less Service, so the Google edge
  # returns 502), never the API. Variants cover path normalization: the edge
  # resolves `..` with a redirect to the normalized path, which must again be
  # denied, so curl follows redirects here.
  ws_a="$(state_get a.workspaceId)"
  edge_paths=(
    "/internal"
    "/internal/v1/workspaces/$ws_a/environment"
    "/internal/v1/workspaces/$ws_a/integrations"
    "/internal/v1/telemetry/preview"
    "//internal/v1/workspaces/$ws_a/environment"
    "/api/../internal/v1/workspaces/$ws_a/environment"
    "/api/%2e%2e/internal/v1/telemetry/preview"
  )
  edge_denied() { # path -> prints status; returns 0 when the edge denied it
    local body code
    body="$(curl --disable --silent --path-as-is --location --max-redirs 3 --max-time 20 --proto "$PUBLIC_PROTO" \
      --write-out '\n%{http_code}' "$API_ORIGIN$1" 2>/dev/null)"
    code="${body##*$'\n'}"
    body="${body%$'\n'*}"
    printf '%s' "$code"
    # The API answers JSON ({"error": ...}); the edge answers an HTML error page.
    [[ "$code" =~ ^(502|404|403)$ ]] && ! grep -q '"error"' <<<"$body"
  }
  waited=0
  while :; do
    edge_detail=""
    edge_ok=true
    for path in "${edge_paths[@]}"; do
      code="$(edge_denied "$path")" || edge_ok=false
      edge_detail+="${path/$ws_a/A}=$code "
    done
    $edge_ok && break
    ((waited >= EDGE_WAIT)) && break
    sleep 30
    waited=$((waited + 30))
  done
  if $edge_ok; then
    emit PASS admin.internal_edge_denied "${edge_detail% } waited=${waited}s"
  else
    emit FAIL admin.internal_edge_denied "${edge_detail% } waited=${waited}s"
  fi
fi
case_end 12 "admin: env var set/list masked/no plaintext/delete, audit, /internal denied at the edge"

# ---------------------------------------------------------------- case 13

# The worker is a short-lived Pod in the agent-relay namespace (the
# relay-control NetworkPolicy admits any pod in the namespace) running the
# stock agent-relay CLI: `cloud worker register`, then `cloud worker start
# --once`, which exits after one assignment. The single-use enrollment token
# reaches it through a Secret volume, never through args in this script's
# output or the Pod spec.
worker_manifest() { # pod secret name
  cat <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $1
  labels:
    app.kubernetes.io/name: e2e-flows-worker
    app.kubernetes.io/part-of: e2e-gcp-proof
    e2e.agentrelay.com/marker: "$(state_get marker)"
spec:
  restartPolicy: Never
  activeDeadlineSeconds: $((WORKER_WAIT + 600))
  automountServiceAccountToken: false
  nodeSelector:
    kubernetes.io/arch: amd64
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: worker
      image: $WORKER_IMAGE
      command: ["/bin/sh", "-ec"]
      args:
        - |
          export HOME=/tmp/home NPM_CONFIG_CACHE=/tmp/npm-cache NPM_CONFIG_UPDATE_NOTIFIER=false
          export AGENT_RELAY_HOME=/tmp/relay AGENT_RELAY_TELEMETRY_DISABLED=1
          mkdir -p "\$HOME"
          echo "e2e-worker: installing agent-relay@\$AGENT_RELAY_VERSION"
          npx --yes "agent-relay@\$AGENT_RELAY_VERSION" cloud worker register \\
            --token "\$(cat /var/run/e2e-worker/token)" --name "\$WORKER_NAME" --base-url "\$BASE_URL"
          echo "e2e-worker: registered"
          exec npx --yes "agent-relay@\$AGENT_RELAY_VERSION" cloud worker start \\
            --name "\$WORKER_NAME" --base-url "\$BASE_URL" --once
      env:
        - { name: AGENT_RELAY_VERSION, value: "$AGENT_RELAY_VERSION" }
        - { name: WORKER_NAME, value: "$3" }
        - { name: BASE_URL, value: "http://${CONTROL_SERVICE}" }
      resources:
        requests: { cpu: 250m, memory: 768Mi }
        limits: { memory: 2Gi }
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: [ALL] }
      volumeMounts:
        - { name: tmp, mountPath: /tmp }
        - { name: token, mountPath: /var/run/e2e-worker, readOnly: true }
  volumes:
    - name: tmp
      emptyDir: {}
    - name: token
      secret:
        secretName: $2
        defaultMode: 0400
YAML
}

pod_phase() { "${KN[@]}" get pod "$WORKER_POD" -o jsonpath='{.status.phase}' 2>/dev/null; }

# Prints the worker log tail with anything token-shaped redacted.
worker_log_tail() {
  "${KN[@]}" logs "$WORKER_POD" --tail=25 2>/dev/null |
    sed -E 's/(sh_[a-z]+_)[A-Za-z0-9_-]+/\1[redacted]/g; s/(rk_live_)[A-Za-z0-9_-]+/\1[redacted]/g' | sed 's/^/  worker| /'
}

case_begin 13 "flows"
if $SKIP_FLOWS; then
  case_skip "--skip-flows"
elif ! $BOOTSTRAPPED; then
  emit FAIL flows.blocked "no tenant"
elif ! has_capability flows; then
  # Only a control plane with the worker protocol (relaycontrol flows API)
  # can run this; one that declares it but fails still fails the case.
  case_skip "control plane has no worker protocol (/api/v1/workers/enrollment-tokens absent)"
elif ! control_worker_preflight; then
  emit FAIL flows.worker_service "observed Control Service is missing or invalid; worker not started"
else
  marker="$(state_get marker)"
  WORKER_POD="e2e-flows-worker-$marker"
  WORKER_SECRET="e2e-flows-worker-$marker"
  run_phase flows-enroll
  state_pop_to_file enrollmentToken "$WORK/enrollment-token"
  worker_name="$(state_get flows.workerName)"
  if [[ ! -s "$WORK/enrollment-token" || -z "$worker_name" ]]; then
    emit FAIL flows.worker_pod "no enrollment token; worker not started"
  elif ! "${KN[@]}" create secret generic "$WORKER_SECRET" --from-file=token="$WORK/enrollment-token" >/dev/null 2>&1; then
    emit FAIL flows.worker_pod "could not create the worker token Secret"
  elif ! worker_manifest "$WORKER_POD" "$WORKER_SECRET" "$worker_name" | "${KN[@]}" apply -f - >/dev/null 2>&1; then
    emit FAIL flows.worker_pod "could not create the worker Pod"
  else
    started="$(ts)"
    waited=0
    registered=false
    while ((waited < WORKER_WAIT)); do
      if "${KN[@]}" logs "$WORKER_POD" 2>/dev/null | grep -q '^e2e-worker: registered$'; then
        registered=true
        break
      fi
      phase="$(pod_phase)"
      [[ "$phase" == Failed || "$phase" == Succeeded ]] && break
      sleep 5
      waited=$((waited + 5))
    done
    if ! $registered; then
      emit FAIL flows.worker_pod "worker did not register within ${waited}s (phase=$(pod_phase))"
      worker_log_tail
    else
      emit PASS flows.worker_pod "pod=$WORKER_POD image=$WORKER_IMAGE agent-relay=$AGENT_RELAY_VERSION base_url=http://$CONTROL_SERVICE started=$started registered_after=${waited}s"
      run_phase flows-run
      # `start --once` exits after the one assignment.
      waited=0
      while [[ "$(pod_phase)" == Running ]] && ((waited < 120)); do sleep 5; waited=$((waited + 5)); done
      phase="$(pod_phase)"
      if [[ "$phase" == Succeeded ]]; then
        emit PASS flows.worker_exit "phase=Succeeded once=true"
      else
        emit FAIL flows.worker_exit "phase=$phase"
        worker_log_tail
      fi
    fi
  fi
  rm -f "$WORK/enrollment-token"
  run_phase flows-cleanup
  remove_worker
  if [[ -z "$("${KN[@]}" get pod,secret -l app.kubernetes.io/part-of=e2e-gcp-proof -o name 2>/dev/null)" ]] &&
    ! "${KN[@]}" get pod "$WORKER_POD" >/dev/null 2>&1 && ! "${KN[@]}" get secret "$WORKER_SECRET" >/dev/null 2>&1; then
    emit PASS flows.worker_removed "pod=$WORKER_POD secret=$WORKER_SECRET deleted"
    WORKER_POD=""
    WORKER_SECRET=""
  else
    emit FAIL flows.worker_removed "worker Pod or Secret still present"
  fi
fi
case_end 13 "flows: enrollment token, in-namespace worker Pod, deterministic run completes, steps/logs readable, worker removed"

# ---------------------------------------------------------------- case 14

case_begin 14 "dashboard"
if public_gate dashboard; then
  fetch() { # url file -> prints status
    curl --disable --silent --max-time 20 --proto "$PUBLIC_PROTO" --output "$2" --write-out '%{http_code} %{content_type}' "$1" 2>/dev/null
  }
  index_meta="$(fetch "$DASHBOARD_ORIGIN/" "$WORK/index.html")"
  config_meta="$(fetch "$DASHBOARD_ORIGIN/runtime-config.js" "$WORK/runtime-config.js")"
  deep_meta="$(fetch "$DASHBOARD_ORIGIN/flows/runs/e2e-deep-link" "$WORK/deep.html")"
  bundle="$(sed -n 's/.*<script type="module"[^>]* src="\(\/assets\/index-[A-Za-z0-9_-]*\.js\)".*/\1/p' "$WORK/index.html" | head -n 1)"
  bundle_meta=""
  [[ -n "$bundle" ]] && bundle_meta="$(fetch "$DASHBOARD_ORIGIN$bundle" "$WORK/bundle.js")"
  dash_out="$(python3 - "$WORK" "$index_meta" "$config_meta" "$deep_meta" "$bundle" "$bundle_meta" <<'PY'
import json, os, re, sys
work, index_meta, config_meta, deep_meta, bundle, bundle_meta = sys.argv[1:7]
def read(name):
    try:
        return open(os.path.join(work, name), encoding="utf-8", errors="replace").read()
    except FileNotFoundError:
        return ""
def out(ok, check, detail):
    print(f"{'PASS' if ok else 'FAIL'}\t{check}\t{detail}")
index = read("index.html")
# The self-host build loads /runtime-config.js before the module bundle.
markers = {
    "runtime_config_script": '<script src="/runtime-config.js"></script>' in index,
    "root_div": '<div id="root"></div>' in index,
    "module_bundle": bool(bundle),
}
out(index_meta.startswith("200 text/html") and all(markers.values()), "dashboard.index",
    f"status={index_meta.split()[0] if index_meta else 'none'} " + " ".join(f"{k}={v}" for k, v in markers.items()))
# Deep links fall back to the SPA (history routing at base /).
deep = read("deep.html")
out(deep_meta.startswith("200 text/html") and bundle and bundle in deep, "dashboard.spa_fallback",
    f"status={deep_meta.split()[0] if deep_meta else 'none'} same_bundle={bool(bundle) and bundle in deep}")
config = read("runtime-config.js")
values = dict(re.findall(r'(\w+):\s*"([^"]*)"', config))
expected = {"appPath": "/", "apiBasePath": "/cloud/api", "loginPath": "/login"}
ok = config_meta.startswith("200") and "__AGENT_RELAY_DASHBOARD_CONFIG__" in config and all(values.get(k) == v for k, v in expected.items())
out(ok, "dashboard.runtime_config", " ".join(f"{k}={values.get(k)!r}" for k in ["appPath", "apiBasePath", "loginPath", "publicUrl"]))
# Strings only the new (integrated flows/admin/sessions) build carries.
js = read("bundle.js")
features = {
    "config_global": "__AGENT_RELAY_DASHBOARD_CONFIG__",
    "flows_routes": "#/flows",
    "runs_api": "/workflows/runs",
    "worker_enrollment": "enrollment-tokens",
    "admin_api_tokens": "deployment-api-tokens",
}
found = {name: needle in js for name, needle in features.items()}
out(bundle_meta.startswith("200") and all(found.values()), "dashboard.new_build",
    f"bundle={bundle} status={bundle_meta.split()[0] if bundle_meta else 'none'} " + " ".join(f"{k}={v}" for k, v in found.items()))
PY
)"
  [[ -n "$dash_out" ]] || emit FAIL dashboard.checks "no dashboard results"
  while IFS=$'\t' read -r result check detail; do
    [[ -n "$result" ]] && emit "$result" "$check" "$detail"
  done <<<"$dash_out"
  rm -f "$WORK/index.html" "$WORK/runtime-config.js" "$WORK/deep.html" "$WORK/bundle.js"
fi
case_end 14 "dashboard: new SPA at /, runtime-config appPath /, deep-link fallback"

# ---------------------------------------------------------------- cleanup

case_begin 15 "cleanup"
if $CLEANUP; then
  CLEANUP_RAN=true
  run_phase cleanup
else
  case_skip "--no-cleanup"
fi
case_end 15 "cleanup: Relaycast workspaces deleted, device tokens revoked, control-plane test workspaces deleted"

printf '\n== summary (%s)\n' "$(ts)"
printf 'E2E_MARKER=%s\n' "$(state_get marker)"
printf '%s\n' "${CASE_LINES[@]}" | sort -t'|' -k2,2n
if ((FAILS == 0)); then
  printf 'E2E_RESULT=PASS\n'
  exit 0
fi
printf 'E2E_RESULT=FAIL\n'
exit 1
