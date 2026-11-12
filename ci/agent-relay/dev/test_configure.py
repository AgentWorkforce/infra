import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import configure
import dev
from test_dev import deployment


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.sources = {}
        for group in ("webapp", "control", "pipeline", "cast"):
            repo = self.root / group; repo.mkdir(); self.sources[group] = str(repo)
        self.docs = {}
        images = {"webapp": "relay-webapp", "control": "relay-control", "cast": "relaycast", "collector": "telemetry-collector"}
        for role in configure.REQUIRED:
            d = deployment(role, "owned-" + role)
            c = d["spec"]["template"]["spec"]["containers"][0]
            if role in configure.SERVICES.values():
                c["image"] = "example/pipeline-native@sha256:" + "a" * 64
                c["env"] = [{"name": "SERVICE", "value": next(s for s,r in configure.SERVICES.items() if r == role)}]
            else: c["image"] = "example/" + images[role] + "@sha256:" + "b" * 64
            if role == "webapp": c["env"].append({"name": "DASHBOARD_PUBLIC_URL", "value": "https://dev.example.test"})
            self.docs[role] = d
        self.docs["stable-database"] = deployment("stable-database", "db-owned")
        self.base = {"kubeconfig": str(self.root / "kubeconfig"), "context": "kind-owned", "cluster": "owned",
                     "namespace": "test", "docker": "docker", "dockerContext": "desktop-linux"}
        (self.root / "kubeconfig").touch()

    def tearDown(self): self.tmp.cleanup()

    def discover(self):
        docs = self.docs
        class Cluster:
            def __init__(self, *args): pass
            def get(self, kind, name): return {"metadata": {"uid": "ns-" + name}}
            def target(self): pass
            def inventory(self): return copy.deepcopy(docs)
        class Commands:
            docker_context = None
            def json(self, _): return {"Architecture": "aarch64"}
            def run(self, _): return b"a" * 40 + b"\n"
        with patch.object(dev, "Cluster", Cluster), patch.object(dev, "source_files", return_value={"Dockerfile": b"FROM pinned", "docker/services.Dockerfile": b"FROM pinned"}):
            return configure.discover(self.base, self.root, self.sources, Commands())

    def test_complete_runtime_is_discovered_without_hand_written_uids(self):
        config = self.discover()
        self.assertEqual({t["role"] for g in config["groups"] for t in g["targets"]}, configure.REQUIRED)
        pipeline = next(g for g in config["groups"] if g["name"] == "pipeline")
        self.assertEqual(len(pipeline["targets"]), 4)
        self.assertEqual(config["protectedDeployments"], ["stable-database"])
        self.assertEqual(config["publicOrigin"], "https://dev.example.test")
        for g in config["groups"]:
            for t in g["targets"]:
                self.assertEqual(t["uid"], "owned-" + t["role"])
                self.assertEqual(t["reviewedInitSha256"], dev.digest([]))
                self.assertNotIn("env", t)
        self.assertNotIn("admissionFile", config)

    def test_missing_core_role_refuses_instead_of_frontend_only_success(self):
        self.docs.pop("brief")
        with self.assertRaisesRegex(dev.Refused, "core_runtime_role_missing"): self.discover()

    def test_duplicate_role_refuses_instead_of_selecting_one_by_name(self):
        self.docs["other-reader"] = copy.deepcopy(self.docs["reader"])
        with self.assertRaisesRegex(dev.Refused, "ambiguous_role_reader"): self.discover()

    def test_missing_source_is_reported_and_default_all_refuses_before_effects(self):
        self.sources["pipeline"] = str(self.root / "not-present")
        config = self.discover()
        group = next(g for g in config["groups"] if g["name"] == "pipeline")
        self.assertTrue(group["sourceUnavailable"])
        self.assertIsNone(group["baselineRevision"])
        # No Kubernetes or builder transport is needed to reject missing source.
        with self.assertRaisesRegex(dev.Refused, "source_checkout_required_pipeline"):
            dev.prepare(config, object())
        selected = dev.select_components(config, "webapp")
        self.assertEqual([g["name"] for g in selected["groups"]], ["webapp"])
        self.assertTrue({"ingest", "reader", "consumer", "brief"} <= set(selected["protectedDeployments"]))

    def test_optional_observed_service_without_source_is_honestly_reported(self):
        d = deployment("file", "file-owned")
        d["spec"]["template"]["spec"]["containers"][0]["image"] = "example/relayfile:dev"
        self.docs["file"] = d
        config = self.discover()
        group = next(g for g in config["groups"] if g["name"] == "file")
        self.assertTrue(group["sourceUnavailable"])
        self.assertIn("file", dev.select_components(config, "webapp")["protectedDeployments"])
        with self.assertRaisesRegex(dev.Refused, "source_checkout_required_file"):
            dev.prepare(config, object())

    def test_collector_command_discriminator_precedes_shared_control_image(self):
        command = ["/usr/bin/flock", "--nonblock", "--no-fork", "/var/lib/telemetry/.writer.lock", "node", "node_modules/relay-control/dist/collector-cli.js"]
        c = {"name": "collector", "image": "example/relay-control:dev", "command": command}
        self.assertEqual(configure.classify(c, "telemetry-collector"), "collector")
        c["command"] = ["node", "unknown.js"]
        with self.assertRaisesRegex(dev.Refused, "collector_command_shape_changed"):
            configure.classify(c, "telemetry-collector")
        self.assertEqual(configure.classify({"name": "server", "image": "example/relaycast-self-host:dev"}), "cast")
        self.assertEqual(configure.classify({"name": "gateway", "image": "example/relaycast-actors-gateway:dev"}), "cast")
        self.assertIsNone(configure.classify({"name": "durable-actors-dev", "image": "local/relaycast-actors-dev:source"}))

    def test_migration_entrypoint_is_not_a_runtime_role(self):
        self.assertIsNone(configure.classify({"image": "example/pipeline-native:dev", "env": [{"name": "SERVICE", "value": "hoopdb-migrate"}]}))


if __name__ == "__main__": unittest.main()
