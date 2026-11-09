"""Inspect actual mocked Lambda plan values, never just convenience outputs.

Run after init -backend=false with the selected engine. Terraform needs its
plan-time computed mock flag; OpenTofu 1.11 already provides computed fixtures
at plan and rejects that flag. The two plan-only fixtures must otherwise match.
All providers are mocked; this makes no AWS, SDK, credential or backend request.
"""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
FUNCTION = "module.pipeline[0].aws_lambda_function.this"
DOMAIN = "module.search.aws_opensearch_domain.this[0]"
RUN = "actual_lambda_environment"


def require(value, message):
    if not value:
        raise SystemExit(message)


def unknown(value):
    if isinstance(value, dict):
        return any(unknown(v) for v in value.values())
    if isinstance(value, list):
        return any(unknown(v) for v in value)
    require(value is None or type(value) is bool, "Malformed native unknown metadata")
    return value is True


def main(engine):
    fixture = ROOT / "tests/lambda-environment.tftest.hcl"
    tofu_fixture = fixture.with_suffix(".hcl").with_name("lambda-environment.tofutest.hcl")
    tf_text = fixture.read_text()
    require(tf_text.count("  override_during = plan\n") == 1 and tf_text.replace("  override_during = plan\n", "", 1) == tofu_fixture.read_text(), "Computed fixture parity changed")
    selected = tofu_fixture if Path(engine).name == "tofu" else fixture
    relative = str(selected.relative_to(ROOT))
    result = subprocess.run([engine, "test", "-filter=" + relative, "-json", "-verbose"], cwd=ROOT, capture_output=True, text=True, timeout=120)
    require(result.returncode == 0, "Native mock test failed: " + result.stderr[-2000:])
    events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
    plans = [e["test_plan"] for e in events if e.get("type") == "test_plan" and e.get("@testfile") == relative and e.get("@testrun") == RUN]
    require(len(plans) == 1, "Missing or duplicate selected native plan")
    rows = plans[0].get("resource_changes")
    require(isinstance(rows, list), "Missing native resource changes")
    def one(address):
        matches = [r for r in rows if r.get("address") == address]
        require(len(matches) == 1 and isinstance(matches[0].get("change"), dict), "Missing or duplicate actual resource: " + address)
        return matches[0]["change"]
    function, domain = one(FUNCTION), one(DOMAIN)
    endpoint = domain["after"].get("endpoint")
    require(endpoint == "vpc-mock.us-west-2.es.amazonaws.com" and not unknown(domain.get("after_unknown", {}).get("endpoint")), "Computed Search endpoint unknown/malformed")
    environment = function["after"].get("environment")
    require(isinstance(environment, list) and len(environment) == 1 and isinstance(environment[0], dict) and isinstance(environment[0].get("variables"), dict), "Actual Lambda environment missing/malformed")
    require(not unknown(function.get("after_unknown", {}).get("environment")), "Actual Lambda environment contains unknown values")
    values = environment[0]["variables"]
    expected = {
        "PIPELINE_RUNTIME": "lambda", "SEARCH_INDEX_BACKEND": "opensearch",
        "OPENSEARCH_ENDPOINT": "https://" + endpoint, "OPENSEARCH_REGION": "us-west-2",
        "OPENSEARCH_INDEX": "agent-relay-dev-sessions-v2",
        "SEARCH_INDEX_STATE_BACKEND_ID": "agent-relay-dev-sessions",
        "READ_API_COMPLETE_SINCE": "epoch", "SEARCH_INDEX_POSTGRES_SCHEMA": "search_index",
        "SESSION_POSTGRES_TLS_PROFILE": "custom-ca", "SESSION_POSTGRES_CA_FILE": "/var/task/assets/postgres-ca.pem",
        "SESSION_POSTGRES_CA_SHA256": "a" * 64,
    }
    require(all(values.get(k) == v for k, v in expected.items()), "Actual Lambda resource lost or changed a provider/TLS binding")
    require("AWS_REGION" not in values, "Reserved AWS_REGION must not be configured")
    mapping = one("module.pipeline[0].aws_lambda_event_source_mapping.events")
    require(mapping["after"].get("enabled") is False and not unknown(mapping.get("after_unknown", {}).get("enabled")), "Unqualified shared-database queue processing was activated")
    for rule in ("reconcile", "brief"):
        change = one("module.pipeline[0].aws_cloudwatch_event_rule." + rule)
        require(change["after"].get("state") == "DISABLED" and not unknown(change.get("after_unknown", {}).get("state")), "Unqualified shared-database schedule was activated")
    print(json.dumps({"ok": True, "resource": FUNCTION, "binding_count": len(expected), "computed_endpoint_matches_domain": True, "reserved_aws_region_absent": True, "automatic_processing_inactive": True, "provider_requests": 0}))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "terraform")
