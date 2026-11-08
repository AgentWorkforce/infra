#!/usr/bin/env python3
"""Render the actual charts and exercise acceptance/trust boundaries offline."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import urlparse

import yaml

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import stack
from proof import exit_code


class Profiles(unittest.TestCase):
    def render(self, profile="core", extra=(), ok=True):
        cmd = ["helm", "template", "agent-relay", "charts/agent-relay", "-n", "agent-relay",
               "-f", "charts/agent-relay/values-kind-core.yaml"]
        if profile == "addons":
            cmd += ["-f", "charts/agent-relay/values-kind-addons.yaml"]
        p = subprocess.run([*cmd, *extra], cwd=stack.ROOT, text=True, capture_output=True, timeout=30)
        if not ok:
            self.assertNotEqual(p.returncode, 0, "invalid profile rendered successfully")
            return p.stderr
        self.assertEqual(p.returncode, 0, p.stderr)
        return [d for d in yaml.safe_load_all(p.stdout) if d]

    def test_both_profiles_validate_against_kubernetes_schema(self):
        for profile in ("core", "addons"):
            with self.subTest(profile=profile):
                raw = yaml.safe_dump_all(self.render(profile))
                p = subprocess.run(["kubeconform", "-strict", "-summary", "-kubernetes-version", "1.34.3"],
                                   input=raw, text=True, capture_output=True, timeout=90)
                self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
                self.assertIn("Skipped: 0", p.stdout, "local profiles contain only portable Kubernetes resources")

    def test_core_contains_whole_product_and_internal_temporary_auth(self):
        docs = self.render()
        deployments = {d["metadata"]["name"] for d in docs if d["kind"] == "Deployment"}
        self.assertTrue({"relaycontrol", "relay-app", "relaycast", "relayauth", "relayhistory", "alleyoop-ingest"} <= deployments)
        self.assertFalse(any("relayfile" in n or "relayflows" in n or "relaycron" in n for n in deployments))
        self.assertFalse(any(d["kind"] == "CronJob" for d in docs))
        for d in docs:
            if d["kind"] == "Ingress":
                for rule in d["spec"]["rules"]:
                    self.assertFalse(any("relayauth" in p["backend"]["service"]["name"] for p in rule["http"]["paths"]))
        workers = [d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"].startswith("sessions-")]
        self.assertEqual(len(workers), 3)
        for d in workers:
            env = {e["name"]: e.get("value") for e in stack.pod_spec(d)["containers"][0]["env"]}
            self.assertEqual(env["SEARCH_INDEX_BACKEND"], "postgres")
        migration_env = [{e["name"]: e.get("value") for e in stack.pod_spec(d)["containers"][0]["env"]}
                         for d in docs if d["kind"] == "Job"]
        history_role = next(e["DATABASE_RUNTIME_ROLE"] for e in migration_env if "DATABASE_RUNTIME_ROLE" in e)
        pipeline_role = next(e["HOOPDB_RUNTIME_ROLE"] for e in migration_env if "HOOPDB_RUNTIME_ROLE" in e)
        self.assertNotEqual(history_role, pipeline_role, "History broad backend grants must not contaminate the guarded pipeline runtime role")

    def test_remote_docker_context_refused_before_any_daemon_call(self):
        with tempfile.TemporaryDirectory(prefix="infra-kind-scope-") as directory, patch.object(stack, "ROOT", Path(directory)):
            local = stack.Stack("core")
            local.env["DOCKER_HOST"] = "ssh://someone@remote.example"
            local.cmd = lambda *args, **kwargs: self.fail("remote daemon operation was attempted")
            with self.assertRaisesRegex(stack.StackError, "remote Docker contexts are refused"):
                local.docker()

    def test_history_and_pipeline_have_independent_database_ownership(self):
        with tempfile.TemporaryDirectory(prefix="infra-kind-databases-") as directory, patch.object(stack, "ROOT", Path(directory)):
            local = stack.Stack("core")
            applied = []
            local.apply = lambda doc, chart=False: applied.append(doc)
            local.credentials()
            secrets = {d["metadata"]["name"]: d["stringData"] for d in applied}
            history = urlparse(secrets["kind-history-db"]["DATABASE_URL"])
            history_owner = urlparse(secrets["kind-history-db"]["DATABASE_MIGRATIONS_URL"])
            pipeline = urlparse(secrets["kind-pipeline"]["HOOPDB_URL"])
            pipeline_owner = urlparse(secrets["kind-pipeline"]["HOOPDB_MIGRATION_URL"])
            self.assertEqual(history.path, "/relayhistory")
            self.assertEqual(pipeline.path, "/hoopdb")
            self.assertEqual(history_owner.path, history.path)
            self.assertEqual(pipeline_owner.path, pipeline.path)
            self.assertEqual(len({history.username, history_owner.username, pipeline.username, pipeline_owner.username}), 4,
                             "each database needs distinct runtime and migration-owner roles")

    def test_only_namespace_egress_policy_no_additive_allow_all(self):
        for profile in ("core", "addons"):
            with self.subTest(profile=profile):
                policies = [d for d in self.render(profile) if d["kind"] == "NetworkPolicy" and "Egress" in d["spec"].get("policyTypes", [])]
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

    def test_addons_use_real_cronjob_and_postgres_file_backend(self):
        docs = self.render("addons")
        cron = next(d for d in docs if d["kind"] == "CronJob")
        self.assertEqual(cron["metadata"]["name"], "relayflows")
        self.assertEqual(cron["spec"]["schedule"], "* * * * *")
        self.assertEqual(cron["spec"]["concurrencyPolicy"], "Forbid")
        self.assertFalse(stack.pod_spec(cron).get("initContainers"), "pod startup must not download a runtime")
        self.assertFalse(any(d["kind"] == "Job" and "relayflows" in d["metadata"]["name"] for d in docs))
        file = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "relayfile-server")
        env = {e["name"]: e for e in stack.pod_spec(file)["containers"][0]["env"]}
        self.assertEqual(env["RELAYFILE_BACKEND_PROFILE"]["value"], "production")
        self.assertEqual(env["RELAYFILE_PRODUCTION_DSN"]["valueFrom"]["secretKeyRef"]["name"], "kind-relayfile")
        self.assertIn("relayauth.agent-relay.svc.cluster.local", env["RELAYAUTH_JWKS_URL"]["value"])

    def test_license_only_mounted_in_api_not_migrator(self):
        docs = self.render("addons")
        api = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "relaycontrol")
        spec = stack.pod_spec(api)
        self.assertIn({"name": "SELFHOST_LICENSE_FILE", "value": "/var/run/agent-relay/license/license"}, spec["containers"][0]["env"])
        secret = next(v for v in spec["volumes"] if v["name"] == "license")["secret"]
        self.assertEqual(secret["secretName"], "kind-addon-license")
        self.assertEqual(secret["items"], [{"key": "license", "path": "license"}])
        for workload in (d for d in docs if stack.pod_spec(d) and d is not api):
            self.assertNotIn("SELFHOST_LICENSE", json.dumps(workload))
            self.assertNotIn("kind-addon-license", json.dumps(workload))
        core = self.render()
        self.assertNotIn("SELFHOST_LICENSE", json.dumps(core))

    def test_invalid_profile_and_temporary_auth_disagreement_refused(self):
        self.assertIn("must explicitly match", self.render(extra=["--set", "localKind.temporaryRelayauth=false"], ok=False))
        self.assertIn("must agree", self.render("addons", extra=["--set", "components.relayfile=false"], ok=False))
        self.assertIn("must be core or addons", self.render(extra=["--set", "localKind.profile=unknown"], ok=False))
        self.assertIn("license.key", self.render("addons", extra=["--set", "relay-cloud-api.license.key=../bad"], ok=False))
        self.assertIn("must not mount the migration credential", self.render("addons", extra=["--set", "relay-cloud-api.license.existingSecret=kind-control", "--set", "relay-cloud-api.license.key=database-migrations-url"], ok=False))
        self.assertIn("SELFHOST_LICENSE_FILE is managed", self.render("addons", extra=["--set", "relay-cloud-api.extraEnv[0].name=SELFHOST_LICENSE_FILE", "--set", "relay-cloud-api.extraEnv[0].value=/other-license"], ok=False))

    def test_local_scope_guard_and_configurable_api_ingress(self):
        self.assertIn("allowLocalOnly", self.render(extra=["--set", "localKind.allowLocalOnly=false"], ok=False))
        self.assertIn("ingress.enabled=true", self.render(extra=["--set", "relay-dashboard.ingress.enabled=false"], ok=False))
        self.assertIn("ingress.host", self.render(extra=["--set", "relay-dashboard.ingress.host="], ok=False))
        self.assertIn("child egress", self.render("addons", extra=["--set", "relayflows.networkPolicy.enabled=true"], ok=False))
        docs = self.render(extra=["--set", "relay-cloud-api.fullnameOverride=other-control",
                                  "--set", "relay-dashboard.api.serviceName=other-control",
                                  "--set", "relay-dashboard.ingress.host=custom.kind.agentrelay.com",
                                  "--set", "relay-dashboard.ingress.className=custom",
                                  "--set", "relay-dashboard.ingress.tls[0].secretName=custom-tls"])
        ingress = next(d for d in docs if d["kind"] == "Ingress" and d["metadata"]["name"] == "kind-control-api")
        self.assertEqual(ingress["spec"]["ingressClassName"], "custom")
        self.assertEqual(ingress["spec"]["tls"][0]["secretName"], "custom-tls")
        self.assertEqual(ingress["spec"]["rules"][0]["host"], "custom.kind.agentrelay.com")
        self.assertEqual(ingress["spec"]["rules"][0]["http"]["paths"][0]["backend"]["service"]["name"], "other-control")

    def test_license_secret_shape_and_all_credential_collisions(self):
        for name in ("a.-b", "a" * 254):
            self.assertIn("Kubernetes Secret name", self.render("addons", extra=["--set-string", "relay-cloud-api.license.existingSecret="+name], ok=False))
        for key in ("database-url", "database-migrations-url", "relayauth-api-key"):
            self.assertIn("must not mount", self.render("addons", extra=["--set", "relay-cloud-api.license.existingSecret=kind-control",
                                                                      "--set", "relay-cloud-api.license.key="+key], ok=False))
        self.render("addons", extra=["--set", "relay-cloud-api.license.key=2024"])

    def test_extra_env_cannot_bypass_validation_or_expose_migration_credentials(self):
        invalid = [
            (["--set", "relay-cloud-api.extraEnv[0].name=SELFHOST_OIDC_ISSUER", "--set", "relay-cloud-api.extraEnv[0].value=http://bad"], "managed"),
            (["--set", "relay-cloud-api.extraEnv[0].name=CUSTOM", "--set", "relay-cloud-api.extraEnv[0].value=true"], "must be a string"),
            (["--set", "relay-cloud-api.extraEnv[0].name=CUSTOM_TOKEN", "--set", "relay-cloud-api.extraEnv[0].value=inline"], "never inline"),
            (["--set", "relay-cloud-api.extraEnv[0].name=CUSTOM", "--set", "relay-cloud-api.extraEnv[0].valueFrom.secretKeyRef.name=kind-control",
              "--set", "relay-cloud-api.extraEnv[0].valueFrom.secretKeyRef.key=database-migrations-url"], "migration credential"),
        ]
        for args, diagnostic in invalid:
            self.assertIn(diagnostic, self.render(extra=args, ok=False))
        self.render(extra=["--set", "relay-cloud-api.extraEnv[0].name=CUSTOM_TOKEN",
                           "--set", "relay-cloud-api.extraEnv[0].valueFrom.secretKeyRef.name=separate-secret",
                           "--set", "relay-cloud-api.extraEnv[0].valueFrom.secretKeyRef.key=token"])

    def test_pending_can_never_be_aggregate_success(self):
        self.assertEqual(exit_code([]), 1)
        self.assertEqual(exit_code([{"result": "PASS"}, {"result": "PENDING"}]), 2)
        self.assertEqual(exit_code([{"result": "FAIL"}, {"result": "PENDING"}]), 1)

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
