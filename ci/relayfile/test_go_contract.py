#!/usr/bin/env python3
"""Go bootstrap/auth render contracts; no credentials, SQL or installed proof."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
CHART = ROOT / "charts/relayfile"
VERIFIED = CHART / "ci/verified-postgres-values.yaml"


def render(extra=(), fixture=VERIFIED, success=True):
    result = subprocess.run(["helm", "template", "proof", str(CHART), "-n", "proof",
                             "--no-hooks", "-f", str(fixture), *extra],
                            text=True, capture_output=True, timeout=30)
    if not success:
        if result.returncode == 0:
            raise AssertionError("unsupported Go configuration rendered")
        return result.stderr
    if result.returncode:
        raise AssertionError(result.stderr)
    return [x for x in yaml.safe_load_all(result.stdout) if x]


def pod(documents):
    return next(x for x in documents if x["kind"] == "Deployment" and
                x["metadata"]["labels"].get("app.kubernetes.io/component") == "server")["spec"]["template"]["spec"]


class GoContract(unittest.TestCase):
    def test_api_upgrade_script_requires_ci_and_owned_context_before_effects(self):
        script = ROOT / "ci/relayfile/test_verified_upgrade.sh"
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            calls = directory / "calls"
            stub = directory / "kubectl"
            stub.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\n[ "$*" = "config current-context" ] || exit 98\necho kind-foreign\n')
            stub.chmod(0o755)
            env = {**os.environ, "PATH": str(directory) + ":/usr/bin:/bin", "CALLS": str(calls), "CI": "false"}
            result = subprocess.run(["/bin/bash", str(script)], env=env, text=True, capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("CI=true", result.stderr)
            self.assertFalse(calls.exists())
            env["CI"] = "true"
            result = subprocess.run(["/bin/bash", str(script)], env=env, text=True, capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("kind-ci", result.stderr)
            self.assertEqual(calls.read_text().splitlines(), ["config current-context"])

    def test_default_go_output_equals_explicit_disabled_contract(self):
        fixture = CHART / "ci/default-values.yaml"
        baseline = render(fixture=fixture)
        self.assertEqual(baseline, render(["--set-json", "postgres.enabled=false", "--set", "auth.mode="], fixture))
        current = pod(baseline)
        self.assertNotIn("volumes", current)
        self.assertNotIn("command", current["containers"][0])
        self.assertNotIn("args", current["containers"][0])
        self.assertNotIn("automountServiceAccountToken", current)
        self.assertNotIn("startupProbe", current["containers"][0])
        self.assertIn("RELAYFILE_PRODUCTION_DSN", {x["name"] for x in current["containers"][0]["env"]})

    def test_verified_command_projects_only_runtime_and_public_ca(self):
        documents = render()
        deployment = next(x for x in documents if x["kind"] == "Deployment")
        self.assertEqual(deployment["spec"]["replicas"], 1)
        self.assertEqual(deployment["spec"]["strategy"], {"type": "Recreate", "rollingUpdate": None})
        self.assertFalse(any(x["kind"] in {"Job", "Secret"} for x in documents))
        current = pod(documents)
        self.assertFalse(current["automountServiceAccountToken"])
        self.assertEqual(current["securityContext"]["fsGroup"], 1000)
        self.assertEqual(current["securityContext"]["fsGroupChangePolicy"], "OnRootMismatch")
        self.assertEqual(len(current["containers"]), 1)
        self.assertNotIn("initContainers", current)
        server = current["containers"][0]
        self.assertEqual(server["command"], ["relayfile"])
        self.assertEqual(server["args"], ["postgres", "serve", "--database", "relayfile", "--owner-role", "relayfile",
                         "--runtime-role", "relayfile_runtime", "--ca-sha256", "a" * 64,
                         "--dsn-file", "/var/run/relayfile-postgres/database-url"])
        self.assertEqual(server["image"], "ghcr.io/agentworkforce/relayfile@sha256:" + "1" * 64)
        self.assertTrue(all(v["readOnly"] for v in server["volumeMounts"]))
        volumes = {v["name"]: v for v in current["volumes"]}
        self.assertEqual(set(volumes), {"postgres-credential", "postgres-ca", "introspection-credential"})
        self.assertEqual(volumes["postgres-credential"]["secret"], {
            "secretName": "relayfile-runtime", "defaultMode": 0o440,
            "items": [{"key": "database-url", "path": "database-url"}]})
        self.assertEqual(volumes["postgres-ca"]["configMap"], {
            "name": "relayfile-postgres-ca", "defaultMode": 0o444,
            "items": [{"key": "ca.crt", "path": "ca.crt"}]})
        self.assertNotIn("--operator-role", server["args"])
        self.assertNotIn("postgresql://", json.dumps(documents))

    def test_verified_startup_budget_is_separate_from_liveness(self):
        baseline = pod(render())["containers"][0]
        self.assertEqual(baseline["startupProbe"], {"httpGet": {"path": "/health", "port": "http"},
                         "periodSeconds": 10, "timeoutSeconds": 2, "failureThreshold": 30})
        changed = pod(render(["--set", "postgres.startupProbe.periodSeconds=5",
                              "--set", "postgres.startupProbe.timeoutSeconds=3",
                              "--set", "postgres.startupProbe.failureThreshold=60"]))["containers"][0]
        self.assertEqual(changed["startupProbe"]["periodSeconds"], 5)
        self.assertEqual(changed["startupProbe"]["timeoutSeconds"], 3)
        self.assertEqual(changed["startupProbe"]["failureThreshold"], 60)
        for key in ("livenessProbe", "readinessProbe"):
            self.assertEqual(changed[key], baseline[key])
        for skip in ([], ["--skip-schema-validation"]):
            for field, value in [("periodSeconds", "0"), ("periodSeconds", "31"),
                                 ("timeoutSeconds", '"2"'), ("timeoutSeconds", "true"),
                                 ("failureThreshold", "61"), ("failureThreshold", "0.5")]:
                with self.subTest(skip=skip, field=field, value=value):
                    self.assertIn("startupProbe", render([*skip, "--set-json", "postgres.startupProbe." + field + "=" + value], success=False))

    def test_introspection_is_file_only_exact_origin_no_jwks_or_legacy_dsn(self):
        current = pod(render())
        env = {e["name"]: e for e in current["containers"][0]["env"]}
        for absent in ("RELAYCONTROL_INTROSPECT_SECRET", "RELAYAUTH_JWKS_URL", "RELAYFILE_JWT_SECRET", "RELAYFILE_PRODUCTION_DSN", "PGPASSWORD"):
            self.assertNotIn(absent, env)
        expected = {"RELAYFILE_DEV_MODE": "false", "RELAYFILE_AUTH_MODE": "introspection", "RELAYCONTROL_INTERNAL_URL": "http://relay-control.example.svc.cluster.local",
                    "RELAYFILE_PUBLIC_ORIGIN": "https://files.example.company",
                    "RELAYCONTROL_INTROSPECT_SECRET_FILE": "/var/run/relayfile-introspection/secret",
                    "RELAYFILE_INTROSPECTION_TIMEOUT": "3s", "RELAYFILE_INTROSPECTION_CACHE_TTL": "0s"}
        for name, value in expected.items():
            self.assertEqual(env[name], {"name": name, "value": value})
        self.assertEqual(env["RELAYFILE_INTERNAL_HMAC_SECRET"]["valueFrom"]["secretKeyRef"], {
            "name": "relayfile-service", "key": "RELAYFILE_INTERNAL_HMAC_SECRET"})
        secret = next(v for v in current["volumes"] if v["name"] == "introspection-credential")["secret"]
        self.assertEqual(secret, {"secretName": "control-introspection", "defaultMode": 0o440,
                                 "items": [{"key": "introspect-secret", "path": "secret"}]})

    def test_auth_only_and_database_only_are_explicit_independent_modes(self):
        auth = pod(render(["--set", "postgres.enabled=false"]))
        self.assertNotIn("command", auth["containers"][0])
        self.assertEqual([v["name"] for v in auth["volumes"]], ["introspection-credential"])
        pg = pod(render(["--set-json", 'auth={"mode":"","jwksUrl":"http://auth.example.svc/jwks","introspection":{"internalUrl":"","publicOrigin":"","secretRef":{"name":"","key":"introspect-secret"}}}']))
        self.assertEqual({v["name"] for v in pg["volumes"]}, {"postgres-ca", "postgres-credential"})
        self.assertIn("RELAYAUTH_JWKS_URL", {e["name"] for e in pg["containers"][0]["env"]})

    def test_schema_and_template_refuse_false_as_string_and_other_mistypes(self):
        for skip in ([], ["--skip-schema-validation"]):
            for value in ['"false"', '0', '[]', '{}', 'null']:
                with self.subTest(skip=skip, value=value):
                    self.assertIn("postgres", render([*skip, "--set-json", "postgres.enabled=" + value], success=False))
        for args in [["--set", "auth.mode=dual"], ["--set", "auth.mode=jwks"],
                     ["--set-json", "auth.introspection.timeoutSeconds=true"], ["--set-json", "auth.introspection.cacheTtlSeconds=0.5"]]:
            render(args, success=False)

    def test_missing_or_conflicting_contract_refuses(self):
        cases = [("image.digest=", "image"), ("image.digest=sha256:abcd", "digest"), ("image.tag=latest", "image.tag"),
                 ("postgres.database=", "postgres.database"), ("postgres.ownerRole=Upper", "postgres.ownerRole"),
                 ("postgres.runtimeRole=relayfile", "must differ"), ("postgres.runtimeSecret.name=", "runtimeSecret.name"),
                 ("postgres.ca.configMap=", "postgres.ca.configMap"), ("postgres.ca.sha256=", "postgres.ca.sha256"),
                 ("postgres.ca.sha256=" + "A" * 64, "sha256"), ("server.backendProfile=memory", "backendProfile"),
                 ("auth.jwksUrl=http://auth.example/jwks", "no JWKS fallback"),
                 ("auth.introspection.secretRef.name=", "secretRef.name"), ("secrets.existingSecret=", "existingSecret")]
        for value, expected in cases:
            with self.subTest(value=value):
                self.assertIn(expected, render(["--set-string", value], success=False))
        for assignment in ["replicaCount=2", "autoscaling.enabled=true"]:
            self.assertIn("concurrent snapshot writers", render(["--set", assignment], success=False))

    def test_managed_env_cannot_shadow_contract_or_load_opaque_env_from(self):
        names = ["RELAYFILE_PRODUCTION_DSN", "RELAYFILE_STATE_BACKEND_DSN", "RELAYFILE_ENVELOPE_QUEUE_DSN",
                 "RELAYFILE_WRITEBACK_QUEUE_DSN", "PGHOST", "PGSSLROOTCERT", "PGPASSWORD", "RELAYFILE_BACKEND_PROFILE",
                 "RELAYCONTROL_INTROSPECT_SECRET", "RELAYCONTROL_INTROSPECT_SECRET_FILE", "RELAYCONTROL_INTERNAL_URL",
                 "RELAYFILE_AUTH_MODE", "RELAYFILE_JWT_SECRET", "RELAYAUTH_JWKS_URL", "RELAYFILE_INTERNAL_HMAC_SECRET", "RELAYFILE_DEV_MODE"]
        for name in names:
            with self.subTest(name=name):
                self.assertIn(name, render(["--set-json", "extraEnv=" + json.dumps([{"name": name, "value": "not-accepted"}])], success=False))
        self.assertIn("extraEnvFrom", render(["--set-json", 'extraEnvFrom=[{"secretRef":{"name":"opaque-unmanaged"}}]'], success=False))

    def test_origins_refnames_bounds_and_dormant_auth_mismatch_refuse(self):
        for origin in ["http://files.example.company", "https://user@files.example.company", "https://files.example.company/",
                       "https://files.example.company?x=1", "https://files.example.company#fragment", "https://files.example.company:0", "https://files.example.company:65536",
                       "https://files.example.company:00443", "https://files..company"]:
            with self.subTest(origin=origin):
                self.assertIn("publicOrigin", render(["--set-string", "auth.introspection.publicOrigin=" + origin], success=False))
        for field in ["postgres.runtimeSecret.name", "auth.introspection.secretRef.name", "postgres.ca.configMap"]:
            for name in ["Upper_Name", "has..empty", "a" * 64]:
                with self.subTest(field=field, name=name):
                    self.assertIn(field, render(["--set-string", field + "=" + name], success=False))
        for assignment in ["auth.introspection.timeoutSeconds=0", "auth.introspection.timeoutSeconds=31", "auth.introspection.cacheTtlSeconds=61"]:
            render(["--set", assignment], success=False)
        self.assertIn("auth.mode", render(["--set", "auth.mode="], success=False))
        render(["--set", "auth.introspection.internalUrl=http://control.example/cloud"], success=False)
        current = pod(render(["--set", "postgres.runtimeSecret.name=relayfile.runtime", "--set", "podSecurityContext.fsGroup=2000"]))
        self.assertEqual(current["securityContext"]["fsGroup"], 2000)

    def test_durable_actors_render_is_preserved_and_go_modes_cannot_select_it(self):
        for name in ("durable-actors-values.yaml", "durable-actors-s3-values.yaml", "durable-actors-dev-values.yaml"):
            with self.subTest(name=name):
                documents = render(fixture=CHART / "ci" / name)
                self.assertTrue(any(d["kind"] == "Deployment" for d in documents))
                self.assertNotIn("RELAYFILE_AUTH_MODE", json.dumps(documents))
        self.assertIn("require runtime.backend=go", render(["--set", "runtime.backend=durable-actors"], success=False))


if __name__ == "__main__":
    unittest.main()
