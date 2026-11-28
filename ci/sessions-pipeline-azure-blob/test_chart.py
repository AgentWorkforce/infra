"""sessions-pipeline on native Azure Blob: ingest edge, search indexer and worker on one container.

Runtime support is per sessions-pipeline fefbc87c (the agent-relay-2026.11.24 image): session-ingest
(buildLockerStore + conditional writes) and session-pipeline-consumer (ownLocker) read Azure; alleyoop and
the stage workers refuse it (src/shared/env.ts vendorBindings), so the chart refuses them.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
CHART = ROOT / "charts/sessions-pipeline"
CI = CHART / "ci"
BASE = [CI / "ingest-edge-values.yaml", CI / "search-indexer-values.yaml"]  # what azure-blob-values.yaml merges
AZURE = CI / "azure-blob-values.yaml"


def merge(a, b):
    for k, v in b.items():
        if isinstance(v, dict) and isinstance(a.get(k), dict):
            merge(a[k], v)
        else:
            a[k] = v
    return a


class AzureBlob(unittest.TestCase):
    def render(self, files, overrides=None, fail=None):
        args = ["helm", "template", "x", str(CHART), "-n", "x"]
        for f in files:
            args += ["-f", str(f)]
        with tempfile.TemporaryDirectory() as folder:
            if overrides:
                p = Path(folder) / "overrides.yaml"
                p.write_text(yaml.safe_dump(overrides))
                args += ["-f", str(p)]
            r = subprocess.run(args, text=True, capture_output=True)
        if fail:
            self.assertNotEqual(r.returncode, 0, "rendered but should fail: " + fail)
            self.assertIn(fail, r.stderr)
            return []
        self.assertEqual(r.returncode, 0, r.stderr)
        return [d for d in yaml.safe_load_all(r.stdout) if d]

    @staticmethod
    def locker_env(docs):
        out = {}
        for d in docs:
            if d["kind"] not in ("Deployment", "Job"):
                continue
            for c in d["spec"]["template"]["spec"]["containers"]:
                env = {x["name"]: x.get("value", x.get("valueFrom")) for x in c.get("env", [])}
                if "LOCKER_BUCKET" in env:
                    out[env.get("SERVICE")] = env
        return out

    def azure(self, overrides=None, fail=None):
        return self.render(BASE + [AZURE], overrides, fail)

    def test_every_locker_reader_and_writer_on_the_container(self):
        services = self.locker_env(self.azure())
        self.assertEqual(set(services), {"session-ingest", "session-pipeline-consumer", "session-pipeline-consumer-bootstrap", "hoopdb-migrate"})
        for name, env in services.items():
            with self.subTest(service=name):
                self.assertEqual(env["LOCKER_PROVIDER"], "azure")
                self.assertEqual(env["LOCKER_BUCKET"], "sessions-ci")
                self.assertEqual(env["LOCKER_AZURE_ACCOUNT"], "exampleciacct")
                self.assertIn("secretKeyRef", env["LOCKER_AZURE_ACCOUNT_KEY"])
                for k in ("LOCKER_ACCESS_KEY_ID", "LOCKER_SECRET_ACCESS_KEY", "PIPELINE_RAW_PROVIDER"):
                    self.assertNotIn(k, env)
                self.assertFalse(env.get("LOCKER_ENDPOINT"))
        self.assertEqual(services["session-ingest"]["LOCKER_AZURE_ACCOUNT_KEY"]["secretKeyRef"], {"name": "ingest-store", "key": "account-key"})
        self.assertEqual(services["session-pipeline-consumer"]["LOCKER_AZURE_ACCOUNT_KEY"]["secretKeyRef"], {"name": "search-indexer-store", "key": "account-key"})
        # An explicit https endpoint (sovereign cloud) reaches both.
        ep = "https://exampleciacct.blob.core.usgovcloudapi.net"
        services = self.locker_env(self.azure({"ingestEdge": {"locker": {"endpoint": ep}}, "searchIndexer": {"locker": {"endpoint": ep}}, "worker": {"locker": {"endpoint": ep}}}))
        self.assertEqual(services["session-ingest"]["LOCKER_ENDPOINT"], ep)
        self.assertEqual(services["session-pipeline-consumer"]["LOCKER_ENDPOINT"], ep)

    def test_s3_fixtures_unchanged(self):
        for files in ([CI / "default-values.yaml"], [CI / "ingest-edge-values.yaml"], [CI / "search-indexer-values.yaml"],
                      [CI / "ingest-edge-s3-ledger-values.yaml"], [CI / "ingest-edge-pod-identity-values.yaml"], BASE):
            with self.subTest(files=[f.name for f in files]):
                docs = self.render(files)
                self.assertNotIn("LOCKER_AZURE", yaml.safe_dump_all(docs))

    def test_refusals(self):
        peer = [{"ipBlock": {"cidr": "10.0.0.0/8"}}]
        for overrides, msg in [
            ({"alleyoop": {"deployment": {"enabled": True}}}, "requires alleyoop.deployment.enabled=false"),
            ({"ingestEdge": {"ledger": "s3"}}, "requires ingestEdge.ledger=sql"),
            ({"ingestEdge": {"replicas": 2}}, "replicas above 1 requires ingestEdge.ledger=s3"),
            ({"ingestEdge": {"locker": {"credentials": {"mode": "podIdentity"}, "existingSecret": ""}, "serviceAccountName": "sa"}}, "ingestEdge.locker.provider=azure requires locker.credentials.mode=secret"),
            ({"ingestEdge": {"locker": {"azure": {"account": ""}}}}, "requires ingestEdge.locker.azure.account"),
            ({"ingestEdge": {"locker": {"bucket": "Bad_Container"}}}, "requires ingestEdge.locker.bucket to be an Azure container name"),
            ({"ingestEdge": {"locker": {"endpoint": "http://blob.x.svc.cluster.local"}}}, "ingestEdge.locker.endpoint must be a bare HTTPS DNS origin"),
            ({"ingestEdge": {"locker": {"accountKeyKey": ""}}}, "ingestEdge Secret/CA keys must be nonempty"),
            ({"ingestEdge": {"uploadDirect": {"mode": "on"}, "admission": {"mode": "async"}}}, "uploadDirect currently requires S3-compatible storage"),
            ({"searchIndexer": {"locker": {"bucket": "other-container"}}}, "requires searchIndexer.locker on the same Azure account, container and endpoint"),
            ({"searchIndexer": {"locker": {"provider": "s3", "endpoint": "http://session-object-storage:9000", "accessKeyIdKey": "a", "secretAccessKeyKey": "b"}}}, "requires searchIndexer.locker on the same Azure account, container and endpoint"),
            ({"searchIndexer": {"locker": {"credentials": {"mode": "podIdentity"}}}}, "searchIndexer.locker.provider=azure requires locker.credentials.mode=secret"),
            ({"searchIndexer": {"locker": {"endpoint": "http://blob.example.com"}}}, "must be empty or a bare https origin"),
            ({"searchIndexer": {"extraEnv": [{"name": "LOCKER_AZURE_ACCOUNT_KEY", "value": "x"}]}}, "searchIndexer.extraEnv must not set LOCKER_AZURE_ACCOUNT_KEY"),
            ({"worker": {"locker": {"provider": "s3", "endpoint": "http://session-object-storage:9000"}, "components": {"bob-costas": {"enabled": True}, "referee": {"enabled": True}, "hoopdb-indexer": {"enabled": True}}}}, "requires worker.locker on the same Azure account, container and endpoint"),
            ({"worker": {"components": {"referee": {"enabled": True}}}}, "locker.provider=azure requires components.referee.enabled=false"),
            ({"global": {"operatorSessionErase": {"fenceEnforced": True}}}, "does not support the operator session erase"),
            # Same store means the same effective endpoint too (empty = the account's public endpoint).
            ({"ingestEdge": {"locker": {"endpoint": "https://exampleciacct.blob.core.usgovcloudapi.net"}}, "searchIndexer": {"locker": {"endpoint": "https://exampleciacct.blob.core.usgovcloudapi.net"}}}, "requires worker.locker on the same Azure account, container and endpoint"),
            ({"searchIndexer": {"locker": {"endpoint": "https://other.blob.core.windows.net"}}}, "requires searchIndexer.locker on the same Azure account, container and endpoint"),
            ({"worker": {"locker": {"azure": {"account": "otheracct"}}}}, "requires worker.locker on the same Azure account, container and endpoint"),
            ({"nativeConsumer": {"enabled": True}, "searchIndexer": {"enabled": False}}, "does not support nativeConsumer.enabled=true"),
        ]:
            with self.subTest(msg=msg):
                self.azure(overrides, fail=msg)
        # The read API must read the same store (its Locker settings come through extraEnv).
        key = {"name": "LOCKER_AZURE_ACCOUNT_KEY", "valueFrom": {"secretKeyRef": {"name": "read-store", "key": "account-key"}}}
        good = [{"name": "LOCKER_PROVIDER", "value": "azure"}, {"name": "LOCKER_BUCKET", "value": "sessions-ci"},
                {"name": "LOCKER_AZURE_ACCOUNT", "value": "exampleciacct"}, key,
                {"name": "PIPELINE_ORG_FROM_PREFIX", "value": "true"}, {"name": "PIPELINE_KEY_PREFIX", "value": "96bulls"}]
        read = [AZURE, CI / "read-api-values.yaml"]
        services = self.locker_env(self.render(read, {"sessionReadApi": {"extraEnv": good}}))
        self.assertEqual(services["session-read-api"]["LOCKER_PROVIDER"], "azure")
        self.assertEqual(services["session-read-api"]["LOCKER_AZURE_ACCOUNT"], "exampleciacct")
        drop = lambda name: [e for e in good if e["name"] != name]
        for env, msg in [
            ([], "requires sessionReadApi.extraEnv on the same store"),
            (drop("LOCKER_AZURE_ACCOUNT_KEY"), "requires sessionReadApi.extraEnv on the same store"),
            (drop("LOCKER_AZURE_ACCOUNT") + [{"name": "LOCKER_AZURE_ACCOUNT", "value": "otheracct"}], "requires sessionReadApi.extraEnv on the same store"),
            (good + [{"name": "LOCKER_ENDPOINT", "value": "https://exampleciacct.blob.core.usgovcloudapi.net"}], "requires sessionReadApi.extraEnv on the same store"),
            (good + [{"name": "LOCKER_ACCESS_KEY_ID", "valueFrom": {"secretKeyRef": {"name": "m", "key": "rootUser"}}}], "requires sessionReadApi.extraEnv without LOCKER_ACCESS_KEY_ID"),
        ]:
            with self.subTest(read_api=msg, n=len(env)):
                self.render(read, {"sessionReadApi": {"extraEnv": env}}, fail=msg)
        # The indexer cannot read Azure while the ingest edge writes S3.
        self.render(BASE, {"searchIndexer": {"locker": {"provider": "azure", "bucket": "sessions-ci", "credentials": {"mode": "secret"},
                                                        "existingSecret": "s", "azure": {"account": "exampleciacct"}, "accountKeyKey": "account-key"}}},
                    fail="searchIndexer.locker.provider=azure requires ingestEdge.locker.provider=azure")


if __name__ == "__main__":
    unittest.main()
