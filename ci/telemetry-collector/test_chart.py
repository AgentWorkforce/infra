"""Source renders and isolated probe checks; no installed collector/durability proof."""
import http.server
from pathlib import Path
import subprocess
import json
import unittest
import threading

import yaml

ROOT = Path(__file__).resolve().parents[2]
CHART = "charts/telemetry-collector"
FIXTURE = CHART + "/ci/default-values.yaml"


def render(extra=(), ok=True, umbrella=False):
    command = ["helm", "template", "ci", "charts/agent-relay" if umbrella else CHART, "-n", "ci", "--no-hooks"]
    if umbrella:
        command += ["-f", "charts/agent-relay/values-kind-core.yaml"]
    else:
        command += ["-f", FIXTURE]
    result = subprocess.run(command + list(extra), cwd=ROOT, text=True, capture_output=True, timeout=45)
    if not ok:
        if result.returncode == 0:
            raise AssertionError("unsafe configuration rendered")
        return result.stderr
    if result.returncode:
        raise AssertionError(result.stderr)
    return [document for document in yaml.safe_load_all(result.stdout) if document]


class Collector(unittest.TestCase):
    def test_proxy_numeric_limits_and_name_schema(self):
        docs = render(['--set', 'limits.maxBatchBytes=1000000', '--set', 'limits.maxInFlight=1024'])
        config = next(d for d in docs if d['kind'] == 'ConfigMap')['data']['nginx.conf']
        self.assertIn('client_max_body_size 1000000;', config)
        self.assertIn('worker_connections 2080;', config)
        for key in ['nameOverride', 'fullnameOverride']:
            for value in ['Bad_Name', '-starts', 'a' * 64]:
                with self.subTest(key=key, value=value):
                    render(['--set', key + '=' + value], ok=False)

    def test_unhealthy_store_affects_readiness_without_restarting_process(self):
        class Health(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(503)
                self.end_headers()
                self.wfile.write(b'{"ok":false}')
            def log_message(self, *args):
                pass
        server = http.server.HTTPServer(('127.0.0.1', 0), Health)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        docs = render()
        collector = next(d for d in docs if d['kind'] == 'Deployment')['spec']['template']['spec']['containers'][0]
        def probe(name):
            script = collector[name]['exec']['command'][-1].replace('127.0.0.1:4319',
                      '127.0.0.1:' + str(server.server_port))
            return subprocess.run(['node', '-e', script], capture_output=True, timeout=5).returncode
        try:
            self.assertEqual(probe('readinessProbe'), 1)
            self.assertEqual(probe('livenessProbe'), 0)
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=5)
        self.assertEqual(probe('livenessProbe'), 1)

    def test_exclusive_writer_and_retained_persistent_claim(self):
        documents = render()
        deployment = next(item for item in documents if item["kind"] == "Deployment")
        self.assertEqual(deployment["spec"]["replicas"], 1)
        self.assertEqual(deployment["spec"]["strategy"], {"type": "Recreate"})
        claim = next(item for item in documents if item["kind"] == "PersistentVolumeClaim")
        self.assertEqual(claim["spec"]["accessModes"], ["ReadWriteOncePod"])
        self.assertEqual(claim["metadata"]["annotations"]["helm.sh/resource-policy"], "keep")
        pod = deployment["spec"]["template"]["spec"]
        self.assertFalse(pod["automountServiceAccountToken"])
        data = next(item for item in pod["volumes"] if item["name"] == "data")
        self.assertEqual(data["persistentVolumeClaim"]["claimName"], claim["metadata"]["name"])

    def test_only_tls_is_exposed_and_credentials_are_separated(self):
        documents = render()
        self.assertFalse(any(item["kind"] in {"Secret", "Ingress", "Role", "RoleBinding"} for item in documents))
        service = next(item for item in documents if item["kind"] == "Service")
        self.assertEqual(service["spec"]["type"], "ClusterIP")
        self.assertEqual(service["spec"]["ports"], [{"name": "https", "port": 8443, "targetPort": "https"}])
        deployment = next(item for item in documents if item["kind"] == "Deployment")
        containers = {item["name"]: item for item in deployment["spec"]["template"]["spec"]["containers"]}
        collector = containers["collector"]
        env = {item["name"]: item["value"] for item in collector["env"]}
        self.assertEqual(env["ANALYTICS_COLLECTOR_HOST"], "127.0.0.1")
        self.assertEqual(env["ANALYTICS_COLLECTOR_RETENTION"], "reject-new")
        self.assertTrue(collector["command"][-1].endswith("/dist/collector-cli.js"))
        self.assertEqual({item["name"] for item in collector["volumeMounts"]}, {"data", "producers"})
        self.assertEqual({item["name"] for item in containers["tls-proxy"]["volumeMounts"]}, {"proxy-config", "tls", "proxy-tmp"})
        for container in containers.values():
            self.assertIn("@sha256:", container["image"])
            self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
            self.assertFalse(container["securityContext"]["allowPrivilegeEscalation"])
        self.assertIn(".ok===true", collector["readinessProbe"]["exec"]["command"][-1])
        policy = next(item for item in documents if item["kind"] == "NetworkPolicy")
        self.assertEqual(policy["spec"]["egress"], [])
        self.assertEqual(policy["spec"]["ingress"][0]["ports"], [{"protocol": "TCP", "port": 8443}])
        config = next(item for item in documents if item["kind"] == "ConfigMap")["data"]["nginx.conf"]
        self.assertIn("listen 8443 ssl", config)
        self.assertIn("proxy_request_buffering off", config)
        self.assertIn("access_log off", config)
        for prefix in ["fastcgi", "uwsgi", "scgi"]:
            self.assertIn(prefix + "_temp_path /tmp/", config)
        self.assertIn("client_max_body_size " + env["ANALYTICS_COLLECTOR_MAX_BATCH_BYTES"] + ";", config)

    def test_existing_claim_is_referenced_without_creating_or_replacing_it(self):
        documents = render(["--set", "persistence.existingClaim=retained-telemetry"])
        self.assertFalse(any(item["kind"] == "PersistentVolumeClaim" for item in documents))
        pod = next(item for item in documents if item["kind"] == "Deployment")["spec"]["template"]["spec"]
        self.assertEqual(next(item for item in pod["volumes"] if item["name"] == "data")["persistentVolumeClaim"]["claimName"], "retained-telemetry")

    def test_invalid_or_unsafe_overrides_are_refused(self):
        cases = [
            (["--set", "replicaCount=2"], "replicaCount"),
            (["--set", "image.digest="], "immutable image"),
            (["--set", "image.digest=main"], "digest"),
            (["--set", "image.sourceRevision=main"], "sourceRevision"),
            (["--set", "image.sourceRevision=" + "b" * 40], "sourceRevision"),
            (["--set-json", 'imagePullSecrets=[{"name":""}]'], "name"),
            (["--set", "persistence.size=2GB"], "size"),
            (["--set", "producersSecret="], "producersSecret is required"),
            (["--set", "tlsSecret="], "tlsSecret is required"),
            (["--set", "tlsSecret=ci-telemetry-producers"], "distinct Secrets"),
            (["--set-json", "networkPolicy.allowedFrom=[]"], "allowedFrom"),
            (["--set-json", 'networkPolicy.allowedFrom=[{"podSelector":{}}]'], "podSelector"),
            (["--set-json", 'networkPolicy.allowedFrom=[{"namespaceSelector":{}}]'], "namespaceSelector"),
            (["--set-json", 'networkPolicy.allowedFrom=[{"podSelector":{"matchLabels":{}}}]'], "matchLabels"),
            (["--set-json", 'networkPolicy.allowedFrom=[{"podSelector":{"matchExpressions":[]}}]'], "matchExpressions"),
            (["--set", "limits.maxEventBytes=524288"], "maxEventBytes must not exceed"),
            (["--set", "limits.shutdownDeadlineMs=60000"], "termination grace"),
            (["--set", "retention.maxAgeMs=60000"], "requires delete-oldest-closed"),
            (["--set", "extraEnv[0].name=POSTHOG_HOST"], "additional properties"),
        ]
        for args, message in cases:
            with self.subTest(args=args):
                self.assertIn(message.lower(), render(args, ok=False).lower())

    def test_enabled_umbrella_passes_real_values_and_enforces_kubernetes_version(self):
        values = yaml.safe_load((ROOT / FIXTURE).read_text())
        values["fullnameOverride"] = "telemetry-collector"
        args = ["--set", "components.telemetryCollector=true", "--set-json", "telemetry-collector=" + json.dumps(values)]
        documents = render(args, umbrella=True)
        collector = [item for item in documents if item["metadata"]["name"] == "telemetry-collector"]
        self.assertEqual({item["kind"] for item in collector}, {"ConfigMap", "Deployment", "Service", "PersistentVolumeClaim", "NetworkPolicy"})
        pod = next(item for item in collector if item["kind"] == "Deployment")["spec"]["template"]["spec"]
        self.assertEqual(pod["containers"][0]["image"], values["image"]["repository"] + "@" + values["image"]["digest"])
        self.assertIn("1.29", render(args + ["--kube-version", "1.28.9"], umbrella=True, ok=False))
        self.assertTrue(render(["--kube-version", "1.28.9"], umbrella=True))

    def test_scoped_expression_selector_and_configured_proxy_body_limit(self):
        documents = render(["--set-json", 'networkPolicy.allowedFrom=[{"podSelector":{"matchExpressions":[{"key":"role","operator":"In","values":["producer"]}]}}]', "--set", "limits.maxBatchBytes=8192"])
        config = next(item for item in documents if item["kind"] == "ConfigMap")["data"]["nginx.conf"]
        self.assertIn("client_max_body_size 8192;", config)
        env = next(item for item in documents if item["kind"] == "Deployment")["spec"]["template"]["spec"]["containers"][0]["env"]
        self.assertEqual(next(item["value"] for item in env if item["name"] == "ANALYTICS_COLLECTOR_MAX_BATCH_BYTES"), "8192")

    def test_umbrella_keeps_collector_off_until_explicitly_configured(self):
        self.assertFalse(any(item.get("metadata", {}).get("name") == "telemetry-collector" for item in render(umbrella=True)))
        error = render(["--set", "components.telemetryCollector=true"], ok=False, umbrella=True)
        self.assertIn("sourceRevision", error)


if __name__ == "__main__":
    unittest.main()
