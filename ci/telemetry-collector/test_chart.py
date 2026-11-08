"""Offline renders only; never an installed collector or durable-ack proof."""
from pathlib import Path
import subprocess
import unittest

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
            (["--set", "producersSecret="], "producersSecret is required"),
            (["--set", "tlsSecret="], "tlsSecret is required"),
            (["--set", "tlsSecret=ci-telemetry-producers"], "distinct Secrets"),
            (["--set-json", "networkPolicy.allowedFrom=[]"], "allowedFrom"),
            (["--set", "limits.maxEventBytes=524288"], "maxEventBytes must not exceed"),
            (["--set", "limits.shutdownDeadlineMs=60000"], "termination grace"),
            (["--set", "retention.maxAgeMs=60000"], "requires delete-oldest-closed"),
            (["--set", "extraEnv[0].name=POSTHOG_HOST"], "additional properties"),
        ]
        for args, message in cases:
            with self.subTest(args=args):
                self.assertIn(message.lower(), render(args, ok=False).lower())

    def test_umbrella_keeps_collector_off_until_explicitly_configured(self):
        self.assertFalse(any(item.get("metadata", {}).get("name") == "telemetry-collector" for item in render(umbrella=True)))
        error = render(["--set", "components.telemetryCollector=true"], ok=False, umbrella=True)
        self.assertIn("sourceRevision", error)


if __name__ == "__main__":
    unittest.main()
