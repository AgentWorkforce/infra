#!/usr/bin/env bash
# GitHub side of a Terraform state planned and applied from CI (docs/selfhost-ci-terraform.md). It wraps
# terraform/scripts/aws-environment.py (the saved-plan runner) so plan and apply can run in separate workflow
# runs, with AWS credentials from the ci-terraform module's OIDC roles.
#
#   ci-terraform.sh plan  <ci.json> <tools checkout> <work dir> <run id>
#   ci-terraform.sh apply <ci.json> <tools checkout> <work dir> <run id> <plan run id> <plan sha256>
#
# ci.json (non-secret): account_id, aws_region, tools_ref, tfvars_parameter, backend {...} (the runner's backend
# JSON), plan_store {bucket, prefix, kms_key_arn}.
# TOOLS_REF (environment) must equal ci.json tools_ref and the tools checkout's HEAD.
#
# plan : fetch the tfvars (SSM SecureString, by version), run the runner's plan, then save the runner's private
#        run directory (saved plan, receipt, derived variables) to s3://<plan_store>/<run id>/run.tgz with a
#        manifest. Writes <work>/out/{summary.md,changes.json,plan.txt,outputs}. Nothing secret is written there:
#        changes.json holds addresses and actions only, plan.txt is Terraform's redacted rendering.
# apply: fetch that manifest and run.tgz, check the approved plan digest, tools ref, backend and tfvars version
#        match it, claim the plan (apply-attempt.json, If-None-Match: one attempt per plan, ever), restore the run
#        directory and run the runner's apply --approve-plan. Terraform refuses a saved plan whose state changed
#        since planning ("stale"), so a plan is applied only against the exact state it was made from.
set -euo pipefail
umask 077

die() { echo "ci-terraform: $*" >&2; exit 1; }
sha256() { sha256sum "$1" | cut -d' ' -f1; }
cfg() { jq -er "$1" "$CONFIG"; }

setup() {
  CONFIG=$(realpath "$1"); TOOLS=$(realpath "$2"); WORK=$3; RUN_ID=$4
  [[ "$RUN_ID" =~ ^[0-9]+-[0-9]+$ ]] || die "run id must be <run_id>-<attempt>"
  [[ "${TOOLS_REF:-}" =~ ^[0-9a-f]{40}$ ]] || die "TOOLS_REF must be a full commit"
  [ "$(cfg .tools_ref)" = "$TOOLS_REF" ] || die "ci.json tools_ref differs from TOOLS_REF"
  [ "$(git -C "$TOOLS" rev-parse HEAD)" = "$TOOLS_REF" ] || die "tools checkout is not at TOOLS_REF"
  ACCOUNT=$(cfg .account_id); REGION=$(cfg .aws_region); PARAM=$(cfg .tfvars_parameter)
  BUCKET=$(cfg .plan_store.bucket); PREFIX=$(cfg .plan_store.prefix); STORE_KEY=$(cfg .plan_store.kms_key_arn)
  [[ "$ACCOUNT" =~ ^[0-9]{12}$ ]] || die "account_id"
  [ "$(cfg .backend.region)" = "$REGION" ] || die "backend region differs from aws_region"
  export AWS_REGION=$REGION AWS_DEFAULT_REGION=$REGION
  mkdir -p "$WORK"; WORK=$(realpath "$WORK")
  mkdir -p "$WORK/inputs" "$WORK/runs" "$WORK/out"
  VARS=$WORK/inputs/variables.json; BACKEND=$WORK/inputs/backend.json
  # Same bytes in plan and apply: the runner binds the backend file's digest.
  jq -c .backend "$CONFIG" > "$BACKEND"
  RUNNER=$TOOLS/terraform/scripts/aws-environment.py
  STACK=$TOOLS/terraform/examples/aws-environments
}

# fetch_tfvars [version]: the value goes to $VARS only, never to stdout.
fetch_tfvars() {
  local name=$PARAM resp
  [ -n "${1:-}" ] && name="$PARAM:$1"
  resp=$(aws ssm get-parameter --name "$name" --with-decryption --output json) || die "cannot read $name"
  TFVARS_VERSION=$(jq -er .Parameter.Version <<<"$resp")
  jq -j .Parameter.Value <<<"$resp" > "$VARS"
  unset resp
  jq -e 'type == "object"' "$VARS" >/dev/null 2>&1 || die "$PARAM is not a JSON object"
  [ "$(jq -r .account_id "$VARS")" = "$ACCOUNT" ] && [ "$(jq -r .region "$VARS")" = "$REGION" ] \
    || die "$PARAM account_id/region differ from ci.json"
  ENVIRONMENT=$(jq -er .environment "$VARS")
  RUN_DIR=$WORK/runs/$ACCOUNT/$REGION/$ENVIRONMENT
}

