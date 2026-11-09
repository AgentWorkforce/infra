#!/usr/bin/env python3
"""Deployment retirement preserves every other rendered object."""
import json
import subprocess
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
CHARTS = ("relayauth", "relayhistory", "session-ingest-api")


def render(chart, extra=()):
    return subprocess.run([
        "helm", "template", "retained", str(ROOT / "charts" / chart),
        "--namespace", "retained", "--no-hooks", "-f",
        str(ROOT / "charts" / chart / "ci/default-values.yaml"), *extra,
    ], capture_output=True, text=True)


def objects(result):
    if result.returncode:
        raise AssertionError(result.stderr)
    docs = [v for v in yaml.safe_load_all(result.stdout) if v]
    return {(v["kind"], v["metadata"]["name"]): v for v in docs}


class RetainedWorkloads(unittest.TestCase):
    def test_defaults_equal_explicit_enabled(self):
        for chart in CHARTS:
            with self.subTest(chart=chart):
                baseline = objects(render(chart))
                enabled = objects(render(chart, ["--set", "deployment.enabled=true"]))
                self.assertEqual(baseline, enabled)
                self.assertEqual(sum(k[0] == "Deployment" for k in baseline), 1)

    def test_disabled_omits_only_deployment(self):
        for chart in CHARTS:
            with self.subTest(chart=chart):
                baseline = objects(render(chart))
                disabled = objects(render(chart, ["--set", "deployment.enabled=false"]))
                self.assertEqual(disabled, {k: v for k, v in baseline.items()
                                            if k[0] != "Deployment"})
                self.assertTrue(any(k[0] == "Service" for k in disabled))
                self.assertFalse(any(k[0] == "Secret" for k in disabled))
                if chart == "relayauth":
                    self.assertTrue(any(k[0] == "PersistentVolumeClaim" for k in disabled))

    def test_schema_refuses_non_boolean_or_missing_selection(self):
        for chart in CHARTS:
            for value in ('"false"', '0', '[]', '{}', 'null'):
                with self.subTest(chart=chart, value=value):
                    result = render(chart, ["--set-json", "deployment.enabled=" + value])
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("deployment", result.stderr)

    def test_template_also_refuses_non_boolean_when_schema_skipped(self):
        for chart in CHARTS:
            with self.subTest(chart=chart):
                result = render(chart, ["--skip-schema-validation", "--set-string",
                                        "deployment.enabled=false"])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("deployment.enabled must be a boolean", result.stderr)

    def test_disabled_does_not_skip_existing_secret_validation(self):
        for chart, missing in (("relayauth", "existingSecret"),
                               ("relayhistory", "database.existingSecret"),
                               ("session-ingest-api", "existingSecret")):
            with self.subTest(chart=chart):
                result = render(chart, ["--set", "deployment.enabled=false",
                                        "--set", missing + "="])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(missing, result.stderr)

    def test_umbrella_retirement_removes_exact_five_and_keeps_all_others(self):
        command = ["helm", "template", "retained", "charts/agent-relay", "-n", "retained",
                   "--no-hooks", "-f", "charts/agent-relay/values-gcp-proof.yaml",
                   "-f", "charts/agent-relay/ci/gcp-proof-values.yaml"]
        baseline = objects(subprocess.run(command, cwd=ROOT, capture_output=True, text=True))
        settings = {
            "relayauth.deployment.enabled": False,
            "relayhistory.deployment.enabled": False,
            "sessions-pipeline.alleyoop.deployment.enabled": False,
            "sessions-pipeline.worker.components.bob-costas.enabled": False,
            "sessions-pipeline.worker.components.referee.enabled": False,
        }
        args = [part for key, value in settings.items()
                for part in ("--set-json", key + "=" + json.dumps(value))]
        disabled = objects(subprocess.run(command + args, cwd=ROOT, capture_output=True, text=True))
        removed = {k for k in baseline if k not in disabled}
        self.assertEqual(len(removed), 5)
        self.assertTrue(all(k[0] == "Deployment" for k in removed))
        self.assertEqual(disabled, {k: v for k, v in baseline.items() if k not in removed})
        self.assertIn(("PersistentVolumeClaim", "relayauth-data"), disabled)
        for service in ("relayauth", "relayhistory", "relaycast"):
            self.assertIn(("Service", service), disabled)


if __name__ == "__main__":
    unittest.main()
