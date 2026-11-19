#!/usr/bin/env python3
"""Offline drift contract for dashboard-origin Control routing on every edge."""
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
# Control 0.5.24, edad6432: src/mcp/{routes,oauth/routes,oauth/protocol}.ts.
MCP_PATHS = (
    "/mcp", "/cloud/mcp", "/.well-known/oauth-protected-resource",
    "/.well-known/oauth-authorization-server", "/.well-known/openid-configuration",
    "/cloud/.well-known", "/cloud/oauth",
)
CONTROL_PATHS = ("/cloud/api", "/login", "/relay-node", *MCP_PATHS)


def run(*args, env=None):
    return subprocess.check_output(args, cwd=ROOT, env=env, text=True)


def documents(raw):
    # yq is already required by both chart render suites; no Python YAML dependency.
    result = subprocess.run(["yq", "-o=json", "-I=0", "."], input=raw,
                            text=True, capture_output=True, check=True)
    return [json.loads(line) for line in result.stdout.splitlines() if line != "null"]


def dashboard(docs, host=None):
    return next(rule["http"]["paths"] for doc in docs if doc["kind"] == "Ingress"
                for rule in doc["spec"]["rules"]
                if (host is None or rule["host"] == host)
                and any(p["backend"]["service"]["name"].endswith("relay-webapp")
                        for p in rule["http"]["paths"]))


class Routes(unittest.TestCase):
    def assert_routes(self, paths, expected=CONTROL_PATHS, chief=False):
        target = lambda p: p["backend"]["service"]
        control = [p for p in paths if target(p)["name"].endswith("relay-control")]
        want = [(p, "Exact" if chief else "Prefix") for p in expected]
        if chief:
            want += [(p + "/*", "ImplementationSpecific") for p in expected]
        self.assertEqual([(p["path"], p["pathType"]) for p in control], want)
        self.assertTrue(all(target(p)["port"] == {"number": 80} for p in control))
        self.assertEqual(paths[-1]["path"], "/*" if chief else "/")
        self.assertTrue(target(paths[-1])["name"].endswith("relay-webapp"))
        self.assertFalse(any(p["path"] in ("/.well-known", "/.well-known/*") for p in paths))

    def test_leaf_split_single_and_custom_base(self):
        for fixture, extra, expected in (
            ("default", (), CONTROL_PATHS),
            ("single-host", (), (*CONTROL_PATHS, "/api")),
            ("default", ("--set", "runtime.apiBasePath=/custom/api"),
             tuple(p.replace("/cloud", "/custom") for p in CONTROL_PATHS)),
            ("default", ("--set", "runtime.apiBasePath=/api"),
             tuple(dict.fromkeys(p.replace("/cloud", "") for p in CONTROL_PATHS
                                 if p != "/cloud/.well-known"))),
        ):
            with self.subTest(fixture=fixture, extra=extra):
                docs = documents(run("helm", "template", "ci", "charts/relay-webapp", "-f",
                                     f"charts/relay-webapp/ci/{fixture}-values.yaml", *extra))
                self.assert_routes(dashboard(docs), expected)

    def test_gke_split_and_single(self):
        for single in (False, True):
            with self.subTest(single=single):
                extra = ("-f", "charts/agent-relay/values-single-host-example.yaml") if single else ()
                docs = documents(run("helm", "template", "ci", "charts/agent-relay", "-n", "agent-relay",
                                     "-f", "charts/agent-relay/values-gcp-proof.yaml",
                                     "-f", "charts/agent-relay/ci/gcp-proof-values.yaml", *extra))
                paths = dashboard(docs)
                self.assert_routes(paths, (*CONTROL_PATHS, "/api") if single else CONTROL_PATHS)
                self.assertEqual(len(paths), 12 if single else 11)
                service = next(d for d in docs if d["kind"] == "Service" and d["metadata"]["name"] == "relay-control")
                config = json.loads(service["metadata"]["annotations"]["cloud.google.com/backend-config"])["default"]
                self.assertEqual(next(d for d in docs if d["kind"] == "BackendConfig" and d["metadata"]["name"] == config)["spec"]["timeoutSec"], 3600)

    def test_eks_with_chief_and_flows(self):
        for chief in (False, True):
            for flows in (False, True):
                with self.subTest(chief=chief, flows=flows):
                    # Fixtures must not inherit an operator's install settings.
                    clean_env = {k: v for k, v in os.environ.items()
                                 if not k.startswith("EKS_ALB_") and k != "EKS_INGRESS_CLASS"}
                    env = {**clean_env, "EKS_ALB_DOMAIN": "relay.example.com", "EKS_ALB_CERT_ARN": "render-only",
                           "EKS_ALB_CHIEF_SERVICE": "relaychief-control" if chief else "",
                           "EKS_ALB_RELAYFILE_CONTROL": str(flows).lower()}
                    self.assert_routes(dashboard(documents(run("bash", "scripts/selfhost/eks-alb-ingress.sh", env=env))), chief=chief)

    def test_azure(self):
        self.assert_routes(dashboard(documents((ROOT / "docs/azure-install/ingress.yaml").read_text()), "__HOST_ROOT__"))


if __name__ == "__main__":
    unittest.main()
