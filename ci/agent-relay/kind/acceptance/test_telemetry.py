import datetime
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from api import Failure
from telemetry import SCRIPT, cast_collector


class CastCollectorTests(unittest.TestCase):
    def test_actor_skip_does_not_access_kubectl_or_claim_a_pass(self):
        with patch("telemetry.subprocess.run") as command:
            result = cast_collector({}, "durable-actors")
        command.assert_not_called()
        self.assertEqual(result["status"], "skipped")

    def test_node_lanes_refuse_empty_or_failed_evidence(self):
        for result in (SimpleNamespace(returncode=1, stdout="private-data"),
                SimpleNamespace(returncode=0, stdout=json.dumps({"matchingEvents": 0, "scannedSegments": 1, "privateSegments": True}))):
            with patch("telemetry.subprocess.run", return_value=result), self.assertRaises(Failure):
                cast_collector({"kubeconfig": "fixture", "historySince": "2000-01-01T00:00:00Z"}, "postgres")

    def test_real_node_observer_counts_only_recent_cast_events_and_checks_file_modes(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "1700000000000-0000000000-11111111-1111-4111-8111-111111111111.ndjson"
            event = {"component": "relaycast", "deployment_id": "local-kind", "occurred_at": now.isoformat(), "properties": {"unreported": "private-marker"}}
            others = [{**event, "component": "relaycontrol"}, {**event, "occurred_at": "2000-01-01T00:00:00Z"}]
            path.write_text("\n".join(json.dumps(e) for e in [event, *others]) + "\n")
            path.chmod(0o600)
            script = SCRIPT.replace("const directory='/var/lib/telemetry/segments';", "const directory=" + json.dumps(tmp) + ";")
            config = json.dumps({"since": (now - datetime.timedelta(seconds=10)).isoformat(), "deploymentId": "local-kind"})
            result = subprocess.run(["node", "-e", script], input=config, capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(result.stdout), {"matchingEvents": 1, "scannedSegments": 1, "privateSegments": True})
            self.assertNotIn("private-marker", result.stdout + result.stderr)
            path.chmod(0o644)
            result = subprocess.run(["node", "-e", script], input=config, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)

    def test_main_cast_traffic_cannot_satisfy_the_postgres_companion(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "1700000000000-0000000000-11111111-1111-4111-8111-111111111111.ndjson"
            event = {"component": "relaycast", "deployment_id": "local-kind", "occurred_at": now.isoformat()}
            path.write_text(json.dumps(event) + "\n")
            path.chmod(0o600)
            script = SCRIPT.replace("const directory='/var/lib/telemetry/segments';", "const directory=" + json.dumps(tmp) + ";")
            config = {"kubeconfig": "fixture", "historySince": (now - datetime.timedelta(seconds=10)).isoformat()}
            real_run = subprocess.run
            def run_observer(argv, **kwargs):
                self.assertEqual(json.loads(kwargs["input"])["deploymentId"], "local-kind-postgres-proof")
                return real_run(["node", "-e", script], **kwargs)
            with patch("telemetry.subprocess.run", side_effect=run_observer):
                with self.assertRaisesRegex(Failure, "cast_collector_events_not_proven"):
                    cast_collector(config, "postgres", deployment_id="local-kind-postgres-proof")
                with path.open("a") as target:
                    target.write(json.dumps({**event, "deployment_id": "local-kind-postgres-proof"}) + "\n")
                result = cast_collector(config, "postgres", deployment_id="local-kind-postgres-proof")
            self.assertEqual(result["evidence"]["matchingEvents"], 1)
            self.assertEqual(result["evidence"]["deploymentId"], "local-kind-postgres-proof")


if __name__ == "__main__":
    unittest.main()
