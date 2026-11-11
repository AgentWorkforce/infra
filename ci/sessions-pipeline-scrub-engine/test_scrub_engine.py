#!/usr/bin/env python3
"""Render-time contract tests for the shared self-host scrub engine."""

from __future__ import annotations

import subprocess
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
CHART = ROOT / "charts/sessions-pipeline"
DEFAULT = CHART / "ci/default-values.yaml"
AWS_PROFILE = CHART / "profiles/aws-rds-native.yaml"
AWS_INPUTS = CHART / "ci/aws-rds-native-inputs.yaml"
AGENT_CHART = ROOT / "charts/agent-relay"
GCP = AGENT_CHART / "values-gcp.yaml"
GCP_NATIVE = AGENT_CHART / "values-gcp-native.yaml"
GCP_NATIVE_INPUTS = AGENT_CHART / "ci/gcp-native-values.yaml"
EKS = AGENT_CHART / "values-eks.yaml"
CUTOVER = AGENT_CHART / "values-scrub-wasm-bindgen.yaml"
MANAGED = {"SCRUB_ENGINE", "SCRUB_ENGINE_REQUIRED", "READER_MAX_RULESET"}


def helm(*args: str, values: tuple[Path, ...] = (DEFAULT,)) -> subprocess.CompletedProcess[str]:
    command = ["helm", "template", "scrub-ci", str(CHART)]
    for value in values:
        command.extend(["-f", str(value)])
    command.extend(args)
    return subprocess.run(command, text=True, capture_output=True)


def helm_agent(*values: Path) -> subprocess.CompletedProcess[str]:
    command = ["helm", "template", "scrub-ci", str(AGENT_CHART)]
    for value in values:
        command.extend(["-f", str(value)])
    return subprocess.run(command, text=True, capture_output=True)


def service_envs(rendered: str) -> list[tuple[str, dict[str, str]]]:
    found: list[tuple[str, dict[str, str]]] = []
    for document in yaml.safe_load_all(rendered):
        if not isinstance(document, dict) or document.get("kind") not in {
            "Deployment",
            "Job",
        }:
            continue
        template = document.get("spec", {}).get("template", {})
        pod = template.get("spec", {})
        for container in pod.get("initContainers", []) + pod.get("containers", []):
            env = {
                entry["name"]: str(entry.get("value", ""))
                for entry in container.get("env", [])
                if isinstance(entry, dict) and "name" in entry
            }
            if "SERVICE" in env:
                found.append(
                    (
                        f'{document["kind"]}/{document["metadata"]["name"]}:{container["name"]}',
                        env,
                    )
                )
    return found


class ScrubEngineContractTest(unittest.TestCase):
    maxDiff = None

    def assert_contract(
        self,
        result: subprocess.CompletedProcess[str],
        expected: dict[str, str],
        minimum_services: int,
    ) -> None:
        self.assertEqual(result.returncode, 0, result.stderr)
        services = service_envs(result.stdout)
        self.assertGreaterEqual(len(services), minimum_services)
        for workload, env in services:
            managed = {name: env[name] for name in MANAGED if name in env}
            self.assertEqual(managed, expected, workload)

    def assert_refused(self, message: str, *args: str) -> None:
        result = helm(*args)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)

    def test_defaults_preserve_legacy_engine_and_ceiling(self) -> None:
        self.assert_contract(helm(), {}, minimum_services=6)

    def test_reader_first_reaches_every_aws_services_workload(self) -> None:
        self.assert_contract(
            helm(
                "--set-string",
                "global.scrubEngine.readerMaxRuleset=10",
                values=(AWS_PROFILE, AWS_INPUTS),
            ),
            {"READER_MAX_RULESET": "10"},
            minimum_services=8,
        )

    def test_cutover_reaches_every_aws_services_workload(self) -> None:
        self.assert_contract(
            helm(
                "--set-string",
                "global.scrubEngine.engine=wasm-bindgen",
                "--set-string",
                "global.scrubEngine.required=wasm-bindgen",
                "--set-string",
                "global.scrubEngine.readerMaxRuleset=10",
                values=(AWS_PROFILE, AWS_INPUTS),
            ),
            {
                "SCRUB_ENGINE": "wasm-bindgen",
                "SCRUB_ENGINE_REQUIRED": "wasm-bindgen",
                "READER_MAX_RULESET": "10",
            },
            minimum_services=8,
        )

    def test_customer_profiles_are_reader_first(self) -> None:
        for profile in (GCP, EKS):
            with self.subTest(profile=profile.name):
                self.assert_contract(
                    helm_agent(profile),
                    {"READER_MAX_RULESET": "10"},
                    minimum_services=5,
                )

    def test_customer_cutover_overlay_reaches_native_gcp_workloads(self) -> None:
        self.assert_contract(
            helm_agent(GCP, GCP_NATIVE, GCP_NATIVE_INPUTS, CUTOVER),
            {
                "SCRUB_ENGINE": "wasm-bindgen",
                "SCRUB_ENGINE_REQUIRED": "wasm-bindgen",
                "READER_MAX_RULESET": "10",
            },
            minimum_services=8,
        )

    def test_refuses_unreviewed_engine(self) -> None:
        self.assert_refused(
            "global.scrubEngine.engine must be empty or wasm-bindgen",
            "--set-string",
            "global.scrubEngine.engine=ts",
        )

    def test_refuses_boolean_engine(self) -> None:
        self.assert_refused(
            "global.scrubEngine.engine must be empty or wasm-bindgen",
            "--set",
            "global.scrubEngine.engine=false",
        )

    def test_refuses_numeric_ceiling(self) -> None:
        self.assert_refused(
            "global.scrubEngine.readerMaxRuleset must be empty or the string 8, 9, or 10",
            "--set",
            "global.scrubEngine.readerMaxRuleset=10",
        )

    def test_refuses_bindgen_before_ceiling_ten(self) -> None:
        self.assert_refused(
            'global.scrubEngine.engine=wasm-bindgen requires global.scrubEngine.readerMaxRuleset="10"',
            "--set-string",
            "global.scrubEngine.engine=wasm-bindgen",
            "--set-string",
            "global.scrubEngine.readerMaxRuleset=9",
        )

    def test_refuses_required_engine_mismatch(self) -> None:
        self.assert_refused(
            "global.scrubEngine.required must be empty or equal global.scrubEngine.engine",
            "--set-string",
            "global.scrubEngine.required=wasm-bindgen",
        )


if __name__ == "__main__":
    unittest.main()
