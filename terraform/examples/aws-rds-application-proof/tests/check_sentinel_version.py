"""Evaluate the actual postcondition with typed values, offline and provider-free.

Terraform mocks expose overridden computed values at apply; OpenTofu 1.11 mocks
expose them at plan. Their expected-failure handling differs for a failed apply
postcondition. Console evaluation exercises the same source expression in both
engines without rewriting test cases or making any provider/cloud request.
"""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sentinel = (root / "main.tf").read_text().split('resource "aws_s3_object" "sentinel" {', 1)[1].split('resource "aws_db_snapshot"', 1)[0]
conditions = re.findall(r"^\s*condition\s*=\s*(.+)$", sentinel, re.MULTILINE)
if len(conditions) != 1 or "self.version_id" not in conditions[0]:
    raise SystemExit("Missing unique sentinel version postcondition")
engine = sys.argv[1] if len(sys.argv) > 1 else "terraform"
scratch = root / ".terraform"
scratch.mkdir(exist_ok=True)
cases = [(None, False), ("", False), ("  ", False), ("null", False), ("synthetic-version", True), ("opaque+/=.v1", True)]
with tempfile.TemporaryDirectory(prefix="sentinel-condition-", dir=scratch) as directory:
    for value, expected in cases:
        expression = conditions[0].replace("self.version_id", json.dumps(value))
        result = subprocess.run([engine, "console", "-no-color"], input=expression + "\n", text=True, capture_output=True, cwd=directory, check=True, timeout=30)
        if result.stdout.strip() != str(expected).lower():
            raise SystemExit("Sentinel version postcondition accepted an invalid reference or refused a valid one")
print(json.dumps({"ok": True, "typed_version_cases": len(cases), "provider_requests": 0}))
