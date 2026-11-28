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

    def test_analysis_dedicated_image_does_not_change_sibling_workers(self):
        shared = "ghcr.io/agentworkforce/96bulls-services@sha256:" + "1" * 64
        dedicated = "registry.example.com/analysis/runner@sha256:" + "2" * 64
        values = {
            "image": {"repository": "ghcr.io/agentworkforce/96bulls-services", "digest": "sha256:" + "1" * 64},
            "components": {"referee": {"enabled": True}},
            "sessionAnalysis": dict(ANALYSIS, image={
                "repository": "registry.example.com/analysis/runner", "digest": "sha256:" + "2" * 64,
                "pullPolicy": "Always",
            }),
        }
        docs = self.render(values)
        deployment_docs = [d for d in docs if d["kind"] == "Deployment"]
        deployment_names = [d["spec"]["template"]["spec"]["containers"][0]["name"] for d in deployment_docs]
        self.assertEqual(len(deployment_names), len(set(deployment_names)))
        deployments = dict(zip(deployment_names, deployment_docs))
        analysis = deployments["session-analysis"]["spec"]["template"]["spec"]["containers"][0]
        status = deployments["session-status-worker"]["spec"]["template"]["spec"]["containers"][0]
        self.assertEqual(analysis["image"], dedicated)
        self.assertEqual(analysis["imagePullPolicy"], "Always")
        self.assertEqual(status["image"], shared)
        self.assertEqual(status["imagePullPolicy"], "IfNotPresent")
        inherited = self.analysis(self.render({
            "image": {"repository": "ghcr.io/agentworkforce/96bulls-services", "digest": "sha256:" + "1" * 64},
            "sessionAnalysis": dict(ANALYSIS, image=None),
        }))["spec"]["template"]["spec"]["containers"][0]
        self.assertEqual(inherited["image"], shared)
        self.assertEqual(inherited["imagePullPolicy"], "IfNotPresent")

    def test_analysis_image_refusals(self):
        for image, msg in [
            ({"repository": "runner"}, "needs image.tag or image.digest"),
            ({"digest": "sha256:" + "2" * 64}, "needs image.repository"),
            ({"repository": "runner", "tag": 20261123}, "image.tag must be a string"),
            ({"repository": "runner", "tag": "v1", "pullPolicy": "Sometimes"}, "pullPolicy must be"),
        ]:
            with self.subTest(msg=msg):
                self.render({"sessionAnalysis": dict(ANALYSIS, image=image)}, fail=msg)

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
            ({"locker": {"provider": "gcs"}}, {}, "requires locker.provider=s3 or azure"),
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
        for endpoint in ("http://minio.ns.svc:9000", "http://minio.ns.svc", "https://minio.example.com", "https://minio.example.com:9000/", "https://minio.example.com:65535", "https://10.0.0.5:9000", "https://minio:9000", "http://localhost:9000", "http://[::1]:9000", "http://127.0.0.1:9000"):
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
            ({"s3Endpoint": "https://minio..example.com"}, "s3Endpoint must be a bare lowercase origin"),
            ({"s3Endpoint": "https://-minio.example.com"}, "s3Endpoint must be a bare lowercase origin"),
            ({"s3Endpoint": "https://MinIO.example.com"}, "s3Endpoint must be a bare lowercase origin"),
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

    # locker.provider=azure: native Azure Blob (runner.ts LOCKER_PROVIDER=azure, Shared Key from a file).
    AZURE_VALUES = CHART / "ci/session-analysis-azure-blob-values.yaml"
    AZ_LOCKER = {"existingSecret": "sessions-pipeline", "locker": {"provider": "azure", "endpoint": "", "bucket": "sessions-ci", "azure": {"account": "exampleciacct"}}, "lockerInit": {"enabled": False},
                 # Only coordination-advisor and session-analysis admit LOCKER_PROVIDER=azure (vendorBindings ownLocker, fefbc87c).
                 "components": {n: {"enabled": False} for n in ("bob-costas", "referee", "hoopdb-indexer", "session-brief")}}
    AZ_ANALYSIS = {"enabled": True, "keyPrefix": "96bulls",
                   "modelKeySecret": {"name": "analysis-model", "key": "OPENAI_API_KEY"},
                   "databaseSecret": {"name": "analysis-db", "key": "SESSION_ANALYSIS_DATABASE_URL"}}

    def azure(self, analysis=None, top=None, fail=None):
        v = merge(yaml.safe_load(yaml.safe_dump(self.AZ_LOCKER)), {"sessionAnalysis": merge(yaml.safe_load(yaml.safe_dump(self.AZ_ANALYSIS)), analysis or {})})
        return self.render(merge(v, top or {}), fail=fail)

    def test_azure_ci_values_render(self):
        r = subprocess.run(["helm", "template", "ci", str(CHART), "-n", "ci", "-f", str(self.AZURE_VALUES)], text=True, capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        docs = [d for d in yaml.safe_load_all(r.stdout) if d]
        e = self.env(docs, "session-analysis")
        self.assertEqual(e["LOCKER_PROVIDER"], "azure")
        self.assertEqual(e["SESSION_ANALYSIS_AZURE_CONTAINER"], "sessions-ci")

    def test_azure_analysis_env_and_key_file(self):
        docs = self.azure()
        e = self.env(docs, "session-analysis")
        self.assertEqual(e["LOCKER_PROVIDER"], "azure")
        self.assertEqual(e["SESSION_ANALYSIS_AZURE_ACCOUNT"], "exampleciacct")
        self.assertEqual(e["SESSION_ANALYSIS_AZURE_CONTAINER"], "sessions-ci")
        self.assertEqual(e["SESSION_ANALYSIS_AZURE_ACCOUNT_KEY_FILE"], "/var/run/session-analysis/azure/account-key")
        self.assertEqual(e["PIPELINE_KEY_PREFIX"], "96bulls")
        self.assertNotIn("SESSION_ANALYSIS_AZURE_ENDPOINT", e)
        self.assertNotIn("SESSION_ANALYSIS_AZURE_ACCOUNT_KEY", e)
        self.assertNotIn("ALLOW_IN_CLUSTER_HTTP", e)
        # The runner refuses any SESSION_ANALYSIS_S3_* on Azure (azure_s3_settings_conflict).
        self.assertFalse([k for k in e if k.startswith("SESSION_ANALYSIS_S3_") or k.startswith("AWS_")])
        spec = self.analysis(docs)["spec"]["template"]["spec"]
        vol = next(v for v in spec["volumes"] if v["name"] == "azure-account-key")
        self.assertEqual(vol["secret"], {"secretName": "sessions-pipeline", "items": [{"key": "LOCKER_AZURE_ACCOUNT_KEY", "path": "account-key"}]})
        mount = next(m for m in spec["containers"][0]["volumeMounts"] if m["name"] == "azure-account-key")
        self.assertEqual(mount, {"name": "azure-account-key", "mountPath": "/var/run/session-analysis/azure", "readOnly": True})
        self.assertFalse([v for v in spec["volumes"] if v["name"] == "s3-keys"])
        # An explicit key Secret and an endpoint (Azure public, sovereign or Azurite on loopback).
        e = self.env(self.azure({"azure": {"accountKeySecret": {"name": "analysis-blob", "key": "accountKey"}}}), "session-analysis")
        docs = self.azure({"azure": {"accountKeySecret": {"name": "analysis-blob", "key": "accountKey"}}})
        vol = next(v for v in self.analysis(docs)["spec"]["template"]["spec"]["volumes"] if v["name"] == "azure-account-key")
        self.assertEqual(vol["secret"], {"secretName": "analysis-blob", "items": [{"key": "accountKey", "path": "account-key"}]})
        for endpoint in ("https://exampleciacct.blob.core.windows.net", "https://exampleciacct.blob.core.usgovcloudapi.net/", "http://127.0.0.1:10000/exampleciacct"):
            with self.subTest(endpoint=endpoint):
                e = self.env(self.azure(top={"locker": {"endpoint": endpoint}}), "session-analysis")
                self.assertEqual(e["SESSION_ANALYSIS_AZURE_ENDPOINT"], endpoint)

    def test_azure_locker_env_for_every_worker(self):
        # coordination-advisor is the one sibling worker the services run on Azure (ownLocker); the migrate Job
        # gets the Locker env too but never reads the Locker.
        docs = self.azure(top={"components": {"coordination-advisor": {"enabled": True}}})
        seen = set()
        for d in docs:
            if d["kind"] not in ("Deployment", "Job"):
                continue
            for c in d["spec"]["template"]["spec"]["containers"]:
                if c["name"] == "session-analysis":
                    continue
                e = {x["name"]: x.get("value", x.get("valueFrom")) for x in c.get("env", [])}
                if "LOCKER_BUCKET" not in e:
                    continue
                seen.add(e["SERVICE"])
                self.assertEqual(e["LOCKER_PROVIDER"], "azure", c["name"])
                self.assertEqual(e["LOCKER_BUCKET"], "sessions-ci")
                self.assertEqual(e["LOCKER_AZURE_ACCOUNT"], "exampleciacct")
                self.assertEqual(e["LOCKER_AZURE_ACCOUNT_KEY"], {"secretKeyRef": {"name": "sessions-pipeline", "key": "LOCKER_AZURE_ACCOUNT_KEY"}})
                for k in ("LOCKER_ACCESS_KEY_ID", "LOCKER_SECRET_ACCESS_KEY", "PIPELINE_RAW_PROVIDER"):
                    self.assertNotIn(k, e, c["name"])
        self.assertEqual(seen, {"coordination-advisor", "hoopdb-migrate"})
        # Analysis off: the Locker on Azure renders on its own.
        self.render(dict(self.AZ_LOCKER))

    def test_azure_refuses_workers_the_services_refuse(self):
        # src/shared/env.ts vendorBindings throws for LOCKER_PROVIDER=azure without ownLocker (fefbc87c, 155f7ba6).
        for name in ("bob-costas", "referee", "hoopdb-indexer", "session-brief"):
            with self.subTest(component=name):
                if name != "session-brief":
                    self.azure(top={"components": {name: {"enabled": True}}}, fail=f"locker.provider=azure requires components.{name}.enabled=false")
                    continue
                # session-brief renders only with a full native-brief selection (ci/sessions-pipeline-native-brief).
                peer = [{"ipBlock": {"cidr": "10.0.0.0/8"}}]
                brief = {"migrations": {"enabled": False}, "postgresCa": {"enabled": True, "configMap": "public-pg-ca", "sha256": "a" * 64}, "components": {"session-brief": {"enabled": True}},
                         "nativeBrief": {"enabled": True, "image": {"repository": "agentworkforce/native-services", "digest": "sha256:" + "b" * 64},
                                         "workspaceIds": ["default-workspace"], "openaiSecret": {"name": "brief-model-key"},
                                         "openaiEgress": {"enabled": True, "to": peer}},
                         "networkPolicy": {"enabled": True, "dns": {"to": peer}, "database": {"to": peer}, "objectStorage": {"to": peer}}}
                self.render(merge(yaml.safe_load(yaml.safe_dump(self.AZ_LOCKER)), brief), fail=f"locker.provider=azure requires components.{name}.enabled=false")

    def test_azure_fixture_pins_the_release_image(self):
        # The agent-relay-2026.11.24 sessions-pipeline pin (source fefbc87c), as the runner image.
        pins = __import__("json").loads((ROOT / "releases/agent-relay-2026.11.24/pins.json").read_text())["pins"]["sessions-pipeline"]
        self.assertEqual(pins["sourceRevision"][:8], "fefbc87c")
        r = subprocess.run(["helm", "template", "ci", str(CHART), "-n", "ci", "-f", str(self.AZURE_VALUES)], text=True, capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        image = self.analysis([d for d in yaml.safe_load_all(r.stdout) if d])["spec"]["template"]["spec"]["containers"][0]["image"]
        self.assertEqual(image, f'{pins["repository"]}@{pins["digest"]}')

    def test_s3_still_renders(self):
        for f in ("session-analysis-static-minio-values.yaml", "default-values.yaml"):
            with self.subTest(values=f):
                r = subprocess.run(["helm", "template", "ci", str(CHART), "-n", "ci", "-f", str(CHART / "ci" / f)], text=True, capture_output=True)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertNotIn("LOCKER_AZURE", r.stdout)
                self.assertNotIn("SESSION_ANALYSIS_AZURE", r.stdout)

    def test_aks_umbrella_renders_with_azure_blob_and_with_minio(self):
        """The AKS guide's own values (ci/agent-relay/aks-native-site-values.sh), through the agent-relay chart."""
        umbrella = ROOT / "charts/agent-relay"
        # The step 13b example from the AKS guide itself, placeholders filled, under sessions-pipeline.worker.
        readme = (ROOT / "docs/azure-install/README.md").read_text()
        section = readme[readme.index("### 13b."):]
        block = section[section.index("```yaml\n") + len("```yaml\n"):section.index("\n```", section.index("```yaml\n"))]
        for k, v in {"__SESSIONS_CONTAINER__": "sessions-ci", "__STORAGE_ACCOUNT__": "exampleciacct", "__POSTGRES_CA_SHA256__": "\"" + "1" * 64 + "\""}.items():
            block = block.replace(k, v)
        self.assertNotIn("__", block)
        overlay = yaml.safe_load(block)
        self.assertEqual(list(overlay), ["sessions-pipeline"])
        with tempfile.TemporaryDirectory() as folder:
            site = Path(folder) / "site.yaml"
            subprocess.run([str(ROOT / "ci/agent-relay/aks-native-site-values.sh"), str(site)], check=True)
            az = Path(folder) / "azure.yaml"
            az.write_text(yaml.safe_dump(overlay))
            base = ["helm", "template", "agent-relay", str(umbrella), "-n", "agent-relay", "-f", str(umbrella / "values-eks.yaml"),
                    "-f", str(site), "-f", str(umbrella / "ci/aks-native-values.yaml")]
            s3 = subprocess.run(base, text=True, capture_output=True)
            self.assertEqual(s3.returncode, 0, s3.stderr)
            self.assertNotIn("SESSION_ANALYSIS_AZURE", s3.stdout)
            r = subprocess.run(base + ["-f", str(az)], text=True, capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        docs = [d for d in yaml.safe_load_all(r.stdout) if d]
        e = self.env(docs, "session-analysis")
        self.assertEqual(e["LOCKER_PROVIDER"], "azure")
        self.assertEqual(e["SESSION_ANALYSIS_AZURE_ACCOUNT"], "exampleciacct")
        self.assertFalse([k for k in e if k.startswith("SESSION_ANALYSIS_S3_")])
        # Every Locker reader and writer on the one Azure container; none keeps S3 keys or the MinIO endpoint.
        services = {}
        for d in docs:
            if d["kind"] not in ("Deployment", "Job"):
                continue
            for c in d["spec"]["template"]["spec"]["containers"]:
                env = {x["name"]: x.get("value", x.get("valueFrom")) for x in c.get("env", [])}
                if "LOCKER_BUCKET" in env:
                    services[env.get("SERVICE")] = env
        for name in ("session-ingest", "session-pipeline-consumer", "session-read-api", "hoopdb-migrate"):
            env = services[name]
            self.assertEqual(env.get("LOCKER_PROVIDER"), "azure", name)
            self.assertEqual(env["LOCKER_BUCKET"], "sessions-ci", name)
            self.assertEqual(env["LOCKER_AZURE_ACCOUNT"], "exampleciacct", name)
            self.assertEqual(env["LOCKER_AZURE_ACCOUNT_KEY"]["secretKeyRef"], {"name": "sessions-pipeline-locker", "key": "azure-account-key"}, name)
            self.assertFalse({"LOCKER_ACCESS_KEY_ID", "LOCKER_SECRET_ACCESS_KEY"} & set(env), name)
            self.assertNotIn("session-object-storage", str(env.get("LOCKER_ENDPOINT", "")), name)
        for refused in ("bob-costas", "referee", "hoopdb-indexer", "session-brief"):
            self.assertNotIn(refused, services)


    def test_azure_analysis_key_follows_locker_key_mapping(self):
        # Renaming only the Locker key moves the analysis mount with it (one Secret entry for both).
        docs = self.azure(top={"secretKeys": {"lockerAzureAccountKey": "blob-key"}, "components": {"coordination-advisor": {"enabled": True}}})
        vol = next(v for v in self.analysis(docs)["spec"]["template"]["spec"]["volumes"] if v["name"] == "azure-account-key")
        self.assertEqual(vol["secret"]["items"], [{"key": "blob-key", "path": "account-key"}])
        e = self.env(docs, "coordination-advisor")
        self.assertEqual(e["LOCKER_AZURE_ACCOUNT_KEY"]["secretKeyRef"]["key"], "blob-key")
        # External Secrets must map every key the target Secret is read for, the analysis key included.
        es = {"externalSecrets": {"enabled": True, "secretStoreRef": {"kind": "ClusterSecretStore", "name": "store"},
              "data": {"HOOPDB_URL": {"key": "k", "property": "url"}, "LOCKER_AZURE_ACCOUNT_KEY": {"key": "k", "property": "blob"}, "SUMMARY_MASTER_KEYS": {"key": "k", "property": "summary"}}}}
        self.azure(top=es)
        self.azure({"azure": {"accountKeySecret": {"key": "analysis-blob"}}}, top=es, fail="externalSecrets.data must map analysis-blob")
        self.azure({"azure": {"accountKeySecret": {"name": "other-secret", "key": "analysis-blob"}}}, top=es)


    def test_azure_refusals(self):
        for analysis, top, msg in [
            ({"bucket": "b"}, {}, "sessionAnalysis.bucket must be empty with locker.provider=azure"),
            ({"bucketRegion": "us-east-1"}, {}, "sessionAnalysis.bucketRegion must be empty with locker.provider=azure"),
            ({"s3Endpoint": "https://s3.example.com"}, {}, "sessionAnalysis.s3Endpoint must be empty with locker.provider=azure"),
            ({"s3VersioningCheck": "true"}, {}, "sessionAnalysis.s3VersioningCheck must be empty with locker.provider=azure"),
            ({"s3KeysSecret": {"name": "keys"}}, {}, "s3KeysSecret.name must be empty with locker.provider=azure"),
            ({"allowInClusterHttp": True}, {}, "allowInClusterHttp must be false with locker.provider=azure"),
            ({"decisionRecords": "true"}, {}, "azure_decision_records_unsupported"),
            ({"azure": {"accountKeySecret": {"key": "a/b"}}}, {}, "accountKeySecret.key must be a Secret data key"),
            ({"keyPrefix": ""}, {}, "sessionAnalysis.keyPrefix is required"),
            ({}, {"locker": {"azure": {"account": ""}}}, "requires locker.azure.account"),
            ({}, {"locker": {"azure": {"account": "Bad_Account"}}}, "requires locker.azure.account"),
            ({}, {"locker": {"bucket": "Sessions"}}, "requires locker.bucket to be an Azure container name"),
            ({}, {"locker": {"bucket": "ab"}}, "requires locker.bucket to be an Azure container name"),
            ({}, {"locker": {"bucket": "a--b"}}, "requires locker.bucket to be an Azure container name"),
            ({}, {"locker": {"credentials": {"mode": "podIdentity"}}}, "locker.provider=azure requires locker.credentials.mode=secret"),
            ({}, {"locker": {"endpoint": "http://blob.example.com"}}, "locker.endpoint with locker.provider=azure must be"),
            ({}, {"locker": {"endpoint": "https://user:pw@blob.example.com"}}, "locker.endpoint with locker.provider=azure must be"),
            ({}, {"locker": {"endpoint": "https://blob.example.com/other"}}, "locker.endpoint with locker.provider=azure must be"),
            ({}, {"locker": {"endpoint": "https://blob.example.com?sv=x"}}, "locker.endpoint with locker.provider=azure must be"),
            ({}, {"lockerInit": {"enabled": True}}, "lockerInit.enabled must be false with locker.provider=azure"),
            ({}, {"extraEnv": [{"name": "LOCKER_AZURE_ACCOUNT_KEY", "value": "x"}]}, "extraEnv must not set LOCKER_AZURE_ACCOUNT_KEY"),
            ({}, {"locker": {"provider": "blob", "endpoint": "https://x.example.com"}}, "requires locker.provider=s3 or azure"),
        ]:
            with self.subTest(msg=msg, analysis=analysis, top=top):
                self.azure(analysis, top, fail=msg)
        self.render(merge(yaml.safe_load(yaml.safe_dump(self.AZ_LOCKER)), {"locker": {"provider": "blob", "endpoint": "https://x.example.com"}}), fail="locker.provider must be s3, gcs or azure")
        # Without any Secret name there is nowhere to read the key from.
        self.azure(top={"existingSecret": "", "hoopdb": {"existingSecret": "hoopdb"}}, fail="existingSecret is required")


if __name__ == "__main__":
    unittest.main()
