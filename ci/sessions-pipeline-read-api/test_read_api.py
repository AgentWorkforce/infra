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
    def render(self, *args, fail=False, overlay=None, fixture=True):
        with tempfile.TemporaryDirectory(prefix="read-api-render-") as directory:
            values = yaml.safe_load(FIXTURE.read_text())
            if not fixture:
                values.pop("readApi", None)
            base = Path(directory) / "base.yaml"
            base.write_text(yaml.safe_dump(values))
            command = ["helm", "template", "test", str(ROOT / "charts/sessions-pipeline"), "-n", "ci", "-f", str(base)]
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
        self.assertEqual(self.render(fixture=False), [])

    def test_credentials_require_secret_key_references(self):
        for name in ["CUSTOM_TOKEN", "DATABASE_URL", "PRIVATE_KEY", "LOCKER_SECRET_ACCESS_KEY", "PGPASSWORD"]:
            for entry in [{"value": "not-a-real-secret"},
                          {"valueFrom": {"configMapKeyRef": {"name": "config", "key": "token"}}},
                          {"valueFrom": {"fieldRef": {"fieldPath": "metadata.name"}}}]:
                with self.subTest(name=name, entry=entry):
                    self.assertIn("require valueFrom.secretKeyRef", self.render(
                        overlay={"extraEnv": [{"name": name, **entry}]}, fail=True))
        self.render(overlay={"extraEnv": [{"name": "CUSTOM_TOKEN", "valueFrom": {
            "secretKeyRef": {"name": "custom", "key": "token"}}}]})

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

    def test_control_only_omits_legacy_verifier_settings(self):
        docs = self.render(overlay={"auth": {"mode": "relaycontrol_only",
            "relayauth": {"jwksUrl": "", "issuer": ""}}})
        deploy = next(d for d in docs if d["kind"] == "Deployment")
        env = {e["name"]: e for e in deploy["spec"]["template"]["spec"]["containers"][0]["env"]}
        self.assertEqual(env["READ_API_AUTH_MODE"]["value"], "relaycontrol_only")
        self.assertEqual(env["RELAYHISTORY_ACCEPT_RELAYCONTROL_TOKENS"]["value"], "true")
        self.assertNotIn("RELAYAUTH_JWKS_URL", env)
        self.assertNotIn("RELAYAUTH_ISSUER", env)
        self.assertEqual(env["RELAYCONTROL_INTROSPECT_SECRET"]["valueFrom"]["secretKeyRef"],
                         {"name": "read-api-introspection", "key": "RELAYCONTROL_INTROSPECT_SECRET"})
        result = subprocess.run(["kubeconform", "-strict", "-summary"],
            input=yaml.safe_dump_all(docs), text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        legacy = next(d for d in self.render() if d["kind"] == "Deployment")
        legacy_env = {e["name"] for e in legacy["spec"]["template"]["spec"]["containers"][0]["env"]}
        self.assertNotIn("READ_API_AUTH_MODE", legacy_env)
        self.assertTrue({"RELAYAUTH_JWKS_URL", "RELAYAUTH_ISSUER"} <= legacy_env)

    def test_control_only_requires_introspection_and_refuses_legacy_settings(self):
        auth = {"mode": "relaycontrol_only", "relayauth": {"jwksUrl": "", "issuer": ""}}
        for setting in ["readApi.auth.relaycontrol.enabled=false", "readApi.auth.relaycontrol.url=",
                        "readApi.auth.relaycontrol.existingSecret=", "readApi.auth.relaycontrol.key=",
                        "readApi.auth.relayauth.jwksUrl=https://auth.agentrelay.com/jwks",
                        "readApi.auth.relayauth.issuer=https://auth.agentrelay.com"]:
            with self.subTest(setting=setting):
                self.render("--set", setting, overlay={"auth": auth}, fail=True)
        for mode in ["", "default", "RELAYCONTROL_ONLY", False, 1]:
            with self.subTest(mode=mode):
                self.assertIn("readApi.auth.mode must be", self.render(
                    overlay={"auth": {"mode": mode}}, fail=True))

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
                    [{"name": "READ_API_AUTH_MODE", "value": "relaycontrol_only"}],
                    [{"name": "RELAYAUTH_JWKS_URL", "valueFrom": {"secretKeyRef": {"name": "x", "key": "x"}}}],
                    [{"name": "RELAYAUTH_ISSUER", "value": "https://auth.agentrelay.com"}],
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
        command = ["helm", "template", "test", str(ROOT / "charts/relay-control"), "-n", "ci", "-f",
                   str(ROOT / "charts/relay-control/ci/default-values.yaml"), *args]
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


class IngestEdge(unittest.TestCase):
    """Merged native ingest contract; no image, database or cluster executed."""

    def render(self, *, overlay=None, read_api=None, fail=False, all_objects=False):
        with tempfile.TemporaryDirectory(prefix="ingest-edge-render-") as directory:
            cmd = ["helm", "template", "test", str(ROOT / "charts/sessions-pipeline"), "-n", "ci",
                   "-f", str(ROOT / "charts/sessions-pipeline/ci/ingest-edge-values.yaml")]
            if overlay or read_api:
                f = Path(directory) / "extra.yaml"
                values = {"ingestEdge": overlay} if overlay else {}
                if read_api:
                    values["readApi"] = read_api
                f.write_text(yaml.safe_dump(values))
                cmd += ["-f", str(f)]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if fail:
            self.assertNotEqual(result.returncode, 0)
            return result.stderr
        self.assertEqual(result.returncode, 0, result.stderr)
        return [d for d in yaml.safe_load_all(result.stdout) if d and (all_objects or
                d.get("metadata", {}).get("labels", {}).get("app.kubernetes.io/component") == "ingest-edge")]

    def test_disabled_needs_no_image_secrets_or_ca(self):
        self.assertEqual(self.render(overlay={"enabled": False, "image": {"digest": ""},
                         "config": {"existingSecret": ""}, "postgres": {"caConfigMap": "", "caSha256": ""}}), [])

    def test_edge_is_distinct_internal_service_with_secret_refs_and_ca(self):
        docs = self.render()
        self.assertEqual({d["kind"] for d in docs}, {"Deployment", "Service"})
        deploy = next(d for d in docs if d["kind"] == "Deployment")
        service = next(d for d in docs if d["kind"] == "Service")
        pod = deploy["spec"]["template"]["spec"]
        c = pod["containers"][0]
        env = {e["name"]: e for e in c["env"]}
        self.assertEqual(deploy["metadata"]["name"], "test-ingest-edge")
        self.assertEqual(service["spec"]["type"], "ClusterIP")
        self.assertEqual(service["spec"]["selector"], deploy["spec"]["selector"]["matchLabels"])
        self.assertEqual(c["ports"][0]["containerPort"], 8081)
        self.assertEqual(env["SERVICE"]["value"], "session-ingest")
        self.assertEqual(env["RELAYHISTORY_SELFHOST_INGEST"]["value"], "true")
        self.assertEqual(env["RELAYHISTORY_INGEST_ORIGIN"]["value"], "https://history.kind.agentrelay.com:8443")
        self.assertEqual(env["RELAYCONTROL_INTROSPECT_URL"]["value"], "http://relay-control.ci.svc.cluster.local")
        self.assertEqual(env["INGEST_KEY_ROOT"]["value"], "96bulls")
        self.assertEqual(env["SESSION_POSTGRES_TLS_PROFILE"]["value"], "custom-ca")
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertTrue(c["securityContext"]["readOnlyRootFilesystem"])
        for name in ["RELAYCONTROL_INTROSPECT_SECRET", "RELAYHISTORY_INGEST_DATABASE_URL",
                     "LOCKER_ACCESS_KEY_ID", "LOCKER_SECRET_ACCESS_KEY"]:
            self.assertNotIn("value", env[name])
            self.assertIn("secretKeyRef", env[name]["valueFrom"])
        self.assertEqual(env["RELAYHISTORY_INGEST_DATABASE_URL"]["valueFrom"]["secretKeyRef"],
                         {"name": "ingest-runtime", "key": "database-url"})
        ca = next(v for v in pod["volumes"] if v["name"] == "postgres-ca")
        self.assertEqual(ca["configMap"], {"name": "postgres-ca", "items": [{"key": "ca.crt", "path": "ca.crt"}]})
        self.assertEqual(c["readinessProbe"]["httpGet"]["path"], "/readyz")
        self.assertEqual(c["livenessProbe"]["httpGet"]["path"], "/healthz")
        self.assertFalse(any(e.startswith(("RELAYAUTH_", "PG", "AWS_", "INGEST_PUBLISH")) for e in env))
        for name in ["INGEST_ACCEPTANCE_MODE", "INGEST_REPLICA_MODE", "INGEST_SIGNING_KEY",
                     "INGEST_CUSTODY_SOURCE", "INGEST_PRIVACY_AUTHORITY", "INGEST_INLINE_MAX_SESSIONS",
                     "INGEST_PUBLISH_ENABLED", "INGEST_PUBLICATION_GC_ENABLED"]:
            self.assertNotIn(name, env)

    def test_missing_qualification_and_bad_numeric_inputs_refuse(self):
        for overlay in [{"image": {"digest": ""}}, {"image": {"digest": "latest"}},
                        {"config": {"existingSecret": ""}}, {"config": {"databaseUrlKey": ""}},
                        {"config": {"existingSecret": "Bad Name"}},
                        {"locker": {"existingSecret": ""}}, {"locker": {"bucket": ""}},
                        {"postgres": {"caConfigMap": ""}}, {"postgres": {"caSha256": "not-a-hash"}},
                        {"postgres": {"caKey": "../ca.crt"}},
                        {"port": 0}, {"port": 65536}, {"port": 8081.5},
                        {"postgres": {"poolMax": 33}}, {"maxPerOrg": 1001},
                        {"enabled": "false"}, {"allowInClusterHttp": "true"}]:
            with self.subTest(overlay=overlay):
                self.assertIn("ingestEdge", self.render(overlay=overlay, fail=True))

    def test_public_origin_is_normalized_and_keeps_nondefault_port(self):
        longest_host = ".".join(["a" * 63] * 3 + ["b" * 57, "com"])
        self.assertEqual(len(longest_host), 253)
        self.render(overlay={"origin": "https://" + longest_host})
        for origin in ["http://history.agentrelay.com", "https://history.agentrelay.com/",
                       "https://history.agentrelay.com:443", "https://history.agentrelay.com:0443",
                       "https://history.agentrelay.com:08443", "https://History.agentrelay.com",
                       "https://127.0.0.1", "https://history.internal", "https://history.example.com",
                       "https://example.com", "https://example.net:8443", "https://example.org",
                       "https://" + longest_host.replace("b" * 57, "b" * 58),
                       "https://history.agentrelay.com:65536", "https://history.agentrelay.com?x=y"]:
            with self.subTest(origin=origin):
                self.assertIn("ingestEdge.origin", self.render(overlay={"origin": origin}, fail=True))

    def test_image_repository_names_its_registry_explicitly(self):
        longest_host = ".".join(["a" * 63] * 3 + ["b" * 57, "com"])
        self.render(overlay={"image": {"repository": longest_host + "/i"}})
        for repository in ["session-ingest", "agentworkforce/session-ingest", "ghcr.io/image:latest",
                           "https://ghcr.io/org/image", "ghcr.io/org/image@sha256:" + "f" * 64,
                           "registry.agentrelay.com:65536/org/image",
                           longest_host.replace("b" * 57, "b" * 58) + "/i"]:
            with self.subTest(repository=repository):
                self.assertIn("ingestEdge.image.repository", self.render(
                    overlay={"image": {"repository": repository}}, fail=True))
        for repository in ["ghcr.io/agentworkforce/96bulls-services",
                           "registry.agentrelay.com:5000/team/session_ingest"]:
            self.render(overlay={"image": {"repository": repository}})

    def test_reader_and_ingest_require_the_same_audience(self):
        reader = yaml.safe_load(FIXTURE.read_text())["readApi"]
        self.render(read_api=reader)
        for origin in ["https://other.agentrelay.com:8443", "https://history.kind.agentrelay.com:9443"]:
            with self.subTest(origin=origin):
                self.assertIn("must exactly equal readApi.origin", self.render(
                    read_api={**reader, "origin": origin}, fail=True))

    def test_fixture_endpoint_names_the_rendered_storage_service(self):
        docs = self.render(all_objects=True)
        storage = next(d for d in docs if d["kind"] == "Service" and
                       d["metadata"]["name"] == "session-object-storage")
        deploy = next(d for d in docs if d["kind"] == "Deployment" and
                      d["metadata"].get("labels", {}).get("app.kubernetes.io/component") == "ingest-edge")
        env = {e["name"]: e for e in deploy["spec"]["template"]["spec"]["containers"][0]["env"]}
        self.assertEqual(env["LOCKER_ENDPOINT"]["value"],
                         f'http://{storage["metadata"]["name"]}.ci.svc.cluster.local:9000')

    def test_endpoint_policy_refuses_external_plaintext_and_duplicate_path(self):
        for group, field in [("locker", "endpoint"), ("relaycontrol", "url")]:
            for url in ["http://metadata.example.com", "http://169.254.169.254", "https://127.0.0.1",
                        "http://locker:9000", "https://user:do-not-leak@control.agentrelay.com",
                        "https://control.agentrelay.com/internal/v1/auth/introspect",
                        "https://control.agentrelay.com?query=1", "https://control.agentrelay.com:0"]:
                with self.subTest(group=group, url=url):
                    error = self.render(overlay={group: {field: url}}, fail=True)
                    self.assertIn("ingestEdge", error)
                    self.assertNotIn("do-not-leak", error)
        self.assertIn("ingestEdge", self.render(overlay={"allowInClusterHttp": False}, fail=True))
        self.render(overlay={"allowInClusterHttp": False,
                            "relaycontrol": {"url": "https://control.agentrelay.com"},
                            "locker": {"endpoint": "https://objects.agentrelay.com"}})

    def test_no_extra_env_can_replace_auth_or_transport(self):
        for name in ["SERVICE", "RELAYHISTORY_SELFHOST_INGEST", "INGEST_SIGNING_KEY",
                     "INGEST_ACCEPTANCE_MODE", "INGEST_REPLICA_MODE", "INGEST_CUSTODY_SOURCE",
                     "INGEST_PRIVACY_AUTHORITY", "INGEST_PUBLISH_ENABLED",
                     "PGOPTIONS", "SESSION_POSTGRES_TLS_PROFILE"]:
            self.assertIn("extraEnv is not supported", self.render(
                overlay={"extraEnv": [{"name": name, "value": "unsafe"}]}, fail=True))

    def test_standard_kubernetes_schema(self):
        result = subprocess.run(["kubeconform", "-strict", "-summary"], input=yaml.safe_dump_all(self.render()),
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Valid: 2", result.stdout)
        self.assertIn("Skipped: 0", result.stdout)

    def test_umbrella_default_off_and_enabled_slot_preserve_existing_specs(self):
        fixture = yaml.safe_load((ROOT / "charts/sessions-pipeline/ci/ingest-edge-values.yaml").read_text())
        command = ["helm", "template", "agent-relay", str(ROOT / "charts/agent-relay"),
                   "-n", "agent-relay", "--is-upgrade", "-f", str(ROOT / "charts/agent-relay/values-kind-core.yaml"),
                   "-f", str(ROOT / "charts/agent-relay/upgrade/kind-control-webapp-identities.yaml")]
        before = subprocess.run(command, capture_output=True, text=True, timeout=30)
        self.assertEqual(before.returncode, 0, before.stderr)
        with tempfile.TemporaryDirectory(prefix="ingest-edge-umbrella-") as directory:
            overlay = Path(directory) / "edge.yaml"
            overlay.write_text(yaml.safe_dump({"sessions-pipeline": {"ingestEdge": fixture["ingestEdge"]}}))
            after = subprocess.run(command + ["-f", str(overlay)], capture_output=True, text=True, timeout=30)
        self.assertEqual(after.returncode, 0, after.stderr)
        def objects(raw):
            return {(d["kind"], d["metadata"]["name"]): d for d in yaml.safe_load_all(raw) if d}
        old, new = objects(before.stdout), objects(after.stdout)
        self.assertFalse(any(d.get("metadata", {}).get("labels", {}).get("app.kubernetes.io/component") == "ingest-edge"
                             for d in old.values()))
        self.assertEqual(set(new) - set(old), {("Deployment", "agent-relay-ingest-edge"),
                                              ("Service", "agent-relay-ingest-edge")})
        self.assertEqual(set(old) - set(new), set())
        for key, value in old.items():
            self.assertEqual(new[key], value, key)


if __name__ == "__main__":
    unittest.main()
