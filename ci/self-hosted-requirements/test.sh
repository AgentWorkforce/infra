#!/usr/bin/env bash
# Regression tests for registry.mjs: each case breaks a copy of the repo on
# purpose and asserts the named check fails with the expected message, or (for
# comment-only mentions) still passes. The clean copy must pass first.
#
#   ci/self-hosted-requirements/test.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail=0
err() { echo "::error::$*"; fail=1; }

fresh() { # a clean copy of what the shipped/planned/coverage checks read
  rm -rf "$WORK/r" && mkdir -p "$WORK/r/ci"
  cp -r "$ROOT/charts" "$ROOT/self-hosted" "$WORK/r/"
  cp -r "$ROOT/ci/self-hosted-requirements" "$WORK/r/ci/"
  rm -rf "$WORK"/r/charts/*/charts
}
check() { node "$WORK/r/ci/self-hosted-requirements/registry.mjs" check "$@" 2>&1; }
expect_fail() { # label check message
  local o
  if o=$(check "$2"); then err "$1: $2 passed, want a failure"; elif ! grep -qF "$3" <<<"$o"; then err "$1: wrong failure: $(grep -m1 '::error' <<<"$o")"; else echo "ok   $1"; fi
}
expect_pass() { # label check
  local o
  if o=$(check "$2"); then echo "ok   $1"; else err "$1: $2 failed: $(grep -m1 '::error' <<<"$o")"; fi
}

fresh
expect_pass "clean copy (coverage)" coverage
expect_pass "clean copy (shipped)" shipped
expect_pass "clean copy (planned)" planned

# (c) A planned subchart value read from the UMBRELLA templates (.Values.worker.<x>).
fresh
echo '{{- if .Values.worker.sessionBrief.enabled }}{{ end }}' >> "$WORK/r/charts/sessions-pipeline/templates/NOTES.txt"
expect_fail "planned: umbrella reads .Values.worker.sessionBrief.enabled" planned \
  "opt.sessions-pipeline.session-briefs is planned, but charts/sessions-pipeline/templates reads sessions-pipeline-worker:sessionBrief.enabled"

# (c) The same through index (a key a dotted path cannot spell).
fresh
echo '{{- if index .Values.worker "sessionBrief" "enabled" }}{{ end }}' >> "$WORK/r/charts/sessions-pipeline/templates/NOTES.txt"
expect_fail "planned: umbrella index .Values.worker \"sessionBrief\"" planned \
  "charts/sessions-pipeline/templates reads sessions-pipeline-worker:sessionBrief.enabled"

# (c) A planned umbrella value read from the umbrella's own templates.
fresh
echo '{{- if .Values.worker.sessionBrief.model }}{{ end }}' >> "$WORK/r/charts/sessions-pipeline/templates/NOTES.txt"
expect_fail "planned: umbrella reads .Values.worker.sessionBrief.model" planned \
  "opt.sessions-pipeline.session-briefs is planned, but charts/sessions-pipeline/templates reads sessions-pipeline:worker.sessionBrief.model"

# (c) A planned entry owned by a SUBCHART (chart: sessions-pipeline-worker) whose path is
# read only by the umbrella templates: every chart's reads are scanned.
fresh
yq -i '(.entries[] | select(.id == "opt.sessions-pipeline.session-briefs")) |= (.chart = "sessions-pipeline-worker" | .values = ["sessionBrief.enabled"])' "$WORK/r/self-hosted/requirements.yaml"
echo '{{- if .Values.worker.sessionBrief.enabled }}{{ end }}' >> "$WORK/r/charts/sessions-pipeline/templates/NOTES.txt"
expect_fail "planned: subchart entry read only by the umbrella" planned \
  "opt.sessions-pipeline.session-briefs is planned, but charts/sessions-pipeline/templates reads sessions-pipeline-worker:sessionBrief.enabled"

# A template comment that names a planned env or value is not a reference.
fresh
printf '%s\n' '{{/* SESSION_BRIEF_ENABLED and .Values.worker.sessionBrief.enabled come with the re-pin */}}' \
  '{{- /* .Values.worker.sessionBrief.model: planned */ -}}' >> "$WORK/r/charts/sessions-pipeline/templates/NOTES.txt"
expect_pass "planned: template comments are not references" planned

# Shipped env whose only mention left is a values.yaml COMMENT.
fresh
sed -i 's/^      - name: BOB_COSTAS_MODEL$/      # - name: BOB_COSTAS_MODEL (BOB_COSTAS_MODEL is set by the image)/; /^        value: "off"$/d' "$WORK/r/charts/sessions-pipeline-worker/values.yaml"
grep -q 'BOB_COSTAS_MODEL' "$WORK/r/charts/sessions-pipeline-worker/values.yaml" || err "fixture: BOB_COSTAS_MODEL comment missing"
expect_fail "shipped: env only in a values.yaml comment" shipped \
  "opt.sessions-pipeline.bob-costas-model: env BOB_COSTAS_MODEL is neither rendered"

# Shipped env whose only mention left is a template COMMENT.
fresh
sed -i 's/^            - name: AUTH_AUDIENCE$/            {{- \/* AUTH_AUDIENCE moved *\/}}\n            - name: AUTH_AUDIENCE_X/' "$WORK/r/charts/session-ingest-api/templates/deployment.yaml"
expect_fail "shipped: env only in a template comment" shipped \
  "opt.alleyoop.auth-mode: env AUTH_AUDIENCE is neither rendered"

[ $fail -eq 0 ] && echo "registry.mjs regression tests: OK"
exit $fail
