"""Native History path/origin admission. Helm rendering only; no cluster calls."""
import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]
ORIGIN = "https://history.selfhosted.company:8443"

def merge(target, overlay):
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(target.get(key), dict):
            merge(target[key], value)
        else:
            target[key] = copy.deepcopy(value)

def fixture():
    values = yaml.safe_load((ROOT / "charts/sessions-pipeline/ci/read-api-values.yaml").read_text())
    values["ingestEdge"] = yaml.safe_load((ROOT / "charts/sessions-pipeline/ci/ingest-edge-values.yaml").read_text())["ingestEdge"]
    values["readApi"]["origin"] = values["ingestEdge"]["origin"] = ORIGIN
    values["readApi"]["loginAdvertisesSync"] = True
    values["readApi"]["auth"].update({"mode": "relaycontrol_only", "relayauth": {"jwksUrl": "", "issuer": ""}})
    values["nativeRouting"] = {"enabled": True, "origin": ORIGIN, "className": "test-edge", "tls": {"existingSecret": "history-tls"}}
    return values

def umbrella_fixture():
    values = yaml.safe_load((ROOT / "charts/agent-relay/values-kind-core.yaml").read_text())
    values["localKind"]["enabled"] = False
    values["components"].update({"webapp": False, "relaycast": False, "relayauth": False, "relayhistory": False})
    values["sessions-pipeline"] = fixture()
    values["relayhistory"]["ingress"]["enabled"] = False
    api = values["relay-control"]
    api["services"].update({"relayauthEnabled": False, "relayhistoryUrl": "http://routing-test-read-api.ci.svc.cluster.local", "relayhistoryPublicUrl": ORIGIN, "relayhistoryReadApiUrl": ORIGIN, "relayhistoryReadApiEvents": True})
    api["extraEnv"] = [
        {"name": "RELAYCONTROL_INTROSPECT_SECRET", "valueFrom": {"secretKeyRef": {"name": "control-introspection", "key": "introspect-secret"}}},
        {"name": "SELFHOST_INTROSPECT_AUDIENCES", "value": ORIGIN},
    ]
    return values

