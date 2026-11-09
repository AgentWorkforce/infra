"""Mandatory offline refusal tests for the actual native-plan checker entrypoint.

The baseline models the selected test_plan UI event, not saved-plan history.
Only subprocess execution is mocked; main() reads the real paired fixtures.
Every negative starts from a separate valid baseline and checks its diagnostic.
"""
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "lambda_bindings", Path(__file__).resolve().parents[1]
    / "examples/aws-environments/tests/check_lambda_bindings.py")
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)

# Independent expected public fixture contract: do not derive it from checker
# source or its success output, which would hide a weakened required-binding set.
BINDINGS = {
    "PIPELINE_RUNTIME": "lambda",
    "SEARCH_INDEX_BACKEND": "opensearch",
    "OPENSEARCH_ENDPOINT": "https://vpc-mock.us-west-2.es.amazonaws.com",
    "OPENSEARCH_REGION": "us-west-2",
    "OPENSEARCH_INDEX": "agent-relay-dev-sessions-v2",
    "SEARCH_INDEX_STATE_BACKEND_ID": "agent-relay-dev-sessions",
    "READ_API_COMPLETE_SINCE": "epoch",
    "SEARCH_INDEX_POSTGRES_SCHEMA": "search_index",
    "SESSION_POSTGRES_TLS_PROFILE": "custom-ca",
    "SESSION_POSTGRES_CA_FILE": "/var/task/assets/postgres-ca.pem",
    "SESSION_POSTGRES_CA_SHA256": "a" * 64,
}
FUNCTION = "module.pipeline[0].aws_lambda_function.this"
DOMAIN = "module.search.aws_opensearch_domain.this[0]"
RUN = "actual_lambda_environment"
MAPPING = "module.pipeline[0].aws_lambda_event_source_mapping.events"
RULES = ["module.pipeline[0].aws_cloudwatch_event_rule." + name for name in ("reconcile", "brief")]


def baseline(engine="terraform"):
    suffix = "tofutest.hcl" if Path(engine).name == "tofu" else "tftest.hcl"
    return {
        "type": "test_plan", "@testfile": "tests/lambda-environment." + suffix,
        "@testrun": RUN,
        "test_plan": {"resource_changes": [
            {"address": MAPPING, "change": {"after": {"enabled": False}, "after_unknown": {"enabled": False}}},
            *[{"address": address, "change": {"after": {"state": "DISABLED"}, "after_unknown": {"state": False}}} for address in RULES],
            {"address": FUNCTION, "change": {
                "after": {"environment": [{"variables": dict(BINDINGS)}]},
                "after_unknown": {"environment": [{"variables": {}}]},
            }},
            {"address": DOMAIN, "change": {
                "after": {"endpoint": "vpc-mock.us-west-2.es.amazonaws.com"},
                "after_unknown": {"endpoint": False},
            }},
        ]},
    }


def row(event, address):
    return next(r["change"] for r in event["test_plan"]["resource_changes"]
                if r["address"] == address)


