"""Causal harness checks; no Docker daemon, database or cluster contacted."""
import json
from types import SimpleNamespace
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import proof
import stack
import addons
import tls
import control


class Harness(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="kind-harness-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        scope = patch.object(stack, "ROOT", self.root)
        scope.start()
        self.addCleanup(scope.stop)
        self.local = stack.Stack("core")

    def test_public_docker_config_selects_anonymous_file_store_without_inherited_auth(self):
        self.local.env["DOCKER_HOST"] = "unix:///fixture/docker.sock"
        self.local.env["DOCKER_AUTH_CONFIG"] = "private-inherited-auth"
        self.local.cmd = lambda argv, **kw: subprocess.CompletedProcess(
            argv, 0, "aarch64" if "{{.Architecture}}" in argv else "29.9.2", "")
        self.local.docker(require_space=False)
        config = self.local.state / "docker-public" / "config.json"
        value = json.loads(config.read_text())
        # Docker ContainsAuth considers a nonempty map configured even though
        # these entries contain no credentials; it must not auto-select a helper.
        self.assertTrue(value["auths"])
        self.assertEqual(value["auths"], {"https://index.docker.io/v1/": {}, "ghcr.io": {}})
        self.assertNotIn("credsStore", value)
        self.assertNotIn("credHelpers", value)
        self.assertNotIn("DOCKER_AUTH_CONFIG", self.local.env)
        self.assertEqual(self.local.env["DOCKER_CONFIG"], str(config.parent))
        self.assertEqual(config.stat().st_mode & 0o777, 0o600)

    def test_auth_signing_key_is_pkcs8_and_reuse_keeps_identity(self):
        key = stack.auth_signing_key(self.local)
        before = key.read_bytes()
        self.assertTrue(before.startswith(b"-----BEGIN PRIVATE KEY-----"))
        self.assertEqual(key.stat().st_mode & 0o777, 0o600)
        self.assertEqual(stack.auth_signing_key(self.local).read_bytes(), before)

    def test_legacy_auth_key_conversion_preserves_public_identity_and_original_backup(self):
        key = self.local.state / "auth-signing.pem"
        version = self.local.cmd(["openssl", "version"]).stdout
        flags = ["-traditional"] if version.startswith("OpenSSL ") and int(version.split()[1].split(".")[0]) >= 3 else []
        self.local.cmd(["openssl", "genrsa", *flags, "-out", key, "2048"], sensitive=True)
        original = key.read_bytes()
        self.assertTrue(original.startswith(b"-----BEGIN RSA PRIVATE KEY-----"))
        public = self.local.cmd(["openssl", "pkey", "-in", key, "-pubout"], sensitive=True).stdout
        stack.auth_signing_key(self.local)
        self.assertTrue(key.read_bytes().startswith(b"-----BEGIN PRIVATE KEY-----"))
        self.assertEqual(self.local.cmd(["openssl", "pkey", "-in", key, "-pubout"], sensitive=True).stdout, public)
        backup = key.with_name("auth-signing.pkcs1-backup.pem")
        self.assertEqual(backup.read_bytes(), original)
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        self.assertFalse(list(self.local.state.glob("auth-signing-*.pem")))

    def test_failed_auth_conversion_keeps_original_and_removes_only_temporary(self):
        key = self.local.state / "auth-signing.pem"
        original = b"-----BEGIN RSA PRIVATE KEY-----\nfixture\n"
        key.write_bytes(original)
        self.local.cmd = lambda *args, **kw: (_ for _ in ()).throw(stack.StackError("conversion failed"))
        with self.assertRaisesRegex(stack.StackError, "conversion failed"):
            stack.auth_signing_key(self.local)
        self.assertEqual(key.read_bytes(), original)
        self.assertFalse(list(self.local.state.glob("auth-signing-*.pem")))

    def test_mcp_pending_requires_both_catalog_aliases_to_be_absent(self):
        paths = ("/api/v1/mcp/shared-sessions", "/cloud/api/v1/mcp/shared-sessions")
        for statuses, native, expected in [((404, 404), False, "PENDING"),
                                           ((404, 503), False, "FAIL"),
                                           ((404, 200), False, "FAIL"),
                                           ((200, 200), False, "PASS"),
                                           ((404, 404), True, "FAIL")]:
            with self.subTest(statuses=statuses, native=native):
                image = ("agent-relay-kind" if native else "ghcr.io/agentworkforce") + "/selfhost-api@sha256:" + "a" * 64
                (self.local.state / "images.json").write_text(json.dumps({"images": [image]}))
                self.local.k = lambda *a, **kw: subprocess.CompletedProcess(a, 0, json.dumps({
                    "spec": {"template": {"spec": {"containers": [{"name": "api", "image": image}]}}}}), "")
                initialized = []
                def edge(host, path, token=None, method="GET", body=None, extra_headers=None, response_headers=None):
                    if not token:
                        return 401, "{}"
                    if (extra_headers or {}).get("origin"):
                        return 403, "{}"
                    if body["method"] == "initialize":
                        initialized.append(path)
                        status = statuses[paths.index(path)]
                        if status != 200:
                            return status, "{}"
                        response_headers["mcp-session-id"] = "fixture-session"
                        result = {"serverInfo": {"name": "agent-relay-selfhost"}, "protocolVersion": "2025-06-18"}
                    elif body["method"] == "tools/list":
                        names = ["describe_capabilities", "send_relay_message", "search_shared_sessions", "get_shared_session"]
                        result = {"tools": [{"name": n} for n in names + [f"fixture-{i}" for i in range(15)]]}
                    else:
                        result = {"structuredContent": {"workspace": {"workspace_id": "fixture-workspace"},
                            "connection": {"auth_mode": "cli_login"},
                            "endpoint": {"url": "https://relay.kind.agentrelay.com:8443" + path}}}
                    return 200, json.dumps({"result": result})
                p = proof.Proof(self.local)
                p.state["a"] = {"accessToken": "fixture-access", "workspaceId": "fixture-workspace"}
                p.edge = edge
                if expected == "FAIL":
                    with self.assertRaises(stack.StackError):
                        p.mcp()
                    self.assertFalse(any(c["result"] == "PENDING" for c in p.checks))
                else:
                    p.mcp()
                    self.assertEqual([c["result"] for c in p.checks], [expected])
                if not native:
                    self.assertEqual(initialized, list(paths))

    def test_each_acl_attempt_is_fresh_and_a_later_failure_is_not_hidden(self):
        jobs, waited = [], []
        self.local.apply = jobs.append
        def wait(name, seconds):
            waited.append(name)
            if len(waited) == 2:
                raise stack.StackError("current ACL drift")
        self.local.wait_job = wait
        self.local.verify_combined_acl("image@sha256:example")
        with self.assertRaisesRegex(stack.StackError, "current ACL drift"):
            self.local.verify_combined_acl("image@sha256:example")
        self.assertEqual(len(jobs), 2)
        self.assertNotEqual(jobs[0]["metadata"]["name"], jobs[1]["metadata"]["name"])
        self.assertEqual(waited, [j["metadata"]["name"] for j in jobs])

    def test_secret_apply_never_creates_plaintext_last_applied_annotation(self):
        calls = []
        def k(*args, **kwargs):
            calls.append((args, kwargs))
            return subprocess.CompletedProcess(args, 0, json.dumps({"metadata": {"name": "fixture", "namespace": "agent-relay", "resourceVersion": "42",
                "annotations": {"keep": "yes", "kubectl.kubernetes.io/last-applied-configuration": "private-old-value"}}}) if args[0] == "get" else "", "")
        self.local.k = k
        self.local.secret("fixture", {"private": "secret-value"})
        args, kwargs = calls[-1]
        self.assertEqual(args[0], "replace")
        self.assertTrue(kwargs["sensitive"])
        doc = json.loads(kwargs["data"])
        self.assertNotIn("stringData", doc)
        self.assertNotIn("secret-value", kwargs["data"])
        self.assertEqual(doc["metadata"]["resourceVersion"], "42")
        self.assertEqual(doc["metadata"]["annotations"], {"keep": "yes"})
        import base64
        self.assertEqual(base64.b64decode(doc["data"]["private"]), b"secret-value")

    def test_addon_build_checks_checkout_space_before_fetch_or_cargo(self):
        self.local.check_space = lambda needed: None
        with patch.object(addons.shutil, "disk_usage", return_value=SimpleNamespace(free=1)), patch.object(addons, "checkout") as checkout:
            with self.assertRaisesRegex(ValueError, "checkout volume"):
                addons.build(self.local)
            checkout.assert_not_called()

    def test_cached_leaf_with_missing_host_or_wrong_key_is_reissued(self):
        self.local.apply = lambda *args, **kwargs: None
        self.local.tls()
        ca = (self.local.state / "ca.crt").read_bytes()
        old = (self.local.state / "tls.crt").read_bytes()
        self.local.tls()
        self.assertEqual((self.local.state / "tls.crt").read_bytes(), old)
        tls.create(self.local, [*stack.HOSTS, "new.kind.agentrelay.com"], stack.NS)
        self.assertNotEqual((self.local.state / "tls.crt").read_bytes(), old)
        old = (self.local.state / "tls.crt").read_bytes()
        self.local.cmd(["openssl", "genrsa", "-out", self.local.state / "tls.key", "2048"])
        tls.create(self.local, [*stack.HOSTS, "new.kind.agentrelay.com"], stack.NS)
        self.assertNotEqual((self.local.state / "tls.crt").read_bytes(), old)
        self.assertEqual((self.local.state / "ca.crt").read_bytes(), ca)

    def test_invalid_profile_cannot_inject_shell_commands_through_make(self):
        sentinel = self.root / "injected"
        result = subprocess.run(["make", "kind-render", "PYTHON=" + sys.executable,
                                 "PROFILE=core'; touch " + str(sentinel) + "; #"],
                                cwd=Path(__file__).resolve().parents[3], text=True, capture_output=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid choice", result.stderr)
        self.assertFalse(sentinel.exists())

    def test_failed_archive_inspection_removes_only_own_transport(self):
        self.local.arch = "arm64"
        self.local.check_space = lambda needed: None
        keep = self.local.state / "keep"
        keep.write_text("preserve")
        archive = self.local.state / "control-image.tar"
        def command(args, **kwargs):
            if "save" in args:
                archive.write_text("transient image")
            return subprocess.CompletedProcess(args, 0, "", "")
        self.local.cmd = command
        with patch.object(control, "checkout"), patch.object(control, "inspect_archive", side_effect=ValueError("wrong image")):
            with self.assertRaisesRegex(ValueError, "wrong image"):
                control.build(self.local)
        self.assertFalse(archive.exists())
        self.assertEqual(keep.read_text(), "preserve")

    def test_pipeline_cleanup_error_preserves_original_read_failure(self):
        p = proof.Proof(self.local)
        p.state["a"] = {"ownerUserId": "owner"}
        self.local.k = lambda *args, **kwargs: subprocess.CompletedProcess(args, 0, '{"accessToken":"private-token"}', "")
        def edge(host, path, *args, **kwargs):
            if "revoke" in path:
                raise ValueError("private cleanup response")
            raise stack.StackError("original read failure")
        p.edge = edge
        with self.assertRaisesRegex(stack.StackError, "original read failure"):
            p.pipeline_app_visibility("session", {"workspaceId": "workspace"})
        self.assertEqual(p.checks, [{"result": "FAIL", "check": "pipeline.read_session_cleanup", "detail": "ValueError"}])

    def test_pipeline_visibility_clock_jump_before_first_poll_stays_pending_and_revokes(self):
        p = proof.Proof(self.local)
        p.state["a"] = {"ownerUserId": "owner"}
        self.local.k = lambda *args, **kwargs: subprocess.CompletedProcess(args, 0, '{"accessToken":"private-token"}', "")
        calls = []
        def edge(host, path, *args, **kwargs):
            calls.append((path, kwargs))
            self.assertEqual(path, "/api/v1/auth/token/revoke", "a skipped poll must not invent an application read")
            return 200, '{"revoked":true}'
        p.edge = edge
        with patch.object(proof.time, "monotonic", side_effect=[0, 30]), patch.object(proof.time, "sleep") as sleep:
            p.pipeline_app_visibility("session", {"workspaceId": "workspace"})
        sleep.assert_not_called()
        self.assertEqual(len(p.checks), 1)
        self.assertEqual(p.checks[0]["result"], "PENDING")
        self.assertIn("last HTTP=not_attempted", p.checks[0]["detail"])
        self.assertNotIn("private-token", p.checks[0]["detail"])
        self.assertEqual(calls[0][1]["body"], {"token": "private-token"})

    def test_pipeline_visibility_keeps_last_actual_http_outcome(self):
        p = proof.Proof(self.local)
        p.state["a"] = {"ownerUserId": "owner"}
        self.local.k = lambda *args, **kwargs: subprocess.CompletedProcess(args, 0, '{"accessToken":"private-token"}', "")
        calls = []
        def edge(host, path, *args, **kwargs):
            calls.append(path)
            return (200, '{"revoked":true}') if "revoke" in path else (200, '{"items":[]}')
        p.edge = edge
        with patch.object(proof.time, "monotonic", side_effect=[0, 0, 16]), patch.object(proof.time, "sleep"):
            p.pipeline_app_visibility("session", {"workspaceId": "workspace"})
        self.assertEqual(p.checks[0]["result"], "PENDING")
        self.assertIn("last HTTP=200", p.checks[0]["detail"])
        self.assertNotIn("not_attempted", p.checks[0]["detail"])
        self.assertEqual(calls, ["/cloud/api/v1/workspaces/workspace/sessions", "/api/v1/auth/token/revoke"])

    def test_cost_sync_session_is_revoked_even_when_ingest_fails(self):
        p = proof.Proof(self.local)
        p.state.update(a={"accessToken": "control-token", "workspaceId": "workspace"}, session={"sessionId": "session"})
        self.local.k = lambda *args, **kwargs: subprocess.CompletedProcess(args, 0, '{"accessToken":"sync-token","payload":{}}', "")
        calls = []
        def edge(host, path, *args, **kwargs):
            calls.append((host, path, kwargs))
            return (200, '{"revoked":true}') if "revoke" in path else (500, '{}')
        p.edge = edge
        with self.assertRaisesRegex(stack.StackError, "did not accept"):
            p.cost_attribution()
        self.assertEqual(calls[-1][1], "/v1/auth/token/revoke")
        self.assertEqual(calls[-1][2]["body"], {"token": "sync-token"})

    def test_unexpected_run_and_cleanup_errors_replace_old_success(self):
        report = self.local.state / "proof.json"
        report.write_text('{"result":"PASS","checks":[]}')
        p = proof.Proof(self.local)
        p.state["a"] = {"accessToken": "never-print-this"}
        def run():
            self.assertFalse(report.exists(), "old receipt must be invalidated before preflight")
            raise TypeError("never-print-this")
        def cleanup(phase):
            self.assertEqual(phase, "cleanup")
            raise AttributeError("another-private-value")
        p.run, p.phase = run, cleanup
        self.local.recipe_hash = lambda: "recipe"
        self.local.cmd = lambda args: subprocess.CompletedProcess(args, 0, "revision\n", "")
        self.assertEqual(proof.execute(p), 1)
        result = json.loads(report.read_text())
        self.assertEqual(result["result"], "FAIL")
        self.assertEqual([c["detail"] for c in result["checks"]], ["TypeError", "AttributeError"])
        self.assertNotIn("private", report.read_text())
        self.assertNotIn("never-print", report.read_text())

    def test_linux_disk_preflight_uses_admitted_daemon_storage(self):
        self.local.env.pop("KIND_DOCKER_DATA_PATH", None)
        self.local.env["DOCKER_HOST"] = "unix:///owned/docker.sock"
        calls = []
        def command(args, **kwargs):
            calls.append(args)
            return subprocess.CompletedProcess(args, 0, str(self.root) + "\n", "")
        self.local.cmd = command
        with patch.object(stack.sys, "platform", "linux"), patch.object(stack.shutil, "disk_usage", return_value=SimpleNamespace(free=100)) as usage:
            with self.assertRaisesRegex(stack.StackError, "needs"):
                self.local.check_space(200)
            usage.assert_called_once_with(self.root)
        self.assertEqual(calls[0][1:3], ["--host", "unix:///owned/docker.sock"])

    def test_unavailable_default_docker_storage_is_not_a_silent_pass(self):
        self.local.env.pop("KIND_DOCKER_DATA_PATH", None)
        with patch.object(stack.sys, "platform", "darwin"), patch.object(stack.Path, "home", return_value=self.root):
            with self.assertRaisesRegex(stack.StackError, "KIND_DOCKER_DATA_PATH"):
                self.local.check_space(1)

    def test_explicit_vm_backing_path_is_measured(self):
        self.local.env["KIND_DOCKER_DATA_PATH"] = str(self.root)
        with patch.object(stack.shutil, "disk_usage", return_value=SimpleNamespace(free=100)) as usage:
            self.local.check_space(99)
            usage.assert_called_once_with(self.root)

    def test_failed_source_fetch_does_not_poison_retry_or_remove_other_state(self):
        source = self.local.state / "source"
        unrelated = self.local.state / "keep"
        unrelated.write_text("preserve")
        failing = True
        def command(args, **kwargs):
            if "fetch" in args and failing:
                raise stack.StackError("fetch interrupted")
            return subprocess.CompletedProcess(args, 0, "revision\n" if "rev-parse" in args else "", "")
        self.local.cmd = command
        with self.assertRaisesRegex(stack.StackError, "interrupted"):
            addons.checkout(self.local, "flows", "revision", source)
        self.assertFalse(source.exists())
        self.assertFalse(list(self.local.state.glob("source-fetch-*")))
        self.assertEqual(unrelated.read_text(), "preserve")
        failing = False
        addons.checkout(self.local, "flows", "revision", source)
        self.assertTrue(source.exists())

    def test_cargo_timeout_removes_only_the_allocated_container(self):
        calls = []
        self.local.arch = "arm64"
        self.local.pull = lambda image: None
        def command(args, **kwargs):
            calls.append(args)
            if "run" in args:
                raise stack.StackError("build timed out")
            return subprocess.CompletedProcess(args, 0, "", "")
        self.local.cmd = command
        with self.assertRaisesRegex(stack.StackError, "timed out"):
            addons.cargo_build(self.local, self.local.state / "source", self.local.state / "native")
        run, remove = calls
        name = run[run.index("--name") + 1]
        self.assertTrue(name.startswith("agent-relay-kind-cargo-"))
        self.assertEqual(remove, [*self.local.docker_args, "rm", "-f", name])
        self.assertIn("--user", run)
        self.assertIn("CARGO_HOME=/cargo", run)

    def test_cargo_cleanup_failure_is_reported(self):
        self.local.arch = "amd64"
        self.local.pull = lambda image: None
        self.local.cmd = lambda args, **kwargs: subprocess.CompletedProcess(args, 1 if "rm" in args else 0, "", "daemon unavailable")
        with self.assertRaisesRegex(RuntimeError, "cleanup failed"):
            addons.cargo_build(self.local, self.local.state / "source", self.local.state / "native")

    def test_mismatched_pinned_source_version_refused_before_cargo(self):
        self.local.check_space = lambda needed: None
        def checkout(local, repository, revision, path):
            package = path / "packages/relayflows/package.json"
            package.parent.mkdir(parents=True)
            package.write_text('{"version":"0.0.0"}')
        with patch.object(addons, "checkout", checkout), patch.object(addons, "cargo_build") as cargo:
            with self.assertRaisesRegex(ValueError, "disagree"):
                addons.build(self.local)
            cargo.assert_not_called()

    def test_leaf_failing_expiry_check_is_reissued_with_the_existing_host_ca(self):
        applied = []
        self.local.apply = lambda doc, chart=False: applied.append(doc)
        self.local.tls()
        ca = (self.local.state / "ca.crt").read_bytes()
        old_key = (self.local.state / "tls.key").read_bytes()
        command = self.local.cmd
        def expiring_leaf(args, **kwargs):
            # Simulate OpenSSL's negative expiry verdict, then exercise real
            # certificate issuance and strict chain verification portably.
            if "-checkend" in args and self.local.state / "tls.crt" in args:
                return subprocess.CompletedProcess(args, 1, "Certificate will expire", "")
            return command(args, **kwargs)
        self.local.cmd = expiring_leaf
        self.local.tls()
        self.local.cmd = command
        self.assertEqual((self.local.state / "ca.crt").read_bytes(), ca)
        self.assertNotEqual((self.local.state / "tls.key").read_bytes(), old_key)
        valid = command(["openssl", "x509", "-in", self.local.state / "tls.crt",
                         "-checkend", "86400", "-noout"], check=False)
        self.assertEqual(valid.returncode, 0)
        self.assertEqual(len(applied), 2)

    def test_truncated_cached_leaf_is_reissued_without_replacing_ca(self):
        self.local.apply = lambda *args, **kwargs: None
        self.local.tls()
        ca = (self.local.state / "ca.crt").read_bytes()
        (self.local.state / "tls.crt").write_text("truncated certificate")
        self.local.tls()
        self.assertEqual((self.local.state / "ca.crt").read_bytes(), ca)
        self.local.cmd(["openssl", "verify", "-x509_strict", "-CAfile", self.local.state / "ca.crt", self.local.state / "tls.crt"])

    def test_scheduled_writer_drains_before_manual_flow_starts(self):
        calls = []
        scheduled = {"metadata": {"name": "scheduled", "ownerReferences": [{"kind": "CronJob", "uid": "owned"}]}, "status": {}}
        listings = iter([[scheduled], [dict(scheduled, status={"conditions": [{"type": "Complete", "status": "True"}]})]])
        p = proof.Proof(self.local)
        def k(*args, **kwargs):
            calls.append(args)
            self.assertEqual(args[:2], ("get", "jobs"))
            return subprocess.CompletedProcess(args, 0, json.dumps({"items": next(listings)}), "")
        self.local.k = k
        with patch.object(proof.time, "sleep") as sleep:
            p.drain_scheduled_flows("owned")
        self.assertEqual(len(calls), 2)
        sleep.assert_called_once_with(2)

    def test_active_scheduled_writer_timeout_refuses_manual_run_and_restores_schedule(self):
        calls = []
        p = proof.Proof(self.local)
        def k(*args, **kwargs):
            calls.append(args)
            if args[:2] == ("get", "cronjob"):
                return subprocess.CompletedProcess(args, 0, json.dumps({"metadata": {"uid": "owned"}, "spec": {}}), "")
            self.assertEqual(args[:2], ("patch", "cronjob"))
            return subprocess.CompletedProcess(args, 0, "", "")
        self.local.k = k
        def refuse(uid):
            raise stack.StackError("scheduled Flow still owns the journal")
        p.drain_scheduled_flows = refuse
        with self.assertRaisesRegex(stack.StackError, "owns the journal"):
            p.flows()
        self.assertFalse(any(c[0] == "create" for c in calls))
        self.assertIn('"suspend":false', calls[-1][-1])


if __name__ == "__main__":
    unittest.main()
