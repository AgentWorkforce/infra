"""coordination-advisor and session-analysis: default off, dormant, enabled, refusals."""
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
CHART = ROOT / "charts/sessions-pipeline-worker"
BASE = CHART / "ci/default-values.yaml"

ANALYSIS = {
    "enabled": True, "bucket": "canonical-bucket", "bucketRegion": "us-east-1", "keyPrefix": "96bulls",
    "modelKeySecret": {"name": "analysis-model", "key": "OPENAI_API_KEY"},
    "databaseSecret": {"name": "analysis-db", "key": "SESSION_ANALYSIS_DATABASE_URL"},
}


def merge(a, b):
    for k, v in b.items():
        if isinstance(v, dict) and isinstance(a.get(k), dict):
            merge(a[k], v)
        else:
            a[k] = v
    return a


class AdvisorAnalysis(unittest.TestCase):
    def render(self, overrides=None, fail=None):
        v = merge(yaml.safe_load(BASE.read_text()), overrides or {})
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder) / "values.yaml"
            p.write_text(yaml.safe_dump(v))
            r = subprocess.run(["helm", "template", "ci", str(CHART), "-n", "ci", "-f", str(p)], text=True, capture_output=True)
        if fail:
            self.assertNotEqual(r.returncode, 0, "rendered but should fail: " + fail)
            self.assertIn(fail, r.stderr)
            return []
        self.assertEqual(r.returncode, 0, r.stderr)
        return [d for d in yaml.safe_load_all(r.stdout) if d]

    @staticmethod
    def env(docs, container):
        for d in docs:
            if d["kind"] == "Deployment":
                for c in d["spec"]["template"]["spec"]["containers"]:
                    if c["name"] == container:
                        return {e["name"]: e.get("value", e.get("valueFrom")) for e in c["env"]}
        return None

    def test_default_renders_neither(self):
        docs = self.render()
        self.assertIsNone(self.env(docs, "coordination-advisor"))
        self.assertIsNone(self.env(docs, "session-analysis"))
        self.assertFalse([d for d in docs if "COORDINATION_ADVISOR" in yaml.safe_dump(d) or "SESSION_ANALYSIS" in yaml.safe_dump(d)])

    def test_advisor_dormant_then_enabled(self):
        e = self.env(self.render({"components": {"coordination-advisor": {"enabled": True}}}), "coordination-advisor")
        self.assertEqual(e["SERVICE"], "coordination-advisor")
        self.assertEqual(e["COORDINATION_ADVISOR_ENABLED"], "false")
        self.assertEqual(e["READ_API_DIRECTORY_WORKSPACES"], "")
        self.assertNotIn("COORDINATION_ADVISOR_RELAY_URL", e)
        on = {"components": {"coordination-advisor": {"enabled": True}}, "coordinationAdvisor": {
            "run": True, "workspaces": ["ws_a", "ws_b"], "factsBackend": "postgres", "intervalSeconds": 300,
            "relayDm": {"enabled": True, "url": "https://relay.example.com/v1/dm", "tokenSecret": {"name": "advisor-relay"}}}}
        e = self.env(self.render(on), "coordination-advisor")
        self.assertEqual(e["COORDINATION_ADVISOR_ENABLED"], "true")
        self.assertEqual(e["READ_API_DIRECTORY_WORKSPACES"], "ws_a,ws_b")
        self.assertEqual(e["COORDINATION_ADVISOR_FACTS_BACKEND"], "postgres")
        self.assertEqual(e["COORDINATION_ADVISOR_INTERVAL_SECONDS"], "300")
        self.assertEqual(e["COORDINATION_ADVISOR_RELAY_URL"], "https://relay.example.com/v1/dm")
        self.assertEqual(e["COORDINATION_ADVISOR_RELAY_TOKEN"]["secretKeyRef"]["name"], "advisor-relay")
        self.assertNotIn("SESSION_PIPELINE_SECRET_JSON", e)
        self.assertNotIn("COORDINATION_ADVISOR_INCARNATION_ENABLED", e)

    def test_advisor_refusals(self):
        on = {"components": {"coordination-advisor": {"enabled": True}}}
        for extra, msg in [
            ({"components": {"coordination-advisor": {"enabled": True, "replicas": 2}}}, "replicas must be 1"),
            ({"coordinationAdvisor": {"factsBackend": "neon"}}, "factsBackend must be clickhouse or postgres"),
            ({"coordinationAdvisor": {"run": True}}, "clickhouseSecret.name is required"),
            ({"coordinationAdvisor": {"relayDm": {"enabled": True, "url": "http://relay.example.com", "tokenSecret": {"name": "t"}}}}, "must be https"),
            ({"coordinationAdvisor": {"relayDm": {"enabled": True, "url": "https://relay.example.com?x=1", "tokenSecret": {"name": "t"}}}}, "must be https"),
            ({"coordinationAdvisor": {"relayDm": {"enabled": True, "url": "https://relay.example.com"}}}, "tokenSecret.name is required"),
            ({"coordinationAdvisor": {"intervalSeconds": 0}}, "intervalSeconds must be a positive integer"),
            ({"coordinationAdvisor": {"egress": {"enabled": True}}}, "egress.to must list destinations"),
            ({"components": {"coordination-advisor": {"enabled": True, "env": [{"name": "COORDINATION_ADVISOR_ENABLED", "value": "true"}]}}}, "must not set COORDINATION_ADVISOR_ENABLED"),
        ]:
            with self.subTest(msg=msg):
                self.render(merge(yaml.safe_load(yaml.safe_dump(on)), extra), fail=msg)

    def test_analysis_dormant_and_enabled(self):
        docs = self.render({"sessionAnalysis": ANALYSIS})
        e = self.env(docs, "session-analysis")
        self.assertEqual(e["SESSION_ANALYSIS_ENABLED"], "false")
        self.assertEqual(e["SESSION_ANALYSIS_S3_BUCKET"], "canonical-bucket")
        self.assertEqual(e["SESSION_ANALYSIS_S3_REGION"], "us-east-1")
        self.assertEqual(e["PIPELINE_ORG_FROM_PREFIX"], "true")
        self.assertEqual(e["SESSION_ANALYSIS_OPENAI_API_KEY_FILE"], "/var/run/session-analysis/model/key")
        self.assertNotIn("SESSION_ANALYSIS_ASSUME_NO_LEGACY_TURNS", e)
        self.assertNotIn("SESSION_ANALYSIS_OPENAI_API_KEY", e)
        self.assertNotIn("HOOPDB_URL", e)
        dep = next(d for d in docs if d["kind"] == "Deployment" and d["spec"]["template"]["spec"]["containers"][0]["name"] == "session-analysis")
        spec = dep["spec"]["template"]["spec"]
        self.assertEqual(spec["terminationGracePeriodSeconds"], 660)
        sa = [d for d in docs if d["kind"] == "ServiceAccount" and d["metadata"]["name"] == spec["serviceAccountName"]]
        self.assertEqual(len(sa), 1)
        shared = [d["metadata"]["name"] for d in docs if d["kind"] == "ServiceAccount"]
        self.assertEqual(len(shared), len(set(shared)))
        self.assertEqual(spec["containers"][0]["livenessProbe"]["periodSeconds"], 30)
        e = self.env(self.render({"sessionAnalysis": dict(ANALYSIS, run=True, tickMs=60000, batch=1,
                                  postgresTls={"profile": "custom-ca", "caConfigMap": "pg-ca", "sha256": "a" * 64})}), "session-analysis")
        self.assertEqual(e["SESSION_ANALYSIS_ENABLED"], "true")
        self.assertEqual(e["SESSION_ANALYSIS_TICK_MS"], "60000")
        self.assertEqual(e["SESSION_POSTGRES_TLS_PROFILE"], "custom-ca")
        self.assertEqual(e["SESSION_POSTGRES_CA_SHA256"], "a" * 64)

    def test_analysis_refusals(self):
        for extra, msg in [
            ({"bucket": ""}, "sessionAnalysis.bucket is required"),
            ({"bucketRegion": ""}, "sessionAnalysis.bucketRegion is required"),
            ({"modelKeySecret": {"name": ""}}, "modelKeySecret.name is required"),
            ({"databaseSecret": {"name": ""}}, "databaseSecret.name is required"),
            ({"s3Credentials": "irsa"}, "must be podIdentity"),
            ({"replicas": 2}, "replicas must be 1"),
            ({"tickMs": 500}, "tickMs must be an integer from 1000 to 600000"),
            ({"batch": 21}, "batch must be an integer from 1 to 20"),
            ({"postgresTls": {"profile": "custom-ca"}}, "needs caConfigMap and a 64-hex sha256"),
            ({"modelEgress": {"enabled": True}}, "modelEgress.to must list destinations"),
        ]:
            with self.subTest(msg=msg):
                self.render({"sessionAnalysis": merge(yaml.safe_load(yaml.safe_dump(ANALYSIS)), extra)}, fail=msg)


if __name__ == "__main__":
    unittest.main()
