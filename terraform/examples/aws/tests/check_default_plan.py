"""Prove this example plans byte-identical after modules/aws/search
and modules/aws/postgres gained `enabled` (default true), and that its own
root-level enable_search = false still leaves no search object behind.

The golden digests in default-plan.golden.json were recorded from origin/main
(before `enabled`). The aliases are the search domain policy and the functions resources counted
for adopt mode, which their modules' moved blocks rename X -> X[0]. All providers are mocked; no AWS
request is made.

    python3 tests/check_default_plan.py terraform|tofu [--write]
"""
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = "tests/default-plan.tftest.hcl"
GOLDEN = ROOT / "tests/default-plan.golden.json"
_SPEC = importlib.util.spec_from_file_location("golden_plan", ROOT.parents[1] / "scripts/golden_plan.py")
golden = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(golden)

SEARCH = "module.search[0]."
FUNCTIONS = "module.functions[0]."
# modules/aws/functions counted these for adopt mode; its moved blocks rename each X -> X[0] in state.
FUNCTIONS_COUNTED = [
    "aws_cloudwatch_log_group.this", "aws_cloudwatch_metric_alarm.backlog_age", "aws_cloudwatch_metric_alarm.dlq_not_empty",
    "aws_cloudwatch_metric_alarm.errors", "aws_lambda_function.this", "aws_lambda_function_event_invoke_config.this",
    "aws_lambda_permission.brief", "aws_lambda_permission.reconcile", "aws_sqs_queue_policy.dlq", "aws_sqs_queue_policy.events",
]
MOVED = {SEARCH + "aws_opensearch_domain_policy.this[0]": SEARCH + "aws_opensearch_domain_policy.this",
         **{FUNCTIONS + r + "[0]": FUNCTIONS + r for r in FUNCTIONS_COUNTED}}
SEARCH_ON = {SEARCH + "aws_opensearch_domain_policy.this[0]", SEARCH + "aws_opensearch_domain.this[0]", SEARCH + 'aws_iam_role.workload["indexer"]', SEARCH + 'aws_iam_role.workload["reader"]'}


def main(engine, write):
    found, summary = golden.check(ROOT, engine, FIXTURE, GOLDEN, MOVED, write)
    if not write:
        on = {r["address"] for r in found["default_all_add_ons"]["resource_changes"]}
        golden.require(SEARCH_ON <= on, "Search on must plan the indexed domain policy, domain and both workload roles")
        off = [r["address"] for r in found["search_off"]["resource_changes"] if r["address"].startswith("module.search")]
        golden.require(not off, "enable_search = false left search objects: " + str(off))
        summary.update(search_off_search_objects=0)
    print(json.dumps(summary))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "terraform", "--write" in sys.argv[2:])