s3_put_once() {  # bucket key file: fails if the object exists
  aws s3api put-object --bucket "$BUCKET" --key "$1" --body "$2" --if-none-match '*' \
    --server-side-encryption aws:kms --ssekms-key-id "$STORE_KEY" >/dev/null
}

case "${1:-}" in
  plan)
    [ $# = 5 ] || die "usage: plan <ci.json> <tools> <work> <run id>"
    setup "$2" "$3" "$4" "$5"
    fetch_tfvars
    [ ! -e "$RUN_DIR" ] || die "$RUN_DIR exists: use a fresh work dir"
    python3 "$RUNNER" plan --variables "$VARS" --backend "$BACKEND" --run-dir "$WORK/runs"
    receipt=$RUN_DIR/plan-receipt.json
    plan=$(jq -er .plan_path "$receipt"); plan_sha=$(jq -er .plan_sha256 "$receipt")
    [ "$(sha256 "$plan")" = "$plan_sha" ] || die "saved plan does not match its receipt"
    tf=(env -u TF_WORKSPACE TF_IN_AUTOMATION=1 TF_INPUT=0 "TF_DATA_DIR=$RUN_DIR/.terraform" "TF_CLI_CONFIG_FILE=$RUN_DIR/terraform.rc" "${TF_BIN:-terraform}" "-chdir=$STACK")
    out=$WORK/out
    # The JSON plan holds sensitive values in clear: it is only piped through jq, never stored.
    "${tf[@]}" show -json "$plan" | jq '{
        resources: [.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])
                    | {address, actions: .change.actions}],
        outputs: [(.output_changes // {}) | to_entries[] | select(.value.actions != ["no-op"]) | {name: .key, actions: .value.actions}]
      }' > "$out/changes.json"
    "${tf[@]}" show -no-color "$plan" > "$out/plan.txt"
    tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --format=gnu \
      --exclude=./.terraform --exclude=./operation.lock -C "$RUN_DIR" -cf - . | gzip -n > "$out/run.tgz"
    changed=$(jq '(.resources + .outputs) | length > 0' "$out/changes.json")
    jq -n --arg run "$RUN_ID" --arg tools "$TOOLS_REF" --arg acct "$ACCOUNT" --arg region "$REGION" \
      --arg env "$ENVIRONMENT" --arg state "$(cfg .backend.key)" --arg backend "$(sha256 "$BACKEND")" \
      --arg param "$PARAM" --arg ver "$TFVARS_VERSION" --arg vars "$(sha256 "$VARS")" --arg plan "$plan_sha" \
      --arg tgz "$(sha256 "$out/run.tgz")" --argjson changed "$changed" --arg sha "${GITHUB_SHA:-}" \
      '{schema_version: 1, plan_run_id: $run, tools_ref: $tools, caller_sha: $sha, account_id: $acct, region: $region,
        environment: $env, state_key: $state, backend_sha256: $backend, tfvars_parameter: $param,
        tfvars_version: $ver, tfvars_sha256: $vars, plan_sha256: $plan, run_tgz_sha256: $tgz, changes: $changed}' \
      > "$out/manifest.json"
    s3_put_once "$PREFIX/$RUN_ID/run.tgz" "$out/run.tgz"
    s3_put_once "$PREFIX/$RUN_ID/manifest.json" "$out/manifest.json"
    rm -f "$out/run.tgz"
    {
      echo "## Terraform plan: $ENVIRONMENT ($ACCOUNT, $REGION)"
      echo
      echo "| | |"; echo "|---|---|"
      echo "| Plan run id | \`$RUN_ID\` |"
      echo "| Plan SHA-256 | \`$plan_sha\` |"
      echo "| State | \`s3://$(cfg .backend.bucket)/$(cfg .backend.key)\` |"
      echo "| tfvars | \`$PARAM\` version $TFVARS_VERSION (sha256 \`$(sha256 "$VARS")\`) |"
      echo "| infra (tools_ref) | \`$TOOLS_REF\` |"
      echo
      if [ "$changed" = true ]; then
        jq -r '"\(.resources | map(select(.actions | index("create"))) | length) to create, \(.resources | map(select(.actions | index("update"))) | length) to update, \(.resources | map(select(.actions | index("delete"))) | length) to delete (replacements count in both)."' "$out/changes.json"
        echo; echo '```'
        jq -r '.resources[] | "\(.actions | join("/"))  \(.address)"' "$out/changes.json"
        jq -r '.outputs[] | "output \(.actions | join("/"))  \(.name)"' "$out/changes.json"
        echo '```'
        echo
        echo "Apply exactly this plan: dispatch mode \`apply\` with plan_run_id \`$RUN_ID\` and plan_sha256 \`$plan_sha\`."
      else
        echo "No changes."
      fi
    } > "$out/summary.md"
    printf 'plan_sha256=%s\nchanges=%s\nplan_run_id=%s\n' "$plan_sha" "$changed" "$RUN_ID" > "$out/outputs"
    ;;
  apply)
    [ $# = 7 ] || die "usage: apply <ci.json> <tools> <work> <run id> <plan run id> <plan sha256>"
    setup "$2" "$3" "$4" "$5"
    PLAN_RUN=$6; APPROVED=$7
    [[ "$PLAN_RUN" =~ ^[0-9]+-[0-9]+$ ]] || die "plan run id must be <run_id>-<attempt> from the plan summary"
    [[ "$APPROVED" =~ ^[0-9a-f]{64}$ ]] || die "plan sha256 must be the 64-hex digest from the plan summary"
    in=$WORK/plan; mkdir -p "$in"
    aws s3api get-object --bucket "$BUCKET" --key "$PREFIX/$PLAN_RUN/manifest.json" "$in/manifest.json" >/dev/null \
      || die "no saved plan $PLAN_RUN"
    m() { jq -er "$1" "$in/manifest.json"; }
    [ "$(m .schema_version)" = 1 ] || die "unsupported manifest"
    [ "$(m .plan_sha256)" = "$APPROVED" ] || die "plan $PLAN_RUN has digest $(m .plan_sha256), not the approved $APPROVED"
    [ "$(m .changes)" = true ] || die "plan $PLAN_RUN has no changes: nothing to apply"
    [ "$(m .tools_ref)" = "$TOOLS_REF" ] || die "plan was made with infra $(m .tools_ref); ci.json now pins $TOOLS_REF: plan again"
    [ "$(m .account_id)" = "$ACCOUNT" ] && [ "$(m .region)" = "$REGION" ] || die "plan belongs to another account/region"
    [ "$(m .backend_sha256)" = "$(sha256 "$BACKEND")" ] || die "backend changed since the plan: plan again"
    [ "$(m .tfvars_parameter)" = "$PARAM" ] || die "tfvars parameter changed since the plan: plan again"
    aws s3api get-object --bucket "$BUCKET" --key "$PREFIX/$PLAN_RUN/run.tgz" "$in/run.tgz" >/dev/null
    [ "$(sha256 "$in/run.tgz")" = "$(m .run_tgz_sha256)" ] || die "run.tgz does not match its manifest"
    fetch_tfvars "$(m .tfvars_version)"
    [ "$(sha256 "$VARS")" = "$(m .tfvars_sha256)" ] || die "tfvars version $(m .tfvars_version) does not match the plan"
    [ "$ENVIRONMENT" = "$(m .environment)" ] || die "environment differs from the plan"
    [ ! -e "$RUN_DIR" ] || die "$RUN_DIR exists: use a fresh work dir"
    mkdir -p "$RUN_DIR"
    tar -xzf "$in/run.tgz" -C "$RUN_DIR" --no-same-owner
    # One attempt per saved plan, recorded before Terraform runs (the runner does the same locally).
    jq -n --arg run "$RUN_ID" --arg plan "$APPROVED" --arg actor "${GITHUB_ACTOR:-}" \
      '{apply_run_id: $run, plan_sha256: $plan, actor: $actor}' > "$in/apply-attempt.json"
    s3_put_once "$PREFIX/$PLAN_RUN/apply-attempt.json" "$in/apply-attempt.json" \
      || die "plan $PLAN_RUN already had an apply attempt (or the claim failed): reconcile, then plan again"
    rc=0
    python3 "$RUNNER" apply --variables "$VARS" --backend "$BACKEND" --run-dir "$WORK/runs" --approve-plan "$APPROVED" || rc=$?
    jq -n --arg run "$RUN_ID" --argjson rc "$rc" '{apply_run_id: $run, exit_code: $rc}' > "$in/apply-result.json"
    s3_put_once "$PREFIX/$PLAN_RUN/apply-result.json" "$in/apply-result.json" || echo "::warning::could not record apply-result.json"
    {
      echo "## Terraform apply: $ENVIRONMENT ($ACCOUNT, $REGION)"
      echo
      echo "Plan run \`$PLAN_RUN\`, SHA-256 \`$APPROVED\`: exit code $rc."
      [ $rc = 0 ] || echo "Do not retry this plan. Reconcile state and resources, then plan again."
    } > "$WORK/out/summary.md"
    exit $rc
    ;;
  *) sed -n '2,20p' "$0" >&2; exit 2 ;;
esac
