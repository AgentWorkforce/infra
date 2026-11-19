"""Offline configuration and CLI guards; no cloud or release actions."""

import base64
from contextlib import redirect_stderr, redirect_stdout
import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "prepare-gcp-edge.py"
SPEC = importlib.util.spec_from_file_location("prepare_gcp_edge", SCRIPT)
PREPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARE)


class PrepareGcpEdgeTest(unittest.TestCase):
    def setUp(self):
        self.config = {
            "hosts": {"root": "relay.placeholder.company", "api": "api.relay.placeholder.company",
                      "cast": "cast.relay.placeholder.company", "history": "history.relay.placeholder.company"},
            "desktop": {"profile": "proof123", "url_scheme": "proof-relay", "product_name": "Agent Relay",
                        "bundle_id": "com.proof.desktop", "feed_public_key": base64.b64encode(bytes(range(32))).decode()},
            "feed": {"bucket": "proof-desktop-feed", "prefix": "desktop-feed", "key_label": "f1",
                     "existing_secret": "desktop-feed-keys"},
        }

    def test_default_preserves_managed_cert_and_nested_hosts(self):
        out = PREPARE.prepare(self.config)
        edge = out["edge.values.json"]
        self.assertEqual(edge["gkeIngress"]["managedCertificateName"], "agent-relay")
        self.assertEqual(edge["gkeIngress"]["tlsSecretName"], "")
        self.assertNotIn("securityPolicy", edge["gkeIngress"])
        self.assertNotIn("cloud.google.com/backend-config", edge["relay-webapp"]["service"]["annotations"])
        self.assertNotIn("relaygate", edge)
        self.assertNotIn("origin-locked.values.json", out)
        self.assertEqual(edge["relay-control"]["auth"]["trustedProxies"], 2)

    def test_flat_restriction_is_opt_in(self):
        self.config["edge"] = {"mode": "cloudflare", "require_single_level_zone": False}
        PREPARE.prepare(self.config)
        self.config["edge"]["require_single_level_zone"] = True
        with self.assertRaisesRegex(ValueError, "flat names"):
            PREPARE.prepare(self.config)
        self.config["hosts"] = {k: f"relay-{k}.placeholder.company" for k in self.config["hosts"]}
        PREPARE.prepare(self.config)

    def test_cloudflare_gate_and_feed_share_public_origins(self):
        self.config["edge"] = {"mode": "cloudflare", "gate_only": True}
        out = PREPARE.prepare(self.config)
        edge = out["edge.values.json"]
        root = "https://relay.placeholder.company"
        history = "https://history.relay.placeholder.company"
        self.assertEqual(edge["gkeIngress"]["tlsSecretName"], "agent-relay-origin-tls")
        self.assertEqual(edge["gkeIngress"]["securityPolicy"], "agent-relay-edge")
        self.assertEqual(edge["relaygate"]["proxy"]["sessionsCorsOrigins"], [root])
        self.assertEqual(edge["sessions-pipeline"]["sessionReadApi"]["cors"]["allowedOrigins"], [root])
        self.assertEqual(edge["relaygate"]["control"]["sessionIngestAudience"], history)
        self.assertEqual(out["origin-locked.values.json"]["relay-control"]["auth"]["trustedProxies"], 3)
        self.assertEqual(edge["relay-control"]["extraEnv"], [])
        feed = out["desktop-feed.values.json"]["relay-control"]
        self.assertEqual(feed["desktopFeed"]["signingKeys"], {"existingSecret": "desktop-feed-keys", "profiles": ["proof123"]})
        self.assertEqual(out["desktop-build.json"]["environment_secrets"]["AGENT_RELAY_SITE_URL"], root)
        self.assertTrue(out["desktop-build.json"]["inputs"]["prepare-only"])

    def test_invalid_inputs_fail_closed(self):
        cases = [
            ("desktop", "feed_public_key", "invalid"), ("desktop", "bundle_id", "com.agentrelay.desktop"),
            ("desktop", "bundle_id", "com.proof-.desktop"),
            ("desktop", "url_scheme", "https"), ("hosts", "root", "<root host>"),
            ("hosts", "root", "relay.invalid"), ("hosts", "api", self.config["hosts"]["root"]),
        ]
        for section, key, value in cases:
            with self.subTest(section=section, key=key, value=value):
                config = copy.deepcopy(self.config)
                config[section][key] = value
                with self.assertRaises(ValueError):
                    PREPARE.prepare(config)
        for options in [{"mode": "unknown"}, {"gate_only": "false"}, {"require_single_level_zone": "true"}]:
            with self.subTest(options=options):
                config = copy.deepcopy(self.config)
                config["edge"] = options
                with self.assertRaises(ValueError):
                    PREPARE.prepare(config)

    def test_signing_secret_name_validates_dot_separated_labels(self):
        for name in ["desktop-feed-keys", "desktop.feed-keys", "a.b", ".".join(["a" * 63] * 3 + ["b" * 61])]:
            with self.subTest(valid=name):
                self.config["feed"]["existing_secret"] = name
                PREPARE.prepare(self.config)
        for name in ["a..b", "a.-b", "a-.b", ".keys", "keys.", "Keys", "a" * 254]:
            with self.subTest(invalid=name):
                self.config["feed"]["existing_secret"] = name
                with self.assertRaisesRegex(ValueError, "signing Secret name"):
                    PREPARE.prepare(self.config)

    def test_cli_refuses_a_file_created_after_the_existence_check(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "site.json"
            config.write_text(json.dumps(self.config))
            output = root / "prepared"
            output.mkdir()
            winner = output / "edge.values.json"
            winner.write_text("another invocation's configuration")
            command = [str(SCRIPT), "--config", str(config), "--output-dir", str(output)]
            # Simulate a stale precheck while another writer owns the first file.
            with mock.patch.object(sys, "argv", command), mock.patch.object(Path, "exists", return_value=False):
                with redirect_stderr(io.StringIO()), redirect_stdout(io.StringIO()):
                    result = PREPARE.main()
            self.assertEqual(result, 1)
            self.assertEqual(winner.read_text(), "another invocation's configuration")
            self.assertEqual(list(output.iterdir()), [winner])

    def test_cli_refuses_overwrite_and_does_not_emit_partial_invalid_config(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "site.json"
            config.write_text(json.dumps(self.config))
            command = [sys.executable, str(SCRIPT), "--config", str(config), "--output-dir", str(root / "prepared")]
            first = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(first.returncode, 0, first.stderr)
            before = {p.name: p.read_bytes() for p in (root / "prepared").iterdir()}
            second = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(second.returncode, 0)
            self.assertEqual(before, {p.name: p.read_bytes() for p in (root / "prepared").iterdir()})
            self.config["desktop"]["feed_public_key"] = "invalid"
            config.write_text(json.dumps(self.config))
            invalid = subprocess.run(command[:-1] + [str(root / "invalid")], capture_output=True, text=True)
            self.assertNotEqual(invalid.returncode, 0)
            self.assertFalse((root / "invalid").exists())


if __name__ == "__main__":
    unittest.main()
