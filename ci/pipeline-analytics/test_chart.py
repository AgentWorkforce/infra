"""Managed native collector adapter: render real charts and refuse unsafe overrides."""
import copy
from pathlib import Path
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]
CONFIG = dict(enabled=True, deploymentId="install_opaque_1", collectorUrl="https://collector.ci.svc.cluster.local:8443/v1/events", existingSecret="producer.token", tokenKey="token", caConfigMap="collector.ca", caKey="ca.pem")
SLOTS = {
    "reader": ("session-read-api", "charts/session-read-api/ci/default-values.yaml", None, "read-api"),
    "ingest": ("sessions-pipeline", "charts/sessions-pipeline/ci/ingest-edge-values.yaml", "ingestEdge", "ingest-edge"),
    "consumer": ("sessions-pipeline", "charts/sessions-pipeline/ci/native-consumer-values.yaml", "nativeConsumer", "native-consumer"),
}

class Analytics(unittest.TestCase):
    def render(self, slot, config=None, mutate=None, fail=False, expected="analytics", all_docs=False):
        chart, fixture, key, component = SLOTS[slot]
        values = yaml.safe_load((ROOT / fixture).read_text())
        leaf = values if key is None else values[key]
        if config is not None:
            leaf["analytics"] = config
        if mutate:
            mutate(leaf)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "values.yaml"
            path.write_text(yaml.safe_dump(values))
            p = subprocess.run(["helm", "template", "test", str(ROOT / "charts" / chart), "-n", "ci", "-f", str(path)], text=True, capture_output=True)
        if fail:
            self.assertNotEqual(p.returncode, 0, slot)
            self.assertIn(expected.lower(), p.stderr.lower())
            return
        self.assertEqual(p.returncode, 0, p.stderr)
        docs = [d for d in yaml.safe_load_all(p.stdout) if d]
        if all_docs:
            return docs
        return next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["labels"].get("app.kubernetes.io/component") == component)

    def env(self, c):
        return {e["name"]: e for e in c["env"]}

    def test_off_has_no_adapter_or_collector_authority(self):
        for slot in SLOTS:
            with self.subTest(slot=slot):
                d = self.render(slot)
                t = d["spec"]["template"]
                self.assertNotIn("agentworkforce.dev/analytics-producer", t["metadata"]["labels"])
                for c in t["spec"]["containers"] + t["spec"].get("initContainers", []):
                    self.assertFalse(any(k.startswith("ANALYTICS_") for k in self.env(c)))
                self.assertFalse(any(v["name"] == "analytics-ca" for v in t["spec"]["volumes"]))

    def test_collector_has_scoped_secret_ca_and_only_runtime_receives_token(self):
        for slot in SLOTS:
            with self.subTest(slot=slot):
                d = self.render(slot, CONFIG)
                t = d["spec"]["template"]
                self.assertEqual(t["metadata"]["labels"]["agentworkforce.dev/analytics-producer"], "true")
                self.assertNotIn("agentworkforce.dev/analytics-producer", d["spec"]["selector"]["matchLabels"])
                p = t["spec"]; c = p["containers"][0]; env = self.env(c)
                self.assertEqual(env["ANALYTICS_SINK"]["value"], "collector")
                self.assertEqual(env["ANALYTICS_DEPLOYMENT_ID"]["value"], CONFIG["deploymentId"])
                self.assertEqual(env["ANALYTICS_COLLECTOR_URL"]["value"], CONFIG["collectorUrl"])
                self.assertEqual(env["ANALYTICS_COLLECTOR_TOKEN"], {"name":"ANALYTICS_COLLECTOR_TOKEN", "valueFrom":{"secretKeyRef":{"name":CONFIG["existingSecret"],"key":"token"}}})
                self.assertEqual(env["NODE_EXTRA_CA_CERTS"]["value"], "/etc/analytics-ca/ca.crt")
                self.assertFalse(any(k.startswith("ANALYTICS_POSTHOG") for k in env))
                self.assertEqual(next(v for v in p["volumes"] if v["name"] == "analytics-ca")["configMap"], {"name":CONFIG["caConfigMap"],"defaultMode":292,"items":[{"key":"ca.pem","path":"ca.crt"}]})
                self.assertEqual(next(m for m in c["volumeMounts"] if m["name"] == "analytics-ca"), {"name":"analytics-ca","mountPath":"/etc/analytics-ca","readOnly":True})
                for init in p.get("initContainers", []):
                    self.assertFalse(any(k.startswith("ANALYTICS_") for k in self.env(init)))

    def test_three_producers_render_through_the_umbrella(self):
        values = yaml.safe_load((ROOT / SLOTS["consumer"][1]).read_text())
        values["ingestEdge"] = yaml.safe_load((ROOT / SLOTS["ingest"][1]).read_text())["ingestEdge"]
        values["ingestEdge"]["image"] = copy.deepcopy(values["nativeConsumer"]["image"])
        reader = yaml.safe_load((ROOT / "charts/sessions-pipeline/ci/read-api-values.yaml").read_text())["sessionReadApi"]
        native = values["nativeConsumer"]
        reader["image"] = copy.deepcopy(native["image"])
        reader["postgresCa"]["configMap"] = native["postgres"]["caConfigMap"]
        reader["completeSince"] = native["completeSince"]
        reader["search"]["backendId"] = native["backendId"]
        reader["extraEnv"] = [{"name":name,"value":value} for name,value in {
            "LOCKER_BUCKET":native["locker"]["bucket"],"LOCKER_ENDPOINT":native["locker"]["endpoint"],
            "LOCKER_REGION":"us-east-1","PIPELINE_KEY_PREFIX":"96bulls","PIPELINE_ORG_FROM_PREFIX":"true",
        }.items()]
        values["sessionReadApi"] = reader
        for key, name in [("nativeConsumer","consumer"),("sessionReadApi","reader"),("ingestEdge","ingest")]:
            values[key]["analytics"] = {**CONFIG, "existingSecret": name + "-producer"}
        components = {key:False for key in yaml.safe_load((ROOT / "charts/agent-relay/values.yaml").read_text())["components"]}
        components["sessionsPipeline"] = True
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "values.yaml"
            path.write_text(yaml.safe_dump({"components":components, "sessions-pipeline":values}))
            p = subprocess.run(["helm","template","test",str(ROOT / "charts/agent-relay"),"-n","ci","-f",str(path)],text=True,capture_output=True)
        self.assertEqual(p.returncode,0,p.stderr)
        docs = [d for d in yaml.safe_load_all(p.stdout) if d and d["kind"]=="Deployment"]
        producers = [d for d in docs if d["spec"]["template"]["metadata"]["labels"].get("agentworkforce.dev/analytics-producer")=="true"]
        self.assertEqual(len(producers),3)
        refs = {self.env(d["spec"]["template"]["spec"]["containers"][0])["ANALYTICS_COLLECTOR_TOKEN"]["valueFrom"]["secretKeyRef"]["name"] for d in producers}
        self.assertEqual(refs,{"consumer-producer","reader-producer","ingest-producer"})
        check = subprocess.run(["kubeconform","-strict","-summary"],input=yaml.safe_dump_all(producers),text=True,capture_output=True)
        self.assertEqual(check.returncode,0,check.stdout+check.stderr)

    def test_bootstrap_has_no_producer_authority_or_credential(self):
        def boot(c):
            c["bootstrap"] = dict(enabled=True, phase="prepare", existingSecret="consumer-owner", ownerRole="hoop")
        docs = self.render("consumer", CONFIG, boot, all_docs=True)
        self.assertFalse(any(d["kind"] == "Deployment" and d["metadata"]["labels"].get("app.kubernetes.io/component") == "native-consumer" for d in docs))
        job = next(d for d in docs if d["kind"] == "Job" and d["metadata"]["labels"].get("app.kubernetes.io/component") == "native-consumer-bootstrap")
        t = job["spec"]["template"]
        self.assertNotIn("agentworkforce.dev/analytics-producer", t["metadata"]["labels"])
        for c in t["spec"]["containers"] + t["spec"]["initContainers"]:
            self.assertFalse(any(k.startswith("ANALYTICS_") for k in self.env(c)))
        self.assertFalse(any(v["name"] == "analytics-ca" for v in t["spec"]["volumes"]))

    def test_public_ca_uses_os_trust_without_extra_mount(self):
        for slot in SLOTS:
            d = self.render(slot, {**CONFIG, "caConfigMap":""})
            p = d["spec"]["template"]["spec"]
            self.assertNotIn("NODE_EXTRA_CA_CERTS", self.env(p["containers"][0]))
            self.assertFalse(any(v["name"] == "analytics-ca" for v in p["volumes"]))

    def test_invalid_config_refuses_in_each_slot(self):
        cases = [
            {"enabled":"true"}, {"deploymentId":""}, {"deploymentId":"person@example.com"},
            {"collectorUrl":"http://collector.ci.svc.cluster.local/v1/events"},
            {"collectorUrl":"https://user:secret@collector.example/v1/events"},
            {"collectorUrl":"https://collector.example/v1/events?token=x"},
            {"collectorUrl":"https://collector.example/v1/events#fragment"},
            {"collectorUrl":"https://collector.example:0/v1/events"},
            {"collectorUrl":"https://collector.example:65536/v1/events"},
            {"collectorUrl":"https://collector.example/wrong"}, {"existingSecret":""},
            {"existingSecret":"Bad_Secret"}, {"tokenKey":"../token"}, {"caKey":"../ca"},
            {"caConfigMap":"Bad_CA"}, {"sink":"posthog"}, {"token":"inline-secret"},
        ]
        for slot in SLOTS:
            for delta in cases:
                with self.subTest(slot=slot, delta=delta):
                    self.render(slot, {**CONFIG, **delta}, fail=True)

    def test_reader_cannot_override_managed_adapter_or_ca(self):
        for name in ["ANALYTICS_SINK","ANALYTICS_COLLECTOR_TOKEN","ANALYTICS_POSTHOG_KEY","NODE_EXTRA_CA_CERTS"]:
            with self.subTest(name=name):
                self.render("reader", CONFIG, lambda c: c.update(extraEnv=[{"name":name,"value":"override"}]), fail=True, expected=name)
        self.render("reader", CONFIG, lambda c:c.update(extraVolumes=[{"name":"analytics-ca","emptyDir":{}}]), fail=True)
        self.render("reader", CONFIG, lambda c:c.update(extraVolumeMounts=[{"name":"other","mountPath":"/etc/analytics-ca"}]), fail=True)

if __name__ == "__main__":
    unittest.main()
