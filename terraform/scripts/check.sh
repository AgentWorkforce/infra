#!/usr/bin/env bash
# Static checks for every Terraform module and example, with no cloud
# credentials: fmt, init (no backend), validate, tflint, terraform test (mock
# providers), Python runner/verifier unit tests, terraform-docs drift and checkov. Each tool is skipped with a
# notice when it is not installed, unless CI=true, where a missing tool fails.
#
#   terraform/scripts/check.sh            # all checks
#   TF_BIN=tofu terraform/scripts/check.sh validate test   # OpenTofu, selected checks
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_BIN="${TF_BIN:-terraform}"
CHECKS=("$@")
KNOWN=(fmt validate tflint test docs checkov)
[ ${#CHECKS[@]} -gt 0 ] || CHECKS=("${KNOWN[@]}")
for c in "${CHECKS[@]}"; do
  case " ${KNOWN[*]} " in *" $c "*) ;; *) echo "unknown check: $c (known: ${KNOWN[*]})" >&2; exit 2 ;; esac
done
export TF_IN_AUTOMATION=1 TF_INPUT=0
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$HOME/.terraform.d/plugin-cache}"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

dirs=()
while IFS= read -r d; do dirs+=("$d"); done < <(cd "$ROOT" && find modules examples -not -path '*/.terraform/*' \( -name versions.tf -o \( -name main.tf -path 'examples/*' \) \) | xargs -n1 dirname | sort -u)

want() { local c; for c in "${CHECKS[@]}"; do [ "$c" = "$1" ] && return 0; done; return 1; }
have() {
  command -v "$1" >/dev/null 2>&1 && return 0
  if [ "${CI:-}" = "true" ]; then echo "::error::$1 is not installed"; exit 1; fi
  echo "skip: $1 not installed"; return 1
}

fail=0
# run [-C dir] cmd...: the command runs in a temporary subshell (for the
# directory change); its result is recorded in the parent shell, so a failure
# always reaches $fail.
run() {
  local dir="$ROOT"
  if [ "$1" = "-C" ]; then dir="$2"; shift 2; fi
  echo "+ (${dir#"$ROOT"/}) $*"
  if ! (cd "$dir" && "$@"); then echo "::error::failed in ${dir#"$ROOT"/}: $*"; fail=1; fi
}

if want fmt; then run "$TF_BIN" fmt -check -recursive -diff "$ROOT"; fi
if want test && have python3; then
  run python3 -m unittest discover -s "$ROOT/scripts" -p 'test_aws_*.py'
  run python3 -m unittest discover -s "$ROOT/modules/aws/search/tests" -p 'test_*.py'
fi

for d in "${dirs[@]}"; do
  echo "== $d"
  if want validate || want test; then
    # Provider downloads (GitHub release assets) occasionally time out: retry
    # those, and fail at once on anything else.
    ok=0
    for attempt in 1 2 3 4; do
      if out=$(cd "$ROOT/$d" && "$TF_BIN" init -backend=false -input=false -no-color 2>&1); then ok=1; break; fi
      if [ $attempt -lt 4 ] && grep -qiE "504|502|503|timeout|timed out|connection reset|could not query provider registry|failed to install provider" <<<"$out"; then
        echo "init in $d hit a transient download error (attempt $attempt), retrying"; sleep $((attempt * 15))
      else
        echo "$out"; break
      fi
    done
    [ $ok = 1 ] || { echo "::error::init failed: $d"; fail=1; continue; }
  fi
  if want validate; then run -C "$ROOT/$d" "$TF_BIN" validate -no-color; fi
  if want test && [ -d "$ROOT/$d/tests" ]; then run -C "$ROOT/$d" "$TF_BIN" test -no-color; fi
  if want test && [ "$d" = "modules/aws/search" ]; then
    run python3 "$ROOT/$d/tests/check_lifecycle.py"
    run python3 "$ROOT/$d/tests/check_mode_history.py" "$TF_BIN"
  fi
  if want test && [ "$d" = "examples/aws-environments" ] && have python3; then
    run -C "$ROOT/$d" python3 tests/check_lambda_bindings.py "$TF_BIN"
  fi
  if want test && [ "$d" = "examples/aws-search-proof" ] && have python3; then
    run -C "$ROOT/$d" python3 -m unittest discover -s proof -p 'test_*.py'
    run -C "$ROOT/$d" python3 tests/check_first_plan.py "$TF_BIN"
  fi
  if want tflint && have tflint; then
    run -C "$ROOT/$d" tflint --config "$ROOT/.tflint.hcl" --no-color
  fi
  if want docs && have terraform-docs; then
    run -C "$ROOT/$d" terraform-docs --config "$ROOT/.terraform-docs.yml" --output-check .
  fi
done

if want checkov && have checkov; then
  run checkov --config-file "$ROOT/.checkov.yaml" --directory "$ROOT"
fi

exit $fail
