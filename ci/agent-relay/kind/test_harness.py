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
import stack
import addons
import tls
import control
import local_host_setup


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
        result = subprocess.run(["make", "kind-down", "PYTHON=" + sys.executable,
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

    def test_ca_renewal_retains_exact_old_public_certificate_for_trust_cleanup(self):
        self.local.apply = lambda *args, **kwargs: None
        self.local.tls()
        ca = self.local.state / "ca.crt"
        previous = ca.read_bytes()
        command = self.local.cmd
        def expiring_ca(args, **kwargs):
            if "-checkend" in args and ca in args:
                return subprocess.CompletedProcess(args, 1, "Certificate will expire", "")
            return command(args, **kwargs)
        self.local.cmd = expiring_ca
        self.local.tls()
        self.local.cmd = command
        self.assertNotEqual(ca.read_bytes(), previous)
        managed = local_host_setup.managed_cas(ca)
        self.assertEqual(len(managed), 2)
        self.assertEqual(managed[1].read_bytes(), previous)
        self.assertEqual(managed[1].stat().st_mode & 0o777, 0o600)

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


if __name__ == "__main__":
    unittest.main()
