#!/usr/bin/env bash
#
# Read-only smoke verification for an agent-relay Helm release.
# This script never requests Kubernetes Secret resources and never prints
# command output, response bodies, manifests, or certificate contents.

set -uo pipefail

PROGRAM="${0##*/}"
NAMESPACE=""
RELEASE=""
CONTEXT=""
SELECTOR=""
MIGRATION_SELECTOR=""
INGRESS_HOST=""
HEALTH_PATH="/health"
TIMEOUT_SECONDS=15
CERT_MIN_VALID_SECONDS=86400
ALLOW_MISSING_MIGRATIONS=false
ALLOW_MISSING_WORKLOADS=false
ALLOW_MISSING_INGRESS=false
ALLOW_NO_TLS=false
REQUIRE_NATIVE_HISTORY=false
HEALTH_URLS=()
EXTERNAL_TLS_HOSTS=()

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

usage() {
  cat <<'EOF'
Usage:
  verify-agent-relay.sh --namespace NAMESPACE --release RELEASE [options]

Required:
  -n, --namespace NAME             Kubernetes namespace
  -r, --release NAME               Helm release name

Selection:
      --context NAME               kubectl/Helm context
      --selector SELECTOR          Suite label selector
                                   (default: app.kubernetes.io/instance=RELEASE)
      --migration-selector SELECTOR
                                   Select all migration Jobs explicitly

Ingress and health:
      --ingress-host HOST          Verify only this ingress host (health URL,
                                   TLS host, and certificate references)
      --health-url URL             Health URL; repeat for multiple endpoints
      --health-path PATH           Derived ingress health path (default: /health)
      --external-tls-host HOST     LB-terminated TLS host; repeat as needed;
                                   must match a selected ingress rule host
      --timeout SECONDS            Per-network-check timeout (default: 15)
      --cert-min-valid SECONDS     Required remaining TLS validity (default: 86400)

Explicit exceptions:
      --allow-missing-migrations   Permit no discoverable migration Jobs
      --allow-missing-workloads    Permit no controller workloads
      --allow-missing-ingress      Permit no ingress and skip derived health/TLS
      --allow-no-tls               Permit ingress without TLS

Architecture:
      --require-native-history     Require read API, ingest edge and search
                                   indexer; reject RelayAuth, standalone
                                   RelayHistory and legacy Control URLs

Other:
  -h, --help                       Show this help

Output:
  PROOF|PASS|check|detail
  PROOF|FAIL|check|detail
  PROOF|SKIP|check|detail
  PROOF_RESULT=PASS|FAIL
  PROOF_COUNTS pass=N fail=N skip=N
EOF
}

proof() {
  local result="$1"
  local check="$2"
  local detail="$3"

  # Callers provide only curated, non-secret details. Normalize delimiters and
  # line breaks so every result remains one parseable record.
  detail="${detail//$'\n'/ }"
  detail="${detail//$'\r'/ }"
  detail="${detail//|//}"

  printf 'PROOF|%s|%s|%s\n' "$result" "$check" "$detail"
  case "$result" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
  esac
}

die_usage() {
  printf '%s: %s\n' "$PROGRAM" "$1" >&2
  printf 'Run %s --help for usage.\n' "$PROGRAM" >&2
  exit 2
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

validate_health_url() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlsplit

try:
    value = urlsplit(sys.argv[1])
except ValueError:
    raise SystemExit(1)

if value.scheme not in {"http", "https"}:
    raise SystemExit(1)
if not value.hostname or value.username is not None or value.password is not None:
    raise SystemExit(1)
if value.query or value.fragment:
    raise SystemExit(1)
try:
    value.port
except ValueError:
    raise SystemExit(1)
PY
}

