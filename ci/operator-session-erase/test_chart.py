"""Operator session erase chart contract: default-off, secret-only, fail closed."""
import copy
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]


class OperatorSessionErase(unittest.TestCase):
    def pipeline_values(self):
        values = yaml.safe_load((ROOT / "charts/sessions-pipeline/ci/native-consumer-values.yaml").read_text())
        ingest = yaml.safe_load((ROOT / "charts/sessions-pipeline/ci/ingest-edge-values.yaml").read_text())["ingestEdge"]
        native = values["nativeConsumer"]
        ingest["image"] = copy.deepcopy(native["image"])
        ingest["locker"] = copy.deepcopy(native["locker"])
        ingest["locker"].setdefault("provider", "s3")
        ingest["locker"].setdefault("region", "us-east-1")
        native["locker"].setdefault("region", "us-east-1")
        ingest["keyRoot"] = native.get("keyPrefix", "96bulls")
        ingest["admission"] = {"mode": "sync"}
        ingest["uploadDirect"] = {"mode": "off"}
        ingest["postgres"]["poolMax"] = 2
        values["ingestEdge"] = ingest
        reader = yaml.safe_load((ROOT / "charts/sessions-pipeline/ci/read-api-values.yaml").read_text())["sessionReadApi"]
        reader["image"] = copy.deepcopy(native["image"])
        reader["origin"] = ingest["origin"]
        reader["completeSince"] = native["completeSince"]
        reader["search"]["backendId"] = native["backendId"]
        reader["postgresCa"].update(configMap=native["postgres"]["caConfigMap"], sha256=native["postgres"]["caSha256"])
        reader["extraEnv"] = [{"name": k, "value": v} for k, v in {
            "LOCKER_BUCKET": ingest["locker"]["bucket"],
            "LOCKER_ENDPOINT": ingest["locker"]["endpoint"],
            "LOCKER_REGION": ingest["locker"]["region"],
            "PIPELINE_KEY_PREFIX": ingest["keyRoot"],
            "PIPELINE_ORG_FROM_PREFIX": "true",
        }.items()]
        values["sessionReadApi"] = reader
        return values

    def enable_pipeline(self, values, *, api=True, bytes_=True):
        # The supported erase composition has no legacy writers. Establish a
        # valid baseline before individual fail-closed tests turn one back on.
        values.setdefault("alleyoop", {}).setdefault("ingest", {})["replicas"] = 0
        components = values.setdefault("worker", {}).setdefault("components", {})
        worker_defaults = yaml.safe_load((ROOT / "charts/sessions-pipeline-worker/values.yaml").read_text())["components"]
        for name in worker_defaults:
            components.setdefault(name, {})["replicas"] = 0
        values.setdefault("global", {}).setdefault("operatorSessionErase", {})["fenceEnforced"] = True
        values["operatorSessionErase"] = {
            "api": {"enabled": api, "existingSecret": "erase-api", "secretKey": "current", "previousSecretKey": "previous"},
            "bytes": {
                "enabled": bytes_,
                "s3Credentials": {"existingSecret": "erase-s3", "accessKeyIdKey": "access", "secretAccessKeyKey": "secret"},
                "postgresSearch": {"existingSecret": "erase-search", "urlKey": "url"},
                "opensearch": {"existingSecret": "", "usernameKey": "username", "passwordKey": "password"},
            },
        }

    def render(self, chart, values, *, fail=None, namespace="ci"):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "values.yaml"
            path.write_text(yaml.safe_dump(values))
            p = subprocess.run(["helm", "template", "test", str(ROOT / "charts" / chart), "-n", namespace, "-f", str(path)], text=True, capture_output=True)
        if fail:
            self.assertNotEqual(p.returncode, 0, p.stdout)
            self.assertIn(fail.lower(), p.stderr.lower())
            return None
        self.assertEqual(p.returncode, 0, p.stderr)
        return [doc for doc in yaml.safe_load_all(p.stdout) if doc]

    @staticmethod
    def deployments(docs):
        return [d for d in docs if d.get("kind") == "Deployment"]

    @staticmethod
    def env(container):
        return {item["name"]: item for item in container["env"]}

    def test_default_off_is_absent(self):
        docs = self.render("sessions-pipeline", self.pipeline_values())
        for deploy in self.deployments(docs):
            for container in deploy["spec"]["template"]["spec"].get("containers", []):
                self.assertFalse(any(name.startswith("SESSION_ERASE_") for name in self.env(container)))

    def test_full_postgres_contract_reaches_only_runtime_replicas(self):
        values = self.pipeline_values()
        self.enable_pipeline(values)
        docs = self.render("sessions-pipeline", values)
        deployments = self.deployments(docs)
        selected = {}
        for deploy in deployments:
            labels = deploy["metadata"].get("labels", {})
            component = labels.get("app.kubernetes.io/component")
            if component in {"ingest-edge", "native-consumer", "read-api"}:
                selected[component] = self.env(deploy["spec"]["template"]["spec"]["containers"][0])
        self.assertEqual(set(selected), {"ingest-edge", "native-consumer", "read-api"})
        for env in selected.values():
            self.assertEqual(env["SESSION_ERASE_FENCE_ENFORCED"]["value"], "1")
        ingest = selected["ingest-edge"]
        self.assertEqual(ingest["SESSION_ERASE_API_ENABLED"]["value"], "1")
        self.assertEqual(ingest["SESSION_ERASE_BYTES_ENABLED"]["value"], "1")
        self.assertEqual(ingest["SESSION_ERASE_API_SECRET"]["valueFrom"]["secretKeyRef"], {"name": "erase-api", "key": "current"})
        self.assertEqual(ingest["SESSION_ERASE_API_SECRET_PREVIOUS"]["valueFrom"]["secretKeyRef"], {"name": "erase-api", "key": "previous"})
        self.assertEqual(ingest["SESSION_ERASE_S3_ACCESS_KEY_ID"]["valueFrom"]["secretKeyRef"]["name"], "erase-s3")
        self.assertEqual(ingest["SESSION_ERASE_SEARCH_POSTGRES_URL"]["valueFrom"]["secretKeyRef"], {"name": "erase-search", "key": "url"})
        self.assertEqual(ingest["SESSION_ERASE_S3_BUCKET"]["value"], values["ingestEdge"]["locker"]["bucket"])
        self.assertEqual(ingest["SESSION_ERASE_S3_REGION"]["value"], values["ingestEdge"]["locker"]["region"])
        self.assertEqual(ingest["SESSION_ERASE_KEY_ROOT"]["value"], values["ingestEdge"]["keyRoot"])
        for job in (d for d in docs if d.get("kind") == "Job"):
            for container in job["spec"]["template"]["spec"].get("containers", []):
                self.assertNotIn("SESSION_ERASE_FENCE_ENFORCED", self.env(container))

    def test_full_opensearch_contract_uses_dedicated_basic_auth(self):
        values = yaml.safe_load((ROOT / "charts/sessions-pipeline/ci/search-indexer-values.yaml").read_text())
        search = values["searchIndexer"]
        search["locker"]["endpoint"] = "https://s3.us-west-2.amazonaws.com"
        ingest = yaml.safe_load((ROOT / "charts/sessions-pipeline/ci/ingest-edge-values.yaml").read_text())["ingestEdge"]
        ingest["locker"].update(provider="s3", bucket=search["locker"]["bucket"], region=search["locker"]["region"], endpoint=search["locker"].get("endpoint", ""))
        ingest["postgres"]["poolMax"] = 2
        values["ingestEdge"] = ingest
        reader = yaml.safe_load((ROOT / "charts/sessions-pipeline/ci/read-api-values.yaml").read_text())["sessionReadApi"]
        reader["origin"] = ingest["origin"]
        reader["completeSince"] = search["completeSince"]
        reader["search"] = {"backend": "opensearch", "backendId": search["search"]["backendId"], "opensearch": copy.deepcopy(search["search"]["opensearch"])}
        reader["search"]["opensearch"].setdefault("indexPrefix", "relayhistory")
        reader["extraEnv"] = [{"name": k, "value": v} for k, v in {
            "LOCKER_BUCKET": ingest["locker"]["bucket"], "LOCKER_REGION": ingest["locker"]["region"],
            "LOCKER_ENDPOINT": ingest["locker"]["endpoint"],
            "PIPELINE_KEY_PREFIX": "96bulls", "PIPELINE_ORG_FROM_PREFIX": "true",
        }.items()]
        values["sessionReadApi"] = reader
        self.enable_pipeline(values)
        values["operatorSessionErase"]["bytes"]["postgresSearch"]["existingSecret"] = ""
        values["operatorSessionErase"]["bytes"]["opensearch"]["existingSecret"] = "erase-opensearch"
        docs = self.render("sessions-pipeline", values)
        ingest_doc = next(d for d in self.deployments(docs) if d["metadata"]["labels"].get("app.kubernetes.io/component") == "ingest-edge")
        env = self.env(ingest_doc["spec"]["template"]["spec"]["containers"][0])
        self.assertEqual(env["SESSION_ERASE_OPENSEARCH_USERNAME"]["valueFrom"]["secretKeyRef"], {"name": "erase-opensearch", "key": "username"})
        self.assertEqual(env["SESSION_ERASE_OPENSEARCH_PASSWORD"]["valueFrom"]["secretKeyRef"], {"name": "erase-opensearch", "key": "password"})
        self.assertEqual(env["SEARCH_INDEX_OPENSEARCH_URL"]["value"], search["search"]["opensearch"]["url"])

    def test_fail_closed_guards(self):
        cases = [
            (lambda v: v["global"]["operatorSessionErase"].update(fenceEnforced=False), "requires global.operatorSessionErase.fenceEnforced=true"),
            (lambda v: v["operatorSessionErase"]["api"].update(enabled="true"), "api.enabled must be a boolean"),
            (lambda v: v["ingestEdge"].update(enabled=False), "requires ingestEdge.enabled=true"),
            (lambda v: v["ingestEdge"]["admission"].update(mode="async"), "admission.mode=sync"),
            (lambda v: v["ingestEdge"]["uploadDirect"].update(mode="on"), "uploadDirect.mode=off"),
            (lambda v: v["sessionReadApi"].update(enabled=False), "sessionReadApi.enabled=true"),
            (lambda v: v["sessionReadApi"]["search"].setdefault("clickhouse", {}).update(enabled=True, existingSecret="clickhouse-reader", key="RELAYHISTORY_READ_API_SECRET"), "clickhouse.enabled=false"),
            (lambda v: v["alleyoop"]["ingest"].update(replicas=1), "legacy ingest Deployment scaled to zero"),
            (lambda v: v["worker"]["components"]["referee"].update(enabled=True, replicas=1), "legacy worker Deployment scaled to zero"),
            (lambda v: v["nativeConsumer"].update(enabled=False), "exactly one enabled consumer"),
            (lambda v: v["nativeConsumer"].setdefault("bootstrap", {}).update(enabled=True, phase="prepare"), "runtime Deployment"),
            (lambda v: v["sessionReadApi"]["search"].update(backendId="different"), "same search backendId"),
            (lambda v: v["ingestEdge"].update(keyRoot="different"), "key roots to match"),
            (lambda v: v["ingestEdge"]["locker"].update(bucket="different"), "Locker bucket/endpoint/region to match"),
            (lambda v: v["ingestEdge"]["locker"].update(provider="gcs"), "locker.provider=s3"),
            (lambda v: v["ingestEdge"]["postgres"].update(poolMax=1), "poolMax at least 2"),
            (lambda v: v["operatorSessionErase"]["api"].update(existingSecret=""), "api.existingSecret is required"),
            (lambda v: v["operatorSessionErase"]["api"].update(existingSecret="ingest-runtime"), "dedicated Secret"),
            (lambda v: v["operatorSessionErase"]["api"].update(previousSecretKey="current"), "previousSecretKey must differ"),
            (lambda v: v["operatorSessionErase"]["bytes"]["s3Credentials"].update(existingSecret="consumer-store"), "dedicated eraser Secret"),
            (lambda v: v["operatorSessionErase"]["bytes"]["s3Credentials"].update(accessKeyIdKey="secret"), "distinct access and secret keys"),
            (lambda v: v["operatorSessionErase"]["bytes"]["s3Credentials"].update(existingSecret="erase-api"), "API and S3 eraser credentials"),
            (lambda v: v["operatorSessionErase"]["bytes"]["postgresSearch"].update(existingSecret="erase-s3"), "Postgres search and S3 eraser credentials"),
            (lambda v: v["operatorSessionErase"]["bytes"]["opensearch"].update(existingSecret="stale-opensearch"), "opensearch must stay empty"),
            (lambda v: v["sessionReadApi"].update(extraEnv=[]), "literal sessionReadApi.extraEnv"),
        ]
        for mutate, message in cases:
            with self.subTest(message=message):
                values = self.pipeline_values()
                self.enable_pipeline(values)
                mutate(values)
                self.render("sessions-pipeline", values, fail=message)

    def control_values(self):
        return yaml.safe_load((ROOT / "charts/relay-control/ci/default-values.yaml").read_text())

    def test_control_handoff_is_default_off_and_secret_backed(self):
        values = self.control_values()
        docs = self.render("relay-control", values)
        deployment = self.deployments(docs)[0]
        self.assertFalse(any(name.startswith("SESSION_ERASE_") for name in self.env(deployment["spec"]["template"]["spec"]["containers"][0])))
        values["sessionErasureApi"] = {"enabled": True, "url": "http://test-ingest-edge.ci.svc.cluster.local", "existingSecret": "erase-api", "secretKey": "current"}
        docs = self.render("relay-control", values)
        env = self.env(self.deployments(docs)[0]["spec"]["template"]["spec"]["containers"][0])
        self.assertEqual(env["SESSION_ERASE_API_URL"]["value"], values["sessionErasureApi"]["url"])
        self.assertEqual(env["SESSION_ERASE_API_SECRET"]["valueFrom"]["secretKeyRef"], {"name": "erase-api", "key": "current"})

    def test_control_refuses_partial_inline_or_override(self):
        values = self.control_values()
        values["sessionErasureApi"] = {"enabled": True, "url": "", "existingSecret": "erase-api", "secretKey": "current"}
        self.render("relay-control", values, fail="url is required")
        for name in ["SESSION_ERASE_API_URL", "SESSION_ERASE_API_SECRET"]:
            values = self.control_values()
            values["extraEnv"] = [{"name": name, "value": "inline"}]
            self.render("relay-control", values, fail="managed by structured chart values")

    def test_umbrella_requires_atomic_matching_handoff(self):
        pipeline = self.pipeline_values()
        self.enable_pipeline(pipeline, bytes_=False)
        control = self.control_values()
        control["sessionErasureApi"] = {"enabled": True, "url": "http://test-ingest-edge.ci.svc.cluster.local", "existingSecret": "erase-api", "secretKey": "current"}
        components = {name: False for name in yaml.safe_load((ROOT / "charts/agent-relay/values.yaml").read_text())["components"]}
        components.update(sessionsPipeline=True, control=True)
        values = {"components": components, "global": {"operatorSessionErase": {"fenceEnforced": True}}, "sessions-pipeline": pipeline, "relay-control": control}
        self.render("agent-relay", values)
        history_upload = copy.deepcopy(yaml.safe_load((ROOT / "charts/relay-control/values.yaml").read_text())["historyUpload"])
        history_upload.update(mode="on", bucket="erase-upload-inbox", region="us-east-1", publicEndpoint="https://uploads.example.com")
        history_upload["credentials"].update(existingSecret="upload-issuer", accessKeyIdKey="access", secretAccessKeyKey="secret")
        history_upload["witness"].update(existingSecret="upload-witness", key="witness")
        values["relay-control"]["historyUpload"] = history_upload
        self.render("agent-relay", values, fail="relay-control.historyUpload.mode=off")
        values["relay-control"]["historyUpload"]["mode"] = "off"
        values["relay-control"]["sessionErasureApi"]["secretKey"] = "other"
        self.render("agent-relay", values, fail="same operator session erase API Secret and key")


if __name__ == "__main__":
    unittest.main()
