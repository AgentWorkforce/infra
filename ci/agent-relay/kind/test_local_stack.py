"""Local target ownership, host changes, and real native Helm composition."""
import json
import io
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import yaml

from local_host_setup import host_contents
import local_host_setup
import local_stack
from local_stack import LocalStack, ROOT, read_model_key
from stack import StackError


class LocalTests(unittest.TestCase):
    def test_model_key_input_is_bounded_single_line_and_never_echoed_in_errors(self):
        self.assertEqual(read_model_key(io.StringIO("fixture-key\n")), "fixture-key")
        for value in ("", "\n", "secret\nsecond", "secret value", "a" * 16385, "a" * 16384 + "\nsecond", "secret\x00"):
            with self.assertRaises(StackError) as error:
                read_model_key(io.StringIO(value))
            self.assertNotIn("secret", str(error.exception))
        interactive = io.StringIO("fixture-key")
        interactive.isatty = lambda: True
        with self.assertRaisesRegex(StackError, "echo"):
            read_model_key(interactive)

    def test_model_key_install_checks_ownership_before_reading_or_writing(self):
        stack = LocalStack.__new__(LocalStack)
        stack.docker = lambda **kw: None
        stack.owned = lambda: (_ for _ in ()).throw(StackError("foreign cluster"))
        with patch.object(local_stack, "read_model_key") as read, patch.object(stack, "configure_model") as configure:
            with self.assertRaisesRegex(StackError, "foreign"):
                stack.install_model_key()
            read.assert_not_called()
            configure.assert_not_called()

    def test_repeat_without_model_override_preserves_existing_secret(self):
        stack = LocalStack.__new__(LocalStack)
        stack.k = lambda *args, **kw: SimpleNamespace(stdout=json.dumps({"data": {"OPENAI_API_KEY": "Zml4dHVyZQ=="}}))
        with patch.dict(local_stack.os.environ, {}, clear=True), patch.object(stack, "secret") as secret, patch.object(stack, "apply") as apply:
            stack.configure_model()
            secret.assert_not_called()
            self.assertEqual(apply.call_args.args[0]["kind"], "NetworkPolicy")
            self.assertEqual(stack.model_key_sha, local_stack.hashlib.sha256(b"fixture").hexdigest())

    def test_explicit_empty_model_override_disables_model_calls(self):
        stack = LocalStack.__new__(LocalStack)
        with patch.dict(local_stack.os.environ, {"OPENAI_API_KEY": ""}), patch.object(stack, "secret") as secret, patch.object(stack, "k") as k:
            stack.configure_model()
            secret.assert_called_once_with("local-model", {"OPENAI_API_KEY": ""})
            self.assertEqual(k.call_args.args[:2], ("delete", "networkpolicy"))

    def test_ca_removal_failure_stops_before_state_or_cluster_removal(self):
        with tempfile.TemporaryDirectory() as tmp:
            stack = LocalStack.__new__(LocalStack)
            stack.state = Path(tmp)
            (stack.state / "ca.crt").write_text("saved CA, even with an expired leaf")
            stack.name = "agent-relay-local"
            stack.docker = lambda **kw: None
            commands = []
            def command(args, **kw):
                commands.append(args)
                if args[0] == "sudo":
                    raise StackError("security failed")
                return SimpleNamespace(stdout=stack.name + "\n")
            stack.cmd = command
            stack.owned = lambda: None
            with patch.object(local_stack.sys, "platform", "darwin"), patch.object(local_stack, "certificate_present", return_value=True):
                with self.assertRaisesRegex(StackError, "security failed"):
                    stack.down_local()
            self.assertTrue((stack.state / "ca.crt").exists())
            self.assertFalse(any(cmd[:3] == ["kind", "delete", "cluster"] for cmd in commands))

    def test_trust_removal_propagates_unexpected_security_failure(self):
        failed = SimpleNamespace(returncode=1, stderr="authorization denied")
        with patch.object(local_host_setup.subprocess, "run", return_value=failed), patch.object(local_host_setup, "certificate_present") as present:
            with self.assertRaisesRegex(RuntimeError, "preserved"):
                local_host_setup.remove_ca(Path("ca.crt"), "fingerprint")
            present.assert_not_called()

    def test_already_absent_ca_is_safe_to_remove_again(self):
        absent = SimpleNamespace(returncode=1, stderr="The specified item could not be found in the keychain.")
        with patch.object(local_host_setup.subprocess, "run", return_value=absent) as run, patch.object(local_host_setup, "certificate_present", return_value=False):
            local_host_setup.remove_ca(Path("ca.crt"), "fingerprint")
            self.assertEqual(run.call_count, 1)

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
                name = deployment["metadata"]["name"]
                if name == "session-native-ingest":
                    self.assertEqual(env["SELFHOST_INGEST_ADMISSION"]["value"], "async")
                    self.assertIn("admission", json.dumps(container["readinessProbe"]))
                if name in ("session-native-ingest", "session-native-consumer", "session-read-api"):
                    self.assertEqual(env["ANALYTICS_SINK"]["value"], "collector")
                    self.assertIn("valueFrom", env["ANALYTICS_COLLECTOR_TOKEN"])
                    self.assertTrue(any(m["name"] == "analytics-ca" for m in container["volumeMounts"]))
                if name == "relay-control":
                    self.assertEqual(env["SELFHOST_ANALYTICS_DESTINATION"]["value"], "collector")
                    self.assertTrue(any(m["name"] == "analytics-producer" for m in container["volumeMounts"]))


if __name__ == "__main__":
    unittest.main()
