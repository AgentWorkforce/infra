"""S3 upload ledger (pipeline decision 0005) chart contract: default-off, refusals mirror the binary."""
import copy
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
CHART = ROOT / "charts/sessions-pipeline"
SQL_FIXTURE = CHART / "ci/ingest-edge-values.yaml"
S3_FIXTURE = CHART / "ci/ingest-edge-s3-ledger-values.yaml"


def load(path):
    return yaml.safe_load(path.read_text())


def merge(base, extra):
    out = copy.deepcopy(base)
    for key, value in extra.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = merge(out[key], value)
        else:
            out[key] = value
    return out


def helm(values, *args):
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / "values.yaml"
        path.write_text(yaml.safe_dump(values))
        return subprocess.run(["helm", "template", "ci", str(CHART), "-n", "ci", "--no-hooks", "-f", str(path), *args],
                              text=True, capture_output=True)


class S3Ledger(unittest.TestCase):
    def render(self, values, fail=None):
        p = helm(values)
        if fail:
            self.assertNotEqual(p.returncode, 0, "rendered despite: " + fail)
            self.assertIn(fail, p.stderr)
            return None
        self.assertEqual(p.returncode, 0, p.stderr)
        return [d for d in yaml.safe_load_all(p.stdout) if d]

    @staticmethod
    def ingest_env(docs):
        dep = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "ci-ingest-edge")
        return {e["name"]: e for e in dep["spec"]["template"]["spec"]["containers"][0]["env"]}

    @staticmethod
    def cronjob(docs):
        return next(d for d in docs if d["kind"] == "CronJob" and d["metadata"]["name"] == "ci-rearm-sweeper")

    def test_ingest_tls_profile(self):
        base = load(SQL_FIXTURE)
        dep = lambda docs: next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "ci-ingest-edge")
        self.assertEqual(helm(base).stdout, helm(merge(base, {"ingestEdge": {"postgres": {"tlsProfile": "custom-ca"}}})).stdout)
        env = self.ingest_env(self.render(base))
        self.assertEqual(env["SESSION_POSTGRES_TLS_PROFILE"]["value"], "custom-ca")
        self.assertIn("SESSION_POSTGRES_CA_FILE", env)
        supa = merge(base, {"ingestEdge": {"postgres": {"tlsProfile": "supabase", "caConfigMap": "", "caSha256": ""}}})
        docs = self.render(supa)
        env = self.ingest_env(docs)
        self.assertEqual(env["SESSION_POSTGRES_TLS_PROFILE"]["value"], "supabase")
        self.assertNotIn("SESSION_POSTGRES_CA_FILE", env)
        self.assertNotIn("SESSION_POSTGRES_CA_SHA256", env)
        pod = dep(docs)["spec"]["template"]["spec"]
        self.assertNotIn("postgres-ca", [v["name"] for v in pod["volumes"]])
        self.assertNotIn("postgres-ca", [m["name"] for m in pod["containers"][0]["volumeMounts"]])
        self.render(merge(base, {"ingestEdge": {"postgres": {"tlsProfile": "supabase"}}}),
                    fail="tlsProfile=supabase pins the built-in Supabase CA")
        self.render(merge(base, {"ingestEdge": {"postgres": {"tlsProfile": "verify-full"}}}),
                    fail="ingestEdge.postgres.tlsProfile must be supabase or custom-ca")

    def test_s3_tenant_limit(self):
        s3 = load(S3_FIXTURE)
        self.assertNotIn("INGEST_S3_TENANT_LIMIT", self.ingest_env(self.render(s3)))
        self.assertEqual(helm(s3).stdout, helm(merge(s3, {"ingestEdge": {"s3TenantLimit": False}})).stdout)
        env = self.ingest_env(self.render(merge(s3, {"ingestEdge": {"s3TenantLimit": True}})))
        self.assertEqual(env["INGEST_S3_TENANT_LIMIT"], {"name": "INGEST_S3_TENANT_LIMIT", "value": "on"})
        self.assertEqual(env["INGEST_LEDGER"]["value"], "s3")
        self.render(merge(load(SQL_FIXTURE), {"ingestEdge": {"s3TenantLimit": True}}),
                    fail="ingestEdge.s3TenantLimit requires ingestEdge.ledger=s3")
        for value in ("on", "true", 1, [], {}):
            with self.subTest(value=value):
                self.render(merge(s3, {"ingestEdge": {"s3TenantLimit": value}}),
                            fail="ingestEdge.s3TenantLimit must be a boolean")

    def test_async_max_per_org(self):
        s3 = merge(load(S3_FIXTURE), {"ingestEdge": {"s3TenantLimit": True, "admission": {"mode": "async", "concurrency": 16}}})
        self.assertNotIn("INGEST_ASYNC_MAX_PER_ORG", self.ingest_env(self.render(s3)))
        env = self.ingest_env(self.render(merge(s3, {"ingestEdge": {"admission": {"asyncMaxPerOrg": 16}}})))
        self.assertEqual(env["INGEST_ASYNC_MAX_PER_ORG"]["value"], "16")
        self.assertEqual(env["SELFHOST_ADMISSION_CONCURRENCY"]["value"], "16")
        for value in (0, 17, "x", -1):
            with self.subTest(value=value):
                self.render(merge(s3, {"ingestEdge": {"admission": {"asyncMaxPerOrg": value}}}),
                            fail="ingestEdge.admission.asyncMaxPerOrg must be an integer from 1 to admission.concurrency")
        self.render(merge(s3, {"ingestEdge": {"s3TenantLimit": False, "admission": {"asyncMaxPerOrg": 4}}}),
                    fail="ingestEdge.admission.asyncMaxPerOrg requires s3TenantLimit=true")

    def test_probe_timeout_seconds(self):
        s3 = merge(load(S3_FIXTURE), {"ingestEdge": {"admission": {"mode": "async"}}})
        c = lambda docs: next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "ci-ingest-edge")["spec"]["template"]["spec"]["containers"][0]
        default = c(self.render(s3))
        self.assertEqual(default["readinessProbe"]["timeoutSeconds"], 3)
        self.assertIn("AbortSignal.timeout(1500)", default["readinessProbe"]["exec"]["command"][2])
        tuned = c(self.render(merge(s3, {"ingestEdge": {"admission": {"probeTimeoutSeconds": 10}}})))
        for probe in ("startupProbe", "readinessProbe"):
            self.assertEqual(tuned[probe]["timeoutSeconds"], 10)
            self.assertIn("AbortSignal.timeout(9000)", tuned[probe]["exec"]["command"][2])
        self.assertEqual(tuned["livenessProbe"], default["livenessProbe"])
        for value in (2, 31, "x"):
            with self.subTest(value=value):
                self.render(merge(s3, {"ingestEdge": {"admission": {"probeTimeoutSeconds": value}}}),
                            fail="ingestEdge.admission.probeTimeoutSeconds must be an integer from 3 to 30")

    def test_ledger_parallel(self):
        s3 = load(S3_FIXTURE)
        self.assertNotIn("INGEST_LEDGER_PARALLEL", self.ingest_env(self.render(s3)))
        env = self.ingest_env(self.render(merge(s3, {"ingestEdge": {"ledgerParallel": 8}})))
        self.assertEqual(env["INGEST_LEDGER_PARALLEL"]["value"], "8")
        for value in (0, 65, "x"):
            with self.subTest(value=value):
                self.render(merge(s3, {"ingestEdge": {"ledgerParallel": value}}),
                            fail="ingestEdge.ledgerParallel must be an integer from 1 to 64")
        self.render(merge(load(SQL_FIXTURE), {"ingestEdge": {"ledgerParallel": 8}}),
                    fail="ingestEdge.ledgerParallel requires ingestEdge.ledger=s3")

    def test_ledger_bucket(self):
        s3 = load(S3_FIXTURE)
        env = self.ingest_env(self.render(s3))
        self.assertNotIn("INGEST_LEDGER_BUCKET", env)
        self.assertNotIn("INGEST_LEDGER_REGION", env)
        self.assertEqual(helm(s3).stdout, helm(merge(s3, {"ingestEdge": {"ledgerBucket": {"bucket": "", "region": ""}}})).stdout)
        moved = merge(s3, {"ingestEdge": {"ledgerBucket": {"bucket": "ci-ledger", "region": "us-west-2"}}})
        env = self.ingest_env(self.render(moved))
        self.assertEqual(env["INGEST_LEDGER_BUCKET"]["value"], "ci-ledger")
        self.assertEqual(env["INGEST_LEDGER_REGION"]["value"], "us-west-2")
        sweeper_env = lambda docs: {e["name"]: e.get("value") for e in self.cronjob(docs)["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]["env"]}
        sw = sweeper_env(self.render(moved))
        self.assertEqual((sw["INGEST_REARM_LEDGER_BUCKET"], sw["INGEST_REARM_LEDGER_REGION"]), ("ci-ledger", "us-west-2"))
        self.assertNotIn("INGEST_REARM_LEDGER_BUCKET", sweeper_env(self.render(s3)))
        default_region = self.ingest_env(self.render(merge(s3, {"ingestEdge": {"ledgerBucket": {"bucket": "ci-ledger"}}})))
        self.assertEqual(default_region["INGEST_LEDGER_REGION"]["value"], self.ingest_env(self.render(s3))["LOCKER_REGION"]["value"])
        self.render(merge(load(SQL_FIXTURE), {"ingestEdge": {"ledgerBucket": {"bucket": "ci-ledger"}}}),
                    fail="ingestEdge.ledgerBucket requires ingestEdge.ledger=s3")
        self.render(merge(s3, {"ingestEdge": {"ledgerBucket": {"bucket": s3["ingestEdge"]["locker"]["bucket"]}}}),
                    fail="ingestEdge.ledgerBucket.bucket must differ from ingestEdge.locker.bucket")
        self.render(merge(s3, {"ingestEdge": {"ledgerBucket": {"bucket": "Bad_Bucket"}}}),
                    fail="ingestEdge.ledgerBucket.bucket must be an S3 bucket name")
        self.render(merge(s3, {"ingestEdge": {"ledgerBucket": {"region": "us-west-2"}}}),
                    fail="ingestEdge.ledgerBucket.region requires ingestEdge.ledgerBucket.bucket")
        self.assertNotIn("INGEST_LEDGER_HOME_GUARD", self.ingest_env(self.render(s3)))
        self.assertEqual(self.ingest_env(self.render(merge(s3, {"ingestEdge": {"ledgerHomeGuard": True}})))["INGEST_LEDGER_HOME_GUARD"]["value"], "on")
        self.render(merge(load(SQL_FIXTURE), {"ingestEdge": {"ledgerHomeGuard": True}}), fail="ingestEdge.ledgerHomeGuard requires ingestEdge.ledger=s3")

    def test_startup_failure_threshold(self):
        s3 = merge(load(S3_FIXTURE), {"ingestEdge": {"admission": {"mode": "async"}}})
        c = lambda docs: next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "ci-ingest-edge")["spec"]["template"]["spec"]["containers"][0]
        self.assertEqual(c(self.render(s3))["startupProbe"]["failureThreshold"], 30)
        tuned = c(self.render(merge(s3, {"ingestEdge": {"admission": {"startupFailureThreshold": 300}}})))
        self.assertEqual(tuned["startupProbe"]["failureThreshold"], 300)
        self.assertEqual(tuned["readinessProbe"], c(self.render(s3))["readinessProbe"])
        for value in (29, 901, "x"):
            with self.subTest(value=value):
                self.render(merge(s3, {"ingestEdge": {"admission": {"startupFailureThreshold": value}}}),
                            fail="ingestEdge.admission.startupFailureThreshold must be an integer from 30 to 900")

    def test_default_is_sql_and_byte_identical_when_explicit(self):
        base = load(SQL_FIXTURE)
        implicit = helm(base)
        explicit = helm(merge(base, {"ingestEdge": {"ledger": "sql"}, "rearmSweeper": {"enabled": False}}))
        self.assertEqual(implicit.returncode, 0, implicit.stderr)
        self.assertEqual(implicit.stdout, explicit.stdout)
        self.assertNotIn("INGEST_LEDGER", implicit.stdout)
        self.assertNotIn("INGEST_REARM", implicit.stdout)
        self.assertNotIn("kind: CronJob", implicit.stdout)
        defaults = helm(load(CHART / "ci/default-values.yaml"))
        self.assertEqual(defaults.returncode, 0, defaults.stderr)
        self.assertNotIn("INGEST_LEDGER", defaults.stdout)
        self.assertNotIn("kind: CronJob", defaults.stdout)

    def test_s3_renders_ledger_on_the_ingest_edge_only(self):
        docs = self.render(load(S3_FIXTURE))
        self.assertEqual(self.ingest_env(docs)["INGEST_LEDGER"]["value"], "s3")
        holders = [d["metadata"]["name"] for d in docs if d["kind"] in ("Deployment", "Job", "CronJob", "StatefulSet")
                   and "INGEST_LEDGER" in yaml.safe_dump(d)]
        self.assertEqual(holders, ["ci-ingest-edge"])

    def test_sweeper_cronjob_shape(self):
        values = load(S3_FIXTURE)
        docs = self.render(values)
        cron = self.cronjob(docs)
        self.assertEqual(cron["spec"]["concurrencyPolicy"], "Forbid")
        self.assertEqual(cron["spec"]["schedule"], "*/5 * * * *")
        job = cron["spec"]["jobTemplate"]["spec"]
        self.assertEqual(job["backoffLimit"], 0)
        pod = job["template"]["spec"]
        self.assertEqual(pod["restartPolicy"], "Never")
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertEqual(pod["serviceAccountName"], "rearm-sweeper")
        self.assertTrue(pod["securityContext"]["runAsNonRoot"])
        c = pod["containers"][0]
        self.assertEqual(c["command"], ["bun", "run", "/app/src/session-ingest/rearm-sweeper-main.ts"])
        self.assertEqual(c["image"], "{}@{}".format(values["ingestEdge"]["image"]["repository"], values["ingestEdge"]["image"]["digest"]))
        self.assertEqual(c["securityContext"], {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}})
        self.assertIn("limits", c["resources"])
        env = {e["name"]: e.get("value") for e in c["env"]}
        locker = values["ingestEdge"]["locker"]
        self.assertEqual(env, {
            "INGEST_REARM_SWEEPER_ENABLED": "true",
            "INGEST_REARM_BUCKET": locker["bucket"],
            "INGEST_REARM_REGION": "us-east-1",
            "INGEST_REARM_ENDPOINT": locker["endpoint"],
            "ALLOW_IN_CLUSTER_HTTP": "true",
            "INGEST_REARM_KEY_ROOT": "96bulls",
            "INGEST_REARM_ORGS": "org_ci",
            "INGEST_REARM_CONCURRENCY": "2",
            "INGEST_REARM_CREDENTIALS": "keys",
            "INGEST_REARM_S3_ACCESS_KEY_ID_FILE": "/var/run/secrets/rearm-sweeper/access-key-id",
            "INGEST_REARM_S3_SECRET_ACCESS_KEY_FILE": "/var/run/secrets/rearm-sweeper/secret-access-key",
        })
        vol = next(v for v in pod["volumes"] if v["name"] == "credentials")["secret"]
        self.assertEqual(vol["secretName"], "rearm-sweeper-store")
        self.assertEqual(vol["defaultMode"], 0o440)
        sa = [d for d in docs if d["kind"] == "ServiceAccount" and d["metadata"]["name"] == "rearm-sweeper"]
        self.assertEqual(len(sa), 1)

    def test_sweeper_pod_identity(self):
        docs = self.render(merge(load(S3_FIXTURE), {"rearmSweeper": {"credentials": {"mode": "podIdentity", "existingSecret": ""}}}))
        pod = self.cronjob(docs)["spec"]["jobTemplate"]["spec"]["template"]["spec"]
        c = pod["containers"][0]
        env = {e["name"]: e.get("value") for e in c["env"]}
        self.assertEqual(env["INGEST_REARM_CREDENTIALS"], "podIdentity")
        self.assertFalse([n for n in env if n.startswith("INGEST_REARM_S3_") or n.startswith("AWS_")])
        self.assertTrue(all("valueFrom" not in e for e in c["env"]))
        self.assertEqual([m["name"] for m in c["volumeMounts"]], ["tmp"])
        self.assertEqual([v["name"] for v in pod["volumes"]], ["tmp"])
        self.assertEqual(pod["serviceAccountName"], "rearm-sweeper")
        self.assertFalse(pod["automountServiceAccountToken"])

    def test_sweeper_optional_settings(self):
        base = load(S3_FIXTURE)
        docs = self.render(merge(base, {"rearmSweeper": {"orgs": [], "dryRun": True, "concurrency": None, "maxMarkers": 50,
                                                         "createServiceAccount": False, "serviceAccountName": ""}}))
        pod = self.cronjob(docs)["spec"]["jobTemplate"]["spec"]["template"]["spec"]
        env = {e["name"]: e.get("value") for e in pod["containers"][0]["env"]}
        self.assertNotIn("INGEST_REARM_ORGS", env)
        self.assertNotIn("INGEST_REARM_CONCURRENCY", env)
        self.assertEqual(env["INGEST_REARM_DRY_RUN"], "1")
        self.assertEqual(env["INGEST_REARM_MAX_MARKERS"], "50")
        self.assertNotIn("serviceAccountName", pod)
        self.assertFalse([d for d in docs if d["kind"] == "ServiceAccount" and d["metadata"]["name"] == "rearm-sweeper"])

    def test_s3_refusals_mirror_the_binary(self):
        base = load(S3_FIXTURE)
        cases = [
            ({"ingestEdge": {"sessionSelection": True}}, "ingestEdge.ledger=s3 refuses ingestEdge.sessionSelection=true"),
            ({"global": {"operatorSessionErase": {"fenceEnforced": True}}}, "ingestEdge.ledger=s3 refuses the operator session erase"),
            ({"global": {"operatorSessionErase": {"fenceEnforced": True}}, "operatorSessionErase": {"api": {"enabled": True}}},
             "ingestEdge.ledger=s3 refuses the operator session erase"),
            ({"ingestEdge": {"ledger": "postgres"}}, "ingestEdge.ledger must be sql or s3"),
        ]
        for extra, message in cases:
            with self.subTest(message=message, extra=extra):
                self.render(merge(base, extra), fail=message)
        # The same combinations stay valid on the SQL ledger (unchanged behaviour).
        self.render(merge(base, {"ingestEdge": {"ledger": "sql", "sessionSelection": True}, "rearmSweeper": {"enabled": False}}))

    def test_sweeper_refusals(self):
        base = load(S3_FIXTURE)
        cases = [
            ({"ingestEdge": {"ledger": "sql"}}, "rearmSweeper.enabled=true requires ingestEdge.ledger=s3"),
            ({"ingestEdge": {"enabled": False}}, "rearmSweeper.enabled=true requires ingestEdge.enabled=true"),
            ({"rearmSweeper": {"credentials": {"mode": "webIdentity"}}}, "rearmSweeper.credentials.mode=webIdentity (IRSA) is not supported"),
            ({"rearmSweeper": {"credentials": {"mode": "role"}}}, "rearmSweeper.credentials.mode must be secret or podIdentity"),
            ({"rearmSweeper": {"credentials": {"mode": "podIdentity"}}}, "rearmSweeper.credentials.existingSecret must be empty with credentials.mode=podIdentity"),
            ({"rearmSweeper": {"serviceAccountName": "", "createServiceAccount": False, "credentials": {"mode": "podIdentity", "existingSecret": ""}}},
             "rearmSweeper.credentials.mode=podIdentity requires rearmSweeper.serviceAccountName"),
            ({"ingestEdge": {"serviceAccountName": "shared-sa"}, "rearmSweeper": {"serviceAccountName": "shared-sa", "createServiceAccount": False,
              "credentials": {"mode": "podIdentity", "existingSecret": ""}}}, "rearmSweeper.serviceAccountName must differ from ingestEdge.serviceAccountName"),
            ({"rearmSweeper": {"credentials": {"existingSecret": ""}}}, "rearmSweeper.credentials.existingSecret is required"),
            ({"rearmSweeper": {"credentials": {"existingSecret": "ingest-store"}}}, "must be a dedicated sweeper Secret"),
            ({"rearmSweeper": {"credentials": {"existingSecret": "ingest-runtime"}}}, "must be a dedicated sweeper Secret"),
            ({"rearmSweeper": {"credentials": {"secretAccessKeyKey": "access-key-id"}}}, "requires distinct access and secret keys"),
            ({"rearmSweeper": {"orgs": [".hidden"]}}, "rearmSweeper.orgs entries must be org ids"),
            ({"rearmSweeper": {"concurrency": 17}}, "rearmSweeper.concurrency must be null or an integer from 1 to 16"),
            ({"rearmSweeper": {"schedule": "often"}}, "rearmSweeper.schedule must be a five-field cron expression"),
            ({"rearmSweeper": {"dryRun": "yes"}}, "rearmSweeper.dryRun must be a boolean"),
            ({"rearmSweeper": {"enabled": "true"}}, "rearmSweeper.enabled must be a boolean"),
        ]
        for extra, message in cases:
            with self.subTest(message=message):
                self.render(merge(base, extra), fail=message)


if __name__ == "__main__":
    unittest.main()
