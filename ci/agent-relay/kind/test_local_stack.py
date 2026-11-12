"""Local target ownership, host changes, and real native Helm composition."""
import json
import io
import ipaddress
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import yaml

from local_host_setup import host_contents
import local_host_setup
import local_stack
from local_stack import LocalStack, ROOT, read_model_key, check_selection, selected_images
from stack import StackError


class LocalTests(unittest.TestCase):
    def candidate_fixture(self, root):
        spec = importlib.util.spec_from_file_location("candidate_test_helper", ROOT / "scripts/release/update-release-candidate.py")
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        ledger = {"schema": 1, "version": "2026.11.1", "pins": {
            name: {"repository": entry["imageRepository"], "digest": "sha256:" + str(index) * 64,
                "sourceRepository": entry["sourceRepository"], "sourceRevision": "b" * 40}
            for index, (name, entry) in enumerate(helper.COMPONENTS.items(), 1)}}
        directory = root / "releases/agent-relay-2026.11.1"
        directory.mkdir(parents=True)
        pins, values = directory / "pins.json", directory / "values.yaml"
        pins.write_text(json.dumps(ledger))
        values.write_text(helper.render_values(ledger))
        return helper, ledger, pins, values

    def test_candidate_selector_preserves_default_and_rejects_preview_mix(self):
        base = {"unchanged": True}
        self.assertIs(local_stack.candidate_profile(base, environ={}), base)
        for version in ("../2026.11.1", "2026.11.1-beta.1", "02026.11.1", " 2026.11.1"):
            with self.subTest(version=version), self.assertRaisesRegex(StackError, "strict stable"):
                local_stack.candidate_profile(base, environ={"LOCAL_RELEASE_CANDIDATE": version})
        with self.assertRaisesRegex(StackError, "cannot be combined"):
            local_stack.candidate_profile(base, environ={"LOCAL_RELEASE_CANDIDATE": "2026.11.1", "LOCAL_DESKTOP_RELEASES": "1"})

    def test_candidate_selector_refuses_missing_drifted_incomplete_and_redirected_inputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            environ = {"LOCAL_RELEASE_CANDIDATE": "2026.11.1"}
            with self.assertRaisesRegex(StackError, "validation failed"):
                local_stack.candidate_profile({}, root, environ)
            helper, ledger, pins, values = self.candidate_fixture(root)
            canonical = values.read_text()
            values.write_text(canonical + "unexpected: true\n")
            with self.assertRaisesRegex(StackError, "validation failed"):
                local_stack.candidate_profile({}, root, environ)
            values.write_text(canonical)
            ledger["pins"].pop("relay-control")
            pins.write_text(json.dumps(ledger))
            values.write_text(helper.render_values(ledger))
            with self.assertRaisesRegex(StackError, "validation failed"):
                local_stack.candidate_profile({}, root, environ)
            ledger["pins"]["relay-webapp"]["repository"] = "ghcr.io/unexpected/webapp"
            pins.write_text(json.dumps(ledger))
            with self.assertRaisesRegex(StackError, "validation failed"):
                local_stack.candidate_profile({}, root, environ)
            pins.unlink()
            pins.symlink_to(values)
            with self.assertRaisesRegex(StackError, "symlinks"):
                local_stack.candidate_profile({}, root, environ)

    def test_candidate_images_reach_real_native_render_without_preview_env_or_policy(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, ledger, _, _ = self.candidate_fixture(root)
            base = yaml.safe_load((ROOT / "charts/agent-relay/values-eks.yaml").read_text())
            profile = local_stack.candidate_profile(base, root, {"LOCAL_RELEASE_CANDIDATE": "2026.11.1"})
            self.assertNotEqual(profile["relay-control"]["image"], base["relay-control"]["image"])
            self.assertEqual(profile["relay-control"]["selectedFeatures"], base["relay-control"]["selectedFeatures"])
            references = {name: value["repository"] + "@" + value["digest"] for name, value in ledger["pins"].items()}
            for name in ("ci/agent-relay/kind/local-values.yaml", "ci/agent-relay/kind/desktop-releases-values.yaml",
                    "charts/agent-relay/values-eks.yaml", "charts/agent-relay/values-scrub-wasm-bindgen.yaml",
                    "charts/session-read-api/values.yaml", "scripts/release/update-release-candidate.py"):
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / name, target)
            program = "import sys,json;from pathlib import Path;sys.path.insert(0,'ci/agent-relay/kind');import stack;stack.ROOT=Path(sys.argv[1]);import local_stack as s;print(json.dumps(s.selected_images()))"
            environ = {**os.environ, "LOCAL_RELEASE_CANDIDATE": "2026.11.1"}
            environ.pop("LOCAL_DESKTOP_RELEASES", None)
            process = subprocess.run([sys.executable, "-c", program, str(root)], cwd=ROOT, env=environ, capture_output=True, text=True, check=True)
            actual = json.loads(process.stdout)
            self.assertEqual([actual[key] for key in ("control", "webapp", "pipeline")],
                [references[name] for name in ("relay-control", "relay-webapp", "sessions-pipeline")])
            with patch.multiple(local_stack, AA_VALUES=profile, DESKTOP_RELEASES=False,
                    CONTROL=references["relay-control"], WEBAPP=references["relay-webapp"], PIPELINE=references["sessions-pipeline"]):
                selected = selected_images()
                self.assertEqual([selected[key] for key in ("control", "webapp", "pipeline")],
                    [references[name] for name in ("relay-control", "relay-webapp", "sessions-pipeline")])
                self.assert_final_render(experimental=False, profile=profile)

    def test_desktop_releases_opt_in_is_explicit_and_defaults_off(self):
        for environ in ({}, {"LOCAL_DESKTOP_RELEASES": ""}, {"LOCAL_DESKTOP_RELEASES": "0"}):
            self.assertFalse(local_stack.desktop_releases_enabled(environ))
        self.assertTrue(local_stack.desktop_releases_enabled({"LOCAL_DESKTOP_RELEASES": "1"}))
        for value in ("true", "on", "2", " 1"):
            with self.assertRaises(StackError):
                local_stack.desktop_releases_enabled({"LOCAL_DESKTOP_RELEASES": value})

    def test_fresh_process_selects_release_images_unless_explicitly_opted_in(self):
        program = "import sys,json;sys.path.insert(0,'ci/agent-relay/kind');import local_stack as s;print(json.dumps([s.DESKTOP_RELEASES,s.CONTROL,s.WEBAPP]))"
        for enabled in (False, True):
            environ = dict(os.environ)
            environ.pop("LOCAL_DESKTOP_RELEASES", None)
            if enabled:
                environ["LOCAL_DESKTOP_RELEASES"] = "1"
            result = subprocess.run([sys.executable, "-c", program], cwd=ROOT, env=environ, capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(result.stdout), [enabled, *local_stack.profile_images(enabled)])

    def test_fresh_reader_uses_managed_values_when_chart_reserves_environment(self):
        reader = {"extraEnv": [{"name": "READ_API_SESSION_QUERY", "value": "true"}]}
        with patch.object(local_stack, "READER_VALUES", {"turns": {"assumeNoLegacy": False},
                "timing": {"assumeNoTurns": False}, "canonical": {"pinLaggingPointer": False}}):
            local_stack.fresh_reader(reader)
        self.assertEqual(reader, {"turns": {"assumeNoLegacy": True}, "timing": {"assumeNoTurns": True}, "canonical": {"pinLaggingPointer": True},
            "extraEnv": [{"name": "READ_API_SESSION_QUERY", "value": "true"}]})

    def test_services_jobs_keep_the_required_wasm_contract(self):
        stack = LocalStack.__new__(LocalStack)
        stack.k = lambda *args: SimpleNamespace(stdout="")
        with patch.object(stack, "apply") as apply, patch.object(stack, "wait_job"):
            stack.job("migrate", local_stack.PIPELINE, env=[{"name": "SERVICE", "value": "hoopdb-migrate"}])
            container = apply.call_args.args[0]["spec"]["template"]["spec"]["containers"][0]
            env = {e["name"]: e["value"] for e in container["env"]}
            self.assertEqual(env, {"SERVICE": "hoopdb-migrate", "SCRUB_ENGINE": "wasm-bindgen",
                "SCRUB_ENGINE_REQUIRED": "wasm-bindgen", "READER_MAX_RULESET": "10"})
            self.assertEqual(len(container["env"]), len(env))
            stack.job("control-migrate", local_stack.CONTROL)
            self.assertEqual(apply.call_args.args[0]["spec"]["template"]["spec"]["containers"][0]["env"], [])

    def test_tls_consumer_waits_for_current_mount_before_reload_and_records_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            stack = LocalStack.__new__(LocalStack)
            stack.state = Path(tmp)
            stack.leaf_sha = local_stack.hashlib.sha256(b"new certificate").hexdigest()
            responses = iter(["old certificate", "new certificate"])
            loaded = {"leaf": "old certificate", "reloads": 0}
            def command(*args, **kwargs):
                loaded["leaf"] = next(responses)
                return SimpleNamespace(returncode=0, stdout=loaded["leaf"])
            def reload():
                self.assertEqual(loaded["leaf"], "new certificate")
                loaded["reloads"] += 1
            stack.k = command
            with patch.object(local_stack.time, "sleep"):
                stack.reload_leaf_consumer("postgres", "postgres-0", None, "/tls/tls.crt", reload)
                stack.reload_leaf_consumer("postgres", "postgres-0", None, "/tls/tls.crt", reload)
            self.assertEqual(loaded["reloads"], 1)
            self.assertEqual((stack.state / "postgres-tls.sha256").read_text().strip(), stack.leaf_sha)

    def test_tls_reload_failure_retains_old_success_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            stack = LocalStack.__new__(LocalStack)
            stack.state = Path(tmp)
            marker = stack.state / "collector-tls.sha256"
            marker.write_text("old")
            stack.leaf_sha = local_stack.hashlib.sha256(b"new certificate").hexdigest()
            stack.k = lambda *args, **kwargs: SimpleNamespace(returncode=0, stdout="new certificate")
            def fail():
                raise StackError("reload failed")
            with self.assertRaisesRegex(StackError, "reload failed"):
                stack.reload_leaf_consumer("collector", "deployment/telemetry-collector", "tls-proxy", "/tls/tls.crt", fail)
            self.assertEqual(marker.read_text(), "old")

    def test_trust_cleanup_covers_current_and_all_retained_ca_certificates(self):
        with tempfile.TemporaryDirectory() as tmp:
            current, old = Path(tmp) / "ca.crt", Path(tmp) / "old.crt"
            current.write_text("new certificate")
            old.write_text("old certificate")
            with patch.object(local_host_setup.ssl, "PEM_cert_to_DER_cert", side_effect=lambda text: text.encode()), patch.object(local_host_setup, "remove_ca") as remove:
                local_host_setup.remove_saved_cas([current, old])
                self.assertEqual([c.args[0] for c in remove.call_args_list], [current, old])
                remove.reset_mock()
                local_host_setup.remove_saved_cas([current, old], keep=current)
                self.assertEqual([c.args[0] for c in remove.call_args_list], [old])

    def test_teardown_discards_only_dev_config_bound_to_deleted_cluster(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            stack = LocalStack.__new__(LocalStack)
            stack.name = "agent-relay-local"
            stack.kubeconfig = root / ".kind/local/kubeconfig"
            stack.env = {"DOCKER_HOST": "unix:///local/docker.sock"}
            path = root / ".kind/dev/config.json"
            path.parent.mkdir(parents=True)
            config = {"clusterUid": "owned-uid", "cluster": stack.name, "context": "kind-" + stack.name,
                "namespace": "agent-relay", "dockerHost": stack.env["DOCKER_HOST"], "kubeconfig": str(stack.kubeconfig.resolve())}
            with patch.object(local_stack, "ROOT", root):
                for key in config:
                    path.write_text(json.dumps({**config, key: "another-target"}))
                    stack.discard_dev_config({"clusterUid": "owned-uid"})
                    self.assertTrue(path.exists(), key)
                path.write_text(json.dumps(config))
                stack.discard_dev_config({"clusterUid": "owned-uid"})
                self.assertFalse(path.exists())
            self.assertTrue(path.parent.exists())

    def pipeline_shutdown_fixture(self, clears_after):
        stack = LocalStack.__new__(LocalStack)
        state = {"scaled": False, "polls": 0}
        names = ("session-native-ingest", "session-native-consumer", "session-read-api", "sessions-session-brief")
        def command(*args, **kwargs):
            if args[0] == "scale":
                state["scaled"] = True
            elif args[:2] == ("get", "deployment"):
                if state["scaled"]:
                    state["polls"] += 1
                return SimpleNamespace(stdout=json.dumps({"items": [
                    {"metadata": {"name": n, "namespace": "agent-relay", "uid": n, "generation": 2 if state["scaled"] else 1,
                        "annotations": {"meta.helm.sh/release-name": "agent-relay"}},
                     "spec": {"replicas": 0 if state["scaled"] else 1, "selector": {"matchLabels": {"app": n}}},
                     "status": {"observedGeneration": 2 if state["scaled"] else 1}} for n in names]}))
            elif args[:2] == ("get", "pods"):
                draining = args[3] == "app=session-native-ingest" and state["polls"] < clears_after
                return SimpleNamespace(stdout=json.dumps({"items": [{"metadata": {"deletionTimestamp": "still-draining"}}] if draining else []}))
            return SimpleNamespace(stdout="")
        stack.k = command
        return stack, state

    def test_migrations_wait_for_terminating_old_pod_to_disappear(self):
        stack, state = self.pipeline_shutdown_fixture(clears_after=3)
        def stage(name, callback):
            self.assertTrue(state["scaled"])
            self.assertEqual(state["polls"], 3)
            callback()
        stack.stage = stage
        with patch.object(stack, "migrate_pipeline") as migrate, patch.object(local_stack.time, "sleep"):
            stack.prepare_pipeline_generation(True)
        migrate.assert_called_once_with()

    def test_shutdown_timeout_preserves_state_and_never_starts_migrations(self):
        stack, state = self.pipeline_shutdown_fixture(clears_after=999)
        clock = {"value": 0}
        with patch.object(stack, "stage") as stage, patch.object(stack, "migrate_pipeline") as migrate, patch.object(local_stack.time, "monotonic", side_effect=lambda: clock["value"]), patch.object(local_stack.time, "sleep", side_effect=lambda seconds: clock.update(value=181)):
            with self.assertRaisesRegex(StackError, "migrations not started.*state preserved"):
                stack.prepare_pipeline_generation(True)
        self.assertTrue(state["scaled"])
        stage.assert_not_called()
        migrate.assert_not_called()

    def test_existing_exact_credential_probe_is_verified_without_reinstalling(self):
        stack = LocalStack.__new__(LocalStack)
        installer = "AS $credential_probe$\nBEGIN RETURN true; END\n$credential_probe$;"
        row = {"owner": "postgres", "definer": True, "config": ["search_path=pg_catalog"], "body": "\nBEGIN RETURN true; END\n"}
        with patch.object(stack, "k", return_value=SimpleNamespace(stdout=json.dumps(row))), patch.object(stack, "sql") as sql:
            stack.ensure_credential_probe(installer)
            sql.assert_not_called()
        for override in ({"owner": "unexpected"}, {"definer": False}, {"body": "changed"}, {"config": None}):
            with patch.object(stack, "k", return_value=SimpleNamespace(stdout=json.dumps({**row, **override}))), patch.object(stack, "sql") as sql:
                with self.assertRaisesRegex(StackError, "no function is overwritten"):
                    stack.ensure_credential_probe(installer)
                sql.assert_not_called()

    def test_missing_credential_probe_uses_official_installer(self):
        stack = LocalStack.__new__(LocalStack)
        with patch.object(stack, "k", return_value=SimpleNamespace(stdout="")), patch.object(stack, "sql") as sql:
            stack.ensure_credential_probe("official installer")
            self.assertEqual(sql.call_args.args, ("hoopdb", "official installer"))

    def test_pipeline_only_pin_change_runs_migrations_without_adopting_another_generation(self):
        previous = {**selected_images(), "pipeline": "old"}
        self.assertFalse(check_selection(None, previous))
        self.assertFalse(check_selection(previous, previous))
        self.assertTrue(check_selection(previous, {**previous, "pipeline": "new"}))
        for selection in (*({**previous, key: "new"} for key in previous if key != "pipeline"), {"pipeline": "new"}):
            with self.assertRaisesRegex(StackError, "non-pipeline"):
                check_selection(previous, selection)

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
            spec = apply.call_args.args[0]["spec"]
            self.assertEqual(spec["podSelector"]["matchLabels"], {"app.kubernetes.io/instance": "agent-relay", "app.kubernetes.io/component": "session-brief"})
            self.assertEqual(spec["policyTypes"], ["Egress"])
            self.assertEqual(len(spec["egress"]), 1)
            rule = spec["egress"][0]
            self.assertEqual(rule["ports"], [{"protocol": "TCP", "port": 443}])
            block = rule["to"][0]["ipBlock"]
            def allows(address):
                ip = ipaddress.ip_address(address)
                return ip in ipaddress.ip_network(block["cidr"]) and not any(ip in ipaddress.ip_network(n) for n in block["except"])
            for address in ("1.1.1.1", "8.8.8.8", "172.15.255.255", "172.32.0.0", "169.253.255.255"):
                self.assertTrue(allows(address), address)
            for address in ("10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.169.254"):
                self.assertFalse(allows(address), address)
            self.assertEqual(stack.model_key_sha, local_stack.hashlib.sha256(b"fixture").hexdigest())

    def test_explicit_empty_model_override_disables_model_calls(self):
        stack = LocalStack.__new__(LocalStack)
        with patch.dict(local_stack.os.environ, {"OPENAI_API_KEY": ""}), patch.object(stack, "secret") as secret, patch.object(stack, "k") as k:
            stack.configure_model()
            secret.assert_called_once_with("local-model", {"OPENAI_API_KEY": ""})
            self.assertEqual(k.call_args.args[:2], ("delete", "networkpolicy"))

    def test_github_releases_egress_is_control_api_only_and_excludes_private_https(self):
        stack = LocalStack.__new__(LocalStack)
        with patch.object(local_stack, "DESKTOP_RELEASES", True), patch.object(stack, "apply") as apply:
            stack.github_releases_egress()
        policy = apply.call_args.args[0]
        self.assertEqual(policy["metadata"]["name"], "local-control-github-releases-egress")
        self.assertEqual(policy["spec"]["podSelector"]["matchLabels"], {
            "app.kubernetes.io/name": "relay-control", "app.kubernetes.io/instance": "agent-relay",
            "app.kubernetes.io/component": "api"})
        self.assertEqual(policy["spec"]["policyTypes"], ["Egress"])
        self.assertEqual(len(policy["spec"]["egress"]), 1)
        rule = policy["spec"]["egress"][0]
        self.assertEqual(rule["ports"], [{"protocol": "TCP", "port": 443}])
        block = rule["to"][0]["ipBlock"]
        self.assertEqual(block["cidr"], "0.0.0.0/0")
        self.assertEqual(set(block["except"]), {"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16"})

    def test_ca_removal_failure_stops_before_state_or_cluster_removal(self):
        with tempfile.TemporaryDirectory() as tmp:
            stack = LocalStack.__new__(LocalStack)
            stack.state = Path(tmp)
            stack.marker = stack.state / "cluster.json"
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
            with patch.object(local_stack.sys, "platform", "darwin"), patch.object(local_stack, "managed_cas", return_value=[stack.state / "ca.crt"]), patch.object(local_stack, "certificate_present", return_value=True):
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
        control, webapp = local_stack.profile_images(False)
        with patch.multiple(local_stack, DESKTOP_RELEASES=False, CONTROL=control, WEBAPP=webapp):
            self.assert_final_render(experimental=False)

    def test_opt_in_final_render_selects_downloads_images_env_and_policy(self):
        control, webapp = local_stack.profile_images(True)
        with patch.multiple(local_stack, DESKTOP_RELEASES=True, CONTROL=control, WEBAPP=webapp):
            self.assert_final_render(experimental=True)

    def assert_final_render(self, experimental, profile=None):
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
        aa = profile if profile is not None else yaml.safe_load((ROOT / "charts/agent-relay/values-eks.yaml").read_text())
        release = {name: local_stack.reference(aa[name]["image"]) for name in ("relay-control", "relay-webapp", "relaycast")}
        selected = local_stack.DESKTOP_RELEASE_VALUES if experimental else aa
        for name in ("relay-control", "relay-webapp"):
            release[name] = local_stack.reference(selected[name]["image"])
        with patch.object(stack, "apply") as apply:
            stack.github_releases_egress()
        if experimental:
            github_selector = apply.call_args.args[0]["spec"]["podSelector"]["matchLabels"]
        else:
            apply.assert_not_called()
            github_selector = None
        release.update({name: local_stack.reference(aa["sessions-pipeline"]["worker"]["image"])
            for name in ("session-native-ingest", "session-native-consumer", "session-read-api", "sessions-session-brief")})
        for deployment in active:
            pod = deployment["spec"]["template"]["spec"]
            labels = deployment["spec"]["template"]["metadata"]["labels"]
            if github_selector:
                self.assertEqual(all(labels.get(k) == v for k, v in github_selector.items()), deployment["metadata"]["name"] == "relay-control")
            if deployment["metadata"]["name"] in release:
                self.assertEqual(pod["containers"][0]["image"], release[deployment["metadata"]["name"]])
            if deployment["metadata"]["name"] == "relay-webapp":
                pod = deployment["spec"]["template"]["spec"]
                copy = next(c for c in pod["initContainers"] if c["name"] == "copy-dashboard")
                dashboard = next(c for c in pod["containers"] if c["name"] == "dashboard")
                self.assertEqual(copy["image"], local_stack.WEBAPP)
                self.assertEqual(dashboard["image"], copy["image"])
            for container in deployment["spec"]["template"]["spec"]["containers"]:
                self.assertIn("@sha256:", container["image"])
                self.assertIn(container["image"], selected_images().values())
                env = {e["name"]: e for e in container.get("env", [])}
                if container["image"] == local_stack.PIPELINE:
                    self.assertEqual(env["SCRUB_ENGINE"]["value"], "wasm-bindgen")
                    self.assertEqual(env["SCRUB_ENGINE_REQUIRED"]["value"], "wasm-bindgen")
                    self.assertEqual(env["READER_MAX_RULESET"]["value"], "10")
                if "OPENAI_API_KEY" in env:
                    self.assertIn("valueFrom", env["OPENAI_API_KEY"])
                name = deployment["metadata"]["name"]
                if name == "session-native-ingest":
                    self.assertEqual(env["SELFHOST_INGEST_ADMISSION"]["value"], "async")
                    self.assertIn("admission", json.dumps(container["readinessProbe"]))
                if name == "session-read-api":
                    self.assertEqual(env["READ_API_SESSION_QUERY"]["value"], "true")
                    for flag in ("READ_API_TURNS_ASSUME_NO_LEGACY", "READ_API_TIMING_ASSUME_NO_TURNS", "READ_API_CANONICAL_PIN_LAGGING_POINTER"):
                        self.assertEqual(env[flag]["value"], "true")
                        self.assertEqual(sum(e["name"] == flag for e in container["env"]), 1)
                if name == "sessions-session-brief":
                    self.assertEqual(env["SESSION_BRIEF_GLOBAL_DAILY_CAP"]["value"], "64")
                    self.assertEqual(env["SESSION_BRIEF_SESSION_DAILY_CAP"]["value"], "3")
                    self.assertEqual(env["ANALYTICS_SINK"]["value"], "collector")
                    self.assertIn("local-telemetry-brief", json.dumps(container))
                    self.assertTrue(any(m["name"] == "brief-analytics-ca" for m in container["volumeMounts"]))
                    self.assertEqual(deployment["spec"]["template"]["metadata"]["labels"]["agentworkforce.dev/analytics-producer"], "true")
                if name in ("session-native-ingest", "session-native-consumer", "session-read-api"):
                    self.assertEqual(env["ANALYTICS_SINK"]["value"], "collector")
                    self.assertIn("valueFrom", env["ANALYTICS_COLLECTOR_TOKEN"])
                    self.assertTrue(any(m["name"] == "analytics-ca" for m in container["volumeMounts"]))
                if name == "relay-control":
                    self.assertEqual(env["SELFHOST_FEATURES"]["value"], "usage,launch")
                    if experimental:
                        self.assertEqual(env["SELFHOST_DESKTOP_RELEASES_REPO"]["value"], "AgentWorkforce/relay-desktop-kind-releases")
                        self.assertEqual(sum(e["name"] == "SELFHOST_DESKTOP_RELEASES_REPO" for e in container["env"]), 1)
                    else:
                        self.assertNotIn("SELFHOST_DESKTOP_RELEASES_REPO", env)
                        for component in ("relay-control", "relay-webapp"):
                            self.assertEqual(release[component], local_stack.reference(aa[component]["image"]))
                    self.assertEqual(env["SELFHOST_ANALYTICS_DESTINATION"]["value"], "collector")
                    self.assertTrue(any(m["name"] == "analytics-producer" for m in container["volumeMounts"]))
                if name == "relaycast":
                    self.assertEqual(env["RELAYCAST_TELEMETRY_DESTINATION"]["value"], "collector")
                    self.assertTrue(any(m["name"] == "analytics-token" for m in container["volumeMounts"]))


if __name__ == "__main__":
    unittest.main()
