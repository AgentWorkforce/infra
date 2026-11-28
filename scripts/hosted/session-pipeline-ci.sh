#!/usr/bin/env bash
# CI plan and apply for terraform/examples/aws-hosted-session-pipeline (.github/workflows/hosted-session-pipeline.yml).
#
#   session-pipeline-ci.sh plan  <work dir> <run id>
#   session-pipeline-ci.sh apply <work dir> <run id> <plan run id> <plan sha256>
#
# The repository is PUBLIC and so are its Actions logs: nothing here prints a plan, a tfvars value, a policy or an
# identifier. The job log and summary carry resource addresses, actions, digests and the gate verdict only. The
# saved plan, its text rendering and the gate report go to the state bucket (SSE-KMS), written once (If-None-Match).
#
# Environment (GitHub environment variables, set by the account owner):
#   AWS_REGION, STATE_BUCKET, STATE_KEY, STATE_KMS_KEY_ARN, TFVARS_PARAMETER, GATE_ALLOW (space-separated --allow
#   specs, may be empty), TF_BIN (default terraform).
# Apply rule (Khaliq, #owner-decisions 252346480703528960): apply only a saved plan that passed the gate at plan time
# AND passes it again at apply time; anything else stops.
set -euo pipefail
umask 077
die() { echo "hosted-ci: $*" >&2; exit 1; }
sha256() { sha256sum "$1" | cut -d' ' -f1; }
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
STACK=$ROOT/terraform/examples/aws-hosted-session-pipeline
GATE=$STACK/gate/zero_diff_gate.py
TF=${TF_BIN:-terraform}
for v in AWS_REGION STATE_BUCKET STATE_KEY STATE_KMS_KEY_ARN TFVARS_PARAMETER; do [ -n "${!v:-}" ] || die "$v is not set"; done
PREFIX="plans/${STATE_KEY%.tfstate}"
# Environment variables are not secrets to GitHub, so they are not masked by default: mask them here.
for v in STATE_BUCKET STATE_KEY STATE_KMS_KEY_ARN TFVARS_PARAMETER; do echo "::add-mask::${!v}"; done

put_once() {  # key file
  aws s3api put-object --bucket "$STATE_BUCKET" --key "$PREFIX/$1" --body "$2" --if-none-match '*' \
    --server-side-encryption aws:kms --ssekms-key-id "$STATE_KMS_KEY_ARN" >/dev/null || die "cannot write $1 once"
}
get() { aws s3api get-object --bucket "$STATE_BUCKET" --key "$PREFIX/$1" "$2" >/dev/null || die "cannot read $1"; }

fetch_tfvars() {  # out [version]
  local name=$TFVARS_PARAMETER resp
  [ -n "${2:-}" ] && name="$TFVARS_PARAMETER:$2"
  resp=$(aws ssm get-parameter --name "$name" --with-decryption --output json) || die "cannot read the tfvars parameter"
  TFVARS_VERSION=$(jq -er .Parameter.Version <<<"$resp")
  jq -j .Parameter.Value <<<"$resp" > "$1"; unset resp
  jq -e 'type == "object"' "$1" >/dev/null 2>&1 || die "the tfvars parameter is not a JSON object"
  # Mask every string value, so a provider error that echoes one cannot print it in the public log.
  jq -r '.. | strings | select(length >= 6)' "$1" | while IFS= read -r s; do echo "::add-mask::$s"; done
}

init() {
  "$TF" -chdir="$STACK" init -input=false -no-color \
    -backend-config="bucket=$STATE_BUCKET" -backend-config="key=$STATE_KEY" -backend-config="region=$AWS_REGION" \
    -backend-config="encrypt=true" -backend-config="kms_key_id=$STATE_KMS_KEY_ARN" -backend-config="use_lockfile=true" >/dev/null
}

gate() {  # plan file -> report file; returns gate status
  local allow=()
  for a in ${GATE_ALLOW:-}; do allow+=(--allow "$a"); done
  "$TF" -chdir="$STACK" show -json "$1" | python3 -I "$GATE" /dev/stdin "${allow[@]}" > "$2"
}

summary() {  # plan file -> markdown of addresses and actions only
  "$TF" -chdir="$STACK" show -json "$1" | jq -r '
    [.resource_changes[]? | {address, a: (.change.actions | join("/")), imp: (.change.importing != null)}] as $r |
    "\($r | map(select(.imp)) | length) to import; \($r | map(select(.a != "no-op")) | length) with changes",
    "", "```", ($r[] | select(.a != "no-op" or .imp) | "\(.a)\(if .imp then " (import)" else "" end)  \(.address)"), "```"'
}

