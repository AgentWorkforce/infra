"""Causal native phase tests: owned transports only, no cluster or DB access."""
import base64
from copy import deepcopy
import hashlib
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from native_pipeline import NativePipelineAdapter, DRIVER, canonical
from native_recipe import NativeRecipe, NativeRecipeError
import test_native_bootstrap as bootstrap_tests
import test_native_inspect as inspect_tests


class NativePipelineTests(unittest.TestCase):
    image = bootstrap_tests.NativeBootstrapTests.image
    render_fixture = bootstrap_tests.NativeBootstrapTests.render_fixture
    observed_preflight = bootstrap_tests.NativeBootstrapTests.observed_preflight
    fresh = bootstrap_tests.NativeBootstrapTests.fresh
    tearDown = inspect_tests.NativeInspectTests.tearDown

    def setUp(self):
        bootstrap_tests.NativeBootstrapTests.setUp(self)
        self.adapter = NativePipelineAdapter(self.stack, self.inputs, self.material)
        self.adapter._minio_source = lambda: (self.root / "minio-5.4.0.tgz", self.root / "postrender.py")
        self.stack.arch = "arm64"
        self.events = []

    def prepared(self):
        self.fresh()
        self.adapter.prepare_owner(self.s)

    def plan(self, pending=True):
        return {"sourceRevision": self.s["sourceRevision"], "generation": self.s["generation"],
                "physicalLedgerSha256": "1" * 64,
                "inventory": [{"name": "96bulls:001_test.sql", "sha256": "2" * 64, "pending": pending}]}

    def driver(self, operation, **values):
        self.events.append((operation, deepcopy(values)))
        if operation == "plan": return {"ok": True, "plan": self.plan()}
        return {"ok": True, "applied": 1, "skipped": 0, "generation": self.s["generation"]}

    def claims(self, password_absent=True):
        return {self.s["roles"][name]: {"name": self.s["roles"][name], "oid": n, "safe": True, "passwordAbsent": password_absent}
                for n, name in enumerate(("consumer", "reader", "ingest"), 301)}

    def secret_writes(self):
        return [e for e in self.stack.effects if e == ("create", "Secret")]

    def roles_ready(self):
        self.prepared()
        self.adapter._completed.update({"schema_applied", "schema_verified", "consumer_prepared", "roles_promoted"})
        self.adapter._claimed_oids = {n: r["oid"] for n, r in self.claims().items()}
        self.adapter.finalize_owner(self.s)
        self.adapter._verify_post_roles = lambda s: self.events.append(("official-role-verifies", None))
        self.adapter._role_claims = lambda s: self.claims()
        intro = self.s["secretRefs"]["introspection"]
        self.adapter._secret(intro["name"], {intro["key"]: "synthetic-introspection-proof-only-123456789"})

    def test_still_incomplete_adapter_refuses_before_any_inspection_or_write(self):
        with self.assertRaisesRegex(NativeRecipeError, "complete_native_adapter"):
            NativeRecipe(self.s).run(self.adapter)
        self.assertEqual(self.stack.effects, [])

    def test_phase_order_and_changed_selection_refuse_before_operator_transport(self):
        self.observed_preflight()
        with self.assertRaisesRegex(NativeRecipeError, "prerequisite"):
            self.adapter.schema_plan(self.s)
        self.assertEqual(self.stack.effects, [])
        changed = deepcopy(self.s); changed["backendId"] = "other"
        with self.assertRaisesRegex(NativeRecipeError, "selection_changed"):
            self.adapter.schema_plan(changed)
        self.assertEqual(self.stack.effects, [])

    def test_plan_is_bound_to_exact_source_generation_physical_ledger_and_inventory(self):
        self.prepared()
        self.adapter._driver = lambda s, op, **kw: self.driver(op, **kw)
        result = self.adapter.schema_plan(self.s)
        self.assertEqual(result["pending"], 1)
        self.assertEqual(result["planSha256"], hashlib.sha256(canonical(self.plan()).encode()).hexdigest())
        self.assertEqual(self.events, [("plan", {})])
        self.assertFalse((self.root / "ready.json").exists())
        self.assertFalse((self.root / "credentials.json").exists())

    def test_plan_rejects_wrong_generation_duplicate_inventory_or_unknown_checksum(self):
        self.prepared()
        for field in ("generation", "duplicate", "checksum", "extra"):
            p = self.plan()
            if field == "duplicate": p["inventory"].append(deepcopy(p["inventory"][0]))
            elif field == "checksum": p["inventory"][0]["sha256"] = "wrong"
            elif field == "extra": p["untrusted"] = True
            else: p[field] = "f" * 64
            self.adapter._driver = lambda s, op, p=p: {"ok": True, "plan": p}
            with self.subTest(field=field), self.assertRaisesRegex(NativeRecipeError, "native_plan"):
                self.adapter.schema_plan(self.s)

    def test_changed_saved_plan_refuses_before_apply_and_repeat_never_applies(self):
        self.prepared()
        self.adapter._driver = lambda s, op, **kw: self.driver(op, **kw)
        receipt = self.adapter.schema_plan(self.s)
        self.adapter._plan["inventory"][0]["pending"] = False
        with self.assertRaisesRegex(NativeRecipeError, "saved_native_plan"):
            self.adapter.schema_apply(self.s, receipt)
        self.assertEqual([n for n, _ in self.events], ["plan"])
        self.adapter._inspected["mode"] = "repeat"
        with self.assertRaisesRegex(NativeRecipeError, "retained"):
            self.adapter.schema_apply(self.s, receipt)

    def test_noop_refuses_new_pending_schema_before_noop_call(self):
        self.prepared(); self.adapter._completed.add("schema_applied")
        self.adapter._driver = lambda s, op, **kw: self.driver(op, **kw)
        with self.assertRaisesRegex(NativeRecipeError, "noop_has_pending"):
            self.adapter.schema_noop(self.s)
        self.assertEqual([n for n, _ in self.events], ["plan"])

    def test_apply_then_fresh_noop_replans_the_new_physical_ledger(self):
        self.prepared(); state = {"pending": True}
        def run(s, op, **kw):
            self.events.append((op, deepcopy(kw)))
            if op == "plan": return {"ok": True, "plan": self.plan(state["pending"])}
            if op == "apply": state["pending"] = False
            return {"ok": True, "applied": 1 if op == "apply" else 0, "skipped": 0 if op == "apply" else 1, "generation": s["generation"]}
        self.adapter._driver = run
        self.adapter._operator = {"name": "native-owner-test"}
        receipt = self.adapter.schema_plan(self.s)
        self.assertEqual(self.adapter.schema_apply(self.s, receipt)["applied"], 1)
        self.assertEqual(self.adapter.schema_noop(self.s)["applied"], 0)
        self.assertEqual([n for n, _ in self.events], ["plan", "apply", "plan", "noop"])

    def test_post_schema_role_files_are_reapplied_after_consumer_and_before_credentials(self):
        self.prepared(); self.adapter._completed.update({"consumer_prepared", "schema_verified"})
        calls = []
        self.adapter._official = lambda s, n: "-- official:" + n
        self.adapter._psql = lambda s, db, text, **kw: calls.append((text, kw))
        self.adapter._role_claims = lambda s: self.claims()
        self.adapter.post_roles(self.s)
        self.assertEqual([text for text, kw in calls[:2]], ["-- official:session_ingest_role.sql", "-- official:session_read_api_role.sql"])
        self.assertTrue(all(kw.get("read_only") is True for _, kw in calls[2:]))
        self.assertIn("roles_promoted", self.adapter._completed)
        self.assertNotIn("runtime_credentials_created", self.adapter._completed)

    def test_owner_must_be_finalized_before_runtime_password_or_secret_assignment(self):
        self.prepared(); self.adapter._completed.add("roles_promoted")
        before = len(self.stack.effects)
        with self.assertRaisesRegex(NativeRecipeError, "prerequisite"):
            self.adapter.initial_credentials(self.s)
        self.assertEqual(len(self.stack.effects), before)

    def test_existing_password_oid_or_foreign_secret_refuses_before_new_secrets(self):
        self.roles_ready(); before = len(self.secret_writes())
        self.adapter._role_claims = lambda s: self.claims(False)
        with self.assertRaisesRegex(NativeRecipeError, "no_longer_unclaimed"):
            self.adapter.initial_credentials(self.s)
        self.assertEqual(len(self.secret_writes()), before)
        changed = self.claims(); next(iter(changed.values()))["oid"] = 900
        self.adapter._role_claims = lambda s: changed
        with self.assertRaisesRegex(NativeRecipeError, "no_longer_unclaimed"):
            self.adapter.initial_credentials(self.s)
        self.assertEqual(len(self.secret_writes()), before)
        self.adapter._role_claims = lambda s: self.claims()
        ref = self.s["secretRefs"]["reader"]
        self.stack.objects_by_name["secret/" + ref["name"]] = {"metadata": {"uid": "foreign"}}
        with self.assertRaisesRegex(NativeRecipeError, "secret_already_exists"):
            self.adapter.initial_credentials(self.s)
        self.assertEqual(len(self.secret_writes()), before)

    def test_runtime_secrets_precede_scram_assignment_and_credentials_never_enter_argv_or_files(self):
        self.roles_ready(); calls = []
        original = self.adapter._psql
        self.adapter._psql = lambda s, db, text, **kw: original(s, db, text, **kw) if kw.get("read_only") else calls.append((text, kw))
        values = ["A" * 64, "B" * 64, "C" * 64]  # fixed synthetic credentials, never real material
        with patch("native_pipeline.secrets.token_urlsafe", side_effect=values):
            result = self.adapter.initial_credentials(self.s)
        self.assertEqual(set(result["secretUids"]), {"consumer", "reader", "ingest"})
        raw = []
        for key in ("consumer", "reader", "ingest"):
            obj = self.stack.objects_by_name["secret/" + self.s["secretRefs"][key]["name"]]
            self.assertTrue(obj["immutable"])
            raw.extend(base64.b64decode(v).decode() for v in obj["data"].values())
        self.assertTrue(all("PASSWORD 'SCRAM-SHA-256$" in sql for sql, _ in calls))
        sql = calls[0][0]
        self.assertIn("rolpassword IS NULL", sql)
        self.assertIn("LOCK TABLE pg_catalog.pg_auth_members", sql)
        self.assertTrue(all(value not in sql and value not in repr([a for a, kw in self.stack.calls]) for value in values + raw))
        self.assertFalse((self.root / "credentials.json").exists())
        with self.assertRaisesRegex(NativeRecipeError, "attempt_requires_review"):
            self.adapter.initial_credentials(self.s)

    def test_duplicate_generated_passwords_refuse_before_any_runtime_secret(self):
        self.roles_ready(); before = len(self.secret_writes())
        with patch("native_pipeline.secrets.token_urlsafe", return_value="duplicate-test-only"):
            with self.assertRaisesRegex(NativeRecipeError, "distinct_native_runtime_passwords"):
                self.adapter.initial_credentials(self.s)
        self.assertEqual(len(self.secret_writes()), before)

    def test_partial_secret_api_failure_never_assigns_passwords_or_blindly_rotates(self):
        self.roles_ready(); original = self.adapter._secret; count = 0
        original_sql = self.adapter._psql
        self.adapter._psql = lambda *a, **kw: original_sql(*a, **kw) if kw.get("read_only") else self.fail("SQL writes must not run before all Secrets exist")
        def create(name, values):
            nonlocal count
            count += 1
            if count == 2: raise NativeRecipeError("synthetic_API_failure")
            return original(name, values)
        self.adapter._secret = create
        with self.assertRaisesRegex(NativeRecipeError, "synthetic_API_failure"):
            self.adapter.initial_credentials(self.s)
        self.assertIn("secret/" + self.s["secretRefs"]["consumer"]["name"], self.stack.objects_by_name)
        with self.assertRaisesRegex(NativeRecipeError, "attempt_requires_review"):
            self.adapter.initial_credentials(self.s)
        self.assertNotIn("runtime_credentials_created", self.adapter._completed)

    def operator_fixture(self):
        self.prepared()
        self.adapter._ensure_pipeline_image = lambda s: self.events.append(("qualified-node-import", None))
        original = self.stack.k
        def request(*args, **kwargs):
            if args[0] == "wait": return SimpleNamespace(stdout="ready")
            if args[0] == "exec" and "bun" in args:
                self.events.append(("bun-exec", (args, kwargs)))
                return SimpleNamespace(stdout='{"level":"info","message":"official migration log"}\nNATIVE_OPERATOR_RESULT {"ok":true,"verified":3}\n')
            result = original(*args, **kwargs)
            if args[0] == "create":
                obj = json.loads(result.stdout)
                if obj["kind"] == "Job":
                    pod = {"metadata": {"name": "operator-fixture", "uid": "66666666-6666-4666-8666-666666666666",
                            "ownerReferences": [{"kind": "Job", "uid": obj["metadata"]["uid"]}]}, "status": {"phase": "Running"}}
                    self.stack.objects_by_name["pod/operator-fixture"] = pod
                    self.stack.objects_by_name["pods"] = {"items": [pod]}
            return result
        self.stack.k = request

    def test_owner_job_is_bounded_tokenless_and_mounts_only_existing_owner_secret_and_public_ca(self):
        self.operator_fixture()
        self.adapter._operator_pod(self.s)
        job = next(v for k, v in self.stack.objects_by_name.items() if k.startswith("job/"))
        self.assertEqual(job["apiVersion"], "batch/v1")
        self.assertEqual(job["spec"]["activeDeadlineSeconds"], 1200)
        self.assertEqual(job["spec"]["backoffLimit"], 0)
        self.assertEqual(job["spec"]["ttlSecondsAfterFinished"], 3600)
        pod = job["spec"]["template"]["spec"]
        self.assertIs(pod["automountServiceAccountToken"], False)
        self.assertTrue(pod["containers"][0]["securityContext"]["readOnlyRootFilesystem"])
        self.assertEqual({v["secret"]["secretName"] for v in pod["volumes"] if "secret" in v}, {self.s["secretRefs"]["owner"]["name"]})
        self.assertNotIn("env", pod["containers"][0])

    def test_job_spec_or_pod_uid_drift_refuses_before_any_exec(self):
        self.operator_fixture(); self.adapter._operator_pod(self.s)
        job = self.stack.objects_by_name["job/" + self.adapter._operator["name"]]
        before = deepcopy(job["spec"]); job["spec"]["activeDeadlineSeconds"] = 3600
        with self.assertRaisesRegex(NativeRecipeError, "operator_job_changed"):
            self.adapter._driver(self.s, "credentials", credentials=[])
        job["spec"] = before
        self.stack.objects_by_name["pod/operator-fixture"]["metadata"]["uid"] = "foreign"
        with self.assertRaisesRegex(NativeRecipeError, "operator_pod_changed"):
            self.adapter._driver(self.s, "credentials", credentials=[])
        self.assertFalse(any(n == "bun-exec" for n, _ in self.events))

    def test_operator_cleanup_is_deferred_until_terminal_and_cannot_be_removed_on_reuse(self):
        self.operator_fixture()
        result = self.adapter._driver(self.s, "noop")
        self.assertEqual(result, {"ok": True, "verified": 3})
        job = self.stack.objects_by_name["job/" + self.adapter._operator["name"]]
        self.assertEqual(job["spec"]["ttlSecondsAfterFinished"], 3600)
        self.assertNotIn("ttlSecondsAfterFinished", job["spec"]["template"]["spec"])
        # A changed cleanup policy is a changed owned Job, not a reason to
        # recreate it or retry owner operations without inspection.
        job["spec"].pop("ttlSecondsAfterFinished")
        self.events.clear()
        with self.assertRaisesRegex(NativeRecipeError, "operator_job_changed"):
            self.adapter._driver(self.s, "noop")
        self.assertFalse(any(n == "bun-exec" for n, _ in self.events))

    def test_driver_result_framing_ignores_official_logs_and_credentials_stay_in_sensitive_stdin(self):
        self.operator_fixture()
        self.assertEqual(self.adapter._driver(self.s, "credentials", credentials=[{"url": "synthetic-private-test-only"}]), {"ok": True, "verified": 3})
        args, kwargs = next(value for name, value in self.events if name == "bun-exec")
        self.assertNotIn("synthetic-private-test-only", repr(args))
        self.assertIn("synthetic-private-test-only", kwargs["data"])
        self.assertTrue(kwargs["sensitive"])

    def bootstrap_fixture(self):
        self.prepared(); self.adapter._completed.add("schema_verified")
        values = {"SERVICE": "session-pipeline-consumer-bootstrap", "SEARCH_INDEX_BACKEND": "postgres",
                  "SEARCH_INDEX_POSTGRES_BACKEND_ID": self.s["backendId"], "READ_API_COMPLETE_SINCE": self.s["completeSince"],
                  "PIPELINE_KEY_PREFIX": self.s["keyRoot"], "PIPELINE_ORG_FROM_PREFIX": "true",
                  "SESSION_POSTGRES_TLS_PROFILE": "custom-ca", "SESSION_POSTGRES_CA_SHA256": self.s["postgresCa"]["sha256"]}
        env = [{"name": k, "value": v} for k, v in values.items()]
        env.append({"name": "RELAYHISTORY_PIPELINE_CONSUMER_SECRET", "valueFrom": {"secretKeyRef": {
            "name": self.s["secretRefs"]["owner"]["name"], "key": self.s["secretRefs"]["owner"]["key"]}}})
        job = {"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": "native-consumer-bootstrap-fixture",
               "labels": {"app.kubernetes.io/component": "native-consumer-bootstrap"}},
               "spec": {"activeDeadlineSeconds": 600, "backoffLimit": 0, "template": {"spec": {
                   "containers": [{"name": "bootstrap", "image": self.s["reference"], "env": env}],
                   "volumes": [{"name": "contract", "configMap": {"name": "native-consumer-contract"}},
                               {"name": "ca", "configMap": {"name": self.s["postgresCa"]["configMap"]}}]}}}}
        self.stack.docs = [job, {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "native-consumer-contract"}, "data": {"preflight.mjs": "// reviewed public contract"}}]
        self.stack.wait_job = lambda name, seconds: {"succeeded": 1}
        return job

    def test_managed_consumer_prepare_applies_only_source_helper_job_and_its_contract(self):
        self.bootstrap_fixture()
        result = self.adapter.consumer_prepare(self.s)
        self.assertEqual(result["sourceRevision"], self.s["sourceRevision"])
        cm = self.stack.objects_by_name["configmap/native-consumer-contract"]
        self.assertEqual(cm["metadata"]["annotations"]["meta.helm.sh/release-name"], "agent-relay")
        self.assertIn("consumer_prepared", self.adapter._completed)
        self.assertFalse(any(k.startswith("deployment/") for k in self.stack.objects_by_name))
        with self.assertRaisesRegex(NativeRecipeError, "attempt_requires_review"):
            self.adapter.consumer_prepare(self.s)

    def test_foreign_contract_or_wrong_backend_floor_refuses_before_one_time_helper(self):
        job = self.bootstrap_fixture()
        baseline = len(self.stack.effects)
        self.stack.objects_by_name["configmap/native-consumer-contract"] = {"metadata": {"uid": "foreign"}}
        with self.assertRaisesRegex(NativeRecipeError, "contract_requires_review"):
            self.adapter.consumer_prepare(self.s)
        self.assertEqual(len(self.stack.effects), baseline)
        del self.stack.objects_by_name["configmap/native-consumer-contract"]
        env = job["spec"]["template"]["spec"]["containers"][0]["env"]
        next(e for e in env if e["name"] == "READ_API_COMPLETE_SINCE")["value"] = "2000-01-01T00:00:00Z"
        with self.assertRaisesRegex(NativeRecipeError, "backend_floor_or_tls"):
            self.adapter.consumer_prepare(self.s)
        self.assertEqual(len(self.stack.effects), baseline)

if __name__ == "__main__":
    unittest.main()