class LambdaBindings(unittest.TestCase):
    def invoke(self, events, engine="terraform", returncode=0, stderr=""):
        # Ordinary non-JSON progress lines and unrelated native events must not
        # substitute for the one specifically selected plan.
        stdout = "native progress\n" + "\n".join(json.dumps(e) for e in events)
        result = subprocess.CompletedProcess([], returncode, stdout, stderr)
        output = io.StringIO()
        with patch.object(checker.subprocess, "run", return_value=result) as run, contextlib.redirect_stdout(output):
            checker.main(engine)
        return run, json.loads(output.getvalue())

    def refuses(self, event, diagnostic):
        with self.assertRaisesRegex(SystemExit, diagnostic):
            self.invoke([event])

    def test_positive_and_exact_cli_for_both_engine_fixtures(self):
        for engine in ["terraform", "/synthetic/tools/terraform", "tofu", "/synthetic/tools/tofu"]:
            with self.subTest(engine=engine):
                event = baseline(engine)
                run, result = self.invoke([{"type": "test_summary"}, event], engine)
                run.assert_called_once_with(
                    [engine, "test", "-filter=" + event["@testfile"], "-json", "-verbose"],
                    cwd=checker.ROOT, capture_output=True, text=True, timeout=120)
                self.assertEqual(result, {
                    "ok": True, "resource": FUNCTION, "binding_count": 11,
                    "computed_endpoint_matches_domain": True,
                    "reserved_aws_region_absent": True, "automatic_processing_inactive": True, "provider_requests": 0,
                })

    def test_missing_or_duplicate_selected_native_plan_refuses(self):
        for events in [[], [baseline(), baseline()]]:
            with self.subTest(count=len(events)), self.assertRaisesRegex(SystemExit, "Missing or duplicate selected native plan"):
                self.invoke(events)

    def test_wrong_file_run_and_event_type_are_not_selected(self):
        for field, value in [("@testfile", "tests/other.tftest.hcl"),
                             ("@testfile", "tests/lambda-environment.tofutest.hcl"),
                             ("@testrun", "other_run"), ("type", "test_state")]:
            with self.subTest(field=field, value=value):
                event = baseline(); event[field] = value
                self.refuses(event, "Missing or duplicate selected native plan")

    def test_unrelated_plans_do_not_make_selected_plan_duplicate(self):
        other = baseline(); other["@testrun"] = "other_run"
        self.assertTrue(self.invoke([other, baseline()])[1]["ok"])

    def test_missing_malformed_resource_inventory_refuses(self):
        event = baseline(); del event["test_plan"]["resource_changes"]
        self.refuses(event, "Missing native resource changes")
        for value in [None, {}, "unknown"]:
            event = baseline(); event["test_plan"]["resource_changes"] = value
            with self.subTest(value=value): self.refuses(event, "Missing native resource changes")

    def test_missing_duplicate_or_malformed_actual_resources_refuse(self):
        for address in [FUNCTION, DOMAIN, MAPPING, *RULES]:
            for mutation in ["missing", "duplicate", "change"]:
                event = baseline(); rows = event["test_plan"]["resource_changes"]
                selected = next(r for r in rows if r["address"] == address)
                if mutation == "missing": rows.remove(selected)
                if mutation == "duplicate": rows.append(copy.deepcopy(selected))
                if mutation == "change": selected["change"] = None
                with self.subTest(address=address, mutation=mutation):
                    self.refuses(event, "Missing or duplicate actual resource")

    def test_missing_or_malformed_environment_refuses(self):
        event = baseline(); del row(event, FUNCTION)["after"]["environment"]
        self.refuses(event, "Actual Lambda environment missing/malformed")
        for value in [None, [], {}, [{}], [{"variables": []}],
                      [{"variables": "unknown"}], [{"variables": {}}, {"variables": {}}]]:
            event = baseline(); row(event, FUNCTION)["after"]["environment"] = value
            with self.subTest(value=value): self.refuses(event, "Actual Lambda environment missing/malformed")

    def test_each_required_binding_missing_or_changed_refuses(self):
        for key in BINDINGS:
            for mutation in ["missing", "changed"]:
                event = baseline(); values = row(event, FUNCTION)["after"]["environment"][0]["variables"]
                if mutation == "missing": del values[key]
                else: values[key] = "wrong-fixture-value"
                with self.subTest(key=key, mutation=mutation):
                    self.refuses(event, "Actual Lambda resource lost or changed a provider/TLS binding")

    def test_unknown_environment_refuses_even_with_all_expected_values(self):
        for value in [True, [{"variables": True}], [{"variables": {"PIPELINE_RUNTIME": True}}]]:
            event = baseline(); row(event, FUNCTION)["after_unknown"]["environment"] = value
            with self.subTest(value=value): self.refuses(event, "Actual Lambda environment contains unknown values")

    def test_wrong_or_unknown_endpoint_refuses(self):
        for value in [None, "vpc-other.us-west-2.es.amazonaws.com", "https://vpc-mock.us-west-2.es.amazonaws.com"]:
            event = baseline(); row(event, DOMAIN)["after"]["endpoint"] = value
            with self.subTest(value=value): self.refuses(event, "Computed Search endpoint unknown/malformed")
        event = baseline(); row(event, DOMAIN)["after_unknown"]["endpoint"] = True
        self.refuses(event, "Computed Search endpoint unknown/malformed")

    def test_reserved_aws_region_refuses_with_all_eleven_bindings_intact(self):
        event = baseline(); row(event, FUNCTION)["after"]["environment"][0]["variables"]["AWS_REGION"] = "us-west-2"
        self.refuses(event, "Reserved AWS_REGION must not be configured")

    def test_malformed_unknown_metadata_is_not_treated_as_known(self):
        for address, key in [(FUNCTION, "environment"), (DOMAIN, "endpoint")]:
            for value in [0, 1, "false", {"nested": [False, "invalid"]}]:
                event = baseline(); row(event, address)["after_unknown"][key] = value
                with self.subTest(address=address, value=value):
                    self.refuses(event, "Malformed native unknown metadata")

    def test_automatic_processing_activation_or_unknown_refuses(self):
        for address, key, active, diagnostic in [(MAPPING, "enabled", True, "queue processing"), *[(r, "state", "ENABLED", "schedule") for r in RULES]]:
            for mutation in ["active", "unknown", "missing"]:
                event = baseline(); change = row(event, address)
                if mutation == "active": change["after"][key] = active
                if mutation == "unknown": change["after_unknown"][key] = True
                if mutation == "missing": del change["after"][key]
                with self.subTest(address=address, mutation=mutation):
                    self.refuses(event, "Unqualified shared-database " + diagnostic + " was activated")

    def test_native_failure_refuses_before_parsing_an_event(self):
        with self.assertRaisesRegex(SystemExit, "Native mock test failed: synthetic native failure"):
            self.invoke([], returncode=1, stderr="synthetic native failure")


if __name__ == "__main__": unittest.main()