class NativeRouting(unittest.TestCase):
    def render(self, overlay=None, defaults=False, umbrella=False, error=None):
        values = umbrella_fixture() if umbrella else fixture()
        if defaults:
            for key in ("readApi", "ingestEdge", "nativeRouting"):
                values.pop(key, None)
        if overlay:
            merge(values, overlay)
        with tempfile.TemporaryDirectory(prefix="native-routing-render-") as directory:
            file = Path(directory) / "values.json"
            file.write_text(json.dumps(values))
            chart = "agent-relay" if umbrella else "sessions-pipeline"
            result = subprocess.run(["helm", "template", "routing-test", str(ROOT / "charts" / chart), "-n", "ci", "-f", str(file)], text=True, capture_output=True)
        if error is not None:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
            return []
        self.assertEqual(result.returncode, 0, result.stderr)
        return [d for d in yaml.safe_load_all(result.stdout) if d]

    @staticmethod
    def ingress(docs):
        routes = [d for d in docs if d["kind"] == "Ingress" and d["metadata"].get("labels", {}).get("app.kubernetes.io/component") == "native-routing"]
        assert len(routes) == 1
        return routes[0]

    def test_default_off_and_staged_services_create_no_public_route(self):
        self.assertFalse(any(d["kind"] == "Ingress" for d in self.render(defaults=True)))
        self.assertFalse(any(d["kind"] == "Ingress" for d in self.render({"nativeRouting": {"enabled": False}})))
        for enabled in ["true", 1, None]:
            self.render({"nativeRouting": {"enabled": enabled}}, error="nativeRouting.enabled must be a boolean")

    def test_exact_paths_bind_to_actual_service_ports_not_container_ports(self):
        docs = self.render({"readApi": {"port": 8092}, "ingestEdge": {"port": 8093}})
        route = self.ingress(docs)
        self.assertEqual(route["metadata"]["namespace"], "ci")
        self.assertEqual(route["spec"]["ingressClassName"], "test-edge")
        self.assertEqual(route["spec"]["tls"], [{"hosts": ["history.selfhosted.company"], "secretName": "history-tls"}])
        paths = route["spec"]["rules"][0]["http"]["paths"]
        self.assertEqual([(p["path"], p["pathType"]) for p in paths], [("/", "Prefix"), ("/v1/delivery/batches", "Exact"), ("/v1/turns/batches", "Exact"), ("/v1/delivery/limits", "Exact")])
        self.assertEqual(len({p["path"] for p in paths}), 4)
        for path in paths:
            backend = path["backend"]["service"]
            name = "routing-test-read-api" if path["path"] == "/" else "routing-test-ingest-edge"
            self.assertEqual(backend["name"], name)
            service = next(d for d in docs if d["kind"] == "Service" and d["metadata"]["name"] == name)
            deployment = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == name)
            port = next(p for p in service["spec"]["ports"] if p["name"] == "http")
            target = next(p for c in deployment["spec"]["template"]["spec"]["containers"] for p in c["ports"] if p["name"] == port["targetPort"])
            self.assertEqual(backend["port"], {"number": port["port"]})
            self.assertEqual(port["port"], 80)
            self.assertNotEqual(backend["port"]["number"], target["containerPort"])
        result = subprocess.run(["kubeconform", "-strict", "-summary"], input=yaml.safe_dump(route), text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_records_and_other_reads_never_match_the_upload_edge(self):
        paths = self.ingress(self.render())["spec"]["rules"][0]["http"]["paths"]
        def selected(path):
            matches = [p for p in paths if (p["pathType"] == "Exact" and path == p["path"]) or (p["pathType"] == "Prefix" and p["path"] == "/")]
            return max(matches, key=lambda p: (len(p["path"]), p["pathType"] == "Exact"))["backend"]["service"]["name"]
        for path in ["/v1/delivery/records", "/v1/delivery/batches/extra", "/v1/sessions", "/v1/sessions/test-id/turns", "/v1/events", "/v1/cli/login", "/v1/privacy/control-head", "/v1/sessions/test-id/reset"]:
            self.assertEqual(selected(path), "routing-test-read-api", path)
        for path in ["/v1/delivery/batches", "/v1/turns/batches", "/v1/delivery/limits"]:
            self.assertEqual(selected(path), "routing-test-ingest-edge", path)

    def test_service_and_route_names_follow_selected_fullname_overrides(self):
        docs = self.render({"readApi": {"fullnameOverride": "selected-reader"}, "ingestEdge": {"fullnameOverride": "selected-ingest"}, "nativeRouting": {"fullnameOverride": "selected-history"}})
        route = self.ingress(docs)
        self.assertEqual(route["metadata"]["name"], "selected-history")
        self.assertEqual({p["backend"]["service"]["name"] for p in route["spec"]["rules"][0]["http"]["paths"]}, {"selected-reader", "selected-ingest"})
        self.render({"readApi": {"fullnameOverride": "same-service"}, "ingestEdge": {"fullnameOverride": "same-service"}}, error="distinct reader and ingest Service names")

    def test_both_selected_services_and_matching_origin_are_required(self):
        for key in ["readApi", "ingestEdge"]:
            self.render({key: {"enabled": False}}, error="nativeRouting requires readApi.enabled=true and ingestEdge.enabled=true")
        self.render({"readApi": {"auth": {"mode": "legacy", "relayauth": {"jwksUrl": "http://auth.ci.svc.cluster.local/jwks", "issuer": "http://auth.ci.svc.cluster.local"}}}}, error="nativeRouting requires readApi.auth.mode=relaycontrol_only")
        self.render({"readApi": {"loginAdvertisesSync": False}}, error="nativeRouting requires readApi.loginAdvertisesSync=true")
        for origin in ["https://other.selfhosted.company:8443", "https://history.selfhosted.company", "https://history.selfhosted.company:9443"]:
            self.render({"nativeRouting": {"origin": origin}}, error="nativeRouting.origin must exactly equal")
        for origin in ["http://history.selfhosted.company", ORIGIN + "/", ORIGIN + "?q=1", ORIGIN + "#fragment", "https://user:pass@history.selfhosted.company:8443", "https://127.0.0.1:8443", "https://history.internal:8443", "https://History.selfhosted.company:8443"]:
            self.render({"nativeRouting": {"origin": origin}}, error="nativeRouting.origin must be a normalized public HTTPS origin")
        for port in ["0", "65536", "443", "08443"]:
            self.render({"nativeRouting": {"origin": "https://history.selfhosted.company:" + port}}, error="nativeRouting.origin port")

    def test_existing_tls_class_and_managed_route_configuration_are_required(self):
        for overlay, error in [({"className": ""}, "className is required"), ({"tls": {"existingSecret": ""}}, "tls.existingSecret is required"), ({"tls": {"existingSecret": "bad/secret"}}, "DNS subdomain"), ({"className": "BAD"}, "DNS subdomain"), ({"fullnameOverride": "bad/name"}, "DNS subdomain"), ({"paths": []}, "routes and backends are managed"), ({"tls": {"secretName": "unmanaged"}}, "select an existingSecret")]:
            self.render({"nativeRouting": overlay}, error=error)

    def test_umbrella_uses_managed_control_origin_and_refuses_legacy_public_competitors(self):
        docs = self.render(umbrella=True)
        self.ingress(docs)
        control = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "relay-control")
        env = {e["name"]: e for e in control["spec"]["template"]["spec"]["containers"][0]["env"]}
        self.assertEqual(env["RELAYHISTORY_READ_API_URL"]["value"], ORIGIN)
        self.assertEqual(env["RELAYHISTORY_READ_API_EVENTS"]["value"], "true")
        self.assertEqual(env["RELAYCONTROL_INTROSPECT_SECRET"]["valueFrom"]["secretKeyRef"]["name"], "control-introspection")
        reader = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "routing-test-read-api")
        reader_env = {e["name"]: e for e in reader["spec"]["template"]["spec"]["containers"][0]["env"]}
        self.assertEqual(reader_env["RELAYHISTORY_SELFHOST_LOGIN_ADVERTISES_SYNC"]["value"], "true")
        self.render({"components": {"relayhistory": True}, "relayhistory": {"ingress": {"enabled": True}}}, umbrella=True, error="relayhistory.ingress.enabled=false")
        self.render({"gkeIngress": {"enabled": True}}, umbrella=True, error="cannot share the legacy gkeIngress")
        for key in ["relayhistoryPublicUrl", "relayhistoryReadApiUrl"]:
            api = {"services": {key: "https://other.selfhosted.company:8443"}}
            # Keep leaf authentication admission valid so this causal case
            # reaches the parent single-origin boundary, not its audience guard.
            api["extraEnv"] = copy.deepcopy(umbrella_fixture()["relay-control"]["extraEnv"])
            api["extraEnv"][1]["value"] += ",https://other.selfhosted.company:8443"
            self.render({"relay-control": api}, umbrella=True, error="exactly equal Control's managed public and direct-reader origins")
        self.render({"relay-control": {"services": {"relayhistoryReadApiEvents": False}}}, umbrella=True, error="relayhistoryReadApiEvents=true")

if __name__ == "__main__":
    unittest.main()
