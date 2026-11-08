"""Read API chart admission and real health-probe checks; no cluster calls."""
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "charts/sessions-pipeline/ci/read-api-values.yaml"


class ReadApi(unittest.TestCase):
    def render(self, *args, fail=False, overlay=None):
        with tempfile.TemporaryDirectory(prefix="read-api-render-") as directory:
            command = ["helm", "template", "test", str(ROOT / "charts/sessions-pipeline"), "-n", "ci", "-f", str(FIXTURE)]
            if overlay:
                extra = Path(directory) / "extra.yaml"
                extra.write_text(yaml.safe_dump({"readApi": overlay}))
                command += ["-f", str(extra)]
            result = subprocess.run(command + list(args), text=True, capture_output=True, check=False)
        if fail:
            self.assertNotEqual(result.returncode, 0)
            return result.stderr
        self.assertEqual(result.returncode, 0, result.stderr)
        return [d for d in yaml.safe_load_all(result.stdout) if d and
                d.get("metadata", {}).get("labels", {}).get("app.kubernetes.io/component") == "read-api"]

    def test_default_off_renders_no_read_api_objects(self):
        self.assertEqual(self.render("--set", "readApi.enabled=false", "--set", "readApi.image.digest="), [])

    def test_both_kind_profiles_keep_read_api_disabled(self):
        for profile in ("core", "addons"):
            with self.subTest(profile=profile):
                command = ["helm", "template", "agent-relay", str(ROOT / "charts/agent-relay"), "-n", "agent-relay",
                           "-f", str(ROOT / "charts/agent-relay/values-kind-core.yaml")]
                if profile == "addons":
                    command += ["-f", str(ROOT / "charts/agent-relay/values-kind-addons.yaml")]
                result = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                docs = [d for d in yaml.safe_load_all(result.stdout) if d]
                self.assertFalse(any(d.get("metadata", {}).get("labels", {}).get("app.kubernetes.io/component") == "read-api" for d in docs))

    def test_enabled_is_internal_and_config_credentials_are_secret_refs(self):
        docs = self.render()
        self.assertEqual({d["kind"] for d in docs}, {"Service", "Deployment"})
        deploy = next(d for d in docs if d["kind"] == "Deployment")
        service = next(d for d in docs if d["kind"] == "Service")
        spec = deploy["spec"]["template"]["spec"]
        container = spec["containers"][0]
        env = {e["name"]: e for e in container["env"]}
        self.assertEqual(env["SERVICE"]["value"], "session-read-api")
        self.assertEqual(env["RELAYHISTORY_SELFHOST_READ_API"]["value"], "true")
        self.assertEqual(env["RELAYHISTORY_ACCEPT_RELAYCONTROL_TOKENS"]["value"], "true")
        self.assertEqual(env["RELAYHISTORY_READ_API_SECRET"]["valueFrom"]["secretKeyRef"],
                         {"name": "read-api-config", "key": "RELAYHISTORY_READ_API_SECRET"})
        self.assertNotIn("value", env["RELAYCONTROL_INTROSPECT_SECRET"])
        self.assertFalse(spec["automountServiceAccountToken"])
        self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
        self.assertEqual(service["spec"]["type"], "ClusterIP")
        self.assertEqual(service["spec"]["selector"], deploy["spec"]["selector"]["matchLabels"])

    def test_missing_required_inputs_and_wildcard_workspace_are_refused(self):
        for setting in ["readApi.image.digest=", "readApi.config.existingSecret=", "readApi.origin=https://history.example.invalid/path",
                        "readApi.completeSince=", "readApi.directoryWorkspaces=*", "readApi.auth.relayauth.jwksUrl=",
                        "readApi.auth.relaycontrol.existingSecret=", "readApi.port=65536", "readApi.probeRuntime=sh"]:
            with self.subTest(setting=setting):
                self.render("--set", setting, fail=True)

    def test_public_origin_rejects_credentials_private_hosts_and_invalid_ports(self):
        invalid = [
            "http://history.agentrelay.com", "https://user:example@history.agentrelay.com",
            "https://user@history.agentrelay.com", "https://127.0.0.1", "https://8.8.8.8",
            "https://[::1]", "https://[2606:4700:4700::1111]", "https://history", "https://localhost",
            *["https://history." + suffix for suffix in
              ("localhost", "local", "internal", "lan", "invalid", "test", "example", "home.arpa", "onion")],
            *["https://history.example." + suffix for suffix in ("com", "net", "org")],
            *["https://history.agentrelay.com:" + port for port in ("0", "65536", "999999", "abc", "-1", "1.5", "")],
            "https://history.agentrelay.com/", "https://history.agentrelay.com/path",
            "https://history.agentrelay.com?query=x", "https://history.agentrelay.com#fragment",
        ]
        for origin in invalid:
            with self.subTest(origin=origin):
                message = self.render(fail=True, overlay={"origin": origin})
                self.assertIn("readApi.origin", message)
        for origin in ["https://history.agentrelay.com", *["https://history.kind.agentrelay.com:" + str(port)
                       for port in (1, 443, 8443, 65535)]]:
            with self.subTest(origin=origin):
                deploy = next(d for d in self.render(overlay={"origin": origin}) if d["kind"] == "Deployment")
                env = {e["name"]: e for e in deploy["spec"]["template"]["spec"]["containers"][0]["env"]}
                self.assertEqual(env["READ_API_ORIGIN"]["value"], origin)

    def test_search_backend_comes_from_config_with_postgres_default(self):
        for overlay, expected in [(None, "postgres"), ({"search": {"backend": "clickhouse"}}, "clickhouse")]:
            with self.subTest(backend=expected):
                deploy = next(d for d in self.render(overlay=overlay) if d["kind"] == "Deployment")
                env = {e["name"]: e for e in deploy["spec"]["template"]["spec"]["containers"][0]["env"]}
                self.assertEqual(env["SEARCH_INDEX_BACKEND"]["value"], expected)
        self.render("--set", "readApi.search.backend=", fail=True)

    def test_extra_env_cannot_replace_flag_or_duplicate_credentials(self):
        for env in [[{"name": "SERVICE", "value": "other"}],
                    [{"name": "RELAYHISTORY_SELFHOST_READ_API", "value": "false"}],
                    [{"name": "SEARCH_INDEX_BACKEND", "value": "clickhouse"}],
                    [{"name": "CUSTOM", "value": "a"}, {"name": "CUSTOM", "value": "b"}],
                    [{"name": "CUSTOM", "value": "a", "valueFrom": {"secretKeyRef": {"name": "x", "key": "x"}}}]]:
            with self.subTest(names=[e["name"] for e in env]):
                self.render(fail=True, overlay={"extraEnv": env})
        docs = self.render(overlay={"extraEnv": [{"name": "CUSTOM", "value": 123}]})
        deploy = next(d for d in docs if d["kind"] == "Deployment")
        self.assertEqual(next(e["value"] for e in deploy["spec"]["template"]["spec"]["containers"][0]["env"] if e["name"] == "CUSTOM"), "123")

    def test_standard_kubernetes_schema(self):
        result = subprocess.run(["kubeconform", "-strict", "-summary"], input=yaml.safe_dump_all(self.render()), text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Valid: 2", result.stdout)
        self.assertIn("Skipped: 0", result.stdout)

    def control(self, *args, fail=False):
        command = ["helm", "template", "test", str(ROOT / "charts/relay-cloud-api"), "-n", "ci", "-f",
                   str(ROOT / "charts/relay-cloud-api/ci/default-values.yaml"), *args]
        result = subprocess.run(command, capture_output=True, text=True)
        if fail:
            self.assertNotEqual(result.returncode, 0)
            return result.stderr
        self.assertEqual(result.returncode, 0, result.stderr)
        return [d for d in yaml.safe_load_all(result.stdout) if d]

    def test_control_keeps_legacy_default_and_can_omit_unused_auth_credentials(self):
        for disabled in (False, True):
            with self.subTest(disabled=disabled):
                args = ["--set", "services.relayauthEnabled=false", "--set", "services.relayauthUrl=",
                        "--set", "secretKeys.relayauthApiKey="] if disabled else []
                deploy = next(d for d in self.control(*args) if d["kind"] == "Deployment")
                spec = deploy["spec"]["template"]["spec"]
                env = {e["name"] for e in spec["containers"][0]["env"]}
                keys = {i["key"] for volume in spec["volumes"] if volume["name"] == "secrets" for i in volume["secret"]["items"]}
                self.assertEqual("RELAYAUTH_URL" in env, not disabled)
                self.assertEqual("RELAYAUTH_API_KEY_FILE" in env, not disabled)
                self.assertEqual("relayauth-api-key" in keys, not disabled)
                self.assertIn("database-url", keys)
                self.assertNotIn("database-migrations-url", keys)

    def test_control_no_legacy_mode_cannot_reintroduce_auth_through_extra_env(self):
        for name in ("RELAYAUTH_URL", "RELAYAUTH_API_KEY", "RELAYAUTH_API_KEY_FILE"):
            with self.subTest(name=name):
                message = self.control("--set", "services.relayauthEnabled=false", "--set", "extraEnv[0].name=" + name,
                                       "--set", "extraEnv[0].value=not-used", fail=True)
                self.assertIn("managed by structured chart values", message)
        message = self.control("--set-string", "services.relayauthEnabled=false", fail=True)
        self.assertIn("must be a boolean", message)

    def test_actual_readiness_program_rejects_dormant_and_bad_health(self):
        deploy = next(d for d in self.render() if d["kind"] == "Deployment")
        command = deploy["spec"]["template"]["spec"]["containers"][0]["readinessProbe"]["exec"]["command"]
        self.assertEqual(command[:2], ["bun", "-e"])
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                status, body = self.server.reply
                self.send_response(status); self.end_headers(); self.wfile.write(body)
            def log_message(self, *args):
                pass
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            for status, body, expected in [(200, b'{"ok":true,"enabled":false}', 1),
                                            (200, b'{"ok":true,"enabled":true}', 0),
                                            (200, b'{"ok":false,"enabled":true}', 1),
                                            (503, b'{"ok":true,"enabled":true}', 1), (200, b'not json', 1)]:
                with self.subTest(status=status, body=body):
                    server.reply = (status, body)
                    env = dict(os.environ, RELAYHISTORY_READ_API_PORT=str(server.server_port))
                    # The emitted probe is plain JavaScript; use Node to exercise
                    # its actual network/JSON behavior without a services image.
                    result = subprocess.run(["node", "-e", command[2]], env=env, capture_output=True, timeout=8)
                    self.assertEqual(result.returncode, expected)
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