case "${1:-}" in
  plan)
    [ $# = 3 ] || die "usage: plan <work> <run id>"
    WORK=$2; RUN=$3; mkdir -p "$WORK"; VARS=$WORK/hosted.tfvars.json
    fetch_tfvars "$VARS"
    init
    "$TF" -chdir="$STACK" plan -input=false -no-color -lock-timeout=120s -var-file="$VARS" -out="$WORK/tfplan" >/dev/null 2>"$WORK/plan.err" \
      || { echo "terraform plan failed; the error (masked) is in the plan store"; put_once "$RUN/plan.err" "$WORK/plan.err"; exit 1; }
    "$TF" -chdir="$STACK" show -no-color "$WORK/tfplan" > "$WORK/plan.txt"
    status=0; gate "$WORK/tfplan" "$WORK/gate.txt" || status=$?
    plan_sha=$(sha256 "$WORK/tfplan")
    jq -n --arg run "$RUN" --arg sha "$plan_sha" --arg ver "$TFVARS_VERSION" --arg vars "$(sha256 "$VARS")" \
      --arg commit "${GITHUB_SHA:-}" --arg allow "${GATE_ALLOW:-}" --argjson pass "$([ $status = 0 ] && echo true || echo false)" \
      '{schema_version: 1, plan_run_id: $run, plan_sha256: $sha, tfvars_version: $ver, tfvars_sha256: $vars,
        commit: $commit, gate_allow: $allow, gate_pass: $pass}' > "$WORK/manifest.json"
    for f in tfplan plan.txt gate.txt; do put_once "$RUN/$f" "$WORK/$f"; done
    put_once "$RUN/manifest.json" "$WORK/manifest.json"
    {
      echo "## Hosted session-pipeline plan"; echo
      echo "| | |"; echo "|---|---|"
      echo "| Plan run id | \`$RUN\` |"; echo "| Plan SHA-256 | \`$plan_sha\` |"
      echo "| tfvars version | $TFVARS_VERSION |"; echo "| Gate | $([ $status = 0 ] && echo PASS || echo REFUSED) |"; echo
      summary "$WORK/tfplan"; echo
      sed -E 's/^(REFUSED|PASS)/- \1/' "$WORK/gate.txt"; echo
      echo "Full plan text: \`s3://<state bucket>/$PREFIX/$RUN/plan.txt\` (reviewers with plan-store read)."
      [ $status = 0 ] && echo "Apply exactly this plan: dispatch mode \`apply\`, plan_run_id \`$RUN\`, plan_sha256 \`$plan_sha\`."
    } > "$WORK/summary.md"
    exit $status
    ;;
  apply)
    [ $# = 5 ] || die "usage: apply <work> <run id> <plan run id> <plan sha256>"
    WORK=$2; RUN=$3; PLAN_RUN=$4; APPROVED=$5; mkdir -p "$WORK"; VARS=$WORK/hosted.tfvars.json
    [[ "$PLAN_RUN" =~ ^[0-9]+-[0-9]+$ ]] || die "plan run id must be <run>-<attempt>"
    [[ "$APPROVED" =~ ^[0-9a-f]{64}$ ]] || die "plan sha256 must be 64 hex"
    get "$PLAN_RUN/manifest.json" "$WORK/manifest.json"
    m() { jq -er "$1" "$WORK/manifest.json"; }
    [ "$(m .schema_version)" = 1 ] || die "unsupported manifest"
    [ "$(m .plan_sha256)" = "$APPROVED" ] || die "plan $PLAN_RUN is not the approved digest"
    [ "$(m .gate_pass)" = true ] || die "plan $PLAN_RUN did not pass the gate"
    [ "$(m .gate_allow)" = "${GATE_ALLOW:-}" ] || die "GATE_ALLOW changed since the plan"
    get "$PLAN_RUN/tfplan" "$WORK/tfplan"
    [ "$(sha256 "$WORK/tfplan")" = "$APPROVED" ] || die "the stored plan does not match its digest"
    fetch_tfvars "$VARS" "$(m .tfvars_version)"
    [ "$(sha256 "$VARS")" = "$(m .tfvars_sha256)" ] || die "tfvars at the planned version changed"
    init
    gate "$WORK/tfplan" "$WORK/gate.txt" || die "the gate refuses this plan at apply time"
    jq -n --arg run "$RUN" '{apply_run_id: $run}' > "$WORK/attempt.json"
    put_once "$PLAN_RUN/apply-attempt.json" "$WORK/attempt.json"   # one attempt per plan, ever
    rc=0; "$TF" -chdir="$STACK" apply -input=false -no-color -lock-timeout=120s "$WORK/tfplan" >/dev/null 2>"$WORK/apply.err" || rc=$?
    jq -n --arg run "$RUN" --argjson rc "$rc" '{apply_run_id: $run, exit_code: $rc}' > "$WORK/result.json"
    put_once "$PLAN_RUN/apply-result.json" "$WORK/result.json"
    [ $rc = 0 ] || { put_once "$PLAN_RUN/apply.err" "$WORK/apply.err"; die "apply failed (exit $rc); the error is in the plan store; reconcile and plan again"; }
    echo "## Hosted session-pipeline apply: plan \`$PLAN_RUN\` (\`$APPROVED\`) applied" > "$WORK/summary.md"
    ;;
  *) die "usage: plan|apply ..." ;;
esac