while (($#)); do
  case "$1" in
    -n|--namespace)
      (($# >= 2)) || die_usage "$1 requires a value"
      NAMESPACE="$2"
      shift 2
      ;;
    -r|--release)
      (($# >= 2)) || die_usage "$1 requires a value"
      RELEASE="$2"
      shift 2
      ;;
    --context)
      (($# >= 2)) || die_usage "$1 requires a value"
      CONTEXT="$2"
      shift 2
      ;;
    --selector)
      (($# >= 2)) || die_usage "$1 requires a value"
      SELECTOR="$2"
      shift 2
      ;;
    --migration-selector)
      (($# >= 2)) || die_usage "$1 requires a value"
      MIGRATION_SELECTOR="$2"
      shift 2
      ;;
    --ingress-host)
      (($# >= 2)) || die_usage "$1 requires a value"
      INGRESS_HOST="$2"
      shift 2
      ;;
    --health-url)
      (($# >= 2)) || die_usage "$1 requires a value"
      HEALTH_URLS+=("$2")
      shift 2
      ;;
    --health-path)
      (($# >= 2)) || die_usage "$1 requires a value"
      HEALTH_PATH="$2"
      shift 2
      ;;
    --external-tls-host)
      (($# >= 2)) || die_usage "$1 requires a value"
      external_host="$(python3 - "$2" <<'PY'
import re, sys
value = sys.argv[1]
label = r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
if len(value) > 253 or not re.fullmatch(label + r"(?:\." + label + r")*", value):
    raise SystemExit(1)
print(value.lower())
PY
      )" || die_usage "--external-tls-host must be a DNS hostname without a port or URL"
      EXTERNAL_TLS_HOSTS+=("$external_host")
      shift 2
      ;;
    --timeout)
      (($# >= 2)) || die_usage "$1 requires a value"
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --cert-min-valid)
      (($# >= 2)) || die_usage "$1 requires a value"
      CERT_MIN_VALID_SECONDS="$2"
      shift 2
      ;;
    --allow-missing-migrations)
      ALLOW_MISSING_MIGRATIONS=true
      shift
      ;;
    --allow-missing-workloads)
      ALLOW_MISSING_WORKLOADS=true
      shift
      ;;
    --allow-missing-ingress)
      ALLOW_MISSING_INGRESS=true
      shift
      ;;
    --allow-no-tls)
      ALLOW_NO_TLS=true
      shift
      ;;
    --require-native-history)
      REQUIRE_NATIVE_HISTORY=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      (($# == 0)) || die_usage "positional arguments are not supported"
      ;;
    -*)
      die_usage "unknown option: $1"
      ;;
    *)
      die_usage "positional arguments are not supported: $1"
      ;;
  esac
done

[[ -n "$NAMESPACE" ]] || die_usage "--namespace is required"
[[ -n "$RELEASE" ]] || die_usage "--release is required"
[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
  die_usage "--namespace must be a DNS label"
[[ "$RELEASE" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] ||
  die_usage "--release contains unsupported characters"
[[ "$HEALTH_PATH" == /* ]] || die_usage "--health-path must start with /"
[[ "$HEALTH_PATH" != *$'\n'* && "$HEALTH_PATH" != *$'\r'* ]] ||
  die_usage "--health-path must be one line"
is_positive_integer "$TIMEOUT_SECONDS" || die_usage "--timeout must be a positive integer"
is_positive_integer "$CERT_MIN_VALID_SECONDS" ||
  die_usage "--cert-min-valid must be a positive integer"

if [[ -n "$INGRESS_HOST" ]]; then
  [[ "$INGRESS_HOST" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] ||
    die_usage "--ingress-host is not a valid DNS host"
fi

for health_url in ${HEALTH_URLS[@]+"${HEALTH_URLS[@]}"}; do
  validate_health_url "$health_url" ||
    die_usage "--health-url must be HTTP(S), contain a host, and contain no credentials, query, or fragment"
done

[[ -n "$SELECTOR" ]] || SELECTOR="app.kubernetes.io/instance=$RELEASE"

missing_tools=()
for tool in helm kubectl python3 curl openssl timeout; do
  command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
done
if ((${#missing_tools[@]})); then
  proof FAIL prerequisites "missing_tools=${missing_tools[*]}"
  printf 'PROOF_RESULT=FAIL\n'
  printf 'PROOF_COUNTS pass=%d fail=%d skip=%d\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
  exit 1
fi
proof PASS prerequisites "required_tools_present"

KUBECTL=(kubectl)
HELM=(helm)
if [[ -n "$CONTEXT" ]]; then
  KUBECTL+=(--context "$CONTEXT")
  HELM+=(--kube-context "$CONTEXT")
fi
KUBECTL+=(--namespace "$NAMESPACE")

# Helm release status. Raw Helm output is parsed in memory and never printed.
release_state="$(
  "${HELM[@]}" status "$RELEASE" --namespace "$NAMESPACE" --output json 2>/dev/null |
    python3 -c '
import json, sys
data = json.load(sys.stdin)
status = data.get("info", {}).get("status", "")
if not isinstance(status, str):
    raise SystemExit(1)
print(status)
' 2>/dev/null
)"
release_rc=$?
if ((release_rc != 0)); then
  proof FAIL release "helm_status_unavailable"
elif [[ "$release_state" == "deployed" ]]; then
  proof PASS release "status=deployed"
else
  proof FAIL release "status_not_deployed"
fi

# Jobs are selected explicitly when requested. Otherwise, discover release
# Jobs whose names or common component labels indicate migration/schema work.
migration_json="$(
  "${KUBECTL[@]}" get jobs.batch -l "${MIGRATION_SELECTOR:-$SELECTOR}" -o json 2>/dev/null
)"
migration_get_rc=$?
if ((migration_get_rc != 0)); then
  proof FAIL migrations "job_query_failed"
else
  migration_summary="$(
    printf '%s' "$migration_json" |
      MIGRATION_MODE="$([[ -n "$MIGRATION_SELECTOR" ]] && printf explicit || printf discover)" \
      python3 -c '
import json, os, re, sys
data = json.load(sys.stdin)
explicit = os.environ["MIGRATION_MODE"] == "explicit"
matched = []
for item in data.get("items", []):
    metadata = item.get("metadata", {})
    labels = metadata.get("labels", {})
    text = " ".join([
        metadata.get("name", ""),
        labels.get("app.kubernetes.io/component", ""),
        labels.get("app.kubernetes.io/name", ""),
        labels.get("job-type", ""),
    ])
    if explicit or re.search(r"(migrat|schema|database[-_]?setup|db[-_]?setup)", text, re.I):
        matched.append(item)

failed = 0
incomplete = 0
for item in matched:
    status = item.get("status", {})
    conditions = {
        c.get("type"): c.get("status")
        for c in status.get("conditions", [])
    }
    if status.get("failed", 0) > 0 or conditions.get("Failed") == "True":
        failed += 1
    elif conditions.get("Complete") != "True":
        incomplete += 1
print(len(matched), failed, incomplete)
' 2>/dev/null
  )"
  migration_parse_rc=$?
  if ((migration_parse_rc != 0)); then
    proof FAIL migrations "job_status_parse_failed"
  else
    read -r migration_count migration_failed migration_incomplete <<<"$migration_summary"
    if ((migration_count == 0)); then
      if $ALLOW_MISSING_MIGRATIONS; then
        proof SKIP migrations "no_migration_jobs_allowed"
      else
        proof FAIL migrations "no_migration_evidence"
      fi
    elif ((migration_failed > 0)); then
      proof FAIL migrations "jobs=$migration_count failed=$migration_failed"
    elif ((migration_incomplete > 0)); then
      proof FAIL migrations "jobs=$migration_count incomplete=$migration_incomplete"
    else
      proof PASS migrations "jobs=$migration_count complete=$migration_count"
    fi
  fi
fi

# Controller health is evaluated without fetching manifests or pod logs.
workload_count=0
workload_json="$(
  "${KUBECTL[@]}" get deployments.apps,statefulsets.apps,daemonsets.apps \
    -l "$SELECTOR" -o json 2>/dev/null
)"
workload_get_rc=$?
if ((workload_get_rc != 0)); then
  proof FAIL workloads "controller_query_failed"
else
  workload_summary="$(
    printf '%s' "$workload_json" |
      python3 -c '
import json, sys
data = json.load(sys.stdin)
items = data.get("items", [])
unready = 0
for item in items:
    kind = item.get("kind", "")
    metadata = item.get("metadata", {})
    spec = item.get("spec", {})
    status = item.get("status", {})
    generation = metadata.get("generation", 0)
    observed = status.get("observedGeneration", 0)
    ready = True
    if observed < generation:
        ready = False
    if kind == "Deployment":
        desired = spec.get("replicas", 1)
        ready = ready and status.get("availableReplicas", 0) >= desired
        ready = ready and status.get("updatedReplicas", 0) >= desired
        ready = ready and status.get("unavailableReplicas", 0) == 0
    elif kind == "StatefulSet":
        desired = spec.get("replicas", 1)
        ready = ready and status.get("readyReplicas", 0) >= desired
        ready = ready and status.get("updatedReplicas", 0) >= desired
    elif kind == "DaemonSet":
        desired = status.get("desiredNumberScheduled", 0)
        ready = ready and status.get("numberReady", 0) >= desired
        ready = ready and status.get("updatedNumberScheduled", 0) >= desired
        ready = ready and status.get("numberUnavailable", 0) == 0
    else:
        ready = False
    if not ready:
        unready += 1
print(len(items), unready)
' 2>/dev/null
  )"
  workload_parse_rc=$?
  if ((workload_parse_rc != 0)); then
    proof FAIL workloads "controller_status_parse_failed"
  else
    read -r workload_count workload_unready <<<"$workload_summary"
    if ((workload_count == 0)); then
      if $ALLOW_MISSING_WORKLOADS; then
        proof SKIP workloads "no_controllers_allowed"
      else
        proof FAIL workloads "no_controllers_found"
      fi
    elif ((workload_unready > 0)); then
      proof FAIL workloads "controllers=$workload_count unready=$workload_unready"
    else
      proof PASS workloads "controllers=$workload_count ready=$workload_count"
    fi
  fi
fi

# Native History architecture: require all three pipeline controllers, reject
# both legacy controllers, and prove Control is configured for the native
# backend without the retired RelayAuth/RelayHistory URL handoff. This reads
# Deployment metadata and literal env names/values only; it never fetches a
# Secret resource.
if $REQUIRE_NATIVE_HISTORY; then
  if ((workload_get_rc != 0)); then
    proof FAIL native_history "controller_query_failed"
  else
    native_summary="$(
      printf '%s' "$workload_json" |
        NATIVE_RELEASE="$RELEASE" python3 -c '
import json, os, sys
release = os.environ["NATIVE_RELEASE"]
items = [x for x in json.load(sys.stdin).get("items", []) if x.get("kind") == "Deployment"]
by_name = {x.get("metadata", {}).get("name", ""): x for x in items}
required = [f"{release}-read-api", f"{release}-ingest-edge", f"{release}-search-indexer"]
missing = [name for name in required if name not in by_name]
legacy = [name for name in by_name if name in {"relayauth", "relayhistory"} or name in {f"{release}-relayauth", f"{release}-relayhistory"}]
control = next((x for x in items if x.get("metadata", {}).get("name") in {"relay-control", f"{release}-relay-control"} or x.get("metadata", {}).get("labels", {}).get("app.kubernetes.io/name") == "relay-control"), None)
env = {}
if control:
    containers = control.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
    if containers:
        env = {x.get("name"): x.get("value") for x in containers[0].get("env", []) if x.get("name")}
control_ok = control is not None and env.get("RELAYHISTORY_BACKEND") == "native" and "RELAYAUTH_URL" not in env and "RELAYHISTORY_URL" not in env
print(",".join(missing) or "-", ",".join(legacy) or "-", "ok" if control_ok else "bad")
' 2>/dev/null
    )"
    native_parse_rc=$?
    if ((native_parse_rc != 0)); then
      proof FAIL native_history "controller_status_parse_failed"
    else
      read -r native_missing native_legacy native_control <<<"$native_summary"
      if [[ "$native_missing" == - && "$native_legacy" == - && "$native_control" == ok ]]; then
        proof PASS native_history "reader_ingest_search_present legacy_absent control_backend=native"
      else
        proof FAIL native_history "missing=$native_missing legacy=$native_legacy control=$native_control"
      fi
    fi
  fi
fi

pod_json="$("${KUBECTL[@]}" get pods -l "$SELECTOR" -o json 2>/dev/null)"
pod_get_rc=$?
if ((pod_get_rc != 0)); then
  proof FAIL pods "pod_query_failed"
else
  pod_summary="$(
    printf '%s' "$pod_json" |
      python3 -c '
import json, sys
data = json.load(sys.stdin)
items = data.get("items", [])
unhealthy = 0
for item in items:
    metadata = item.get("metadata", {})
    status = item.get("status", {})
    phase = status.get("phase", "")
    deleting = metadata.get("deletionTimestamp") is not None
    healthy = deleting or phase == "Succeeded"
    if phase == "Running" and not deleting:
        statuses = status.get("containerStatuses", [])
        healthy = bool(statuses) and all(s.get("ready") is True for s in statuses)
    if not healthy:
        unhealthy += 1
print(len(items), unhealthy)
' 2>/dev/null
  )"
  pod_parse_rc=$?
  if ((pod_parse_rc != 0)); then
    proof FAIL pods "pod_status_parse_failed"
  else
    read -r pod_count pod_unhealthy <<<"$pod_summary"
    if ((pod_count == 0 && workload_count > 0)); then
      proof FAIL pods "no_pods_for_controllers"
    elif ((pod_unhealthy > 0)); then
      proof FAIL pods "pods=$pod_count unhealthy=$pod_unhealthy"
    else
      proof PASS pods "pods=$pod_count unhealthy=0"
    fi
  fi
fi

ingress_json="$("${KUBECTL[@]}" get ingresses.networking.k8s.io -l "$SELECTOR" -o json 2>/dev/null)"
ingress_get_rc=$?
INGRESS_AVAILABLE=false
SELECTED_HOSTS=()
TLS_HOSTS=()
TLS_SECRET_REFS=()
MANAGED_CERT_NAMES=()
MANAGED_CERT_HOSTS=()

if ((ingress_get_rc != 0)); then
  proof FAIL ingress "ingress_query_failed"
else
  ingress_summary="$(
    printf '%s' "$ingress_json" |
      INGRESS_HOST_FILTER="$INGRESS_HOST" python3 -c '
import json, os, sys
data = json.load(sys.stdin)
host_filter = os.environ.get("INGRESS_HOST_FILTER", "").lower()
items = data.get("items", [])
selected = []
for item in items:
    rules = item.get("spec", {}).get("rules", [])
    hosts = [r.get("host", "").lower() for r in rules if r.get("host")]
    if not host_filter or host_filter in hosts:
        selected.append(item)
admitted = 0
rule_hosts = set()
for item in selected:
    lb = item.get("status", {}).get("loadBalancer", {}).get("ingress", [])
    if any(x.get("hostname") or x.get("ip") for x in lb):
        admitted += 1
    for rule in item.get("spec", {}).get("rules", []):
        if rule.get("host"):
            rule_hosts.add(rule["host"].lower())
if host_filter:
    rule_hosts &= {host_filter}
print(len(selected), admitted, len(rule_hosts))
' 2>/dev/null
  )"
  ingress_parse_rc=$?
  if ((ingress_parse_rc != 0)); then
    proof FAIL ingress "ingress_status_parse_failed"
  else
    read -r ingress_count ingress_admitted ingress_host_count <<<"$ingress_summary"
    if ((ingress_count == 0)); then
      if $ALLOW_MISSING_INGRESS; then
        proof SKIP ingress "no_ingress_allowed"
      else
        proof FAIL ingress "no_matching_ingress"
      fi
    elif ((ingress_admitted != ingress_count)); then
      proof FAIL ingress "ingresses=$ingress_count admitted=$ingress_admitted"
    elif ((ingress_host_count == 0)); then
      proof FAIL ingress "no_rule_hosts"
    else
      INGRESS_AVAILABLE=true
      proof PASS ingress "ingresses=$ingress_count admitted=$ingress_admitted hosts=$ingress_host_count"
    fi

    if ((ingress_count > 0)); then
      # One pass emits typed records. With --ingress-host, every list is
      # narrowed to that host: sibling hosts on the same Ingress are neither
      # probed nor used for TLS or certificate references. A GKE Ingress
      # without spec.tls that names a ManagedCertificate serves TLS for its
      # rule hosts through that certificate.
      while IFS=$'\t' read -r record_type record_value; do
        case "$record_type" in
          HOST) SELECTED_HOSTS+=("$record_value") ;;
          TLS) TLS_HOSTS+=("$record_value") ;;
          REF) TLS_SECRET_REFS+=("$record_value") ;;
          MCERT) MANAGED_CERT_NAMES+=("$record_value") ;;
          MHOST) MANAGED_CERT_HOSTS+=("$record_value") ;;
        esac
      done < <(
        printf '%s' "$ingress_json" |
          INGRESS_HOST_FILTER="$INGRESS_HOST" python3 -c '
import json, os, sys
data = json.load(sys.stdin)
host_filter = os.environ.get("INGRESS_HOST_FILTER", "").lower()
records = {"HOST": set(), "TLS": set(), "REF": set(), "MCERT": set(), "MHOST": set()}
for item in data.get("items", []):
    spec = item.get("spec", {})
    rule_hosts = {
        r.get("host", "").lower()
        for r in spec.get("rules", [])
        if r.get("host")
    }
    if host_filter and host_filter not in rule_hosts:
        continue
    wanted = {host_filter} if host_filter else rule_hosts
    records["HOST"].update(wanted)
    tls_entries = spec.get("tls") or []
    for tls in tls_entries:
        tls_hosts = {h.lower() for h in tls.get("hosts", []) if h}
        matched = tls_hosts & wanted if host_filter else tls_hosts
        if not matched:
            continue
        records["TLS"].update(matched)
        if tls.get("secretName"):
            records["REF"].add(tls["secretName"])
    annotations = item.get("metadata", {}).get("annotations", {}) or {}
    managed = [
        name.strip()
        for name in annotations.get("networking.gke.io/managed-certificates", "").split(",")
        if name.strip()
    ]
    if managed:
        records["MCERT"].update(managed)
        records["MHOST"].update(wanted)
        if not tls_entries:
            records["TLS"].update(wanted)
for kind, values in records.items():
    for value in sorted(values):
        print(f"{kind}\t{value}")
' 2>/dev/null
      )
    fi
  fi
fi

# An explicit external-termination target must still belong to the selected
# ingress. It adds real chain/hostname/expiry verification, never a TLS skip.
for external_host in ${EXTERNAL_TLS_HOSTS[@]+"${EXTERNAL_TLS_HOSTS[@]}"}; do
  external_selected=false
  for selected_host in ${SELECTED_HOSTS[@]+"${SELECTED_HOSTS[@]}"}; do
    [[ "$external_host" == "$selected_host" ]] && external_selected=true
  done
  if $INGRESS_AVAILABLE && $external_selected; then
    TLS_HOSTS+=("$external_host")
  else
    proof FAIL certificate "external_tls_host_not_in_selected_ingress"
  fi
done

# Use explicit health URLs, or derive HTTPS URLs from the selected ingress rules.
if ((${#HEALTH_URLS[@]} == 0)) && $INGRESS_AVAILABLE; then
  for host in ${SELECTED_HOSTS[@]+"${SELECTED_HOSTS[@]}"}; do
    HEALTH_URLS+=("https://${host}${HEALTH_PATH}")
  done
fi

if ((${#HEALTH_URLS[@]} == 0)); then
  if $ALLOW_MISSING_INGRESS; then
    proof SKIP health "no_health_endpoint"
  else
    proof FAIL health "no_health_endpoint"
  fi
else
  health_failures=0
  health_index=0
  for health_url in "${HEALTH_URLS[@]}"; do
    health_index=$((health_index + 1))
    http_code="$(
      curl --disable --silent --show-error --output /dev/null --max-time "$TIMEOUT_SECONDS" \
        --write-out '%{http_code}' "$health_url" 2>/dev/null
    )"
    curl_rc=$?
    if ((curl_rc == 0)) && [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
      proof PASS "health[$health_index]" "http_status=$http_code"
    else
      proof FAIL "health[$health_index]" "request_or_status_failed"
      health_failures=$((health_failures + 1))
    fi
  done
fi

if ((${#TLS_HOSTS[@]} == 0)); then
  if $ALLOW_NO_TLS || $ALLOW_MISSING_INGRESS; then
    proof SKIP certificate "no_tls_hosts_allowed"
  else
    proof FAIL certificate "no_tls_hosts"
  fi
else
  cert_index=0
  for tls_host in "${TLS_HOSTS[@]}"; do
    cert_index=$((cert_index + 1))
    if timeout "$TIMEOUT_SECONDS" openssl s_client \
      -connect "${tls_host}:443" \
      -servername "$tls_host" \
      -verify_hostname "$tls_host" \
      -verify_return_error </dev/null 2>/dev/null |
      openssl x509 -noout -checkend "$CERT_MIN_VALID_SECONDS" >/dev/null 2>&1; then
      proof PASS "certificate[$cert_index]" "trusted_hostname_valid_and_not_expiring"
    else
      proof FAIL "certificate[$cert_index]" "tls_validation_failed"
    fi
  done
fi

# GKE ManagedCertificate status corroborates the public TLS checks: every
# certificate named by the selected Ingress must be Active and its domains
# must cover the hosts it serves.
if ((${#MANAGED_CERT_NAMES[@]} == 0)); then
  proof SKIP managed_certificate "no_managed_certificate_references"
else
  managed_cert_json="$("${KUBECTL[@]}" get managedcertificates.networking.gke.io -o json 2>/dev/null)"
  managed_cert_get_rc=$?
  if ((managed_cert_get_rc != 0)); then
    proof FAIL managed_certificate "managed_certificate_query_failed"
  else
    managed_cert_summary="$(
      printf '%s' "$managed_cert_json" |
        MANAGED_NAMES="$(printf '%s\n' "${MANAGED_CERT_NAMES[@]}")" \
        MANAGED_HOSTS="$(printf '%s\n' ${MANAGED_CERT_HOSTS[@]+"${MANAGED_CERT_HOSTS[@]}"})" \
        python3 -c '
import json, os, sys
names = [n for n in os.environ.get("MANAGED_NAMES", "").splitlines() if n]
hosts = {h for h in os.environ.get("MANAGED_HOSTS", "").splitlines() if h}
data = json.load(sys.stdin)
by_name = {i.get("metadata", {}).get("name"): i for i in data.get("items", [])}
inactive = 0
covered = set()
for name in names:
    item = by_name.get(name)
    if not item or item.get("status", {}).get("certificateStatus") != "Active":
        inactive += 1
        continue
    covered.update(d.lower() for d in item.get("spec", {}).get("domains", []) if d)
print(len(names), inactive, len(hosts - covered))
' 2>/dev/null
    )"
    managed_cert_parse_rc=$?
    if ((managed_cert_parse_rc != 0)); then
      proof FAIL managed_certificate "managed_certificate_status_parse_failed"
    else
      read -r managed_count managed_inactive managed_uncovered <<<"$managed_cert_summary"
      if ((managed_inactive > 0)); then
        proof FAIL managed_certificate "certificates=$managed_count inactive=$managed_inactive"
      elif ((managed_uncovered > 0)); then
        proof FAIL managed_certificate "certificates=$managed_count uncovered_hosts=$managed_uncovered"
      else
        proof PASS managed_certificate "certificates=$managed_count active=$managed_count"
      fi
    fi
  fi
fi

# If cert-manager is installed, corroborate public TLS checks using Certificate
# status only. Certificate resources may refer to Secrets, but Secret resources
# themselves are never requested. Secret reference names are never printed.
if "${KUBECTL[@]}" api-resources --api-group=cert-manager.io -o name 2>/dev/null |
  python3 -c 'import sys; raise SystemExit(0 if "certificates.cert-manager.io" in sys.stdin.read().split() else 1)'; then
  certificate_json="$("${KUBECTL[@]}" get certificates.cert-manager.io -o json 2>/dev/null)"
  certificate_get_rc=$?
  if ((certificate_get_rc != 0)); then
    proof FAIL cert_manager "certificate_query_failed"
  elif ((${#TLS_SECRET_REFS[@]} == 0)); then
    proof SKIP cert_manager "no_ingress_certificate_references"
  else
    cert_refs_joined="$(printf '%s\n' "${TLS_SECRET_REFS[@]}")"
    cert_manager_summary="$(
      printf '%s' "$certificate_json" |
        CERT_REFS="$cert_refs_joined" python3 -c '
import json, os, sys
refs = set(os.environ.get("CERT_REFS", "").splitlines())
data = json.load(sys.stdin)
matched = 0
unready = 0
for item in data.get("items", []):
    if item.get("spec", {}).get("secretName") not in refs:
        continue
    matched += 1
    ready = any(
        c.get("type") == "Ready" and c.get("status") == "True"
        for c in item.get("status", {}).get("conditions", [])
    )
    if not ready:
        unready += 1
print(matched, unready)
' 2>/dev/null
    )"
    cert_manager_parse_rc=$?
    if ((cert_manager_parse_rc != 0)); then
      proof FAIL cert_manager "certificate_status_parse_failed"
    else
      read -r cert_manager_count cert_manager_unready <<<"$cert_manager_summary"
      if ((cert_manager_count == 0)); then
        proof SKIP cert_manager "no_matching_certificate_objects"
      elif ((cert_manager_unready > 0)); then
        proof FAIL cert_manager "certificates=$cert_manager_count unready=$cert_manager_unready"
      else
        proof PASS cert_manager "certificates=$cert_manager_count ready=$cert_manager_count"
      fi
    fi
  fi
else
  proof SKIP cert_manager "api_not_installed"
fi

if ((FAIL_COUNT == 0)); then
  printf 'PROOF_RESULT=PASS\n'
  result_rc=0
else
  printf 'PROOF_RESULT=FAIL\n'
  result_rc=1
fi
printf 'PROOF_COUNTS pass=%d fail=%d skip=%d\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
exit "$result_rc"
