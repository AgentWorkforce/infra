"""Control's collector and introspection authority stay in the API container."""
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = dict(enabled=True, deploymentId="install_opaque_1", profile="production",
               collectorUrl="https://collector.ci.svc.cluster.local:8443/v1/events",
               existingSecret="control-producer", tokenKey="token", caConfigMap="collector-ca", caKey="ca.pem")


class ControlAdapters(unittest.TestCase):
    def render(self, analytics=None, intro=None, change=None, fail=None, umbrella=False):
        v = yaml.safe_load((ROOT / "charts/relay-control/ci/default-values.yaml").read_text())
        if analytics is not None:
            v["analytics"] = analytics
        if intro is not None:
            v["introspection"] = intro
        if change:
            change(v)
        chart = "relay-control"
        if umbrella:
            chart = "agent-relay"
            components = {k: False for k in yaml.safe_load((ROOT / "charts/agent-relay/values.yaml").read_text())["components"]}
            components["control"] = True
            v = {"components": components, "relay-control": v}
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder) / "values.yaml"
            p.write_text(yaml.safe_dump(v))
            r = subprocess.run(["helm", "template", "ci", str(ROOT / "charts" / chart), "-n", "ci", "-f", str(p)], text=True, capture_output=True)
        if fail:
            self.assertNotEqual(r.returncode, 0)
            self.assertIn(fail.lower(), r.stderr.lower())
            return []
        self.assertEqual(r.returncode, 0, r.stderr)
        return [d for d in yaml.safe_load_all(r.stdout) if d]

    @staticmethod
    def deployment(docs):
        return next(d for d in docs if d["kind"] == "Deployment")

    @staticmethod
    def env(container):
        return {e["name"]: e for e in container.get("env", [])}

    def assert_file_mount(self, container, variable, volume, projected_path):
        mounts = {m["name"]: m for m in container.get("volumeMounts", [])}
        self.assertIn(volume, mounts)
        mount = mounts[volume]
        self.assertIs(mount.get("readOnly"), True)
        self.assertEqual(self.env(container)[variable]["value"],
                         f'{mount["mountPath"].rstrip("/")}/{projected_path}')

    def test_default_off_adds_no_collector_authority(self):
        d = self.deployment(self.render())
        p = d["spec"]["template"]
        self.assertNotIn("agentworkforce.dev/analytics-producer", p["metadata"]["labels"])
        self.assertFalse(any(e.startswith("SELFHOST_ANALYTICS_") for e in self.env(p["spec"]["containers"][0])))
        self.assertFalse(any(v["name"] in {"analytics-producer", "analytics-ca", "introspection-secret"} for v in p["spec"]["volumes"]))

    def test_real_leaf_and_umbrella_use_dedicated_api_only_collector(self):
        for umbrella in [False, True]:
            with self.subTest(umbrella=umbrella):
                docs = self.render(ADAPTER, umbrella=umbrella)
                d = self.deployment(docs); p = d["spec"]["template"]
                self.assertEqual(p["metadata"]["labels"]["agentworkforce.dev/analytics-producer"], "true")
                self.assertNotIn("agentworkforce.dev/analytics-producer", d["spec"]["selector"]["matchLabels"])
                c = p["spec"]["containers"][0]; e = self.env(c)
                self.assertEqual(e["SELFHOST_ANALYTICS_DESTINATION"]["value"], "collector")
                self.assertEqual(e["SELFHOST_ANALYTICS_DEPLOYMENT_ID"]["value"], ADAPTER["deploymentId"])
                self.assertEqual(e["SELFHOST_ANALYTICS_COLLECTOR_URL"]["value"], ADAPTER["collectorUrl"])
                self.assertEqual(e["SELFHOST_ANALYTICS_COLLECTOR_TOKEN_FILE"]["value"], "/var/run/secrets/analytics-control/token")
                self.assertEqual(e["SELFHOST_ANALYTICS_COLLECTOR_CA_FILE"]["value"], "/var/run/analytics-collector-ca/ca.crt")
                self.assertFalse(any("POSTHOG" in key or key.endswith("COLLECTOR_TOKEN") for key in e))
                volumes = {v["name"]: v for v in p["spec"]["volumes"]}
                self.assertEqual(volumes["analytics-producer"]["secret"], dict(secretName="control-producer", defaultMode=288, items=[dict(key="token", path="token")]))
                self.assertEqual(volumes["analytics-ca"]["configMap"], dict(name="collector-ca", defaultMode=292, items=[dict(key="ca.pem", path="ca.crt")]))
                self.assert_file_mount(c, "SELFHOST_ANALYTICS_COLLECTOR_TOKEN_FILE", "analytics-producer", "token")
                self.assert_file_mount(c, "SELFHOST_ANALYTICS_COLLECTOR_CA_FILE", "analytics-ca", "ca.crt")
                check = subprocess.run(["kubeconform", "-strict", "-summary"], input=yaml.safe_dump_all(docs), text=True, capture_output=True)
                self.assertEqual(check.returncode, 0, check.stdout + check.stderr)

    def test_migration_pod_and_job_identity_do_not_receive_runtime_authority(self):
        plain = self.render()
        enabled = self.render(ADAPTER, dict(existingSecret="control-introspection", key="bearer"))
        a = next(d for d in plain if d["kind"] == "Job")
        b = next(d for d in enabled if d["kind"] == "Job")
        self.assertEqual(a["metadata"]["name"], b["metadata"]["name"])
        self.assertEqual(a["spec"]["template"], b["spec"]["template"])
        for c in b["spec"]["template"]["spec"]["containers"]:
            self.assertFalse(any(key.startswith("SELFHOST_ANALYTICS_") or "INTROSPECT" in key for key in self.env(c)))

    def test_pepper_init_has_no_producer_or_introspection_mount(self):
        def pepper(v):
            v["secretKeys"] = {"passwordPepper": "pepper"}
        p = self.deployment(self.render(ADAPTER, dict(existingSecret="control-introspection", key="bearer"), pepper))["spec"]["template"]["spec"]
        self.assertEqual(len(p["initContainers"]), 1)
        mounts = {m["name"] for m in p["initContainers"][0]["volumeMounts"]}
        self.assertFalse(mounts & {"analytics-producer", "analytics-ca", "introspection-secret"})
        self.assertFalse(self.env(p["initContainers"][0]))

    def test_collector_ca_is_separate_from_postgres_trust(self):
        def pg(v):
            v["postgresCa"] = dict(enabled=True, configMap="postgres-ca", key="ca.crt")
        e = self.env(self.deployment(self.render(ADAPTER, change=pg))["spec"]["template"]["spec"]["containers"][0])
        self.assertEqual(e["NODE_EXTRA_CA_CERTS"]["value"], "/etc/postgres-ca/ca.crt")
        self.assertNotEqual(e["NODE_EXTRA_CA_CERTS"]["value"], e["SELFHOST_ANALYTICS_COLLECTOR_CA_FILE"]["value"])

    def test_public_ca_collector_uses_system_trust(self):
        p = self.deployment(self.render({**ADAPTER, "caConfigMap": ""}))["spec"]["template"]["spec"]
        self.assertNotIn("SELFHOST_ANALYTICS_COLLECTOR_CA_FILE", self.env(p["containers"][0]))
        self.assertFalse(any(v["name"] == "analytics-ca" for v in p["volumes"]))

    def test_external_introspection_preserves_secret_and_public_route_shield(self):
        docs = self.render(intro=dict(existingSecret="control-introspection", key="bearer", audiences=["https://history.gcp-proof.agentrelay.com"]))
        p = self.deployment(docs)["spec"]["template"]["spec"]
        self.assertEqual(self.env(p["containers"][0])["RELAYCONTROL_INTROSPECT_SECRET_FILE"]["value"], "/var/run/agent-relay/introspection/secret")
        self.assert_file_mount(p["containers"][0], "RELAYCONTROL_INTROSPECT_SECRET_FILE", "introspection-secret", "secret")
        self.assertEqual(next(v for v in p["volumes"] if v["name"] == "introspection-secret")["secret"], dict(secretName="control-introspection", defaultMode=288, items=[dict(key="bearer", path="secret")]))
        primary = next(v for v in p["volumes"] if v["name"] == "secrets")
        self.assertNotIn("bearer", {i["key"] for i in primary["secret"]["items"]})
        ingress = next(d for d in docs if d["kind"] == "Ingress")
        deny = next(x for x in ingress["spec"]["rules"][0]["http"]["paths"] if x["path"] == "/internal")
        service = next(d for d in docs if d["kind"] == "Service" and d["metadata"]["name"] == deny["backend"]["service"]["name"])
        self.assertNotIn("selector", service["spec"])

    def test_legacy_introspection_projection_still_works(self):
        def legacy(v):
            v["secretKeys"] = dict(introspectSecret="old-introspection")
        p = self.deployment(self.render(change=legacy))["spec"]["template"]["spec"]
        self.assertEqual(self.env(p["containers"][0])["RELAYCONTROL_INTROSPECT_SECRET_FILE"]["value"], "/var/run/agent-relay/secrets/old-introspection")
        self.assertFalse(any(v["name"] == "introspection-secret" for v in p["volumes"]))

    def test_external_introspection_satisfies_native_history_admission(self):
        def native(v):
            v["secretKeys"] = dict(sessionReadApiSecret="reader-handoff")
            v["services"].update(relayhistoryBackend="native", relayauthEnabled=False,
                                 relayhistoryUrl="", relayhistoryPublicUrl="",
                                 sessionReadApiUrl="http://reader.ci.svc.cluster.local",
                                 sessionReadApiPublicUrl="https://history.gcp-proof.agentrelay.com",
                                 sessionReadApiMcpReads=True)
        docs = self.render(ADAPTER, dict(existingSecret="control-introspection", key="bearer",
                                        audiences=["https://history.gcp-proof.agentrelay.com"]), native)
        e = self.env(self.deployment(docs)["spec"]["template"]["spec"]["containers"][0])
        self.assertEqual(e["RELAYHISTORY_BACKEND"]["value"], "native")
        self.assertEqual(e["SESSION_READ_API_MCP_READS"]["value"], "true")
        self.assertNotIn("RELAYHISTORY_URL", e)
        self.assertNotIn("RELAYHISTORY_PUBLIC_URL", e)
        self.assertNotIn("RELAYAUTH_URL", e)

    def test_selector_and_application_security_are_unchanged(self):
        off = self.deployment(self.render()); on = self.deployment(self.render(ADAPTER))
        self.assertEqual(off["spec"]["selector"], on["spec"]["selector"])
        self.assertEqual(off["spec"]["strategy"], on["spec"]["strategy"])
        for field in ["securityContext", "automountServiceAccountToken", "serviceAccountName"]:
            self.assertEqual(off["spec"]["template"]["spec"][field], on["spec"]["template"]["spec"][field])

    def test_bad_analytics_and_overrides_refuse(self):
        cases = [{"enabled": "true"}, {"deploymentId": ""}, {"deploymentId": "person@example.com"}, {"profile": "preview"},
                 {"collectorUrl": "http://collector.ci.svc/v1/events"}, {"collectorUrl": "https://user:secret@collector.ci.svc/v1/events"},
                 {"collectorUrl": "https://collector.ci.svc/v1/events?token=x"}, {"collectorUrl": "https://collector.ci.svc/v1/events#x"},
                 {"collectorUrl": "https://collector.ci.svc:0/v1/events"}, {"collectorUrl": "https://collector.ci.svc:65536/v1/events"},
                 {"collectorUrl": "https://127.0.0.1/v1/events"}, {"collectorUrl": "https://collector.ci.svc/wrong"}, {"existingSecret": ""},
                 {"existingSecret": "Bad_Secret"}, {"existingSecret": "relay-cloud-api"}, {"tokenKey": "../token"},
                 {"caConfigMap": "Bad_CA"}, {"caKey": "../ca"}, {"token": "inline"}, {"destination": "posthog"}]
        for delta in cases:
            with self.subTest(delta=delta):
                self.render({**ADAPTER, **delta}, fail="analytics")
        for enabled in [None, ADAPTER]:
            for name in ["SELFHOST_ANALYTICS_DESTINATION", "SELFHOST_ANALYTICS_COLLECTOR_TOKEN", "SELFHOST_ANALYTICS_COLLECTOR_TOKEN_FILE", "SELFHOST_ANALYTICS_POSTHOG_PROJECT_KEY"]:
                self.render(enabled, change=lambda v: v.update(extraEnv=[dict(name=name, value="override")]), fail="SELFHOST_ANALYTICS")
        self.render(ADAPTER, change=lambda v: v.update(podLabels={"agentworkforce.dev/analytics-producer": "false"}), fail="producer Pod label")

    def test_bad_introspection_and_cross_purpose_secrets_refuse(self):
        for intro in [dict(existingSecret="Bad_Secret"), dict(existingSecret="introspection", key="../bearer"),
                      dict(existingSecret="relay-cloud-api", key="database-migrations-url"), dict(existingSecret="relay-cloud-api", key="database-url")]:
            with self.subTest(intro=intro):
                self.render(intro=intro, fail="introspection")
        self.render(intro=dict(existingSecret="introspection"), change=lambda v: v.update(secretKeys=dict(introspectSecret="old-secret")), fail="never both")
        self.render(ADAPTER, dict(existingSecret="control-producer"), fail="dedicated producer")


