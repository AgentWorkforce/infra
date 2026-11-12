import copy
import json
from pathlib import Path
import unittest

from fixture import NAME, validate_identity, validate_plan
from plan_replay import compile_plan


class FixtureBoundaries(unittest.TestCase):
    def test_local_fixture_identity_cannot_adopt_the_viewing_cluster_or_another_daemon(self):
        expected = {"name": NAME, "clusterUid": "fixture-id", "dockerHost": "unix:///owned.sock"}
        validate_identity(expected, "fixture-id", "unix:///owned.sock")
        for changes in ({"name": "agent-relay-local"}, {"clusterUid": "foreign-id"}, {"dockerHost": "ssh://foreign"}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                validate_identity({**expected, **changes}, "fixture-id", "unix:///owned.sock")

    def test_tampered_rate_and_oversized_workload_are_refused_before_pod_creation(self):
        profile = json.loads((Path(__file__).parent / "profiles/synthetic-example.json").read_text())
        plan = compile_plan(profile)
        validate_plan(plan, 10)
        for rate in (float("nan"), 5001, -1, True):
            tampered = copy.deepcopy(plan);tampered["steps"][0]["targetPeakRps"] = rate
            with self.subTest(rate=rate), self.assertRaises(ValueError): validate_plan(tampered, 10)
        tampered = copy.deepcopy(plan);tampered["steps"][0]["routes"][0]["targetRps"] += 1
        with self.assertRaises(ValueError): validate_plan(tampered, 10)


if __name__ == "__main__":
    unittest.main()
