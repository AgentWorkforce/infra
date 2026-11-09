"""Owned transport fakes and real in-memory PKI; no cluster/DB is touched."""
import base64
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import re
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from native_bootstrap import (NativeBootstrapAdapter, TlsMaterial, fresh_tls_material,
                              require_hostname_verifier, scram)
from native_recipe import NativeRecipe, NativeRecipeError
from native_inspect import runtime_files
import test_native_inspect as inspect_tests
Stack, tar, write_json = inspect_tests.Stack, inspect_tests.tar, inspect_tests.write_json


class OperatorStack(Stack):
    def __init__(self, root):
        super().__init__(root)
        self.objects_by_name = {}; self.applied = []; self.effects = []
        self.owner_crea = False; self.owner_login = False; self.owner_oid = 101
        self.profile = "core"; self.kubeconfig = root / "kubeconfig"; self.creation_nonce = None
        self.cluster_uid_value = "44444444-4444-4444-8444-444444444444"

    def pull(self, image): self.effects.append(("pull", image))
    def load(self, image): self.effects.append(("load", image))
    def cluster(self): raise AssertionError("legacy reusable cluster primitive forbidden")
    def cluster_uid(self, kubeconfig): return self.cluster_uid_value
    def cni(self): self.effects.append(("cni", None))

    def apply(self, doc, chart=False):
        self.effects.append(("apply", doc["kind"]))
        d = deepcopy(doc); d["metadata"]["uid"] = "11111111-1111-4111-8111-111111111111"
        self.applied.append(d); self.objects_by_name[d["kind"].lower() + "/" + d["metadata"]["name"]] = d
        if d["kind"] == "StatefulSet":
            self.objects_by_name["pod/postgres-0"] = {"metadata": {"ownerReferences": [{"kind": "StatefulSet", "uid": d["metadata"]["uid"]}]}}
            self.objects_by_name["persistentvolumeclaim/data-postgres-0"] = {"metadata": {"uid": "22222222-2222-4222-8222-222222222222"}}

    def cmd(self, args, **kw):
        if args[:3] == ["kind", "create", "cluster"]:
            import yaml
            config = yaml.safe_load(kw["data"])
            self.creation_nonce = config["nodes"][0]["labels"]["agentrelay-native-creation"]
            self.clusters = self.name
            Path(args[args.index("--kubeconfig") + 1]).write_bytes(b"synthetic-kubeconfig")
            self.effects.append(("create-cluster", self.name))
            return SimpleNamespace(stdout="")
        if args[0] == "kubectl" and args[-4:] == ["get", "nodes", "-o", "json"]:
            return SimpleNamespace(stdout=json.dumps({"items": [self.node()]}))
        if args[:2] == ["helm", "version"]: return SimpleNamespace(stdout="v4.3.1")
        if args[:2] == ["helm", "install"]:
            self.calls.append((args, kw)); self.effects.append(("install-storage", "kind-locker"))
            self.objects_by_name["persistentvolumeclaim/locker"] = {"metadata": {"uid": "33333333-3333-4333-8333-333333333333"}}
            return SimpleNamespace(stdout="")
        return super().cmd(args, **kw)

    def node(self):
        return {"metadata": {"labels": {"agentrelay-kind-owner": "infra", "agentrelay-native-creation": self.creation_nonce}}}

    def k(self, *args, **kw):
        self.calls.append((args, kw))
        if args[0] == "get":
            if len(args) > 2 and args[2] not in ("-o",):
                key = args[1].lower() + "/" + args[2]
            else: key = args[1].lower()
            obj = self.objects_by_name.get(key)
            if "--ignore-not-found=true" in args: return SimpleNamespace(stdout="" if obj is None else key)
            if key == "namespace/kube-system": obj = {"metadata": {"uid": "44444444-4444-4444-8444-444444444444"}}
            if key == "nodes": obj = {"items": [self.node()]}
            if obj is None: raise NativeRecipeError("synthetic_missing_resource")
            return SimpleNamespace(stdout=json.dumps(obj))
        if args[0] == "create":
            assert kw.get("sensitive") is True
            d = json.loads(kw["data"]); d["metadata"]["uid"] = "55555555-5555-4555-8555-555555555555"
            self.objects_by_name[d["kind"].lower() + "/" + d["metadata"]["name"]] = d
            if d["kind"] == "Job" and d["spec"]["template"]["spec"]["containers"][0]["name"] == "locker-init":
                d["status"] = {"succeeded": 1, "conditions": [{"type": "Complete", "status": "True"}]}
                pod = {"metadata": {"name": d["metadata"]["name"] + "-pod", "uid": "66666666-6666-4666-8666-666666666666",
                                    "ownerReferences": [{"kind": "Job", "name": d["metadata"]["name"], "uid": d["metadata"]["uid"], "controller": True}]},
                       "spec": deepcopy(d["spec"]["template"]["spec"]), "status": {"phase": "Succeeded", "containerStatuses": [{"name": "locker-init", "imageID": "containerd://" + self.locker_config_digest, "state": {"terminated": {"exitCode": 0}}}]}}
                self.objects_by_name["pods"] = {"items": [pod]}
                self.objects_by_name["job/" + d["metadata"]["name"]] = d
            self.effects.append(("create", d["kind"])); return SimpleNamespace(stdout=json.dumps(d))
        if args[0] == "rollout": return SimpleNamespace(stdout="ready")
        if args[0] == "wait": return SimpleNamespace(stdout="condition met")
        if args[0] == "exec":
            assert kw.get("sensitive") is True and "-i" in args and "psql" in args
            sql = kw["data"]; self.effects.append(("psql", None))
            if "json_build_object('oid'" in sql:
                return SimpleNamespace(stdout=json.dumps({"oid": self.owner_oid if "r.oid::bigint" in sql else str(self.owner_oid), "clean": not self.owner_login}))
            if "ALTER ROLE hoop LOGIN CREATEROLE PASSWORD" in sql: self.owner_login = True; self.owner_crea = True
            if "ALTER ROLE hoop NOCREATEROLE" in sql: self.owner_crea = False
            if "json_build_object('ownerOid'" in sql:
                return SimpleNamespace(stdout=json.dumps({"ownerOid": self.owner_oid if "r.oid::bigint" in sql else str(self.owner_oid), "ownerNoCreateRole": self.owner_login and not self.owner_crea}))
            return SimpleNamespace(stdout="")
        raise AssertionError("unexpected test transport")


