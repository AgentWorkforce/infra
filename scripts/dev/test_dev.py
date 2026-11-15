import importlib.util
import json
from pathlib import Path
import plistlib
import socket
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("dev", Path(__file__).with_name("dev.py"))
dev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dev)


class LauncherTests(unittest.TestCase):
    def test_sdk_fallback_handles_inherited_alias_and_preserves_explicit_choices(self):
        sdk_dir = "/Library/Developer/CommandLineTools/SDKs"
        clt = "/Library/Developer/CommandLineTools"
        cases = [
            ({}, clt, True, sdk_dir + "/MacOSX26.5.sdk"),
            ({"SDKROOT": sdk_dir + "/MacOSX.sdk"}, clt, True, sdk_dir + "/MacOSX26.5.sdk"),
            ({"SDKROOT": "macosx"}, clt, True, sdk_dir + "/MacOSX26.5.sdk"),
            ({"SDKROOT": sdk_dir + "/MacOSX27.2.sdk"}, clt, True, sdk_dir + "/MacOSX27.2.sdk"),
            ({"DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}, clt, True, None),
            ({}, "/Applications/Xcode.app/Contents/Developer", True, None),
            ({}, clt, False, None),
        ]
        for inherited, selected, installed, expected in cases:
            with self.subTest(inherited=inherited, selected=selected, installed=installed):
                with patch.dict(dev.os.environ, inherited, clear=True), \
                     patch.object(dev.sys, "platform", "darwin"), \
                     patch.object(dev.subprocess, "run", return_value=SimpleNamespace(stdout=selected)), \
                     patch.object(dev.Path, "is_dir", return_value=installed), \
                     patch.object(dev, "say"):
                    self.assertEqual(dev.environment().get("SDKROOT"), expected)

    def test_port_check_rejects_listener_but_allows_restart(self):
        with socket.socket() as server:
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind(("127.0.0.1", 0))
            port = server.getsockname()[1]
            server.listen(1)
            with patch.object(dev, "PORTS", ("port",)):
                self.assertTrue(dev.available_ports({"port": port}))
            with socket.create_connection(("127.0.0.1", port)) as client:
                connection, _ = server.accept()
                connection.close()
                self.assertEqual(client.recv(1), b"")
        with patch.object(dev, "PORTS", ("port",)):
            self.assertEqual(dev.available_ports({"port": port}), [])

    def test_missing_siblings_lists_every_repository(self):
        with tempfile.TemporaryDirectory() as directory:
            errors = dev.missing_repos(Path(directory))
            self.assertEqual(len(errors), len(dev.REQUIRED))
            for name in dev.REQUIRED:
                self.assertTrue(any(name in e for e in errors))

    def test_relaycast_preflight_accepts_typescript_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            for name in ("Dockerfile", "package.json", "packages/engine/package.json"):
                path = parent / "relaycast" / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            self.assertFalse(any("relaycast" in error for error in dev.missing_repos(parent)))
            (parent / "relaycast/packages/engine/package.json").unlink()
            self.assertIn(
                f"Incomplete sibling checkout: {parent / 'relaycast/packages/engine/package.json'}",
                dev.missing_repos(parent),
            )

    def config(self, directory, **updates):
        path = Path(directory) / "config.json"
        path.write_text(json.dumps({"adminEmail": "owner@kind.example", **updates}))
        path.chmod(0o600)
        return path

    def test_google_is_required_unless_explicit_operator_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.config(directory)
            with self.assertRaisesRegex(dev.DevError, "Missing googleClientId"):
                dev.read_config(path, "google")
            self.assertEqual(dev.read_config(path, "operator")["port"], 3100)

    def test_rejects_duplicate_ports_and_world_readable_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.config(directory, port=3102)
            with self.assertRaisesRegex(dev.DevError, "distinct"):
                dev.read_config(path, "operator")
            path.chmod(0o644)
            with self.assertRaisesRegex(dev.DevError, "chmod 600"):
                dev.read_config(path, "operator")

    def test_imports_only_google_values_without_shell_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "legacy.env"
            source.write_text('GOOGLE_CLIENT_ID="local-client"\nexport GOOGLE_CLIENT_SECRET=\'$(touch never)\'\nDATABASE_URL=do-not-import\n')
            path = self.config(directory, googleEnvFile="legacy.env")
            config = dev.read_config(path, "google")
            self.assertEqual(config["googleClientSecret"], "$(touch never)")
            self.assertEqual(config["googleClientId"], "local-client")
            self.assertNotIn("DATABASE_URL", config)

    def test_no_secrets_in_invalid_json_error(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.config(directory)
            path.write_text('{"googleClientSecret":"do-not-print", broken')
            with self.assertRaises(dev.DevError) as raised:
                dev.read_config(path, "google")
            self.assertNotIn("do-not-print", str(raised.exception))

    def test_refuses_takeover_marker_wrong_identity_and_origin(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "App.app"
            contents = app / "Contents"
            (contents / "Library/LaunchAgents").mkdir(parents=True)
            (contents / "Resources").mkdir()
            info = {"CFBundleIdentifier": dev.DEV_ID, "CFBundleURLTypes": [{"CFBundleURLSchemes": ["agentrelay-dev"]}]}
            info_path = contents / "Info.plist"
            info_path.write_bytes(plistlib.dumps(info))
            job_path = contents / f"Library/LaunchAgents/{dev.DEV_ID}.core.plist"
            job_path.write_bytes(plistlib.dumps({"Label": dev.DEV_ID + ".core"}))
            (contents / "Resources/site-url.txt").write_text("http://localhost:3100\n")
            dev.verify_bundle(app, "http://localhost:3100")
            info["AgentRelayProduct"] = dev.DEV_ID
            info_path.write_bytes(plistlib.dumps(info))
            with self.assertRaisesRegex(dev.DevError, "takeover"):
                dev.verify_bundle(app, "http://localhost:3100")
            del info["AgentRelayProduct"]
            info["CFBundleIdentifier"] = "com.agentrelay.desktop"
            info_path.write_bytes(plistlib.dumps(info))
            with self.assertRaisesRegex(dev.DevError, "identity"):
                dev.verify_bundle(app, "http://localhost:3100")

    def test_docker_desktop_started_only_for_its_own_stopped_context(self):
        env = {"PATH": "/usr/bin", "DOCKER_HOST": "unix:///Users/me/.docker/run/docker.sock"}
        opened = SimpleNamespace(returncode=0)
        with patch.object(dev, "docker_running", return_value=True), patch.object(dev.subprocess, "run") as run:
            dev.ensure_docker(env)
            run.assert_not_called()
        with patch.object(dev.sys, "platform", "darwin"), patch.object(dev.Path, "is_dir", return_value=True), \
                patch.object(dev.time, "sleep"), patch.object(dev, "docker_running", side_effect=[False, False, True]), \
                patch.object(dev.subprocess, "run", return_value=opened) as run:
            dev.ensure_docker(env)
            self.assertEqual(run.call_args.args[0][:3], ["open", "-g", "-a"])
        other = dict(env, DOCKER_HOST="unix:///Users/me/.colima/default/docker.sock")
        with patch.object(dev.sys, "platform", "darwin"), patch.object(dev.Path, "is_dir", return_value=True), \
                patch.object(dev, "docker_running", return_value=False), patch.object(dev.subprocess, "run") as run:
            with self.assertRaisesRegex(dev.DevError, "not reachable"):
                dev.ensure_docker(other)
            run.assert_not_called()

    def test_cluster_pause_and_resume_touch_only_the_owned_node(self):
        env = {"PATH": "/usr/bin"}
        ok = SimpleNamespace(returncode=0, stdout="")
        with patch.object(dev, "node_state", return_value=None), patch.object(dev.subprocess, "run") as run:
            self.assertFalse(dev.pause_cluster(env))
            run.assert_not_called()
        with patch.object(dev, "node_state", return_value="exited"), patch.object(dev.subprocess, "run", return_value=ok) as run:
            self.assertFalse(dev.pause_cluster(env))  # Only keeps Docker from restarting it.
            self.assertEqual([call.args[0][:2] for call in run.call_args_list], [["docker", "update"]])
        with patch.object(dev, "node_state", return_value="running"), patch.object(dev.subprocess, "run", return_value=ok) as run:
            self.assertTrue(dev.pause_cluster(env))
            self.assertEqual(run.call_args_list[0].args[0], ["docker", "update", "--restart", "no", dev.NODE])
            self.assertEqual(run.call_args.args[0][:2], ["docker", "stop"])
            self.assertEqual(run.call_args.args[0][-1], dev.NODE)
        with patch.object(dev, "node_state", return_value=None), patch.object(dev.subprocess, "run") as run:
            self.assertFalse(dev.resume_cluster(env))
            run.assert_not_called()
        with patch.object(dev, "node_state", return_value="running"), patch.object(dev.subprocess, "run", return_value=ok) as run:
            self.assertFalse(dev.resume_cluster(env))  # Already serving: nothing started.
            self.assertEqual(run.call_args.args[0][:2], ["docker", "exec"])
        down = SimpleNamespace(returncode=1, stdout="")
        with patch.object(dev, "node_state", return_value="running"), patch.object(dev.time, "sleep"), \
                patch.object(dev.subprocess, "run", side_effect=[down, down, ok]) as run:
            self.assertTrue(dev.resume_cluster(env))  # Docker restarted the node; wait for its API.
            self.assertTrue(all(call.args[0][:2] == ["docker", "exec"] for call in run.call_args_list))
        with patch.object(dev, "node_state", return_value="exited"), patch.object(dev.time, "sleep"), \
                patch.object(dev.subprocess, "run", return_value=ok) as run:
            self.assertTrue(dev.resume_cluster(env))
            self.assertEqual(run.call_args_list[0].args[0], ["docker", "start", dev.NODE])
        foreign = SimpleNamespace(returncode=0, stdout="running some-other-cluster\n")
        with patch.object(dev.subprocess, "run", return_value=foreign):
            self.assertIsNone(dev.node_state(env))
        owned = SimpleNamespace(returncode=0, stdout="running agent-relay-local\n")
        with patch.object(dev.subprocess, "run", return_value=owned):
            self.assertEqual(dev.node_state(env), "running")

    def test_snapshot_notices_deletion_but_ignores_build_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            source = repo / "macos/Sources/a.swift"
            source.parent.mkdir(parents=True)
            source.write_text("first")
            before = dev.source_snapshot(repo)
            source.unlink()
            self.assertNotEqual(before, dev.source_snapshot(repo))



if __name__ == "__main__":
    unittest.main()
