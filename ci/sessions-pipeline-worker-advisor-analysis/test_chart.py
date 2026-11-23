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
        self.assertEqual(e["COORDINATION_ADVISOR_RELAY_DM_ENABLED"], "false")
        docs = self.render({"components": {"coordination-advisor": {"enabled": True}}})
        dep = next(d for d in docs if d["kind"] == "Deployment" and d["spec"]["template"]["spec"]["containers"][0]["name"] == "coordination-advisor")
        c = dep["spec"]["template"]["spec"]["containers"][0]
        self.assertEqual(dep["spec"]["strategy"]["type"], "Recreate")
        named = self.render({"components": {"coordination-advisor": {"enabled": True, "fullnameOverride": "advisor-custom"}}})
        self.assertIn("advisor-custom", [d["metadata"]["name"] for d in named if d["kind"] == "Deployment"])
        for k in ("startupProbe", "readinessProbe", "livenessProbe", "ports"):
            self.assertNotIn(k, c)
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
        docs = self.render(on)
        c = next(d for d in docs if d["kind"] == "Deployment" and d["spec"]["template"]["spec"]["containers"][0]["name"] == "coordination-advisor")["spec"]["template"]["spec"]["containers"][0]
        self.assertIn("readinessProbe", c)

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
            ({"components": {"coordination-advisor": {"enabled": True, "env": [{"name": "COORDINATION_ADVISOR_INCARNATION_ENABLED", "value": "true"}]}}}, "must not set COORDINATION_ADVISOR_INCARNATION_ENABLED"),
            ({"components": {"coordination-advisor": {"enabled": True, "env": [{"name": "COORDINATION_ADVISOR_SESSION_HOURLY_CAP", "value": "99"}]}}}, "must not set COORDINATION_ADVISOR_SESSION_HOURLY_CAP"),
            ({"extraEnv": [{"name": "COORDINATION_ADVISOR_RELAY_DM_ENABLED", "value": "true"}]}, "extraEnv must not set COORDINATION_ADVISOR_RELAY_DM_ENABLED"),
            ({"coordinationAdvisor": {"egress": {"enabled": True, "to": [{"ipBlock": {"cidr": "10.0.0.0/8"}}]}}}, "egress requires networkPolicy.enabled"),
            ({"networkPolicy": {"enabled": True, "dns": {"to": [{"ipBlock": {"cidr": "10.0.0.0/8"}}]}, "database": {"to": [{"ipBlock": {"cidr": "10.0.0.0/8"}}]}, "objectStorage": {"to": [{"ipBlock": {"cidr": "10.0.0.0/8"}}]}}, "coordinationAdvisor": {"run": True, "clickhouseSecret": {"name": "ch"}}}, "needs coordinationAdvisor.egress"),
        ]:
            with self.subTest(msg=msg):
                self.render(merge(yaml.safe_load(yaml.safe_dump(on)), extra), fail=msg)

    def test_analysis_dormant_and_enabled(self):
        docs = self.render({"sessionAnalysis": ANALYSIS})
        e = self.env(docs, "session-analysis")
        self.assertEqual(e["SESSION_ANALYSIS_ENABLED"], "false")
        self.assertEqual(e["OTEL_EXPORTER_OTLP_ENDPOINT"], "")
        e2 = self.env(self.render({"global": {"otel": {"endpoint": "http://otel.observability.svc:4318"}}, "sessionAnalysis": ANALYSIS}), "session-analysis")
        self.assertEqual(e2["OTEL_EXPORTER_OTLP_ENDPOINT"], "http://otel.observability.svc:4318")
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
        peer = [{"ipBlock": {"cidr": "10.0.0.0/8"}}]
        netpol = {"enabled": True, "dns": {"to": peer}, "database": {"to": peer}, "objectStorage": {"to": peer}}
        for top, extra, msg in [
            ({"locker": {"provider": "gcs"}}, {}, "requires locker.provider=s3"),
            ({}, {"modelEgress": {"enabled": True, "to": peer}}, "modelEgress requires networkPolicy.enabled"),
            ({"networkPolicy": netpol}, {"run": True}, "needs sessionAnalysis.modelEgress"),
            ({"networkPolicy": netpol}, {"modelEgress": {"enabled": True, "to": peer}}, "workloadIdentity.to must list the Pod Identity agent"),
        ]:
            with self.subTest(msg=msg):
                self.render(merge(yaml.safe_load(yaml.safe_dump(top)), {"sessionAnalysis": merge(yaml.safe_load(yaml.safe_dump(ANALYSIS)), extra)}), fail=msg)
        ok = merge(yaml.safe_load(yaml.safe_dump(netpol)), {"workloadIdentity": {"to": [{"ipBlock": {"cidr": "169.254.170.23/32"}}], "ports": [{"protocol": "TCP", "port": 80}]}})
        docs = self.render({"networkPolicy": ok, "sessionAnalysis": dict(ANALYSIS, run=True, modelEgress={"enabled": True, "to": peer})})
        self.assertTrue(any(d["kind"] == "NetworkPolicy" and d["metadata"]["name"].endswith("-model") for d in docs))


    MINIO = "http://session-object-storage.agent-relay.svc.cluster.local:9000"
    STATIC = {"s3Credentials": "static", "s3KeysSecret": {"name": "sessions-pipeline-locker", "accessKeyIdKey": "rootUser", "secretAccessKeyKey": "rootPassword"},
              "s3Endpoint": MINIO, "allowInClusterHttp": True}

    def analysis(self, docs):
        return next(d for d in docs if d["kind"] == "Deployment" and d["spec"]["template"]["spec"]["containers"][0]["name"] == "session-analysis")

    def test_analysis_pod_identity_default_renders_no_new_store_settings(self):
        e = self.env(self.render({"sessionAnalysis": ANALYSIS}), "session-analysis")
        self.assertEqual(e["SESSION_ANALYSIS_S3_CREDENTIALS"], "podIdentity")
        for name in ("SESSION_ANALYSIS_S3_ENDPOINT", "ALLOW_IN_CLUSTER_HTTP", "SESSION_ANALYSIS_S3_VERSIONING_CHECK",
                     "SESSION_ANALYSIS_S3_ACCESS_KEY_ID_FILE", "SESSION_ANALYSIS_S3_SECRET_ACCESS_KEY_FILE",
                     "SESSION_ANALYSIS_S3_ACCESS_KEY_ID", "SESSION_ANALYSIS_S3_SECRET_ACCESS_KEY"):
            self.assertNotIn(name, e)
        e = self.env(self.render({"sessionAnalysis": dict(ANALYSIS, s3VersioningCheck="true")}), "session-analysis")
        self.assertEqual(e["SESSION_ANALYSIS_S3_VERSIONING_CHECK"], "true")
        e = self.env(self.render({"sessionAnalysis": dict(ANALYSIS, s3Endpoint="https://s3.example.com")}), "session-analysis")
        self.assertEqual(e["SESSION_ANALYSIS_S3_CREDENTIALS"], "podIdentity")
        self.assertEqual(e["SESSION_ANALYSIS_S3_ENDPOINT"], "https://s3.example.com")
        self.assertEqual(e["ALLOW_IN_CLUSTER_HTTP"], "false")

    def test_analysis_static_keys_with_in_cluster_minio(self):
        docs = self.render({"sessionAnalysis": dict(ANALYSIS, **self.STATIC)})
        e = self.env(docs, "session-analysis")
        self.assertEqual(e["SESSION_ANALYSIS_S3_CREDENTIALS"], "static")
        self.assertEqual(e["SESSION_ANALYSIS_S3_ENDPOINT"], self.MINIO)
        self.assertEqual(e["ALLOW_IN_CLUSTER_HTTP"], "true")
        self.assertEqual(e["SESSION_ANALYSIS_S3_ACCESS_KEY_ID_FILE"], "/var/run/session-analysis/s3/access-key-id")
        self.assertEqual(e["SESSION_ANALYSIS_S3_SECRET_ACCESS_KEY_FILE"], "/var/run/session-analysis/s3/secret-access-key")
        self.assertNotIn("SESSION_ANALYSIS_S3_VERSIONING_CHECK", e)
        self.assertFalse([k for k in e if k.startswith("AWS_") or k in ("SESSION_ANALYSIS_S3_ACCESS_KEY_ID", "SESSION_ANALYSIS_S3_SECRET_ACCESS_KEY")])
        spec = self.analysis(docs)["spec"]["template"]["spec"]
        vol = next(v for v in spec["volumes"] if v["name"] == "s3-keys")
        self.assertEqual(vol["secret"]["secretName"], "sessions-pipeline-locker")
        self.assertEqual(vol["secret"]["items"], [{"key": "rootUser", "path": "access-key-id"}, {"key": "rootPassword", "path": "secret-access-key"}])
        mount = next(m for m in spec["containers"][0]["volumeMounts"] if m["name"] == "s3-keys")
        self.assertEqual(mount, {"name": "s3-keys", "mountPath": "/var/run/session-analysis/s3", "readOnly": True})
        sa = next(d for d in docs if d["kind"] == "ServiceAccount" and d["metadata"]["name"] == spec["serviceAccountName"])
        self.assertNotIn("annotations", sa["metadata"])
        for endpoint in ("http://minio.ns.svc:9000", "http://minio.ns.svc", "https://minio.example.com", "https://minio.example.com:9000/", "https://minio.example.com:65535", "http://localhost:9000", "http://[::1]:9000", "http://127.0.0.1:9000"):
            with self.subTest(endpoint=endpoint):
                e = self.env(self.render({"sessionAnalysis": dict(ANALYSIS, **dict(self.STATIC, s3Endpoint=endpoint))}), "session-analysis")
                self.assertEqual(e["SESSION_ANALYSIS_S3_ENDPOINT"], endpoint)
        e = self.env(self.render({"sessionAnalysis": dict(ANALYSIS, **dict(self.STATIC, s3Endpoint="", allowInClusterHttp=False))}), "session-analysis")
        self.assertEqual(e["SESSION_ANALYSIS_S3_CREDENTIALS"], "static")
        self.assertNotIn("SESSION_ANALYSIS_S3_ENDPOINT", e)
        self.assertNotIn("ALLOW_IN_CLUSTER_HTTP", e)

    def test_analysis_static_network_policy_needs_no_workload_identity(self):
        minio = [{"podSelector": {"matchLabels": {"app": "minio"}}}]
        peer = [{"ipBlock": {"cidr": "10.0.0.0/8"}}]
        netpol = {"enabled": True, "dns": {"to": peer}, "database": {"to": peer}, "objectStorage": {"to": minio, "ports": [{"protocol": "TCP", "port": 9000}]}}
        docs = self.render({"networkPolicy": netpol, "sessionAnalysis": dict(ANALYSIS, run=True, modelEgress={"enabled": True, "to": peer}, **self.STATIC)})
        shared = next(d for d in docs if d["kind"] == "NetworkPolicy" and not d["metadata"]["name"].endswith("-model") and d["spec"]["policyTypes"] == ["Ingress", "Egress"])
        self.assertIn({"to": minio, "ports": [{"protocol": "TCP", "port": 9000}]}, shared["spec"]["egress"])

    def test_analysis_store_refusals(self):
        for extra, msg in [
            ({"s3Credentials": "role"}, "must be podIdentity or static"),
            ({"s3Credentials": "static", "s3KeysSecret": {"name": ""}}, "s3Credentials=static needs sessionAnalysis.s3KeysSecret.name"),
            ({"s3Credentials": "static", "s3KeysSecret": {"name": "keys", "accessKeyIdKey": ""}}, "s3KeysSecret.accessKeyIdKey must be a Secret data key"),
            ({"s3Credentials": "static", "s3KeysSecret": {"name": "keys", "secretAccessKeyKey": "a/b"}}, "s3KeysSecret.secretAccessKeyKey must be a Secret data key"),
            ({"s3Credentials": "static", "s3KeysSecret": {"name": "keys", "accessKeyIdKey": "k", "secretAccessKeyKey": "k"}}, "must be different keys"),
            ({"s3KeysSecret": {"name": "keys"}}, "s3KeysSecret is used only with s3Credentials=static"),
            ({"s3Endpoint": "http://session-object-storage.agent-relay.svc.cluster.local:9000"}, "needs sessionAnalysis.allowInClusterHttp=true"),
            ({"s3Endpoint": "http://minio.example.com:9000", "allowInClusterHttp": True}, "s3Endpoint must be a bare lowercase origin"),
            ({"s3Endpoint": "http://10.0.0.5:9000", "allowInClusterHttp": True}, "s3Endpoint must be a bare lowercase origin"),
            ({"s3Endpoint": "http://minio:9000", "allowInClusterHttp": True}, "s3Endpoint must be a bare lowercase origin"),
            ({"s3Endpoint": "https://minio.example.com/bucket"}, "s3Endpoint must be a bare lowercase origin"),
            ({"s3Endpoint": "https://user:pw@minio.example.com"}, "s3Endpoint must be a bare lowercase origin"),
            ({"s3Endpoint": "https://minio.example.com?x=1"}, "s3Endpoint must be a bare lowercase origin"),
            ({"s3Endpoint": "minio.example.com"}, "s3Endpoint must be a bare lowercase origin"),
            ({"s3Endpoint": "https://minio.example.com:99999"}, "s3Endpoint port must be from 1 to 65535"),
            ({"s3Endpoint": "https://minio.example.com:0"}, "s3Endpoint port must be from 1 to 65535"),
            ({"s3Endpoint": "http://minio.ns.svc:65536", "allowInClusterHttp": True}, "s3Endpoint port must be from 1 to 65535"),
            ({"s3Endpoint": "https://storage.googleapis.com"}, "must not be the GCS API host"),
            ({"s3Endpoint": "https://bucket.storage.googleapis.com"}, "must not be the GCS API host"),
            ({"allowInClusterHttp": True}, "allowInClusterHttp=true needs sessionAnalysis.s3Endpoint"),
            ({"allowInClusterHttp": "true", "s3Endpoint": "https://minio.example.com"}, "allowInClusterHttp must be true or false"),
            ({"s3VersioningCheck": "false"}, "s3VersioningCheck must be"),
            ({"s3VersioningCheck": False}, "s3VersioningCheck must be"),
            ({"s3VersioningCheck": "yes"}, "s3VersioningCheck must be"),
        ]:
            with self.subTest(msg=msg, extra=extra):
                self.render({"sessionAnalysis": merge(yaml.safe_load(yaml.safe_dump(ANALYSIS)), extra)}, fail=msg)

if __name__ == "__main__":
    unittest.main()
