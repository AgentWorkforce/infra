"""Real Stack/guard source; command/socket fakes never claim a cluster proof."""
from copy import deepcopy
import errno
import json
import os
from pathlib import Path
import socket
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

import native_target
from native_target import NativeInstanceTarget, NativeInstanceStack, binding, require_record, require_free_ports
from native_bootstrap import NativeBootstrapAdapter
from native_core_cli import run
from native_inspect import INPUT_FIELDS
from native_recipe import CORE_OPERATIONS, NativeRecipe, NativeRecipeError, selection
from stack import Stack, StackError
import stack as stack_module
import test_native_core_cli as cli_tests
import test_native_network as network_tests
import native_network
from native_core_values import compose
from test_native_control import contract
from test_native_recipe import selected


class Target(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.target = NativeInstanceTarget("agent-relay-core-native-proof1", ".kind/native-instances/agent-relay-core-native-proof1", 18080, 18443)

    def real_stack(self, target=None):
        with patch.object(stack_module, "ROOT", self.root): return NativeInstanceStack("core", target or self.target)

    def test_layout_selected_before_original_core_filesystem_access(self):
        old = self.root / ".kind/core"; old.mkdir(parents=True, mode=0o700)
        sentinel = old / "cluster.json"; sentinel.write_text("retained"); sentinel.chmod(0o600)
        before = {p: (p.stat().st_mode, p.stat().st_ctime_ns, p.stat().st_mtime_ns) for p in (old, sentinel)}
        stack = self.real_stack()
        self.assertEqual((stack.name, stack.state, stack.profile), (self.target.cluster_name, self.root / self.target.state_relative, "core"))
        self.assertEqual(before, {p: (p.stat().st_mode, p.stat().st_ctime_ns, p.stat().st_mtime_ns) for p in (old, sentinel)})
        empty = self.root / "empty"; empty.mkdir()
        with patch.object(stack_module, "ROOT", empty): NativeInstanceStack("core", self.target)
        self.assertFalse((empty / ".kind/core").exists())

    def test_default_core_addons_layout_and_native_ports_unchanged(self):
        for profile in ("core", "addons"):
            with patch.object(stack_module, "ROOT", self.root): stack = Stack(profile)
            self.assertEqual((stack.name, stack.state), ("agent-relay-" + profile, self.root / ".kind" / profile))
            self.assertEqual([p["hostPort"] for p in stack.native_port_mappings()], [8080, 443, 8443])
            self.assertIsNone(binding(stack))

    def test_invalid_identity_state_bool_ports_or_address_refuse_before_filesystem(self):
        base = dict(cluster_name=self.target.cluster_name, state_relative=self.target.state_relative, http_port=18080, history_https_port=18443)
        for change in [dict(cluster_name="agent-relay-core"), dict(cluster_name="agent-relay-addons"), dict(cluster_name="agent-relay-core-native-bad-"),
                       dict(state_relative=".kind/core"), dict(state_relative="../escape"),
                       dict(http_port=True), dict(history_https_port="18443"), dict(http_port=8080),
                       dict(history_https_port=8443), dict(history_https_port=18080), dict(history_https_port=65536),
                       dict(site_https_port=True), dict(site_https_port=4443), dict(listen_address="0.0.0.0")]:
            with self.subTest(change=change):
                with self.assertRaises(NativeRecipeError): NativeInstanceTarget(**{**base, **change})
        self.assertFalse((self.root / ".kind").exists())
        with self.assertRaises(NativeRecipeError):
            with patch.object(stack_module, "ROOT", self.root): NativeInstanceStack("addons", self.target)

    def test_state_symlink_rejects_before_mkdir_or_chmod(self):
        old = self.root / "retained"; old.mkdir(); before = old.stat().st_ctime_ns
        (self.root / ".kind").symlink_to(old, target_is_directory=True)
        with self.assertRaisesRegex(NativeRecipeError, "symlink"): self.real_stack()
        self.assertEqual(old.stat().st_ctime_ns, before); self.assertEqual(list(old.iterdir()), [])

    def test_raced_state_symlink_cannot_redirect_constructor_chmod(self):
        retained = self.root / "retained"; retained.mkdir(mode=0o755)
        before = (retained.stat().st_mode, retained.stat().st_ctime_ns)
        original = os.mkdir
        def race(path, mode=0o777, *, dir_fd=None):
            if path == self.target.cluster_name and dir_fd is not None:
                os.symlink(retained, path, dir_fd=dir_fd)
                raise FileExistsError()
            return original(path, mode, dir_fd=dir_fd)
        with patch.object(native_target.os, "mkdir", race):
            with self.assertRaisesRegex(NativeRecipeError, "private_directory"): self.real_stack()
        self.assertEqual(before, (retained.stat().st_mode, retained.stat().st_ctime_ns))
        self.assertEqual(list(retained.iterdir()), [])

    def test_factory_source_or_mutated_identity_refuses(self):
        for field, changed in [("name", "agent-relay-core"), ("state", self.root / ".kind/core"),
                               ("kubeconfig", self.root / "foreign"), ("marker", self.root / "foreign")]:
            stack = self.real_stack(); setattr(stack, field, changed)
            with self.assertRaisesRegex(NativeRecipeError, "changed_since"): binding(stack)
        stack = self.real_stack(); source = self.root / "changed-target.py"; source.write_text("changed source")
        with patch.object(native_target, "__file__", str(source)):
            with self.assertRaisesRegex(NativeRecipeError, "changed_since"): binding(stack)

    def test_repeat_target_drift_and_legacy_cross_adoption_refuse(self):
        stack = self.real_stack(); record = {"nativeTarget": binding(stack)}; require_record(stack, record)
        with self.assertRaisesRegex(NativeRecipeError, "ownership"): require_record(stack, {})
        for field in ("clusterName", "stateRelative", "historyHttpsPort", "factorySourceSha256", "targetSha256"):
            changed = deepcopy(record); changed["nativeTarget"][field] = "changed"
            with self.assertRaisesRegex(NativeRecipeError, "ownership"): require_record(stack, changed)
        with patch.object(stack_module, "ROOT", self.root): legacy = Stack("core")
        with self.assertRaisesRegex(NativeRecipeError, "ownership"): require_record(legacy, record)

    def test_actual_occupied_loopback_port_refuses_before_create(self):
        with socket.socket() as occupied:
            occupied.bind(("127.0.0.1", 0)); occupied.listen(); port = occupied.getsockname()[1]
            if port in (8080, 8443): self.skipTest("OS chose a reserved fixture port")
            target = NativeInstanceTarget(self.target.cluster_name, self.target.state_relative, port, 18443 if port != 18443 else 18444)
            stack = self.real_stack(target)
            with self.assertRaisesRegex(NativeRecipeError, "port_unavailable"): require_free_ports(stack)
            self.assertFalse(stack.marker.exists())

    def test_only_matching_core_independent_origin_can_select_custom_port(self):
        value = selected(); value["control"]["independentIssuer"] = True; value["readerLoginAdvertisesSync"] = False
        value["historyOrigin"] = self.target.history_origin
        self.assertEqual(selection(value, target=self.target)["historyOrigin"], self.target.history_origin)
        with self.assertRaisesRegex(NativeRecipeError, "origin_audience"): selection(value)
        for key, wrong in [("historyOrigin", "https://history.kind.agentrelay.com:8443"), ("siteOrigin", "https://relay.kind.agentrelay.com:18443")]:
            bad = deepcopy(value); bad[key] = wrong
            with self.assertRaises(NativeRecipeError): selection(bad, target=self.target)
        value["control"]["independentIssuer"] = False; value["readerLoginAdvertisesSync"] = True
        with self.assertRaisesRegex(NativeRecipeError, "independent_issuer"): selection(value, target=self.target)

    def test_direct_recipe_cannot_dispatch_another_instance_with_the_same_origins(self):
        value = selected(); value["control"]["independentIssuer"] = True; value["readerLoginAdvertisesSync"] = False
        value["historyOrigin"] = self.target.history_origin
        recipe = NativeRecipe(value, target=self.target)
        other = NativeInstanceTarget("agent-relay-core-native-proof2", ".kind/native-instances/agent-relay-core-native-proof2", 18080, 18443)
        operations = SimpleNamespace(stack=self.real_stack(other))
        for name in CORE_OPERATIONS:
            setattr(operations, name, lambda *a: {})
        operations.inspect = lambda *a: self.fail("must refuse before dispatch to another instance")
        with self.assertRaisesRegex(NativeRecipeError, "target_adapter_mismatch"): recipe.run(operations)

    def test_target_and_diagnostics_modules_participate_in_actual_recipe_hash(self):
        stack = self.real_stack(); before = stack.recipe_hash(); original = Path.read_bytes
        for module in ("native_target.py", "native_diagnostics.py"):
            def changed(path):
                raw = original(path); return raw + b"\n# changed\n" if path.name == module else raw
            with self.subTest(module=module), patch.object(Path, "read_bytes", changed):
                self.assertNotEqual(stack.recipe_hash(), before)

    def test_actual_create_uses_target_ports_and_keeps_nonce_uid_guards(self):
        stack = self.real_stack(); stack.env["DOCKER_HOST"] = "unix:///owned-test/docker.sock"
        for key in ("DOCKER_CONTEXT", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH"): stack.env.pop(key, None)
        captured = {}; nonce = None; uid = "44444444-4444-4444-8444-444444444444"
        def commands(argv, **kwargs):
            nonlocal nonce
            if argv == ["kind", "get", "clusters"]: return SimpleNamespace(stdout="agent-relay-core\n")
            if argv[:3] == ["kind", "create", "cluster"]:
                import yaml
                captured.update(yaml.safe_load(kwargs["data"])); nonce = captured["nodes"][0]["labels"]["agentrelay-native-creation"]
                Path(argv[argv.index("--kubeconfig") + 1]).write_text("owned-unit-kubeconfig"); return SimpleNamespace(stdout="")
            if argv[0] == "kubectl":
                self.assertEqual(argv[argv.index("--context") + 1], "kind-" + self.target.cluster_name)
                self.assertTrue(Path(argv[argv.index("--kubeconfig") + 1]).is_relative_to(stack.state))
                if any(str(a).startswith("jsonpath=") for a in argv): return SimpleNamespace(stdout=uid)
                return SimpleNamespace(stdout=json.dumps({"items": [{"metadata": {"labels": {"agentrelay-kind-owner": "infra", "agentrelay-native-creation": nonce}}}]}))
            self.fail("unexpected command boundary")
        class FreeSocket:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def settimeout(self, seconds): pass
            def bind(self, address): pass
            def connect_ex(self, address): return errno.ECONNREFUSED
        stack.cmd = commands; adapter = NativeBootstrapAdapter(stack, {name: "source-only" for name in INPUT_FIELDS})
        with patch.object(native_target.socket, "socket", return_value=FreeSocket()): adapter._fresh_cluster()
        self.assertEqual(captured["nodes"][0]["extraPortMappings"], [
            {"containerPort": 30080, "hostPort": 18080, "listenAddress": "127.0.0.1"},
            {"containerPort": 30443, "hostPort": 443, "listenAddress": "127.0.0.1"},
            {"containerPort": 30443, "hostPort": 18443, "listenAddress": "127.0.0.1"}])
        self.assertEqual(json.loads((stack.state / "native-fresh-creation.json").read_text()),
                         {"name": self.target.cluster_name, "nonce": nonce, "nativeTarget": binding(stack)})
        self.assertEqual(json.loads(stack.marker.read_text())["nativeTarget"], binding(stack))
        self.assertEqual(json.loads(stack.marker.read_text())["clusterUid"], uid)
        self.assertFalse((self.root / ".kind/core").exists())
        with self.assertRaises(NativeRecipeError):
            with patch.object(native_target.socket, "socket", return_value=FreeSocket()): adapter._fresh_cluster()

    def test_target_or_claim_drift_after_exclusive_claim_refuses_before_kind(self):
        class FreeSocket:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def settimeout(self, seconds): pass
            def bind(self, address): pass
            def connect_ex(self, address): return errno.ECONNREFUSED
        for drift in ("target", "factory", "claim"):
            with self.subTest(drift=drift), tempfile.TemporaryDirectory() as temporary:
                with patch.object(stack_module, "ROOT", Path(temporary)):
                    stack = NativeInstanceStack("core", self.target)
                stack.env["DOCKER_HOST"] = "unix:///owned-test/docker.sock"
                for key in ("DOCKER_CONTEXT", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH"): stack.env.pop(key, None)
                original = deepcopy(binding(stack)); reads = 0; create_calls = []
                def commands(argv, **kwargs):
                    nonlocal reads
                    if argv == ["kind", "get", "clusters"]:
                        reads += 1
                        if reads == 2:
                            claim = stack.state / "native-fresh-creation.json"
                            self.assertEqual(json.loads(claim.read_text())["nativeTarget"], original)
                            if drift == "target":
                                stack.native_target = NativeInstanceTarget(self.target.cluster_name, self.target.state_relative, 18080, 18444)
                            elif drift == "factory":
                                stack._native_target_binding = {**original, "factorySourceSha256": "0" * 64}
                            else:
                                changed = json.loads(claim.read_text()); changed["nativeTarget"]["historyHttpsPort"] = 18444
                                claim.write_text(json.dumps(changed))
                        return SimpleNamespace(stdout="agent-relay-core\n")
                    create_calls.append(argv); self.fail("Kind creation must not dispatch after drift")
                stack.cmd = commands
                adapter = NativeBootstrapAdapter(stack, {name: "source-only" for name in INPUT_FIELDS})
                code = "fresh_creation_claim_changed" if drift == "claim" else "native_target_changed_since_admission"
                with patch.object(native_target.socket, "socket", return_value=FreeSocket()):
                    with self.assertRaisesRegex(NativeRecipeError, code): adapter._fresh_cluster()
                self.assertEqual(create_calls, [])
                self.assertFalse(stack.marker.exists()); self.assertFalse(stack.kubeconfig.exists())
                if drift != "claim":
                    self.assertEqual(json.loads((stack.state / "native-fresh-creation.json").read_text())["nativeTarget"], original)

    def test_legacy_create_and_up_cannot_dispatch_for_native_instance(self):
        stack = self.real_stack()
        stack.cmd = lambda *a, **k: self.fail("legacy command must not dispatch")
        with self.assertRaisesRegex(StackError, "explicit native core"): stack.cluster()
        # The single-phase up is retired for every stack, native instances included.
        with self.assertRaisesRegex(StackError, "retired.*native core installer"): stack.up()

    def test_explicit_target_cannot_instantiate_a_foreign_factory_before_refusal(self):
        fixture = cli_tests.Cli(); fixture.setUp(); self.addCleanup(fixture.doCleanups)
        fixture.s["historyOrigin"] = self.target.history_origin
        def forbidden_factory(profile): self.fail("factory must be refused before construction")
        with self.assertRaisesRegex(NativeRecipeError, "exact_factory"):
            run(*fixture.save(), execute=True, generate_local_test_ca=True,
                instance_target=self.target, reviewed_target_sha256=self.target.binding()["targetSha256"],
                stack_factory=forbidden_factory)
        self.assertFalse((self.root / ".kind/core").exists())

    def test_network_custom_port_is_independent_only_and_origins_stay_exact(self):
        value = network_tests.NativeNetwork().independent()
        pipeline = value["sessions-pipeline"]
        for key in ("nativeRouting", "sessionReadApi", "ingestEdge"): pipeline[key]["origin"] = self.target.history_origin
        value["relay-control"]["services"]["sessionReadApiPublicUrl"] = self.target.history_origin
        self.assertTrue(native_network.selection(value)["independentIssuer"])
        bad = deepcopy(value); bad["sessions-pipeline"]["ingestEdge"]["origin"] += "/"
        with self.assertRaises(ValueError): native_network.selection(bad)
        legacy = network_tests.values()
        for key in ("nativeRouting", "sessionReadApi", "ingestEdge"): legacy["sessions-pipeline"][key]["origin"] = self.target.history_origin
        legacy["relay-control"]["services"]["relayhistoryPublicUrl"] = self.target.history_origin
        with self.assertRaises(ValueError): native_network.selection(legacy)
        self.assertEqual(native_network.selection(network_tests.values())["origin"], "https://history.kind.agentrelay.com:8443")

    def test_existing_managed_email_smtp_survives_all_native_phases_without_extra_env(self):
        value = selected(); value["control"]["independentIssuer"] = True; value["readerLoginAdvertisesSync"] = False
        value["historyOrigin"] = self.target.history_origin
        base = {"relay-control": {"auth": {"emailLink": {"enabled": True}}, "smtp": {
            "host": "native-proof-smtp.agent-relay.svc.cluster.local", "port": 1025,
            "security": "none", "username": "", "from": "Fixture <signin@native-proof.invalid>"}}}
        tenant = {"organizationId": "11111111-1111-4111-8111-111111111111", "workspaceId": "22222222-2222-4222-8222-222222222222"}
        for phase in ("plan", "control", "serve"):
            actual = compose(base, value, contract(), phase, tenant if phase == "serve" else None)
            self.assertEqual(actual["relay-control"]["auth"], base["relay-control"]["auth"])
            self.assertEqual(actual["relay-control"]["smtp"], base["relay-control"]["smtp"])
            self.assertEqual(actual["relay-control"]["extraEnv"], [])
            self.assertNotIn("smtp", compose({}, value, contract(), phase, tenant if phase == "serve" else None)["relay-control"])

    def test_plan_hash_bound_and_disclosed_without_stack_io(self):
        fixture = cli_tests.Cli(); fixture.setUp(); self.addCleanup(fixture.doCleanups)
        fixture.s["historyOrigin"] = self.target.history_origin
        result = run(*fixture.save(), instance_target=self.target, reviewed_target_sha256=self.target.binding()["targetSha256"], stack_factory=fixture.no_stack)
        self.assertEqual(result["nativeTarget"], self.target.binding()); self.assertFalse(result["clusterChanged"])
        self.assertFalse(result["fullAcceptance"])
        with self.assertRaisesRegex(NativeRecipeError, "target_hash"):
            run(*fixture.save(), instance_target=self.target, reviewed_target_sha256="0" * 64, stack_factory=fixture.no_stack)
        with self.assertRaisesRegex(NativeRecipeError, "target_hash_without"):
            run(*fixture.save(), reviewed_target_sha256="0" * 64, stack_factory=fixture.no_stack)


if __name__ == "__main__": unittest.main()
