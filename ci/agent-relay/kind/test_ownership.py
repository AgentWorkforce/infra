"""Ownership refusal tests: no Docker daemon or Kubernetes cluster contacted."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import stack


class Ownership(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="kind-ownership-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.scope = patch.object(stack, "ROOT", self.root)
        self.scope.start()
        self.addCleanup(self.scope.stop)
        self.local = stack.Stack("core")
        self.local.env["DOCKER_HOST"] = "unix:///owned/docker.sock"
        self.local.kubeconfig.write_text("original kubeconfig")
        self.local.docker = lambda **kwargs: None
        self.calls = []
        self.live_uid = "bfe8843c-0907-4654-9115-731e4c2c481d"
        self.labels = {"agentrelay-kind-owner": "infra"}
        self.local.cmd = self.command
        self.record = {"version": 1, "name": self.local.name, "profile": "core",
                       "nodeImage": stack.NODE, "dockerHost": self.local.env["DOCKER_HOST"],
                       "clusterUid": self.live_uid}

    def command(self, argv, **kwargs):
        args = [str(x) for x in argv]
        self.calls.append(args)
        if args[:3] == ["kind", "get", "clusters"]:
            output = self.local.name + "\n"
        elif args[:3] == ["kind", "export", "kubeconfig"]:
            candidate = Path(args[args.index("--kubeconfig") + 1])
            self.assertNotEqual(candidate, self.local.kubeconfig)
            candidate.write_text("new validated kubeconfig")
            output = ""
        elif args[0] == "kubectl" and "namespace" in args:
            output = self.live_uid
        elif args[0] == "kubectl" and "nodes" in args:
            output = json.dumps({"items": [{"metadata": {"labels": self.labels}}]})
        elif args[:3] == ["kind", "delete", "cluster"]:
            output = ""
        else:
            self.fail("Unexpected or mutating command: " + repr(args))
        return subprocess.CompletedProcess(args, 0, output, "")

    def write_record(self, value=None):
        self.local.marker.write_text(json.dumps(self.record if value is None else value))

    def assert_refused(self, action):
        before = self.local.kubeconfig.read_text()
        with self.assertRaises(stack.StackError):
            getattr(self.local, action)()
        self.assertEqual(self.local.kubeconfig.read_text(), before)
        self.assertFalse(any(c[:3] == ["kind", "delete", "cluster"] for c in self.calls))
        self.assertFalse(list(self.local.state.glob("ownership-*.kubeconfig")))

    def test_replacement_cluster_refused_before_reuse_or_deletion(self):
        for action in ("cluster", "down"):
            with self.subTest(action=action):
                self.calls.clear()
                self.write_record()
                self.live_uid = "c5a7f64f-34ad-4857-ac23-41729278f2f1"
                self.assert_refused(action)
                self.live_uid = self.record["clusterUid"]

    def test_foreign_docker_endpoint_refused_before_export(self):
        self.write_record()
        self.local.env["DOCKER_HOST"] = "unix:///other/docker.sock"
        for action in ("cluster", "down"):
            with self.subTest(action=action):
                self.calls.clear()
                self.assert_refused(action)
                self.assertFalse(any(c[:2] == ["kind", "export"] for c in self.calls))

    def test_missing_malformed_and_legacy_receipts_refused(self):
        values = [None, "{broken", "[]", "null", json.dumps({"name": self.local.name})]
        for action in ("cluster", "down"):
            for text in values:
                with self.subTest(action=action, text=text):
                    self.calls.clear()
                    self.local.marker.unlink(missing_ok=True)
                    if text is not None:
                        self.local.marker.write_text(text)
                    self.assert_refused(action)

    def test_every_ownership_field_is_required_and_exact(self):
        for field in self.record:
            for replacement in (None, "foreign"):
                for action in ("cluster", "down"):
                    with self.subTest(field=field, replacement=replacement, action=action):
                        self.calls.clear()
                        value = dict(self.record)
                        if replacement is None:
                            del value[field]
                        else:
                            value[field] = replacement
                        self.write_record(value)
                        self.assert_refused(action)
        self.write_record(dict(self.record, version=True))
        self.assert_refused("down")

    def test_labels_still_required_even_when_uid_matches(self):
        self.write_record()
        self.labels = {}
        for action in ("cluster", "down"):
            with self.subTest(action=action):
                self.assert_refused(action)

    def test_failed_identity_query_cannot_replace_config_or_delete(self):
        self.write_record()
        original = self.local.cmd
        def fail(argv, **kwargs):
            if "namespace" in [str(x) for x in argv]:
                raise stack.StackError("identity query refused")
            return original(argv, **kwargs)
        self.local.cmd = fail
        for action in ("cluster", "down"):
            with self.subTest(action=action):
                self.assert_refused(action)

    def test_owned_reuse_replaces_only_validated_config(self):
        self.write_record()
        self.local.cluster()
        self.assertEqual(self.local.kubeconfig.read_text(), "new validated kubeconfig")
        self.assertFalse(any(c[:3] == ["kind", "delete", "cluster"] for c in self.calls))
        self.assertFalse(list(self.local.state.glob("ownership-*.kubeconfig")))

    def test_owned_deletion_runs_only_after_native_uid_check(self):
        self.write_record()
        self.local.down()
        native = next(i for i, c in enumerate(self.calls) if c[0] == "kubectl" and "namespace" in c)
        delete = next(i for i, c in enumerate(self.calls) if c[:3] == ["kind", "delete", "cluster"])
        self.assertLess(native, delete)
        self.assertFalse(self.local.marker.exists())

    def test_fresh_creation_records_native_uid_and_docker_endpoint(self):
        original = self.local.cmd
        def fresh(argv, **kwargs):
            args = [str(x) for x in argv]
            if args[:3] == ["kind", "get", "clusters"]:
                self.calls.append(args)
                return subprocess.CompletedProcess(args, 0, "", "")
            if args[:3] == ["kind", "create", "cluster"]:
                self.calls.append(args)
                return subprocess.CompletedProcess(args, 0, "", "")
            return original(argv, **kwargs)
        self.local.cmd = fresh
        self.local.cluster()
        self.assertEqual(json.loads(self.local.marker.read_text()), self.record)

    def test_failed_creation_does_not_fabricate_ownership(self):
        def fail(argv, **kwargs):
            args = [str(x) for x in argv]
            if args[:3] == ["kind", "get", "clusters"]:
                return subprocess.CompletedProcess(args, 0, "", "")
            if args[:3] == ["kind", "create", "cluster"]:
                raise stack.StackError("creation interrupted")
            self.fail("unexpected command after failed creation")
        self.local.cmd = fail
        with self.assertRaisesRegex(stack.StackError, "creation interrupted"):
            self.local.cluster()
        self.assertFalse(self.local.marker.exists())


    def legacy_receipts(self):
        legacy = {k: self.record[k] for k in ("name", "profile", "nodeImage")}
        self.write_record(legacy)
        ready = {"profile": "core", "clusterUid": self.record["clusterUid"],
                 "recipeSha256": "a" * 64, "renderSha256": "b" * 64}
        (self.local.state / "ready.json").write_text(json.dumps(ready))
        return legacy, ready

    def assert_recovery_refused(self, expected_uid):
        before = self.local.marker.read_bytes()
        with self.assertRaises(stack.StackError):
            self.local.recover(expected_uid)
        self.assertEqual(self.local.marker.read_bytes(), before)
        self.assertEqual(self.local.kubeconfig.read_text(), "original kubeconfig")
        self.assertFalse(list(self.local.state.glob("ownership-*")))
        self.assertFalse(list(self.local.state.glob("legacy-ownership-*")))
        self.assertFalse(any(c[:3] == ["kind", "delete", "cluster"] for c in self.calls))

    def test_explicit_recovery_requires_prior_receipt_and_live_identity(self):
        legacy, _ = self.legacy_receipts()
        self.local.recover(self.live_uid)
        self.assertEqual(json.loads(self.local.marker.read_text()), self.record)
        backups = list(self.local.state.glob("legacy-ownership-*.json"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(json.loads(backups[0].read_text()), legacy)
        self.assertEqual(self.local.kubeconfig.read_text(), "original kubeconfig")
        self.assertFalse(list(self.local.state.glob("ownership-*")))
        self.assertFalse(any(c[:2] in (["kind", "delete"], ["kind", "create"]) for c in self.calls))

    def test_up_refusal_preserves_original_recovery_anchor(self):
        self.legacy_receipts()
        # The up entry point now reads profile selections before its first
        # runtime call. Supply a disabled native selection so this test still
        # reaches the original independent ownership-refusal boundary.
        charts = self.root / "charts/agent-relay"
        charts.mkdir(parents=True)
        (charts / "values.yaml").write_text("{}\n")
        (charts / "values-kind-core.yaml").write_text("{}\n")
        ready = self.local.state / "ready.json"
        before = ready.read_bytes()
        with patch.object(stack.shutil, "which", return_value="tool"):
            with self.assertRaises(stack.StackError):
                self.local.up()
        self.assertEqual(ready.read_bytes(), before)
        self.assertEqual(self.local.kubeconfig.read_text(), "original kubeconfig")
        self.local.recover(self.live_uid)
        self.assertEqual(json.loads(self.local.marker.read_text()), self.record)

    def test_recovery_cannot_adopt_live_replacement_even_with_same_name(self):
        self.legacy_receipts()
        self.live_uid = "c5a7f64f-34ad-4857-ac23-41729278f2f1"
        self.assert_recovery_refused(self.record["clusterUid"])

    def test_recovery_cannot_use_live_uid_without_original_anchor(self):
        _, ready = self.legacy_receipts()
        for invalid in (None, {}, [], dict(ready, clusterUid="other"), dict(ready, profile="addons"),
                        dict(ready, recipeSha256=None), dict(ready, renderSha256="bad")):
            with self.subTest(ready=invalid):
                path = self.local.state / "ready.json"
                path.unlink(missing_ok=True)
                if invalid is not None:
                    path.write_text(json.dumps(invalid))
                self.assert_recovery_refused(self.live_uid)

    def test_recovery_requires_explicit_matching_uid(self):
        self.legacy_receipts()
        for uid in (None, "", "live-guess", "bad uid", self.live_uid + "\n"):
            with self.subTest(uid=uid):
                self.assert_recovery_refused(uid)

    def test_recovery_refuses_versioned_foreign_or_label_mismatch(self):
        legacy, _ = self.legacy_receipts()
        for record in (self.record, dict(legacy, profile="addons"), {"name": self.local.name}):
            with self.subTest(record=record):
                self.write_record(record)
                self.assert_recovery_refused(self.live_uid)
        self.write_record(legacy)
        self.labels = {}
        self.assert_recovery_refused(self.live_uid)


if __name__ == "__main__":
    unittest.main()
