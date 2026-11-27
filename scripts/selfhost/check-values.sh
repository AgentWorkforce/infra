#!/usr/bin/env bash
# Check Agent Relay Helm values before `helm upgrade --install`, with no
# cluster. Lists every problem at once, with the value's path and the fix.
#
#   scripts/selfhost/check-values.sh -f charts/agent-relay/values-eks.yaml \
#     -f charts/agent-relay/values-eks-native.yaml -f values.yaml
#
# Pass the same -f files, in the same order, as the helm command. It runs
# two checks and reports both:
#   1. Example values left in your own files (the domain, bucket, OpenSearch
#      endpoint, org and admin email of examples/aws/values.yaml), by file and
#      line. The profiles the chart ships (values-eks.yaml, ...) are not
#      scanned; a copy you put in the chart directory is.
#   2. `helm template` of the chart, offline. The chart checks every values
#      problem it can see (site values, contradictions, origins, OpenSearch,
#      buckets) and reports them together.
#
# Options:
#   --chart <dir|oci://ref>  chart to check (default: this checkout's
#                            charts/agent-relay; its dependencies are built
#                            with helm-deps.sh when missing)
#   --version <v>            chart version, with an oci:// chart
#   --release <name>         release name (default agent-relay)
#   --namespace <ns>         namespace (default agent-relay)
#   --allow-example-values   skip check 1 (for rendering the examples)
#   --set/--set-string/--set-json <v>  passed to helm
# Exit status: 0 no problems, 1 problems found, 2 usage or tool error.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
chart="$root/charts/agent-relay" version="" release=agent-relay namespace=agent-relay
allow_examples=false files=() helm_args=()
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d;s/^# \{0,1\}//' >&2; exit 2; }
while [ $# -gt 0 ]; do
  case $1 in
    -f|--values) [ $# -ge 2 ] || usage; files+=("$2"); helm_args+=(-f "$2"); shift 2 ;;
    --set|--set-string|--set-json) [ $# -ge 2 ] || usage; helm_args+=("$1" "$2"); shift 2 ;;
    --chart) [ $# -ge 2 ] || usage; chart=$2; shift 2 ;;
    --version) [ $# -ge 2 ] || usage; version=$2; shift 2 ;;
    --release) [ $# -ge 2 ] || usage; release=$2; shift 2 ;;
    --namespace|-n) [ $# -ge 2 ] || usage; namespace=$2; shift 2 ;;
    --allow-example-values) allow_examples=true; shift ;;
    -h|--help) usage ;;
    *) echo "check-values: unknown argument: $1" >&2; usage ;;
  esac
done
[ ${#files[@]} -gt 0 ] || { echo "check-values: pass your values files with -f, as for helm" >&2; usage; }
command -v helm >/dev/null || { echo "check-values: helm not found on PATH" >&2; exit 2; }
for f in "${files[@]}"; do
  [ -r "$f" ] || { echo "check-values: cannot read $f" >&2; exit 2; }
done

problems=0

# 1. Example values in the operator's own files. Keep in step with
# EXAMPLE_MARKERS in scripts/support/diagnose-install.py.
if [ "$allow_examples" = false ]; then
  markers='selfhost-example|ar\.example\.com|org_example|example-agent-relay-sessions|vpc-agent-relay-example|admin@example\.com|Example Corp|abc123example|placeholder\.company'
  chart_dir=""
  [ -d "$chart" ] && chart_dir=$(cd "$chart" && pwd)
  for f in "${files[@]}"; do
    # Skip the profiles the chart ships (values-eks.yaml has placeholders of
    # its own that site values replace); a copy such as values-poc.yaml is yours.
    dir=$(cd "$(dirname "$f")" && pwd) base=$(basename "$f")
    if [ "$dir" = "$chart_dir" ] && git -C "$root" ls-files --error-unmatch "charts/agent-relay/$base" >/dev/null 2>&1; then continue; fi
    # Comments do not count: a value is what precedes an unquoted " #".
    hits=$(awk -v re="$markers" '{ v = $0; sub(/^[ \t]*#.*/, "", v); sub(/[ \t]#.*/, "", v); if (v ~ re) printf "   %s:%d: %s\n", FILENAME, FNR, $0 }' "$f")
    if [ -n "$hits" ]; then
      if [ $problems -eq 0 ]; then echo "Example values are still in your values:"; fi
      printf '%s\n' "$hits"
      problems=1
    fi
  done
  if [ $problems -ne 0 ]; then
    echo "   fix: replace each with your own value (site: holds the domain, region, bucket,"
    echo "   OpenSearch URL, org and admin email once; see examples/aws/values.yaml)."
    echo
  fi
fi

# 2. The chart's own checks, offline.
if [ -d "$chart" ] && [ "$(cd "$chart" && pwd)" = "$root/charts/agent-relay" ] && [ ! -d "$chart/charts" ]; then
  echo "check-values: building chart dependencies (scripts/selfhost/helm-deps.sh)" >&2
  "$root/scripts/selfhost/helm-deps.sh" >/dev/null
fi
template=(helm template "$release" "$chart" --namespace "$namespace" --no-hooks)
[ -z "$version" ] || template+=(--version "$version")
if ! out=$("${template[@]}" "${helm_args[@]}" 2>&1 >/dev/null); then
  # Keep Helm's message, without its location prefix and --debug hint.
  printf '%s\n' "$out" | sed -E 's/^Error: (execution error at \([^)]*\): )?//; /^Use --debug flag/d'
  echo
  problems=1
fi

if [ $problems -eq 0 ]; then
  echo "check-values: no problems found in ${files[*]}"
fi
exit $problems
