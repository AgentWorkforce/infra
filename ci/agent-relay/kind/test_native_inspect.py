"""Real OCI/source fixtures plus causal transport, render and identity controls."""
from copy import deepcopy
import hashlib
import base64
import io
import json
from pathlib import Path
from types import SimpleNamespace
import tarfile
import tempfile
import unittest

import yaml

from native_inspect import NativeReadOnlyAdapter, native_archive, runtime_files
from native_recipe import BOOTSTRAP, NativeRecipe, NativeRecipeError
from test_native_recipe import selected


def h(raw): return hashlib.sha256(raw).hexdigest()


def write_json(path, obj):
    path.write_text(json.dumps(obj, indent=2) + "\n")
    return h(path.read_bytes())


def tar(path, files):
    with tarfile.open(path, "w") as archive:
        for name, raw in files.items():
            item = tarfile.TarInfo(name); item.size = len(raw)
            archive.addfile(item, io.BytesIO(raw))


def oci(path, source):
    config = json.dumps({"architecture": "arm64", "os": "linux", "rootfs": {"type": "layers", "diff_ids": []},
                         "config": {"Labels": {"org.opencontainers.image.revision": source}, "Env": []}}).encode()
    cd = "sha256:" + h(config)
    manifest = json.dumps({"schemaVersion": 2, "config": {"digest": cd}, "layers": []}).encode()
    md = "sha256:" + h(manifest)
    tar(path, {"index.json": json.dumps({"manifests": [{"digest": md}]}).encode(),
               "blobs/sha256/" + md[7:]: manifest, "blobs/sha256/" + cd[7:]: config})
    return md, cd


class Stack:
    def __init__(self, root):
        self.state = root; self.marker = root / "cluster.json"; self.name = "agent-relay-core"
        self.docker_args = ["docker", "--config", "owned-anonymous-config"]
        self.env = {"DOCKER_HOST": "unix:///owned-fixture/docker.sock"}
        self.images = {}; self.calls = []; self.clusters = ""; self.docs = []; self.objects = []; self.owned = True

    def cmd(self, args, **kw):
        self.calls.append((args, kw))
        if args == ["kind", "get", "clusters"]: return SimpleNamespace(stdout=self.clusters)
        if args == ["kind", "get", "nodes", "--name", self.name]: return SimpleNamespace(stdout="agent-relay-core-control-plane\n")
        if args[:2] == ["helm", "template"]:
            assert kw.get("sensitive") is True
            return SimpleNamespace(stdout=yaml.safe_dump_all(self.docs))
        d = args[len(self.docker_args):]
        if d[:2] == ["image", "inspect"]: return SimpleNamespace(stdout=json.dumps([self.images[d[2]]]))
        assert d[0] == "run" and "--network" in d and d[d.index("--network") + 1] == "none"
        assert "--read-only" in d and "--cap-drop" in d and "--security-opt" in d
        data = json.loads(kw["data"])
        result = {"checked": len(data)}
        if "bun" in d: result["generation"] = "d" * 64
        return SimpleNamespace(stdout=json.dumps(result))

    def require_owned_cluster(self):
        if not self.owned: raise NativeRecipeError("foreign_cluster")

    def k(self, *args, **kw):
        self.calls.append((args, kw))
        assert args[0] == "get" and kw.get("sensitive") is True
        if args[1] == "namespace/kube-system": value = {"metadata": {"uid": "original-cluster"}}
        elif args[1] == "nodes": value = {"items": [{"metadata": {"name": "agent-relay-core-control-plane", "labels": {"agentrelay-kind-owner": "infra"}}}]}
        elif "/" in args[1]: value = next(o for o in self.objects if o["metadata"]["name"] == args[1].split("/", 1)[1])
        else: value = {"items": [o for o in self.objects if o["kind"] != "Secret"]}
        return SimpleNamespace(stdout=json.dumps(value))

    def values_args(self): return ["-f", self.state / "values.yaml"]
    def render(self): return self.docs


class NativeInspectTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name); self.s = selected(); self.stack = Stack(self.root); self.inputs = {}
        files = {"supabase/bootstrap/" + f: ("-- " + f + "\n").encode() for f in BOOTSTRAP}
        files["docker/entrypoint.sh"] = b"#!/bin/sh\n"
        archive = self.root / "source.tar"; tar(archive, files)
        source = {"sourceRevision": self.s["sourceRevision"], "sourceClean": True, "archiveSha256": h(archive.read_bytes()),
                  "files": {n: {"sha256": h(raw), "gitMode": "100644"} for n, raw in files.items()}}
        sm = self.root / "source.json"; sm_sha = write_json(sm, source)
        native = self.root / "native.tar"; md, cd = oci(native, self.s["sourceRevision"])
        self.s.update(manifestDigest=md, configDigest=cd, reference="agent-relay-kind/pipeline-native@" + md)
        receipt = {"source": {"revision": self.s["sourceRevision"], "clean": True, "archiveSha256": source["archiveSha256"]},
                   "artifact": {"nativeManifestDigest": md, "configDigest": cd, "archiveSha256": h(native.read_bytes()), "buildIndexDigest": md},
                   "schemaGeneration": self.s["generation"], "build": {"localTag": "pipeline:fixture"},
                   "allCopiedTrackedSourceCheck": {"checked": len(runtime_files(source)), "mismatched": []}}
        rp = self.root / "pipeline.json"; self.s["artifactReceiptSha256"] = write_json(rp, receipt)
        self.inputs.update(pipelineReceipt=rp, sourceManifest=sm, sourceManifestSha256=sm_sha, sourceArchive=archive, pipelineArchive=native)
        self.stack.images["pipeline:fixture"] = self.image(md, self.s["sourceRevision"])
        control = self.s["control"]; cn = self.root / "control.tar"; cm, cc = oci(cn, control["sourceRevision"])
        control.update(manifestDigest=cm, configDigest=cc, reference="agent-relay-kind/selfhost-api@" + cm)
        dist = self.root / "dist.json"; dist_sha = write_json(dist, {"dist/config.js": "a" * 64})
        sql = {"0001.sql": "b" * 64}; migration = self.root / "migration.json"
        migration_sha = write_json(migration, {"source": control["sourceRevision"], "migrationCount": 1, "sql": sql})
        source_control = self.root / "control-source.json"; cs_sha = write_json(source_control, {"migrations/0001.sql": "b" * 64})
        cr = {k: control[k] for k in ("sourceRevision", "manifestDigest", "configDigest", "reference")}
        cr.update(nativeArchiveSha256=h(cn.read_bytes()), imageDistManifestSha256=dist_sha, sourceFileManifestSha256=cs_sha,
                  tag="control:fixture", dockerIndexDigest=cm)
        cp = self.root / "control.json"; control["artifactReceiptSha256"] = write_json(cp, cr)
        self.inputs.update(controlReceipt=cp, controlArchive=cn, controlDistManifest=dist, controlMigrationManifest=migration,
                           controlMigrationManifestSha256=migration_sha, controlSourceManifest=source_control)
        self.stack.images["control:fixture"] = self.image(cm, control["sourceRevision"])
        self.adapter = NativeReadOnlyAdapter(self.stack, self.inputs)

    def image(self, identity, source):
        return {"Id": identity, "Descriptor": {"digest": identity, "mediaType": "application/vnd.oci.image.manifest.v1+json"}, "Architecture": "arm64", "Os": "linux",
                "RootFS": {"Layers": []}, "Config": {"Labels": {"org.opencontainers.image.revision": source}, "Env": []}}

    def public_receipt(self):
        source = json.loads(Path(self.inputs["sourceManifest"]).read_text())
        old = json.loads(Path(self.inputs["pipelineReceipt"]).read_text())
        source.pop("sourceClean")
        source.update(sourceTree="7" * 40, sourceState="reviewed-archive-description-not-a-clean-flag")
        source["files"] = {name: info["sha256"] for name, info in source["files"].items()}
        self.inputs["sourceManifestSha256"] = write_json(self.inputs["sourceManifest"], source)
        build = self.root / "build-metadata.json"
        self.inputs.update(pipelineBuildMetadata=build, pipelineBuildMetadataSha256=write_json(build, {
            "containerimage.digest": old["artifact"]["buildIndexDigest"],
            "containerimage.descriptor": {"digest": old["artifact"]["buildIndexDigest"]}}))
        public = {"result": "PASS_OFFICIAL_SOURCE_ARCHIVE_NATIVE_CHAIN", "sourceRevision": self.s["sourceRevision"],
            "sourceTree": source["sourceTree"], "sourceState": source["sourceState"], "architecture": self.s["architecture"],
            "officialDockerfileUnmodified": True, "manifestDigest": self.s["manifestDigest"], "configDigest": self.s["configDigest"],
            "generation": self.s["generation"], "sourceArchiveSha256": source["archiveSha256"],
            "sourceManifestSha256": self.inputs["sourceManifestSha256"], "localTag": old["build"]["localTag"],
            "archiveSha256": old["artifact"]["archiveSha256"], "allCopiedSourceFiles": old["allCopiedTrackedSourceCheck"]}
        self.s["artifactReceiptSha256"] = write_json(self.inputs["pipelineReceipt"], public)
        self.adapter = NativeReadOnlyAdapter(self.stack, self.inputs)

    def test_actual_flat_public_schema_verifies_original_archive_and_every_image_file(self):
        self.public_receipt()
        before = {p: Path(p).read_bytes() for p in (self.inputs["pipelineReceipt"], self.inputs["sourceManifest"], self.inputs["pipelineBuildMetadata"])}
        self.assertEqual(self.adapter.verify_artifact(self.s)["generation"], self.s["generation"])
        self.assertEqual(before, {p: Path(p).read_bytes() for p in before}, "qualification receipts are read, never reshaped on disk")
        runs = [args for args, _ in self.stack.calls if "run" in args]
        self.assertEqual(len(runs), 2)

    def test_flat_receipt_missing_or_changed_build_metadata_refuses_before_docker(self):
        self.public_receipt()
        bad = dict(self.inputs); bad.pop("pipelineBuildMetadata"); bad.pop("pipelineBuildMetadataSha256")
        with self.assertRaisesRegex(NativeRecipeError, "pinned_public"): NativeReadOnlyAdapter(self.stack, bad).verify_artifact(self.s)
        self.assertEqual(self.stack.calls, [])
        Path(self.inputs["pipelineBuildMetadata"]).write_text("changed")
        with self.assertRaisesRegex(NativeRecipeError, "evidence_bytes_changed"): self.adapter.verify_artifact(self.s)
        self.assertEqual(self.stack.calls, [])

    def test_flat_receipt_source_tree_and_source_manifest_are_exact_bound_inputs(self):
        self.public_receipt()
        path = self.inputs["sourceManifest"]
        source = json.loads(Path(path).read_text()); source["sourceTree"] = "8" * 40
        self.inputs["sourceManifestSha256"] = write_json(path, source)
        with self.assertRaisesRegex(NativeRecipeError, "public_source_tree"): self.adapter.verify_artifact(self.s)
        self.assertEqual(self.stack.calls, [])

    def test_flat_runtime_config_or_rootfs_drift_refuses_before_any_container_probe(self):
        self.public_receipt()
        original = deepcopy(self.stack.images["pipeline:fixture"])
        for mutate in (lambda x: x["RootFS"].update(Layers=["sha256:" + "f" * 64]),
                       lambda x: x["Config"]["Labels"].update({"extra": "unqualified-runtime-config"})):
            image = deepcopy(original); mutate(image); self.stack.images["pipeline:fixture"] = image
            self.stack.calls.clear()
            with self.assertRaisesRegex(NativeRecipeError, "native_runtime_config"): self.adapter.verify_artifact(self.s)
            self.assertFalse(any("run" in a for a, _ in self.stack.calls))

    def test_real_oci_source_archive_and_module_probe_positive(self):
        result = self.adapter.verify_artifact(self.s)
        self.assertEqual(result["generation"], self.s["generation"])
        runs = [a for a, _ in self.stack.calls if "run" in a]
        self.assertEqual(len(runs), 2)
        self.assertTrue(all("--read-only" in a and "--network" in a for a in runs))

    def test_readonly_adapter_cannot_be_mistaken_for_complete_deployer(self):
        with self.assertRaisesRegex(NativeRecipeError, "complete_native_adapter"): NativeRecipe(self.s).run(self.adapter)
        self.assertEqual(self.stack.calls, [])

    def test_wrong_oci_config_source_arch_or_raw_bytes_refuses(self):
        p = self.inputs["pipelineArchive"]; original = p.read_bytes()
        for field, value in (("source", "f" * 40), ("manifest", "sha256:" + "f" * 64), ("config", "sha256:" + "f" * 64), ("arch", "amd64")):
            with self.subTest(field=field):
                args = [p, h(original), self.s["sourceRevision"], self.s["manifestDigest"], self.s["configDigest"], "arm64"]
                args[{"source": 2, "manifest": 3, "config": 4, "arch": 5}[field]] = value
                with self.assertRaises(NativeRecipeError): native_archive(*args)
        p.write_bytes(original + b"changed")
        with self.assertRaisesRegex(NativeRecipeError, "archive_bytes"): self.adapter.verify_artifact(self.s)
        self.assertEqual(self.stack.calls, [])

    def test_changed_source_manifest_archive_or_bootstrap_refuses_before_docker(self):
        path = self.inputs["sourceArchive"]; path.write_bytes(path.read_bytes() + b"edit")
        with self.assertRaisesRegex(NativeRecipeError, "source_archive"): self.adapter.verify_artifact(self.s)
        self.assertEqual(self.stack.calls, [])

    def test_tag_retarget_wrong_arch_wrong_source_and_live_issuer_refuse(self):
        for mutate in (lambda x: x.update(Architecture="amd64"),
                       lambda x: x["Descriptor"].update(digest="sha256:" + "f" * 64),
                       lambda x: x["Config"]["Labels"].update({"org.opencontainers.image.revision": "f" * 40})):
            image = deepcopy(self.stack.images["pipeline:fixture"]); mutate(image)
            old = self.stack.images["pipeline:fixture"]; self.stack.images["pipeline:fixture"] = image
            with self.assertRaises(NativeRecipeError): self.adapter.verify_artifact(self.s)
            self.stack.images["pipeline:fixture"] = old
        self.stack.images["control:fixture"]["Config"]["Env"] = ["SESSION_READ_API_SECRET=synthetic"]
        with self.assertRaisesRegex(NativeRecipeError, "native_runtime_config"): self.adapter.verify_artifact(self.s)

    def test_fresh_is_only_an_absent_owned_target_with_no_lost_receipts(self):
        self.assertEqual(self.adapter.inspect(self.s)["mode"], "fresh")
        self.assertEqual(len(self.stack.calls), 1)
        self.stack.marker.write_text("original-ownership")
        with self.assertRaisesRegex(NativeRecipeError, "missing_owned_cluster"): self.adapter.inspect(self.s)

    def repeat_fixture(self):
        from stack import NODE
        self.stack.clusters = "agent-relay-core\n"
        self.stack.marker.write_text(json.dumps({"version": 1, "name": self.stack.name, "profile": "core", "nodeImage": NODE,
                                                "dockerHost": self.stack.env["DOCKER_HOST"], "clusterUid": "original-cluster"}))
        ca = b"public-test-ca"; self.s["postgresCa"]["sha256"] = h(ca)
        objects = [{"kind": "ConfigMap", "metadata": {"name": self.s["postgresCa"]["configMap"], "uid": "ca-uid"}, "immutable": True, "data": {"ca.crt": ca.decode()}},
                   {"kind": "StatefulSet", "metadata": {"name": "postgres", "uid": "pg-uid"}, "spec": {"template": {"spec": {"containers": [{"args": ["-c", "ssl=on"]}]}}}},
                   {"kind": "PersistentVolumeClaim", "metadata": {"name": "data-postgres-0", "uid": "pg-pvc-uid"}}]
        objects.append({"kind": "PersistentVolumeClaim", "metadata": {"name": self.s["lockerClaim"], "uid": "locker-pvc-uid"}})
        for ref in self.s["secretRefs"].values():
            objects.append({"kind": "Secret", "metadata": {"name": ref["name"], "uid": ref["name"] + "-uid"}, "immutable": True, "data": {ref["key"]: "c3ludGhldGlj"}})
        for kind in ("owner", "consumer", "reader", "ingest"):
            ref = self.s["secretRefs"][kind]
            folder = "native-consumer" if kind in ("owner", "consumer") else ("session-read" if kind == "reader" else "session-ingest")
            url = "postgresql://" + self.s["roles"][kind] + ":synthetic-" + kind + "@postgres.agent-relay.svc.cluster.local:5432/hoopdb?sslmode=verify-full&sslrootcert=/etc/" + folder + "-postgres/ca.crt"
            payload = json.dumps({ref["jsonField"]: url}) if ref["jsonField"] else url
            obj = next(o for o in objects if o["metadata"]["name"] == ref["name"])
            obj["data"][ref["key"]] = base64.b64encode(payload.encode()).decode()
            if kind == "ingest": obj["data"]["introspect-secret"] = "c3ludGhldGlj"
        for name in ("relay-control", "relay-webapp", "session-native-consumer", "session-native-ingest", "session-read-api"):
            objects.append({"kind": "Deployment", "metadata": {"name": name, "uid": name + "-uid"}, "spec": {"replicas": 1, "template": {"spec": {"containers": []}}}})
        self.stack.objects = objects
        binding = {"clusterUid": "original-cluster", "profile": "core", "roles": self.s["roles"], "generation": self.s["generation"],
                   "officialBootstrapSha256": self.s["officialBootstrapSha256"],
                   "resources": [{"kind": o["kind"], "name": o["metadata"]["name"], "uid": o["metadata"]["uid"]} for o in objects]}
        path = self.root / "binding.json"; self.inputs.update(bindingReceipt=path, bindingReceiptSha256=write_json(path, binding))

    def test_repeat_reads_bound_uids_public_ca_and_secret_keys_without_writes(self):
        self.repeat_fixture()
        config = self.root / "kubeconfig"; config.write_text("original-private-kubeconfig")
        marker = self.stack.marker.read_bytes()
        self.stack.require_owned_cluster = lambda: self.fail("legacy ownership method rewrites kubeconfig")
        result = self.adapter.inspect(self.s)
        self.assertEqual(result["mode"], "repeat"); self.assertEqual(result["clusterUid"], "original-cluster")
        self.assertTrue(all(a[0] == "get" or a[:2] == ["kind", "get"] for a, _ in self.stack.calls))
        self.assertNotIn("c3ludGhldGlj", json.dumps(result))
        self.assertEqual(config.read_text(), "original-private-kubeconfig")
        self.assertEqual(marker, self.stack.marker.read_bytes())

    def test_old_named_layout_is_not_native_role_bootstrap_acceptance(self):
        self.repeat_fixture()
        old = {"clusterUid": "original-cluster", "profile": "core", "storage": {}, "postgres": {}}
        self.inputs["bindingReceiptSha256"] = write_json(self.inputs["bindingReceipt"], old)
        with self.assertRaisesRegex(NativeRecipeError, "native_role_generation_binding"): self.adapter.inspect(self.s)
        self.assertFalse(any(a[0] == "get" and a[1].startswith("secret/") for a, _ in self.stack.calls))
        # Individual input references may still be measured honestly without
        # changing the refusal or inventing the missing native acceptance.
        result = self.adapter.qualify_references(self.s)
        self.assertTrue(result["postgresTlsConfigured"])
        self.assertNotIn("mode", result)
        self.assertNotIn("synthetic-owner", json.dumps(result))

    def test_repeat_uid_ca_secret_or_tls_drift_refuses(self):
        for which in ("uid", "ca", "secret", "tls"):
            self.repeat_fixture()
            if which == "uid": self.stack.objects[0]["metadata"]["uid"] = "foreign"
            if which == "ca": self.stack.objects[0]["data"]["ca.crt"] = "other"
            if which == "secret": next(o for o in self.stack.objects if o["kind"] == "Secret")["data"] = {}
            if which == "tls": self.stack.objects[1]["spec"]["template"]["spec"]["containers"][0]["args"] = []
            with self.subTest(which=which), self.assertRaises(NativeRecipeError): self.adapter.inspect(self.s)

    def test_metadata_denial_stops_without_role_or_identity_fallback(self):
        self.repeat_fixture(); requests = []
        def denied(*args, **kw):
            requests.append(args)
            raise NativeRecipeError("metadata_access_denied")
        self.stack.k = denied
        with self.assertRaisesRegex(NativeRecipeError, "metadata_access_denied"): self.adapter.inspect(self.s)
        self.assertEqual(requests, [("get", "namespace/kube-system", "-o", "json")])
        self.assertEqual([a for a, _ in self.stack.calls], [["kind", "get", "clusters"]])

    def render_fixture(self):
        values = {"sessions-pipeline": {"nativeRouting": {"enabled": True}, "sessionReadApi": {"login": {"advertisesSync": True}, "extraEnv": []}}}
        (self.root / "values.yaml").write_text(yaml.safe_dump(values))
        docs = []
        for name, kind, service, variable in [
            ("session-native-consumer", "consumer", "session-pipeline-consumer", "RELAYHISTORY_PIPELINE_CONSUMER_SECRET"),
            ("session-read-api", "reader", "session-read-api", "RELAYHISTORY_READ_API_SECRET"),
            ("session-native-ingest", "ingest", "session-ingest", "RELAYHISTORY_INGEST_DATABASE_URL")]:
            env = {"SERVICE": service, "SESSION_POSTGRES_TLS_PROFILE": "custom-ca", "SESSION_POSTGRES_CA_SHA256": self.s["postgresCa"]["sha256"], "LOCKER_BUCKET": self.s["lockerBucket"]}
            if kind == "ingest":
                env.update(INGEST_KEY_ROOT="96bulls", RELAYHISTORY_INGEST_ORIGIN=self.s["historyOrigin"])
            else:
                env.update(PIPELINE_KEY_PREFIX="96bulls", PIPELINE_ORG_FROM_PREFIX="true", SEARCH_INDEX_BACKEND="postgres",
                           SEARCH_INDEX_POSTGRES_BACKEND_ID=self.s["backendId"], READ_API_COMPLETE_SINCE=self.s["completeSince"])
            if kind == "reader":
                env.update(READ_API_AUTH_MODE="relaycontrol_only", READ_API_ORIGIN=self.s["historyOrigin"], RELAYHISTORY_SELFHOST_LOGIN_ADVERTISES_SYNC="true")
            ref = self.s["secretRefs"][kind]
            envs = [{"name": n, "value": v} for n, v in env.items()]
            envs.append({"name": variable, "valueFrom": {"secretKeyRef": {"name": ref["name"], "key": ref["key"]}}})
            locker = self.s["secretRefs"]["locker"]
            envs.append({"name": "LOCKER_SECRET_ACCESS_KEY", "valueFrom": {"secretKeyRef": {"name": locker["name"], "key": locker["key"]}}})
            if kind != "consumer":
                ir = ref if kind == "ingest" else self.s["secretRefs"]["introspection"]
                envs.append({"name": "RELAYCONTROL_INTROSPECT_SECRET", "valueFrom": {"secretKeyRef": {"name": ir["name"], "key": "introspect-secret"}}})
            pod = {"containers": [{"image": self.s["reference"], "env": envs, "ports": [{"containerPort": 8080 if kind == "reader" else 8081}]}],
                   "volumes": [{"name": "ca", "configMap": {"name": self.s["postgresCa"]["configMap"]}}]}
            docs.append({"kind": "Deployment", "metadata": {"name": name}, "spec": {"replicas": 1, "template": {"spec": pod}}})
        docs.append({"kind": "Deployment", "metadata": {"name": "relay-control"}, "spec": {"replicas": 1, "template": {"spec": {"containers": [{"image": self.s["control"]["reference"], "env": [
            {"name": "RELAYHISTORY_READ_API_URL", "value": self.s["historyOrigin"]}, {"name": "RELAYHISTORY_READ_API_EVENTS", "value": "true"}]}]}}}})
        self.stack.docs = docs

    def test_actual_render_contract_positive_requires_no_kubernetes_or_sql(self):
        self.render_fixture(); result = self.adapter.render(self.s)
        self.assertTrue(result["managedNative"])
        self.assertEqual(len(self.stack.calls), 1); self.assertEqual(self.stack.calls[0][0][:2], ["helm", "template"])
        self.assertFalse((self.root / "rendered.yaml").exists())

    def test_render_refuses_wrong_secret_ca_port_root_owner_or_publication(self):
        for case in ("secret", "ca", "port", "root", "owner", "publication", "legacy", "bootstrap", "inline-secret"):
            self.render_fixture(); consumer = self.stack.docs[0]["spec"]["template"]["spec"]
            env = consumer["containers"][0]["env"]
            if case == "secret": next(e for e in env if e["name"] == "RELAYHISTORY_PIPELINE_CONSUMER_SECRET")["valueFrom"]["secretKeyRef"]["name"] = "foreign"
            if case == "ca": consumer["volumes"] = []
            if case == "port": consumer["containers"][0]["ports"] = [{"containerPort": 1}]
            if case == "root": next(e for e in env if e["name"] == "PIPELINE_KEY_PREFIX")["value"] = "96bulls/foreign"
            if case == "owner": consumer["volumes"].append({"name": "wrong", "secret": {"secretName": self.s["secretRefs"]["owner"]["name"]}})
            if case == "publication": env.append({"name": "INGEST_PUBLICATION_TARGET", "value": "portable"})
            if case == "legacy": self.stack.docs.append({"kind": "Deployment", "metadata": {"name": "session-ingest-api"}, "spec": {"replicas": 1}})
            if case == "bootstrap": self.stack.docs.append({"kind": "Job", "metadata": {"name": "operator", "labels": {"app.kubernetes.io/component": "native-consumer-bootstrap"}}})
            if case == "inline-secret": self.stack.docs.append({"kind": "Secret", "metadata": {"name": "unexpected"}, "stringData": {"password": "synthetic"}})
            with self.subTest(case=case), self.assertRaises(NativeRecipeError): self.adapter.render(self.s)

    def test_sync_flag_is_typed_and_not_an_extra_env_workaround(self):
        self.render_fixture()
        path = self.root / "values.yaml"; values = yaml.safe_load(path.read_text())
        values["sessions-pipeline"]["sessionReadApi"]["extraEnv"] = [{"name": "RELAYHISTORY_SELFHOST_LOGIN_ADVERTISES_SYNC", "value": "true"}]
        path.write_text(yaml.safe_dump(values))
        with self.assertRaisesRegex(NativeRecipeError, "extra_env"): self.adapter.render(self.s)


if __name__ == "__main__": unittest.main()