class DashboardAdapter(unittest.TestCase):
    def render(self, value=None, explicit=False, umbrella=False, fail=False):
        values = yaml.safe_load((ROOT / "charts/relay-webapp/ci/default-values.yaml").read_text())
        if explicit:
            values.setdefault("runtime", {})["analyticsEnabled"] = value
        chart = "relay-webapp"
        if umbrella:
            chart = "agent-relay"
            components = {key: False for key in yaml.safe_load((ROOT / "charts/agent-relay/values.yaml").read_text())["components"]}
            components["webapp"] = True
            values = {"components": components, "relay-webapp": values}
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder) / "values.yaml"
            p.write_text(yaml.safe_dump(values))
            result = subprocess.run(["helm", "template", "ci", str(ROOT / "charts" / chart), "-n", "ci", "-f", str(p)], text=True, capture_output=True)
        if fail:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("runtime.analyticsEnabled must be a boolean or null", result.stderr)
            return {}
        self.assertEqual(result.returncode, 0, result.stderr)
        docs = [d for d in yaml.safe_load_all(result.stdout) if d]
        pod = next(d for d in docs if d["kind"] == "Deployment")["spec"]["template"]["spec"]
        env = {e["name"]: e.get("value") for e in pod["containers"][0]["env"]}
        self.assertFalse(any("POSTHOG" in name or "TOKEN" in name or "SECRET" in name for name in env))
        return env

    def test_dashboard_selection_preserves_explicit_false_and_leaves_image_default_omitted(self):
        for umbrella in [False, True]:
            self.assertNotIn("DASHBOARD_ANALYTICS_ENABLED", self.render(umbrella=umbrella))
            self.assertNotIn("DASHBOARD_ANALYTICS_ENABLED", self.render(None, explicit=True, umbrella=umbrella))
            for value in [True, False]:
                self.assertEqual(self.render(value, explicit=True, umbrella=umbrella)["DASHBOARD_ANALYTICS_ENABLED"], str(value).lower())

    def test_dashboard_selection_refuses_non_boolean_values(self):
        for value in ["true", "false", 1, [], {}]:
            with self.subTest(value=value):
                self.render(value, explicit=True, fail=True)


if __name__ == "__main__":
    unittest.main()
