#!/usr/bin/env python3
"""Render the actual native kind composition and exercise trust boundaries offline."""
import json
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import yaml

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import stack


class Profiles(unittest.TestCase):
    """The kind base layer renders only through the native core composition."""

    def compose(self, phase):
        from native_core_values import compose
        from test_native_control import contract
        from test_native_core import TENANT
        from test_native_recipe import selected
        s = selected(); s["control"]["independentIssuer"] = True; s["readerLoginAdvertisesSync"] = False
        s["reference"] = "docker.io/" + s["reference"]; s["control"]["reference"] = "docker.io/" + s["control"]["reference"]
        base = yaml.safe_load((stack.ROOT / "charts/agent-relay/values-kind-core.yaml").read_text())
        return compose(base, s, contract(), phase, TENANT if phase == "serve" else None)

    def helm(self, values, extra=(), upgrade=False):
        cmd = ["helm", "template", "agent-relay", "charts/agent-relay", "-n", "agent-relay",
               *(["--is-upgrade"] if upgrade else []), "-f", "-" if values is not None else "charts/agent-relay/values-kind-core.yaml"]
        return subprocess.run([*cmd, *extra], cwd=stack.ROOT, text=True, capture_output=True, timeout=60,
                              input=None if values is None else yaml.safe_dump(values))

    def render(self, phase="serve", extra=(), ok=True):
        p = self.helm(self.compose(phase), extra, upgrade=phase == "serve")
        if not ok:
            self.assertNotEqual(p.returncode, 0, "invalid profile rendered successfully")
            return p.stderr
        self.assertEqual(p.returncode, 0, p.stderr)
        return [d for d in yaml.safe_load_all(p.stdout) if d]

    def test_native_phases_validate_against_kubernetes_schema(self):
        for phase in ("control", "serve"):
            with self.subTest(phase=phase):
                raw = yaml.safe_dump_all(self.render(phase))
                p = subprocess.run(["kubeconform", "-strict", "-summary", "-kubernetes-version", "1.34.3"],
                                   input=raw, text=True, capture_output=True, timeout=90)
                self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
                self.assertIn("Skipped: 0", p.stdout, "local profiles contain only portable Kubernetes resources")

    def test_base_layer_alone_and_standalone_history_selection_refuse(self):
        # The retired single-phase kind-up profile ran the standalone History.
        self.assertNotEqual(self.helm(None).returncode, 0)
        single_phase = self.compose("serve"); single_phase["localKind"]["nativePhase"] = ""
        self.assertIn("nativePhase=control or serve", self.helm(single_phase, upgrade=True).stderr)
        for extra in (["--set", "components.relayhistory=true"], ["--set", "relayhistory.enabled=true"]):
            with self.subTest(extra=extra):
                self.assertNotEqual(self.helm(self.compose("serve"), extra, upgrade=True).returncode, 0)

    def test_native_core_runs_history_on_sessions_pipeline_without_relayauth(self):
        for phase in ("control", "serve"):
            with self.subTest(phase=phase):
                docs = self.render(phase)
                names = {d["metadata"]["name"] for d in docs}
                self.assertFalse(any("relayhistory" in n or "relayauth" in n for n in names), names)
                images = {c["image"] for d in docs for c in stack.pod_spec(d).get("containers", []) + stack.pod_spec(d).get("initContainers", [])}
                self.assertFalse(any("/relayhistory" in i or "/relayauth" in i for i in images), images)
                api = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "relay-control")
                env = {e["name"]: e.get("value") for e in stack.pod_spec(api)["containers"][0]["env"]}
                self.assertEqual(env["RELAYHISTORY_BACKEND"], "native")
                self.assertFalse({"RELAYHISTORY_URL", "RELAYHISTORY_PUBLIC_URL", "RELAYAUTH_URL"} & set(env))
                self.assertFalse(any("relayfile" in n or "relayflows" in n or "relaycron" in n for n in names))
                self.assertFalse(any(d["kind"] == "CronJob" for d in docs))
        deployments = {d["metadata"]["name"] for d in self.render("serve") if d["kind"] == "Deployment"}
        self.assertTrue({"relay-control", "relay-webapp", "relaycast", "session-read-api",
                         "session-native-ingest", "session-native-consumer"} <= deployments)

    def test_remote_docker_context_refused_before_any_daemon_call(self):
        with tempfile.TemporaryDirectory(prefix="infra-kind-scope-") as directory, patch.object(stack, "ROOT", Path(directory)):
            local = stack.Stack("core")
            local.env["DOCKER_HOST"] = "ssh://someone@remote.example"
            local.cmd = lambda *args, **kwargs: self.fail("remote daemon operation was attempted")
            with self.assertRaisesRegex(stack.StackError, "remote Docker contexts are refused"):
                local.docker()

    def test_private_docker_config_discovers_desktop_buildx_without_credentials(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(stack, "ROOT", Path(directory)):
            local = stack.Stack("core")
            local.env["DOCKER_HOST"] = "unix:///fixture/docker.sock"
            local.cmd = lambda *args, **kw: subprocess.CompletedProcess(args, 0, stdout="arm64\n")
            with patch.object(stack.sys, "platform", "darwin"), patch.object(Path, "is_dir", return_value=True):
                local.docker(require_space=False)
            config = json.loads((local.state / "docker-public/config.json").read_text())
            self.assertEqual(config, {"auths": {"https://index.docker.io/v1/": {}, "ghcr.io": {}},
                "cliPluginsExtraDirs": ["/Applications/Docker.app/Contents/Resources/cli-plugins"]})
            spec = importlib.util.spec_from_file_location("dev_config_writer_test", HERE.parent / "dev/dev.py")
            dev = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(dev)
            dev.validate_public_docker_config(local.state / "docker-public")

    def test_only_namespace_egress_policy_no_additive_allow_all(self):
        for phase in ("control", "serve"):
            with self.subTest(phase=phase):
                policies = [d for d in self.render(phase) if d["kind"] == "NetworkPolicy" and d["metadata"]["name"] == "kind-no-external-egress"]
                self.assertEqual(len(policies), 1)
                spec = policies[0]["spec"]
                self.assertEqual(spec["podSelector"], {})
                for rule in spec["egress"]:
                    self.assertTrue(rule["to"])
                    self.assertFalse(any("ipBlock" in peer for peer in rule["to"]))
                self.assertEqual(spec["egress"][0], {"to": [{"podSelector": {}}]})
                dns = spec["egress"][1]
                self.assertEqual(dns["to"][0]["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"], "kube-system")
                self.assertEqual(dns["to"][0]["podSelector"]["matchLabels"]["k8s-app"], "kube-dns")
                self.assertEqual(dns["ports"], [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}])

    def test_invalid_profile_and_temporary_auth_disagreement_refused(self):
        self.assertIn("must explicitly match", self.render(extra=["--set", "localKind.temporaryRelayauth=true"], ok=False))
        self.assertIn("complete native core", self.render(extra=["--set", "localKind.profile=addons"], ok=False))
        self.assertIn("must be core or addons", self.render(extra=["--set", "localKind.profile=unknown"], ok=False))

    def test_local_scope_guard_and_configurable_api_ingress(self):
        self.assertIn("allowLocalOnly", self.render(extra=["--set", "localKind.allowLocalOnly=false"], ok=False))
        self.assertIn("ingress.enabled=true", self.render(extra=["--set", "relay-webapp.ingress.enabled=false"], ok=False))
        self.assertIn("ingress.host", self.render(extra=["--set", "relay-webapp.ingress.host="], ok=False))
        self.assertIn("child egress", self.render(extra=["--set", "sessions-pipeline.alleyoop.networkPolicy.enabled=true"], ok=False))
        docs = self.render(extra=["--set", "relay-control.fullnameOverride=other-control",
                                  "--set", "relay-webapp.api.serviceName=other-control",
                                  "--set", "relay-webapp.ingress.host=custom.kind.agentrelay.com",
                                  "--set", "relay-webapp.ingress.className=custom",
                                  "--set", "relay-webapp.ingress.tls[0].secretName=custom-tls"])
        ingress = next(d for d in docs if d["kind"] == "Ingress" and d["metadata"]["name"] == "kind-control-api")
        self.assertEqual(ingress["spec"]["ingressClassName"], "custom")
        self.assertEqual(ingress["spec"]["tls"][0]["secretName"], "custom-tls")
        self.assertEqual(ingress["spec"]["rules"][0]["host"], "custom.kind.agentrelay.com")
        self.assertEqual(ingress["spec"]["rules"][0]["http"]["paths"][0]["backend"]["service"]["name"], "other-control")

    def test_extra_env_cannot_bypass_validation_or_expose_migration_credentials(self):
        control = self.compose("serve")["relay-control"]
        runtime, migrations = control["existingSecret"], control["secretKeys"]["databaseMigrationsUrl"]
        invalid = [
            (["--set", "relay-control.extraEnv[0].name=SELFHOST_OIDC_ISSUER", "--set", "relay-control.extraEnv[0].value=http://bad"], "managed"),
            (["--set", "relay-control.extraEnv[0].name=CUSTOM", "--set", "relay-control.extraEnv[0].value=true"], "must be a string"),
            (["--set", "relay-control.extraEnv[0].name=CUSTOM_TOKEN", "--set", "relay-control.extraEnv[0].value=inline"], "never inline"),
            (["--set", "relay-control.extraEnv[0].name=CUSTOM", "--set", "relay-control.extraEnv[0].valueFrom.secretKeyRef.name=" + runtime,
              "--set", "relay-control.extraEnv[0].valueFrom.secretKeyRef.key=" + migrations], "migration credential"),
        ]
        for args, diagnostic in invalid:
            self.assertIn(diagnostic, self.render(extra=args, ok=False))
        self.render(extra=["--set", "relay-control.extraEnv[0].name=CUSTOM_TOKEN",
                           "--set", "relay-control.extraEnv[0].valueFrom.secretKeyRef.name=separate-secret",
                           "--set", "relay-control.extraEnv[0].valueFrom.secretKeyRef.key=token"])

    def test_generated_server_cert_is_not_a_ca_and_root_key_stays_host_only(self):
        with tempfile.TemporaryDirectory(prefix="infra-kind-trust-") as directory, patch.object(stack, "ROOT", Path(directory)):
            local = stack.Stack("core")
            applied = []
            local.apply = lambda doc, chart=False: applied.append(doc)
            local.tls()
            p = local.cmd(["openssl", "verify", "-x509_strict", "-CAfile", local.state / "ca.crt", local.state / "tls.crt"])
            self.assertIn("OK", p.stdout)
            text = local.cmd(["openssl", "x509", "-in", local.state / "tls.crt", "-text", "-noout"]).stdout
            self.assertIn("CA:FALSE", text)
            self.assertIn("DNS:relay.kind.agentrelay.com", text)
            for value in applied[0]["stringData"].values():
                self.assertNotIn((local.state / "ca.key").read_text(), value)
            self.assertEqual(applied[0]["stringData"]["tls.key"], (local.state / "tls.key").read_text())
            public_cert = local.cmd(["openssl", "x509", "-in", local.state / "tls.crt", "-pubkey", "-noout"]).stdout
            public_key = local.cmd(["openssl", "pkey", "-in", local.state / "tls.key", "-pubout"]).stdout
            self.assertEqual(public_cert, public_key)


if __name__ == "__main__":
    unittest.main()
