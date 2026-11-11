"""Local target ownership, host changes, and real native Helm composition."""
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest

import yaml

from local_host_setup import host_contents
from local_stack import LocalStack, ROOT
from stack import StackError


class LocalTests(unittest.TestCase):
    def test_host_setup_removes_only_kind_aliases_and_preserves_shared_lines(self):
        original = "127.0.0.1 localhost relay.kind.agentrelay.com # shared\n::1 relay.kind.agentrelay.com other.local\n192.0.2.1 unrelated.local\n"
        installed = host_contents(original, True)
        self.assertIn("127.0.0.1 localhost # shared\n", installed)
        self.assertIn("::1 other.local\n", installed)
        self.assertIn("192.0.2.1 unrelated.local\n", installed)
        self.assertEqual(installed.count("relay.kind.agentrelay.com"), 1)
        self.assertEqual(host_contents(installed, True), installed)
        removed = host_contents(installed, False)
        self.assertNotIn("kind.agentrelay.com", removed)
        self.assertIn("unrelated.local", removed)

    def test_matching_name_with_another_cluster_uid_is_not_owned(self):
        with tempfile.TemporaryDirectory() as tmp:
            stack = LocalStack.__new__(LocalStack)
            stack.marker = Path(tmp) / "cluster.json"
            stack.kubeconfig = Path(tmp) / "kubeconfig"
            stack.env = {"DOCKER_HOST": "unix:///local/docker.sock"}
            stack.name = "agent-relay-local"
            stack.marker.write_text(json.dumps({"version": 1, "name": stack.name, "profile": "core", "clusterUid": "original", "dockerHost": stack.env["DOCKER_HOST"]}))
            stack.cluster_uid = lambda path: "replacement"
            with self.assertRaisesRegex(StackError, "identity"):
                stack.owned()

    def test_mailbox_reader_ignores_terminating_and_unready_pods(self):
        stack = LocalStack.__new__(LocalStack)
        def pod(name, date, ready, deleting=False):
            return {"metadata": {"name": name, "creationTimestamp": date, **({"deletionTimestamp": date} if deleting else {})},
                "status": {"phase": "Running", "containerStatuses": [{"ready": ready}]}}
        pods = [pod("old", "2026-11-11T01:00:00Z", True, True), pod("new", "2026-11-11T01:01:00Z", True), pod("starting", "2026-11-11T01:02:00Z", False)]
        stack.k = lambda *args: SimpleNamespace(stdout=json.dumps({"items": pods}))
        self.assertEqual(stack.pod("local-mail"), "new")

    def test_real_final_render_has_exact_core_roles_without_inline_credentials(self):
        stack = LocalStack.__new__(LocalStack)
        stack.ca_sha = "c" * 64
        stack.edge_ip = "10.96.0.10"
        stack.credentials = {"createdAt": "2026-11-11T00:00:00Z"}
        tenant = {"organizationId": "11111111-1111-4111-8111-111111111111", "workspaceId": "22222222-2222-4222-8222-222222222222"}
        values = stack.values("serve", tenant)
        self.assertEqual(values["sessions-pipeline"]["sessionReadApi"]["cors"]["allowedOrigins"], ["https://relay.kind.agentrelay.com"])
        result = subprocess.run(["helm", "template", "agent-relay", "charts/agent-relay", "-n", "agent-relay", "-f", "-", "--is-upgrade"],
            cwd=ROOT, input=json.dumps(values), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        docs = [d for d in yaml.safe_load_all(result.stdout) if d]
        self.assertFalse(any(d["kind"] in ("Secret", "Job") for d in docs))
        active = [d for d in docs if d["kind"] == "Deployment" and d["spec"].get("replicas", 1) > 0]
        self.assertEqual({d["metadata"]["name"] for d in active}, {"relay-control", "relay-webapp", "relaycast", "session-native-ingest",
            "session-native-consumer", "session-read-api", "sessions-session-brief", "telemetry-collector"})
        for deployment in active:
            for container in deployment["spec"]["template"]["spec"]["containers"]:
                self.assertIn("@sha256:", container["image"])
                env = {e["name"]: e for e in container.get("env", [])}
                self.assertNotIn("SCRUB_ENGINE", env)
                self.assertNotIn("SCRUB_ENGINE_REQUIRED", env)
                self.assertNotIn("READER_MAX_RULESET", env)
                if "OPENAI_API_KEY" in env:
                    self.assertIn("valueFrom", env["OPENAI_API_KEY"])


if __name__ == "__main__":
    unittest.main()
