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
        with patch.object(dev, "node_state", return_value=None), patch.object(dev, "inspect_node", return_value=None), \
                patch.object(dev.subprocess, "run") as run:
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

    def test_pause_failure_is_an_error_not_nothing_to_pause(self):
        env = {"PATH": "/usr/bin"}
        failed = SimpleNamespace(returncode=1, stdout="", stderr="")
        with patch.object(dev, "node_state", return_value="running"), patch.object(dev.subprocess, "run", return_value=failed):
            with self.assertRaisesRegex(dev.DevError, "Could not pause"):
                dev.pause_cluster(env)
        with patch.object(dev.subprocess, "run", return_value=SimpleNamespace(returncode=1, stdout="", stderr="Cannot connect")):
            with self.assertRaisesRegex(dev.DevError, "Could not inspect"):
                dev.inspect_node(env)
        with patch.object(dev.subprocess, "run", return_value=SimpleNamespace(returncode=1, stdout="", stderr="Error: No such object: x")):
            self.assertIsNone(dev.inspect_node(env))

    def test_node_state_requires_this_checkouts_receipt_and_recorded_container(self):
        env = {"PATH": "/usr/bin", "DOCKER_HOST": "unix:///home/me/.docker/run/docker.sock"}
        with tempfile.TemporaryDirectory() as directory:
            receipt, record = Path(directory) / "cluster.json", Path(directory) / "node.json"
            inspected = SimpleNamespace(returncode=0, stdout=f"abc123 exited {dev.CLUSTER}\n", stderr="")
            with patch.object(dev, "RECEIPT", receipt), patch.object(dev, "NODE_RECORD", record), \
                    patch.object(dev.subprocess, "run", return_value=inspected):
                self.assertIsNone(dev.node_state(env))  # Same name and label, but no receipt: another checkout's.
                receipt.write_text(json.dumps({"name": dev.CLUSTER, "dockerHost": env["DOCKER_HOST"]}))
                self.assertIsNone(dev.node_state(env))  # Receipt, but this launcher never recorded the container.
                dev.record_node(env)
                self.assertEqual(dev.node_state(env), "exited")
                self.assertEqual(oct(record.stat().st_mode & 0o777), "0o600")
                replaced = SimpleNamespace(returncode=0, stdout=f"def456 exited {dev.CLUSTER}\n", stderr="")
                with patch.object(dev.subprocess, "run", return_value=replaced):
                    self.assertIsNone(dev.node_state(env))  # Recreated elsewhere under the same name.
                self.assertIsNone(dev.node_state(dict(env, DOCKER_HOST="unix:///other.sock")))
                receipt.write_text(json.dumps({"name": dev.CLUSTER, "dockerHost": "unix:///other.sock"}))
                self.assertIsNone(dev.node_state(env))
            foreign = SimpleNamespace(returncode=0, stdout="abc123 running some-other-cluster\n", stderr="")
            with patch.object(dev.subprocess, "run", return_value=foreign):
                self.assertIsNone(dev.inspect_node(env))

    def test_resume_refuses_a_stopped_node_it_cannot_prove_is_this_checkouts(self):
        env = {"PATH": "/usr/bin"}
        with patch.object(dev, "node_state", return_value=None), patch.object(dev, "inspect_node", return_value=("abc", "exited")), \
                patch.object(dev.subprocess, "run") as run:
            with self.assertRaisesRegex(dev.DevError, "did not record"):
                dev.resume_cluster(env)
            run.assert_not_called()
        with patch.object(dev, "node_state", return_value=None), patch.object(dev, "inspect_node", return_value=("abc", "running")):
            self.assertFalse(dev.resume_cluster(env))  # Running: the stack's own ownership check decides.

    def test_cluster_stays_up_while_backend_restoration_runs(self):
        env = {"PATH": "/usr/bin"}
        with patch.object(dev, "pause_cluster") as pause, patch.object(dev, "say"):
            dev.finish_cluster(env, keep_running=False, restored=False)
            pause.assert_not_called()
            dev.finish_cluster(env, keep_running=False, restored=True)
            pause.assert_called_once()
        with patch.object(dev, "pause_cluster", side_effect=dev.DevError("Could not pause")), patch.object(dev, "say") as say:
            dev.finish_cluster(env, keep_running=False, restored=True)  # Reported, does not mask the original exit.
            self.assertIn("Could not pause", say.call_args.args[0])

    def test_close_reports_unfinished_restoration_and_blocks_the_next_start(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            marker = state / "restoring.json"
            log = state / "backends.log"
            with patch.object(dev, "STATE", state), patch.object(dev, "RESTORING", marker), patch.object(dev, "say"):
                supervisor = dev.Supervisor({})
                backend = Mock(pid=4242)
                backend.poll.return_value = None
                backend.wait.side_effect = dev.subprocess.TimeoutExpired("dev.py", 1800)
                supervisor.children = [("backends", backend)]
                self.assertFalse(supervisor.close())
                backend.terminate.assert_called_once()
                self.assertEqual(json.loads(marker.read_text()), {"pid": 4242})
                alive = SimpleNamespace(returncode=0, stdout="python ci/agent-relay/dev/dev.py run\n")
                with patch.object(dev.subprocess, "run", return_value=alive):
                    self.assertIn("pid 4242", dev.restore_block())
                gone = SimpleNamespace(returncode=1, stdout="")
                with patch.object(dev.subprocess, "run", return_value=gone):
                    self.assertIsNone(dev.restore_block())
                self.assertFalse(marker.exists())

                def finished(returncode, events):
                    log.write_text("old\n" + json.dumps({"stage": "restore_complete"}) + "\n")  # An earlier run's event.
                    supervisor = dev.Supervisor({})
                    supervisor.backend_log_offset = log.stat().st_size
                    with log.open("a") as stream:
                        stream.writelines(json.dumps({"stage": e}) + "\n" for e in events)
                    process = Mock(pid=4243, returncode=returncode)
                    process.poll.return_value = None
                    supervisor.children = [("backends", process)]
                    return supervisor.close()

                self.assertTrue(finished(0, ["watching", "restore_complete"]))
                self.assertFalse(marker.exists())
                # The watcher restores in finally and re-raises what stopped it: exit 1 after a full restore.
                self.assertTrue(finished(1, ["watching", "refused", "restore_complete"]))
                self.assertFalse(marker.exists())
                for returncode, events in ((1, ["restore_incomplete"]), (0, ["watching"]), (None, [])):
                    with self.subTest(returncode=returncode, events=events):
                        self.assertFalse(finished(returncode, events))
                        self.assertTrue(json.loads(marker.read_text())["failed"])
                        with patch.object(dev.subprocess, "run", return_value=gone):
                            self.assertIn("did not complete", dev.restore_block())  # Persists after the watcher exits.
                        marker.unlink()

    def test_bootstrap_tools_are_not_required_before_their_preparation(self):
        with tempfile.TemporaryDirectory() as directory:
            bin_dir = Path(directory) / "bin"
            bin_dir.mkdir()
            for name in ("docker", "kubectl", "openssl", "git", "npm"):
                path = bin_dir / name
                path.write_text("#!/bin/sh\n")
                path.chmod(0o755)
            env = {"PATH": str(bin_dir)}
            with patch.object(dev, "missing_repos", return_value=[]):
                errors = dev.check_prerequisites(Path(directory), env, desktop=False, bootstrap=True)
                self.assertFalse(any("kind" in e or "helm" in e for e in errors), errors)
                errors = dev.check_prerequisites(Path(directory), env, desktop=False, bootstrap=False)
                self.assertIn("Missing executable: kind", errors)
                self.assertIn("Missing executable: helm", errors)
            self.assertEqual(len(dev.missing_bootstrapped(env)), 2)

    def test_desktop_retry_after_a_failed_rebuild_has_no_ui_to_stop(self):
        supervisor = dev.Supervisor({})
        supervisor.desktop_process = None
        dev.stop_desktop_ui(supervisor)  # Previously AttributeError, which stopped every service.
        ui = Mock()
        supervisor.desktop_process = ui
        dev.stop_desktop_ui(supervisor)
        ui.terminate.assert_called_once()
        self.assertIsNone(supervisor.desktop_process)

    def test_snapshot_tolerates_a_file_deleted_mid_scan(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            kept, gone = repo / "macos/Sources/b.swift", repo / "macos/Sources/a.swift"
            kept.parent.mkdir(parents=True)
            kept.write_text("b")
            # The walk listed a.swift and is_file() saw it; the editor removed it before stat().
            with patch.object(dev.Path, "rglob", lambda self, pattern: iter([gone, kept])), \
                    patch.object(dev.Path, "is_file", lambda self: self.name.endswith(".swift")):
                snapshot = dev.source_snapshot(repo)
            self.assertEqual([Path(p).name for p in snapshot], ["b.swift"])

    def test_control_patch_drops_native_oidc_settings_it_does_not_own(self):
        stack = Mock()
        config = {"port": 3100, "adminEmail": "owner@kind.example", "googleClientId": "id", "googleClientSecret": "secret"}
        for auth in ("google", "operator"):
            with self.subTest(auth=auth):
                stack.reset_mock()
                dev.configure_control(stack, config, auth)
                patch_call = next(c for c in stack.k.call_args_list if c.args[:1] == ("patch",))
                env = json.loads(patch_call.kwargs["data"])["spec"]["template"]["spec"]["containers"][0]["env"]
                deleted = {e["name"] for e in env if e.get("$patch") == "delete"}
                self.assertTrue({"SELFHOST_OIDC_CLIENT_SECRET_FILE", "SELFHOST_OIDC_ALLOWED_DOMAINS",
                                 "SELFHOST_OIDC_SCOPES", "SELFHOST_OIDC_ALLOW_HTTP_ISSUER"} <= deleted)
                if auth == "operator":
                    self.assertIn("SELFHOST_OIDC_ISSUER", deleted)
                else:
                    self.assertIn("SELFHOST_OIDC_ISSUER", {e["name"] for e in env if e.get("value")})
                    # The chart's literal client id must be cleared when switching to the Secret.
                    for e in env:
                        if "valueFrom" in e:
                            self.assertIn("value", e)
                            self.assertIsNone(e["value"])
                    self.assertIn("SELFHOST_OIDC_CLIENT_ID", {e["name"] for e in env if "valueFrom" in e})

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
