"""Prove this example plans byte-identical after modules/aws/search
and modules/aws/postgres gained `enabled` (default true), and that its own
root-level enable_search = false still leaves no search object behind.

The golden digests in default-plan.golden.json were recorded from origin/main
(before `enabled`). The only alias is the search domain policy, which the
module's moved block renames this -> this[0]. All providers are mocked; no AWS
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
MOVED = {SEARCH + "aws_opensearch_domain_policy.this[0]": SEARCH + "aws_opensearch_domain_policy.this"}
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
