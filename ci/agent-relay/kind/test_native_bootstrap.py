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

    def pull(self, image): self.effects.append(("pull", image))
    def load(self, image): self.effects.append(("load", image))
    def cluster(self): self.effects.append(("cluster", self.name))
    def cni(self): self.effects.append(("cni", None))

    def apply(self, doc, chart=False):
        self.effects.append(("apply", doc["kind"]))
        d = deepcopy(doc); d["metadata"]["uid"] = "11111111-1111-4111-8111-111111111111"
        self.applied.append(d); self.objects_by_name[d["kind"].lower() + "/" + d["metadata"]["name"]] = d
        if d["kind"] == "StatefulSet":
            self.objects_by_name["pod/postgres-0"] = {"metadata": {"ownerReferences": [{"kind": "StatefulSet", "uid": d["metadata"]["uid"]}]}}
            self.objects_by_name["persistentvolumeclaim/data-postgres-0"] = {"metadata": {"uid": "22222222-2222-4222-8222-222222222222"}}

    def cmd(self, args, **kw):
        if args[:2] == ["helm", "version"]: return SimpleNamespace(stdout="v4.3.1")
        if args[:2] == ["helm", "install"]:
            self.calls.append((args, kw)); self.effects.append(("install-storage", "kind-locker"))
            self.objects_by_name["persistentvolumeclaim/locker"] = {"metadata": {"uid": "33333333-3333-4333-8333-333333333333"}}
            return SimpleNamespace(stdout="")
        return super().cmd(args, **kw)

    def k(self, *args, **kw):
        self.calls.append((args, kw))
        if args[0] == "get":
            if len(args) > 2 and args[2] not in ("-o",):
                key = args[1].lower() + "/" + args[2]
            else: key = args[1].lower()
            obj = self.objects_by_name.get(key)
            if "--ignore-not-found=true" in args: return SimpleNamespace(stdout="" if obj is None else key)
            if key == "namespace/kube-system": obj = {"metadata": {"uid": "44444444-4444-4444-8444-444444444444"}}
            if obj is None: raise NativeRecipeError("synthetic_missing_resource")
            return SimpleNamespace(stdout=json.dumps(obj))
        if args[0] == "create":
            assert kw.get("sensitive") is True
            d = json.loads(kw["data"]); d["metadata"]["uid"] = "55555555-5555-4555-8555-555555555555"
            self.objects_by_name[d["kind"].lower() + "/" + d["metadata"]["name"]] = d
            self.effects.append(("create", d["kind"])); return SimpleNamespace(stdout=json.dumps(d))
        if args[0] == "rollout": return SimpleNamespace(stdout="ready")
        if args[0] == "exec":
            assert kw.get("sensitive") is True and "-i" in args and "psql" in args
            sql = kw["data"]; self.effects.append(("psql", None))
            if "json_build_object('oid'" in sql:
                return SimpleNamespace(stdout=json.dumps({"oid": self.owner_oid, "clean": not self.owner_login}))
            if "ALTER ROLE hoop LOGIN CREATEROLE PASSWORD" in sql: self.owner_login = True; self.owner_crea = True
            if "ALTER ROLE hoop NOCREATEROLE" in sql: self.owner_crea = False
            if "json_build_object('ownerOid'" in sql:
                return SimpleNamespace(stdout=json.dumps({"ownerOid": self.owner_oid, "ownerNoCreateRole": self.owner_login and not self.owner_crea}))
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
        tar(self.inputs["sourceArchive"], files)
        source["archiveSha256"] = hashlib.sha256(self.inputs["sourceArchive"].read_bytes()).hexdigest()
        source["files"][name] = {"gitMode": "100644", "sha256": hashlib.sha256(files[name]).hexdigest()}
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
        with patch.object(TlsMaterial, "verify", return_value=None):
            return self.adapter.prepare_infrastructure(self.s, facts)

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
        self.assertEqual(json.loads(installed["data"])["buckets"], [{"name": "locker", "policy": "none", "purge": False}])

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


if __name__ == "__main__": unittest.main()