class NativeBootstrapTests(unittest.TestCase):
    image = inspect_tests.NativeInspectTests.image
    render_fixture = inspect_tests.NativeInspectTests.render_fixture

    def setUp(self):
        inspect_tests.NativeInspectTests.setUp(self)
        old = self.stack; self.stack = OperatorStack(self.root); self.stack.images = old.images
        self.material = TlsMaterial(b"public-test-ca", b"public-test-leaf", b"synthetic-private-key")
        self.s["postgresCa"]["sha256"] = self.material.ca_sha256
        self.adapter = NativeBootstrapAdapter(self.stack, self.inputs, self.material)
        # Add the exact source fixture used by the local compatibility stage.
        source = json.loads(self.inputs["sourceManifest"].read_text())
        import tarfile
        with tarfile.open(self.inputs["sourceArchive"]) as a: files = {m.name: a.extractfile(m).read() for m in a if m.isfile()}
        name = "supabase/tests/supabase_shim.sql"; files[name] = b"-- official shim fixture\n"
        locker_name = "src/locker/init.ts"; files[locker_name] = b"export const sourceFixture = true;\n"
        tar(self.inputs["sourceArchive"], files)
        source["archiveSha256"] = hashlib.sha256(self.inputs["sourceArchive"].read_bytes()).hexdigest()
        source["files"][name] = {"gitMode": "100644", "sha256": hashlib.sha256(files[name]).hexdigest()}
        source["files"][locker_name] = {"gitMode": "100644", "sha256": hashlib.sha256(files[locker_name]).hexdigest()}
        self.inputs["sourceManifestSha256"] = write_json(self.inputs["sourceManifest"], source)
        receipt = json.loads(self.inputs["pipelineReceipt"].read_text())
        receipt["source"]["archiveSha256"] = source["archiveSha256"]
        receipt["allCopiedTrackedSourceCheck"]["checked"] = len(runtime_files(source))
        self.s["artifactReceiptSha256"] = write_json(self.inputs["pipelineReceipt"], receipt)
        # The real pinned chart and transform are checked separately by source
        # tests. This transport fixture has no Helm chart or running Kubernetes.
        self.adapter._minio_source = lambda: (self.root / "minio-5.4.0.tgz", self.root / "postrender.py")

    def observed_preflight(self):
        # Exercise real artifact verification and render checks, then the
        # already-tested fresh target fact. No raw trusted=True input exists.
        self.render_fixture()
        self.adapter.inspect(self.s)
        self.adapter.verify_artifact(self.s); self.adapter.render(self.s)
        return self.adapter._inspected

    def fresh(self):
        facts = self.observed_preflight()
        def qualified_import(selected):
            self.stack.locker_config_digest = selected["configDigest"]
            self.stack.effects.append(("qualified-node-import", None))
        with patch.object(TlsMaterial, "verify", return_value=None), patch.object(self.adapter, "_ensure_pipeline_image", side_effect=qualified_import):
            return self.adapter.prepare_infrastructure(self.s, facts)

    def test_owner_json_projects_oid_as_bigint_before_strict_decode(self):
        self.fresh()
        # PostgreSQL's oid JSON category is a string. Match the real PG17
        # behavior unless the producer explicitly projects a numeric type.
        raw = self.stack.k("exec", "-i", "postgres-0", "--", "psql", data="SELECT json_build_object('oid',r.oid,'clean',true)", sensitive=True).stdout
        self.assertEqual(json.loads(raw)["oid"], str(self.stack.owner_oid))
        owner = self.adapter._owner_snapshot(self.s)
        self.assertIs(type(owner["oid"]), int)
        self.assertEqual(owner, {"oid": self.stack.owner_oid, "clean": True})
        self.stack.owner_login = True
        with patch.object(self.adapter, "_preflight"):
            self.adapter._owner_oid = self.stack.owner_oid
            self.adapter.verify_owner_final(self.s)
        for args, kw in self.stack.calls:
            if args[0] == "exec" and ("json_build_object('oid'" in kw["data"] or "json_build_object('ownerOid'" in kw["data"]):
                if "SELECT json_build_object('oid',r.oid,'clean',true)" == kw["data"]:
                    continue
                self.assertIn("r.oid::bigint", kw["data"])
                self.assertTrue(kw["data"].startswith("BEGIN READ ONLY;"))

    def test_owner_json_does_not_coerce_malformed_oid_or_boolean_values(self):
        for oid in ["101", True, False, 0, -1, 101.0, None]:
            with self.subTest(oid=oid), patch.object(self.adapter, "_psql", return_value=json.dumps({"oid": oid, "clean": True})):
                with self.assertRaisesRegex(NativeRecipeError, "fresh_owner_snapshot_unreadable"):
                    self.adapter._owner_snapshot(self.s)
        with patch.object(self.adapter, "_psql", return_value=json.dumps({"oid": 101, "clean": "true"})):
            with self.assertRaisesRegex(NativeRecipeError, "fresh_owner_snapshot_unreadable"):
                self.adapter._owner_snapshot(self.s)
        for oid, final in [("101", True), (True, True), (0, True), (101, "true"), (101, None)]:
            with self.subTest(oid=oid, final=final), patch.object(self.adapter, "_preflight"), patch.object(self.adapter, "_psql", return_value=json.dumps({"ownerOid": oid, "ownerNoCreateRole": final})):
                with self.assertRaisesRegex(NativeRecipeError, "final_owner_snapshot_unreadable"):
                    self.adapter.verify_owner_final(self.s)
        with patch.object(self.adapter, "_preflight"), patch.object(self.adapter, "_psql", return_value=json.dumps({"ownerOid": 101, "ownerNoCreateRole": False})):
            with self.assertRaisesRegex(NativeRecipeError, "owner_privilege_not_finalized"):
                self.adapter.verify_owner_final(self.s)

    def test_applying_adapter_is_still_incomplete_and_cannot_dispatch(self):
        with self.assertRaisesRegex(NativeRecipeError, "complete_native_adapter"): NativeRecipe(self.s).run(self.adapter)
        self.assertEqual(self.stack.effects, [])

    def test_fresh_requires_observed_chain_and_refuses_retained_before_any_write(self):
        with self.assertRaises(NativeRecipeError): self.adapter.prepare_infrastructure(self.s, {})
        self.assertEqual(self.stack.effects, [])
        self.observed_preflight(); self.adapter._inspected["mode"] = "repeat"
        with self.assertRaisesRegex(NativeRecipeError, "retained"): self.adapter.prepare_infrastructure(self.s, self.adapter._inspected)
        self.assertEqual(self.stack.effects, [])

    def test_fresh_tls_pod_and_hba_never_boot_plaintext_and_separate_databases(self):
        result = self.fresh(); self.assertTrue(result["ok"])
        claim = (self.stack.state / "native-fresh-creation.json").read_bytes()
        record = json.loads(claim)
        self.assertEqual(set(record), {"name", "nonce"})
        self.assertEqual(claim, (json.dumps({"name": self.stack.name, "nonce": record["nonce"]}) + "\n").encode())
        pg = next(d for d in self.stack.applied if d["kind"] == "StatefulSet")
        c = pg["spec"]["template"]["spec"]["containers"][0]
        self.assertIn("ssl=on", c["args"]); self.assertTrue(any(a.startswith("hba_file=") for a in c["args"]))
        secret_ref = c["env"][0]["valueFrom"]["secretKeyRef"]
        self.assertEqual(secret_ref, {"name": "kind-native-postgres-admin", "key": "password"})
        hba = self.stack.objects_by_name["configmap/kind-native-postgres-hba"]["data"]["pg_hba.conf"]
        self.assertIn("hostnossl all all 0.0.0.0/0 reject", hba); self.assertIn("hostssl all all ::/0 scram-sha-256", hba)
        sql = "\n".join(kw.get("data", "") for a, kw in self.stack.calls if a[0] == "exec")
        for d, owner in [("hoopdb", "hoop"), ("relaycontrol", "control_owner"), ("relayfile", "relayfile"), ("relaycast", "cast_owner")]:
            self.assertIn("CREATE DATABASE " + d + " OWNER " + owner, sql)
        self.assertNotIn("IF NOT EXISTS", sql)
        installed = next(kw for a, kw in self.stack.calls if a[:2] == ["helm", "install"])
        self.assertEqual(json.loads(installed["data"])["buckets"], [])
        self.assertEqual(json.loads(installed["data"])["image"], self.adapter._locker_image())

    def test_credentials_only_go_to_create_stdin_and_never_to_files_or_argv(self):
        self.fresh(); self.adapter.prepare_owner(self.s)
        secrets = [o for o in self.stack.objects_by_name.values() if o.get("kind") == "Secret"]
        self.assertTrue(secrets and all(o["immutable"] is True for o in secrets))
        argv = repr([a for a, _ in self.stack.calls])
        for obj in secrets:
            for key, encoded in obj["data"].items():
                if key == "rootUser": continue  # public login name, not its credential
                raw = base64.b64decode(encoded).decode()
                self.assertTrue(raw not in argv, "Secret value leaked to argv (value withheld)")
        self.assertFalse((self.root / "credentials.json").exists())
        self.assertTrue(self.stack.owner_crea)
        self.adapter.finalize_owner(self.s)
        self.assertTrue(self.adapter.verify_owner_final(self.s)["ownerNoCreateRole"])
        self.assertFalse(self.stack.owner_crea)

    def test_ca_mismatch_replay_and_selection_change_refuse_before_new_mutation(self):
        self.observed_preflight(); bad = deepcopy(self.s); bad["postgresCa"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(NativeRecipeError, "selection_changed"): self.adapter.prepare_infrastructure(bad, self.adapter._inspected)
        self.assertEqual(self.stack.effects, [])
        self.adapter.tls_material = TlsMaterial(b"other-public-ca", b"other-leaf", b"other-synthetic-key")
        with patch.object(TlsMaterial, "verify", return_value=None):
            with self.assertRaisesRegex(NativeRecipeError, "ca_not_bound"): self.adapter.prepare_infrastructure(self.s, self.adapter._inspected)
        self.assertEqual(self.stack.effects, [])
        self.adapter.tls_material = self.material
        self.fresh(); before = list(self.stack.effects)
        with self.assertRaisesRegex(NativeRecipeError, "not_retry"): self.adapter.prepare_infrastructure(self.s, self.adapter._inspected)
        self.assertEqual(self.stack.effects, before)

    def test_raced_cluster_or_marker_after_inspect_refuses_before_pull_or_resource_writes(self):
        self.observed_preflight()
        for race in ("cluster", "marker", "ready", "kubeconfig"):
            with self.subTest(race=race):
                path = {"marker": self.stack.marker, "ready": self.root / "ready.json",
                        "kubeconfig": self.stack.kubeconfig}.get(race)
                if path: path.write_text("raced-state")
                else: self.stack.clusters = self.stack.name
                with patch.object(TlsMaterial, "verify", return_value=None):
                    with self.assertRaisesRegex(NativeRecipeError, "fresh_cluster_.*appeared"):
                        self.adapter.prepare_infrastructure(self.s, self.adapter._inspected)
                self.assertEqual(self.stack.effects, [])
                if path: path.unlink()
                self.stack.clusters = ""

    def test_race_during_pull_refuses_create_and_all_kubernetes_writes(self):
        self.observed_preflight()
        def pull(image):
            self.stack.effects.append(("pull", image)); self.stack.clusters = self.stack.name
        self.stack.pull = pull
        with patch.object(TlsMaterial, "verify", return_value=None):
            with self.assertRaisesRegex(NativeRecipeError, "fresh_cluster_name_appeared"):
                self.adapter.prepare_infrastructure(self.s, self.adapter._inspected)
        self.assertTrue(self.stack.effects and all(e[0] == "pull" for e in self.stack.effects))

    def test_creation_nonce_or_new_marker_race_refuses_before_cni_or_resource_writes(self):
        self.observed_preflight(); original = self.stack.cmd
        def raced(args, **kw):
            result = original(args, **kw)
            if args[:3] == ["kind", "create", "cluster"]: self.stack.creation_nonce = "wrong-attempt"
            return result
        self.stack.cmd = raced
        with patch.object(TlsMaterial, "verify", return_value=None):
            with self.assertRaisesRegex(NativeRecipeError, "creation_binding_mismatch"):
                self.adapter.prepare_infrastructure(self.s, self.adapter._inspected)
        self.assertTrue(all(e[0] in {"pull", "create-cluster"} for e in self.stack.effects))
        self.assertFalse(self.stack.marker.exists())

    def test_marker_appearing_during_creation_is_never_overwritten(self):
        self.observed_preflight(); original = self.stack.cmd
        def raced(args, **kw):
            result = original(args, **kw)
            if args[:3] == ["kind", "create", "cluster"]: self.stack.marker.write_text("other-owner-receipt")
            return result
        self.stack.cmd = raced
        with patch.object(TlsMaterial, "verify", return_value=None):
            with self.assertRaisesRegex(NativeRecipeError, "state_raced_creation"):
                self.adapter.prepare_infrastructure(self.s, self.adapter._inspected)
        self.assertEqual(self.stack.marker.read_text(), "other-owner-receipt")
        self.assertTrue(all(e[0] in {"pull", "create-cluster"} for e in self.stack.effects))
        self.assertFalse(self.stack.kubeconfig.exists())

    def test_uid_replacement_before_cni_is_not_adopted(self):
        self.observed_preflight(); calls = []
        def changed_uid(path):
            calls.append(path)
            return self.stack.cluster_uid_value if len(calls) == 1 else "different-uid"
        self.stack.cluster_uid = changed_uid
        with patch.object(TlsMaterial, "verify", return_value=None):
            with self.assertRaisesRegex(NativeRecipeError, "uid_changed"):
                self.adapter.prepare_infrastructure(self.s, self.adapter._inspected)
        self.assertTrue(all(e[0] in {"pull", "create-cluster"} for e in self.stack.effects))

    def test_kind_name_race_at_create_failure_never_falls_back_to_reuse(self):
        self.observed_preflight(); original = self.stack.cmd
        def create_collision(args, **kw):
            if args[:3] == ["kind", "create", "cluster"]:
                self.stack.clusters = self.stack.name
                raise NativeRecipeError("kind_name_already_exists")
            return original(args, **kw)
        self.stack.cmd = create_collision
        with patch.object(TlsMaterial, "verify", return_value=None):
            with self.assertRaisesRegex(NativeRecipeError, "kind_name_already_exists"):
                self.adapter.prepare_infrastructure(self.s, self.adapter._inspected)
        self.assertTrue(all(e[0] == "pull" for e in self.stack.effects))
        self.assertFalse(self.stack.marker.exists())

    def test_local_docker_endpoint_is_bound_before_every_effect(self):
        self.observed_preflight()
        for host in ("tcp://unqualified.example:2375", "unix://remote/var/run/docker.sock", "unix:///other/docker.sock"):
            with self.subTest(host=host):
                self.stack.env["DOCKER_HOST"] = host
                with self.assertRaises(NativeRecipeError):
                    self.adapter.prepare_infrastructure(self.s, self.adapter._inspected)
                self.assertEqual(self.stack.effects, [])
        self.stack.env["DOCKER_HOST"] = self.adapter._docker_transport[0]
        for key, value in (("DOCKER_CONTEXT", "remote-context"), ("DOCKER_TLS_VERIFY", "1"), ("DOCKER_CERT_PATH", "/other")):
            with self.subTest(override=key):
                self.stack.env[key] = value
                with self.assertRaisesRegex(NativeRecipeError, "endpoint_override"):
                    self.adapter.prepare_infrastructure(self.s, self.adapter._inspected)
                self.assertEqual(self.stack.effects, [])
                del self.stack.env[key]
        self.stack.docker_args = ["docker", "--context", "remote-context"]
        with self.assertRaisesRegex(NativeRecipeError, "endpoint_override"):
            self.adapter.prepare_infrastructure(self.s, self.adapter._inspected)
        self.assertEqual(self.stack.effects, [])

    def test_endpoint_drift_after_first_pull_prevents_second_pull_and_kind(self):
        self.observed_preflight()
        def drift(image):
            self.stack.effects.append(("pull", image)); self.stack.env["DOCKER_HOST"] = "tcp://unqualified.example:2375"
        self.stack.pull = drift
        with patch.object(TlsMaterial, "verify", return_value=None):
            with self.assertRaisesRegex(NativeRecipeError, "local_docker_required"):
                self.adapter.prepare_infrastructure(self.s, self.adapter._inspected)
        self.assertEqual([e[0] for e in self.stack.effects], ["pull"])

    def test_actual_stack_docker_argument_contract_and_exact_host_binding(self):
        import stack as stack_module
        # Execute the real helper with only its subprocess boundary faked.
        # It writes its own anonymous config under this disposable test root.
        with patch.object(stack_module, "ROOT", self.root / "actual-stack"):
            actual = stack_module.Stack("core")
        actual.env = {"DOCKER_HOST": self.stack.env["DOCKER_HOST"]}
        observed = []
        def command(args, **kwargs):
            observed.append(args)
            return SimpleNamespace(stdout="arm64" if "{{.Architecture}}" in args else "29.8.0")
        actual.cmd = command
        actual.docker(require_space=False)
        expected = ["docker", "--config", actual.state / "docker-public", "--host", actual.env["DOCKER_HOST"]]
        self.assertEqual(actual.docker_args, expected)
        self.assertTrue(any(args[:5] == expected for args in observed))
        adapter = NativeBootstrapAdapter(actual, self.inputs, self.material)
        adapter._require_local_transport()
        for args in (
            [*expected[:4], "tcp://unqualified.example:2375"],
            [*expected[:4], "unix:///other/docker.sock"],
            [*expected[:3], "--context", "remote-context"],
            ["docker", "--host", actual.env["DOCKER_HOST"], "--config", expected[2]],
            [*expected, "--tlsverify"],
        ):
            with self.subTest(args=args):
                actual.docker_args = args
                with self.assertRaisesRegex(NativeRecipeError, "command_endpoint_override"):
                    NativeBootstrapAdapter(actual, self.inputs, self.material)
        actual.docker_args = ["docker", "--config", self.root / "changed-config", "--host", actual.env["DOCKER_HOST"]]
        with self.assertRaisesRegex(NativeRecipeError, "endpoint_changed_since_admission"):
            adapter._require_local_transport()
        self.assertEqual(self.stack.effects, [])

    def test_operator_instance_change_or_existing_owner_credential_never_resets_it(self):
        self.fresh()
        self.stack.objects_by_name["statefulset/postgres"]["metadata"]["uid"] = "foreign"
        before = len([a for a, _ in self.stack.calls if a[0] == "exec"])
        with self.assertRaisesRegex(NativeRecipeError, "instance_changed"): self.adapter.prepare_owner(self.s)
        self.assertEqual(len([a for a, _ in self.stack.calls if a[0] == "exec"]), before)

    def test_preexisting_owner_login_or_changed_oid_refuses_without_secret_or_reset(self):
        self.fresh()
        for changed in ("login", "oid"):
            self.stack.owner_login = changed == "login"
            self.stack.owner_oid = 102 if changed == "oid" else 101
            with self.subTest(changed=changed), self.assertRaisesRegex(NativeRecipeError, "not_unclaimed"):
                self.adapter.prepare_owner(self.s)
            self.assertNotIn("secret/" + self.s["secretRefs"]["owner"]["name"], self.stack.objects_by_name)

    def test_repeat_claimed_role_transport_is_readonly_and_denial_never_falls_back(self):
        self.fresh(); self.adapter.prepare_owner(self.s); self.adapter.finalize_owner(self.s)
        # Model an independently admitted repeat observation. The applying
        # adapter still cannot dispatch without the remaining implementations.
        self.adapter._inspected = {"owned": True, "mode": "repeat", "clusterUid": "owned-test"}
        start = len(self.stack.calls)
        self.assertTrue(self.adapter.verify_claimed_roles(self.s)["ok"])
        calls = [kw["data"] for a, kw in self.stack.calls[start:] if a[0] == "exec"]
        self.assertEqual(len(calls), 4)
        self.assertTrue(all(x.startswith("BEGIN READ ONLY;") and x.rstrip().endswith("ROLLBACK;") for x in calls))
        self.assertFalse(any("ALTER ROLE" in x or "session_consumer_credential_probe.sql" in x for x in calls))
        attempts = []
        original = self.stack.k
        def denied(*args, **kw):
            if args[0] == "exec":
                attempts.append(args)
                raise NativeRecipeError("protected_metadata_denied")
            return original(*args, **kw)
        self.stack.k = denied
        with self.assertRaisesRegex(NativeRecipeError, "protected_metadata_denied"): self.adapter.verify_claimed_roles(self.s)
        self.assertEqual(len(attempts), 1)

    def test_scram_has_fixed_parameters_without_plaintext(self):
        password = "A" * 64; a, b = scram(password), scram(password)
        self.assertRegex(a, r"^SCRAM-SHA-256\$4096:[A-Za-z0-9+/]{22}==\$[A-Za-z0-9+/]{43}=:[A-Za-z0-9+/]{43}=$")
        self.assertNotEqual(a, b); self.assertNotIn(password, a)


class RealPkiTests(unittest.TestCase):
    def test_memory_only_real_chain_host_and_wrong_host_refusal(self):
        try: require_hostname_verifier()
        except NativeRecipeError: self.skipTest("OpenSSL hostname-verification capability unavailable; fresh recipe refuses too")
        hosts = ["postgres.agent-relay.svc.cluster.local", "relay.kind.agentrelay.com"]
        material = fresh_tls_material(hosts); material.verify(hosts)
        self.assertNotIn("PRIVATE KEY", repr(material))
        with self.assertRaises(NativeRecipeError): material.verify(["wrong.kind.agentrelay.com"])
        other = fresh_tls_material(hosts)
        with self.assertRaises(NativeRecipeError): TlsMaterial(other.ca, material.certificate, material.private_key).verify(hosts)

    def test_extra_pem_private_material_refused_before_transport(self):
        hosts = ["postgres.agent-relay.svc.cluster.local", "relay.kind.agentrelay.com", "cast.kind.agentrelay.com",
                 "history.kind.agentrelay.com", "files.kind.agentrelay.com"]
        material = fresh_tls_material(hosts)
        ca_der = base64.b64decode(b"".join(material.ca.splitlines()[1:-1]))
        hidden_der = b"-----BEGIN CERTIFICATE-----\n" + base64.encodebytes(ca_der + b"extra-object") + b"-----END CERTIFICATE-----\n"
        key_der = base64.b64decode(b"".join(material.private_key.splitlines()[1:-1]))
        hidden_key = b"-----BEGIN PRIVATE KEY-----\n" + base64.encodebytes(key_der + b"extra-object") + b"-----END PRIVATE KEY-----\n"
        for ca, leaf, key, error in [
            (material.ca + material.private_key, material.certificate, material.private_key, "public_ca"),
            (material.ca + material.ca, material.certificate, material.private_key, "public_ca"),
            (b"unexpected\n" + material.ca, material.certificate, material.private_key, "public_ca"),
            (hidden_der, material.certificate, material.private_key, "public_ca"),
            (material.ca, material.certificate + material.private_key, material.private_key, "tls_leaf"),
            (material.ca, material.certificate, material.private_key + material.ca, "tls_key"),
            (material.ca, material.certificate, hidden_key, "tls_key"),
        ]:
            with self.subTest(error=error):
                fixture = NativeBootstrapTests("test_applying_adapter_is_still_incomplete_and_cannot_dispatch")
                fixture.setUp()
                try:
                    bad = TlsMaterial(ca, leaf, key); fixture.adapter.tls_material = bad
                    fixture.s["postgresCa"]["sha256"] = bad.ca_sha256
                    fixture.observed_preflight()
                    with self.assertRaisesRegex(NativeRecipeError, error):
                        fixture.adapter.prepare_infrastructure(fixture.s, fixture.adapter._inspected)
                    self.assertEqual(fixture.stack.effects, [])
                finally: fixture.doCleanups()

    def test_ca_and_server_leaf_constraints_are_required(self):
        hosts = ["postgres.agent-relay.svc.cluster.local"]
        material = fresh_tls_material(hosts)
        with self.assertRaisesRegex(NativeRecipeError, "public_ca_constraints"):
            TlsMaterial(material.certificate, material.certificate, material.private_key).verify(hosts)
        with self.assertRaisesRegex(NativeRecipeError, "tls_leaf_server_constraints"):
            TlsMaterial(material.ca, material.ca, material.private_key).verify(hosts)


if __name__ == "__main__": unittest.main()
