#!/usr/bin/env bash
# Offline smoke test of session-pipeline-ci.sh with stub terraform and aws binaries (no AWS, no Terraform state).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); SCRIPT=$HERE/../session-pipeline-ci.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/s3"
cat > "$T/bin/aws" <<'A'
#!/usr/bin/env bash
set -euo pipefail
S3=$STUB_S3
case "$1 $2" in
  "ssm get-parameter") jq -n --arg v "$(cat "$STUB_TFVARS")" '{Parameter: {Version: 3, Value: $v}}' ;;
  "s3api put-object")
    key=; body=; while [ $# -gt 0 ]; do case "$1" in --key) key=$2; shift;; --body) body=$2; shift;; esac; shift; done
    f="$S3/$(echo "$key" | tr / _)"; [ -e "$f" ] && { echo "PreconditionFailed" >&2; exit 254; }; cp "$body" "$f" ;;
  "s3api get-object")
    key=$6; out=$7; cp "$S3/$(echo "$key" | tr / _)" "$out" ;;
  *) echo "unexpected aws $*" >&2; exit 2 ;;
esac
A
cat > "$T/bin/terraform" <<'B'
#!/usr/bin/env bash
set -euo pipefail
for a in "$@"; do case "$a" in -out=*) echo "planbytes" > "${a#-out=}";; esac; done
case " $* " in
  *" init "*) exit 0 ;;
  *" plan "*) exit 0 ;;
  *" show -json "*) cat "$STUB_PLAN_JSON" ;;
  *" show -no-color "*) echo "plan text" ;;
  *" apply "*) echo applied >> "$STUB_S3/applied" ;;
esac
B
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" TF_BIN=terraform STUB_S3=$T/s3
export AWS_REGION=us-east-1 STATE_BUCKET=b STATE_KEY=hosted/session-pipeline.tfstate STATE_KMS_KEY_ARN=k TFVARS_PARAMETER=/p
echo '{"account_id":"111111111111"}' > "$T/vars"; export STUB_TFVARS=$T/vars
ESM=aws_lambda_event_source_mapping.events
export GATE_ALLOW="module.pipeline.$ESM:scaling_config.0.maximum_concurrency=20->25"
mk() { jq -n --argjson b "$1" --argjson a "$2" '{complete: true, errored: false, applyable: true, resource_changes: [
  {address: "module.pipeline.aws_lambda_event_source_mapping.events", change: {actions: ["update"], before: {scaling_config: [{maximum_concurrency: $b}]}, after: {scaling_config: [{maximum_concurrency: $a}]}, after_unknown: {}, importing: {id: "u"}}},
  {address: "aws_sqs_queue_policy.events", change: {actions: ["no-op"], before: {}, after: {}, importing: {id: "q"}}}]}' > "$T/plan.json"; }
export STUB_PLAN_JSON=$T/plan.json

mk 20 25
"$SCRIPT" plan "$T/w1" 100-1 >/dev/null
grep -q "Gate | PASS" "$T/w1/summary.md" || { echo "FAIL: approved plan should pass"; exit 1; }
sha=$(sha256sum "$T/w1/tfplan" | cut -d' ' -f1)
"$SCRIPT" apply "$T/a1" 200-1 100-1 "$sha" >/dev/null
[ "$(cat "$T/s3/applied")" = applied ] || { echo "FAIL: apply did not run"; exit 1; }
if "$SCRIPT" apply "$T/a2" 201-1 100-1 "$sha" >/dev/null 2>&1; then echo "FAIL: second apply of one plan allowed"; exit 1; fi

mk 20 30
if "$SCRIPT" plan "$T/w2" 101-1 >/dev/null 2>&1; then echo "FAIL: unapproved change passed"; exit 1; fi
grep -q "Gate | REFUSED" "$T/w2/summary.md" || { echo "FAIL: refused plan not reported"; exit 1; }
sha2=$(sha256sum "$T/w2/tfplan" | cut -d' ' -f1)
if "$SCRIPT" apply "$T/a3" 202-1 101-1 "$sha2" >/dev/null 2>&1; then echo "FAIL: refused plan applied"; exit 1; fi

mk 20 25
"$SCRIPT" plan "$T/w3" 102-1 >/dev/null
if "$SCRIPT" apply "$T/a4" 203-1 102-1 "$(printf '0%.0s' {1..64})" >/dev/null 2>&1; then echo "FAIL: wrong digest applied"; exit 1; fi
mk 20 30   # live drifted between plan and apply: the apply-time gate refuses
sha3=$(sha256sum "$T/w3/tfplan" | cut -d' ' -f1)
if "$SCRIPT" apply "$T/a5" 204-1 102-1 "$sha3" >/dev/null 2>&1; then echo "FAIL: apply-time gate not enforced"; exit 1; fi
GATE_ALLOW="" ; export GATE_ALLOW
if "$SCRIPT" apply "$T/a6" 205-1 102-1 "$sha3" >/dev/null 2>&1; then echo "FAIL: changed GATE_ALLOW accepted"; exit 1; fi
! grep -rq "111111111111" "$T/w1/summary.md" || { echo "FAIL: account id in summary"; exit 1; }
echo "smoke: 8 checks passed"
