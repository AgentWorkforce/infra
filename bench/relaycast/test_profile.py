import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from plan_replay import compile_plan

HERE = Path(__file__).resolve().parent


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.profile = json.loads((HERE / "profiles/synthetic-example.json").read_text())

    def test_global_peak_is_scaled_once_and_message_counters_are_not_added(self):
        self.profile["rps_peak_minute_max"] = 71.3
        self.profile["burst"]["max_1min_over_avg"] = 9
        self.profile["messages_per_s"]["writes_avg"] = 999
        self.profile["routes"][0]["rps_peak"] = 9999
        plan = compile_plan(self.profile)
        for step, factor in zip(plan["steps"], (1, 3, 10)):
            self.assertAlmostEqual(step["targetPeakRps"], 71.3 * factor)
            self.assertAlmostEqual(sum(r["targetRps"] for r in step["routes"]), step["targetPeakRps"])
            self.assertAlmostEqual(step["routes"][0]["share"], .9)
        self.assertEqual(plan["execution"], "not_run")
        self.assertIsNone(plan["measuredSaturation"])
        self.assertIsNone(plan["oneSecondBurstShape"])
        self.assertIn("ws_connections_peak", plan["assumptions"])

    def test_caps_report_effective_scale_and_preserve_the_mix(self):
        plan = compile_plan(self.profile, caps={"rps": 50, "websockets": 60, "agents": 60})
        self.assertFalse(plan["steps"][0]["capped"])
        for step in plan["steps"][1:]:
            self.assertTrue(step["capped"])
            self.assertLess(step["effectiveScale"], step["requestedScale"])
            self.assertLessEqual(step["targetPeakRps"], 50)
            self.assertLessEqual(step["assumedPopulation"]["websockets"], 60)
            self.assertLessEqual(step["assumedPopulation"]["agents"], 60)
            self.assertAlmostEqual(step["routes"][0]["targetRps"] / step["routes"][1]["targetRps"], 9)

    def test_literal_invocation_ids_are_normalized_and_merged(self):
        self.profile["routes"] = [{"method": "GET", "path": "/v1/actions/spawn/invocations/inv_idem_" + letter * 64,
                                   "rps_avg": value, "rps_peak": value * 3}
                                  for letter, value in (("a", 1), ("b", 2))]
        plan = compile_plan(self.profile)
        self.assertEqual(len(plan["steps"][0]["routes"]), 1)
        self.assertTrue(plan["steps"][0]["routes"][0]["pathTemplate"].endswith("/:invocation_id"))
        self.assertNotIn("a" * 64, json.dumps(plan))
        self.assertNotIn("b" * 64, json.dumps(plan))

    def test_rounding_does_not_drop_rare_routes_with_zero_rounded_share(self):
        self.profile["routes"][1]["rps_avg"] = .00001
        self.profile["routes"][1]["share"] = 0
        route = compile_plan(self.profile)["steps"][0]["routes"][1]
        self.assertGreater(route["targetRps"], 0)

    def test_invalid_rates_windows_routes_and_caps_are_refused(self):
        cases = []
        for value in (float("nan"), float("inf"), -1, True, 0):
            profile = copy.deepcopy(self.profile); profile["rps_peak_minute_max"] = value; cases.append(profile)
        for path in ("https://production.example/v1/agents", "/v1/agents?token=secret", "/v1/../internal/secret"):
            profile = copy.deepcopy(self.profile); profile["routes"][0]["path"] = path; cases.append(profile)
        profile = copy.deepcopy(self.profile); profile["window"]["hourly_and_totals"] = "2000-01-01/2000-01-08"; cases.append(profile)
        profile = copy.deepcopy(self.profile); profile["hourly_curve"][-1] = float("nan"); cases.append(profile)
        for profile in cases:
            with self.subTest(profile=profile), self.assertRaises((ValueError, TypeError)):
                compile_plan(profile)
        with self.assertRaises(ValueError):
            compile_plan(self.profile, caps={"rps": 0})

    def test_cli_produces_plan_and_refuses_malformed_input_without_echoing_it(self):
        result = subprocess.run([sys.executable, str(HERE / "plan_replay.py"), "--profile", str(HERE / "profiles/synthetic-example.json")],
                                capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout)["execution"], "not_run")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bad.json"; path.write_text('private-marker-not-to-echo')
            result = subprocess.run([sys.executable, str(HERE / "plan_replay.py"), "--profile", str(path)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("private-marker", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
