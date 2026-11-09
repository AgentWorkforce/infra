"""Causal phase and binding tests; no Docker, Kubernetes, SQL or credentials."""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from native_recipe import (BOOTSTRAP, CORE_OPERATIONS, ROLES, SECRET_KEYS,
                          NativeRecipe, NativeRecipeError, native_selected,
                          merge_values, official_sql, refuse_legacy_up, selection)


def selected(profile="core"):
    files = {f: hashlib.sha256(("-- " + f + "\n").encode()).hexdigest() for f in BOOTSTRAP}
    return {
        "profile": profile, "sourceRevision": "a" * 40,
        "manifestDigest": "sha256:" + "b" * 64, "configDigest": "sha256:" + "c" * 64,
        "reference": "agent-relay-kind/pipeline-native@sha256:" + "b" * 64,
        "architecture": "arm64", "generation": "d" * 64,
        "artifactReceiptSha256": "e" * 64, "sourceClean": True,
        "control": {"sourceRevision": "3" * 40, "manifestDigest": "sha256:" + "4" * 64,
                    "configDigest": "sha256:" + "5" * 64,
                    "reference": "agent-relay-kind/selfhost-api@sha256:" + "4" * 64,
                    "artifactReceiptSha256": "6" * 64, "nativeEvents": True, "independentIssuer": False},
        "acceptedSource": {"revision": "a" * 40, "scope": "native-kind", "accepted": True,
                           "bootstrapSha256": files}, "officialBootstrapSha256": files,
        "roles": deepcopy(ROLES),
        "postgres": {"host": "postgres.agent-relay.svc.cluster.local", "port": 5432,
                     "pipelineDatabase": "hoopdb", "controlDatabase": "relaycontrol",
                     "fileDatabase": "relayfile", "castDatabase": "relaycast", "tls": "verify-full"},
        "postgresCa": {"sha256": "f" * 64, "configMap": "kind-native-public-ca", "key": "ca.crt", "immutable": True},
        "secretRefs": {n: {"name": "kind-native-" + n.lower(), "key": k, "jsonField": j}
                       for n, (k, j) in SECRET_KEYS.items()},
        "keyRoot": "96bulls", "orgFromPrefix": True, "backend": "postgres", "backendId": "kind-native-test",
        "readerLoginAdvertisesSync": True,
        "lockerBucket": "locker", "lockerClaim": "locker",
        "completeSince": "2026-11-08T22:02:26Z", "siteOrigin": "https://relay.kind.agentrelay.com",
        "historyOrigin": "https://history.kind.agentrelay.com:8443",
        "publication": False, "gc": False, "ownerBuffered": False,
    }


class Operations:
    def __init__(self, mode="fresh", fail=None):
        self.mode, self.fail, self.calls = mode, fail, []
        for name in CORE_OPERATIONS + ("addons",):
            setattr(self, name, self.operation(name))

    def operation(self, name):
        def run(s, *args):
            self.calls.append((name, args))
            if name == self.fail:
                raise NativeRecipeError("synthetic_phase_failure")
            if name == "inspect":
                return {"owned": True, "mode": self.mode, "clusterUid": "owned-uid", "foreignWriters": []}
            if name == "verify_artifact":
                return {k: s[k] for k in ("sourceRevision", "manifestDigest", "configDigest", "generation", "officialBootstrapSha256", "control")}
            if name == "render":
                return {"legacyWriterCount": 0, "managedNative": True, "ownerBuffered": False, "publication": False, "readerLoginAdvertisesSync": s["readerLoginAdvertisesSync"]}
            if name == "schema_plan":
                return {"ok": True, "pending": 0, "physicalLedgerSha256": "1" * 64, "planSha256": "2" * 64}
            if name == "install_control":
                return {"ok": True, "workspaceId": "11111111-1111-4111-8111-111111111111", "organizationId": "22222222-2222-4222-8222-222222222222"}
            if name == "addons":
                return {"ok": True, "capabilitiesVerified": True, "workloadsVerified": True, "apiVerified": True, "uiVerified": True, "featureModes": {"flows": "enabled", "relayfile": "enabled", "chief": "disabled"}}
            return {"ok": True}
        return run


class NativeRecipeTests(unittest.TestCase):
    def test_explicit_new_store_epoch_is_supported_but_ambiguous_floor_is_not(self):
        s = selected(); s["completeSince"] = "epoch"
        self.assertEqual(selection(s)["completeSince"], "epoch")
        for floor in ("", "now", "2000-01-01", "2999-01-01T00:00:00Z"):
            s["completeSince"] = floor
            with self.assertRaises(NativeRecipeError): selection(s)

    def test_independent_reader_discovery_and_authority_are_bound_before_io(self):
        s = selected(); s["control"]["independentIssuer"] = True; s["readerLoginAdvertisesSync"] = False
        self.assertEqual(selection(s), s)
        o = Operations(); NativeRecipe(s).run(o)
        for mutate in (lambda x: x.update(readerLoginAdvertisesSync=True),
                       lambda x: x["secretRefs"]["readerIssuer"].update(name=x["secretRefs"]["introspection"]["name"])):
            bad = deepcopy(s); mutate(bad); o = Operations()
            with self.assertRaises(NativeRecipeError): NativeRecipe(bad).run(o)
            self.assertEqual(o.calls, [])

    def test_addons_require_actual_selected_workload_api_ui_evidence_not_license(self):
        from native_recipe import phase_receipt
        good = {"ok": True, "capabilitiesVerified": True, "workloadsVerified": True,
                "apiVerified": True, "uiVerified": True,
                "featureModes": {"flows": "enabled", "relayfile": "enabled"}}
        self.assertEqual(phase_receipt("addons", good), good)
        for k in ("capabilitiesVerified", "workloadsVerified", "apiVerified", "uiVerified"):
            bad = deepcopy(good); bad[k] = False
            with self.assertRaises(NativeRecipeError): phase_receipt("addons", bad)
        with self.assertRaises(NativeRecipeError):
            phase_receipt("addons", {"ok": True, "signedLicenseVerified": True, "featureModes": good["featureModes"]})

    def test_fresh_has_exact_native_order_and_finalizes_before_runtime(self):
        o = Operations(); receipts = NativeRecipe(selected()).run(o)
        self.assertEqual([n for n, _ in o.calls], [
            "inspect", "verify_artifact", "render", "prepare_infrastructure", "install_control",
            "prepare_owner", "schema_plan", "schema_apply", "schema_noop", "consumer_prepare", "post_roles",
            "finalize_owner", "verify_owner_final", "initial_credentials", "verify_credentials", "serve", "verify_ready", "record_ready"])
        serve = next(args for n, args in o.calls if n == "serve")
        self.assertEqual(serve, ({"bootstrapEnabled": False, "phase": "serve"},))
        self.assertFalse(o.calls[-1][1][0]["fullAcceptance"])
        self.assertEqual(receipts[-1]["phase"], "record_ready")

    def test_repeat_never_elevates_reinstalls_rotates_or_requeues_bootstrap(self):
        o = Operations("repeat"); NativeRecipe(selected()).run(o)
        names = [n for n, _ in o.calls]
        self.assertEqual(names, ["inspect", "verify_artifact", "render", "verify_infrastructure", "verify_control", "schema_plan",
                                 "schema_noop", "verify_claimed_roles", "verify_owner_final", "verify_credentials", "serve", "verify_ready", "record_ready"])
        self.assertFalse(set(names) & {"prepare_owner", "consumer_prepare", "initial_credentials", "schema_apply", "prepare_infrastructure"})

    def test_addons_reuses_identical_native_core_and_runs_selected_workload_proof_last(self):
        a, b = Operations(), Operations()
        NativeRecipe(selected()).run(a); NativeRecipe(selected("addons")).run(b)
        self.assertEqual([n for n, _ in a.calls[:-1]], [n for n, _ in b.calls[:-2]])
        self.assertEqual([n for n, _ in b.calls[-3:]], ["verify_ready", "addons", "record_ready"])

    def test_partial_owner_preparation_always_attempts_finalization_and_never_serves(self):
        for failed in ("prepare_owner", "schema_plan", "schema_apply", "schema_noop", "consumer_prepare", "post_roles"):
            with self.subTest(failed=failed):
                o = Operations(fail=failed)
                with self.assertRaises(NativeRecipeError): NativeRecipe(selected()).run(o)
                self.assertEqual(o.calls[-1][0], "finalize_owner")
                self.assertNotIn("serve", [n for n, _ in o.calls])

    def test_finalization_failure_refuses_all_runtime_and_ready_writes(self):
        o = Operations(fail="finalize_owner")
        with self.assertRaises(NativeRecipeError): NativeRecipe(selected()).run(o)
        self.assertNotIn("initial_credentials", [n for n, _ in o.calls])
        self.assertNotIn("record_ready", [n for n, _ in o.calls])

    def test_pending_repeat_schema_requires_explicit_operator_upgrade(self):
        o = Operations("repeat"); o.schema_plan = lambda s: {"ok": True, "pending": 1}
        with self.assertRaisesRegex(NativeRecipeError, "explicit_native_operator"): NativeRecipe(selected()).run(o)
        self.assertNotIn("serve", [n for n, _ in o.calls])

    def test_missing_adapter_refuses_before_inspection_or_mutation(self):
        o = Operations(); o.consumer_prepare = None
        with self.assertRaisesRegex(NativeRecipeError, "complete_native_adapter"): NativeRecipe(selected()).run(o)
        self.assertEqual(o.calls, [])

    def test_wrong_artifact_bootstrap_or_rendered_writers_refuses_before_first_write(self):
        for key in ("artifact", "bootstrap", "writers"):
            o = Operations()
            if key in ("artifact", "bootstrap"):
                original = o.verify_artifact
                def bad(s, original=original, key=key):
                    r = deepcopy(original(s)); r["generation" if key == "artifact" else "officialBootstrapSha256"] = "changed"; return r
                o.verify_artifact = bad
            else:
                o.render = lambda s: {"legacyWriterCount": 1, "managedNative": True, "ownerBuffered": False, "publication": False}
            with self.assertRaises(NativeRecipeError): NativeRecipe(selected()).run(o)
            self.assertNotIn("prepare_infrastructure", [n for n, _ in o.calls])

    def test_role_owner_ca_secret_and_layout_refusals_have_valid_positive(self):
        self.assertEqual(selection(selected())["roles"], ROLES)
        mutations = [
            lambda x: x["roles"].update(consumer="hoop"),
            lambda x: x["postgres"].update(tls="disable"),
            lambda x: x["postgres"].update(controlDatabase="hoopdb"),
            lambda x: x["postgresCa"].update(immutable=False),
            lambda x: x["secretRefs"]["reader"].update(jsonField="hoopdb_url"),
            lambda x: x["secretRefs"]["consumer"].update(name=x["secretRefs"]["owner"]["name"]),
            lambda x: x.update(keyRoot="96bulls/org"), lambda x: x.update(orgFromPrefix=False),
            lambda x: x.update(completeSince=""), lambda x: x.update(ownerBuffered=True),
            lambda x: x.update(completeSince="2026-99-99T22:02:26Z"),
            lambda x: x.update(completeSince="2099-11-08T22:02:26Z"),
            lambda x: x.update(readerLoginAdvertisesSync=False),
            lambda x: x.update(sourceClean=False), lambda x: x["acceptedSource"].update(accepted=False),
            lambda x: x["control"].update(nativeEvents=False),
            lambda x: x["control"].update(independentIssuer=True),
            lambda x: x["officialBootstrapSha256"].pop("session_consumer_credential_probe.sql"),
        ]
        for mutate in mutations:
            x = selected(); mutate(x)
            with self.assertRaises(NativeRecipeError): selection(x)

    def test_no_credentials_in_selection_or_receipts(self):
        x = selected(); x["password"] = "synthetic-do-not-persist"
        with self.assertRaises(NativeRecipeError): selection(x)
        x = selected(); x["untypedExtra"] = "postgresql://synthetic:synthetic@localhost/db"
        with self.assertRaises(NativeRecipeError): selection(x)
        o = Operations(); o.verify_credentials = lambda s: {"ok": True, "token": "synthetic"}
        with self.assertRaises(NativeRecipeError): NativeRecipe(selected()).run(o)
        self.assertNotIn("serve", [n for n, _ in o.calls])
        for mutate in (lambda x: x.update(extraApiKey="synthetic"),
                       lambda x: x["control"].update(extraApiKey="synthetic"),
                       lambda x: x["acceptedSource"].update(extraApiKey="synthetic"),
                       lambda x: x["secretRefs"].update(extra={"name": "synthetic"}),
                       lambda x: x["officialBootstrapSha256"].update(extra="a" * 64)):
            x = selected(); mutate(x)
            with self.assertRaises(NativeRecipeError): selection(x)
        o = Operations(); o.verify_credentials = lambda s: {"ok": True, "extraApiKey": "synthetic"}
        with self.assertRaisesRegex(NativeRecipeError, "unexpected_phase_receipt_fields"): NativeRecipe(selected()).run(o)

    def test_legacy_guard_detects_each_managed_native_surface_before_ready_unlink(self):
        for surface in ("nativeConsumer", "sessionReadApi", "ingestEdge"):
            values = {"sessions-pipeline": {surface: {"enabled": True}}}
            self.assertTrue(native_selected(values))
            events = []
            with self.assertRaises(NativeRecipeError):
                refuse_legacy_up(values)
                events.append("ready_unlink")
                events.append("postgres_apply")
            self.assertEqual(events, [])
        self.assertFalse(native_selected({"sessions-pipeline": {"ingestEdge": {"enabled": False}}}))
        self.assertTrue(native_selected({"sessions-pipeline": {"nativeRouting": {"enabled": True}, "sessionReadApi": {"enabled": False}, "ingestEdge": {"enabled": False}}}))
        for invalid in (True, "enabled", {"enabled": "true"}):
            with self.assertRaises(NativeRecipeError): native_selected({"sessions-pipeline": {"nativeRouting": invalid}})
            with self.assertRaises(NativeRecipeError): native_selected({"sessions-pipeline": {"sessionReadApi": {"enabled": True}, "nativeRouting": invalid}})
        refuse_legacy_up({})

    def test_early_guard_uses_merged_base_profile_and_private_values(self):
        base = {"sessions-pipeline": {"nativeConsumer": {"enabled": False, "phase": "prepare"}}}
        profile = {"sessions-pipeline": {"sessionReadApi": {"enabled": False}}}
        private = {"sessions-pipeline": {"nativeConsumer": {"enabled": True}}}
        merged = merge_values(base, profile, private)
        self.assertTrue(native_selected(merged))
        self.assertEqual(merged["sessions-pipeline"]["nativeConsumer"]["phase"], "prepare")
        self.assertFalse(base["sessions-pipeline"]["nativeConsumer"]["enabled"])
        with self.assertRaises(NativeRecipeError): native_selected({"sessions-pipeline": {"ingestEdge": {"enabled": "true"}}})

    def test_actual_stack_up_refuses_before_docker_ready_unlink_and_pg_writes(self):
        from stack import Stack, StackError
        for profile in ("core", "addons"):
            for surface in ("nativeConsumer", "sessionReadApi", "ingestEdge", "nativeRouting"):
                with self.subTest(profile=profile, surface=surface), tempfile.TemporaryDirectory() as td:
                    s = Stack.__new__(Stack)
                    s.profile = profile; s.state = Path(td); s.overrides = s.state / "values.json"
                    s.overrides.write_text(json.dumps({"sessions-pipeline": {surface: {"enabled": True}}}))
                    ready = s.state / "ready.json"; ready.write_text("owned-original-receipt")
                    events = []
                    s.docker = lambda **kw: events.append("docker_config_write")
                    s.postgres = lambda *args: events.append("postgres_write")
                    with patch("stack.shutil.which", return_value="/bin/mock"):
                        with self.assertRaisesRegex(ValueError, "native.*(?:requires|require).*native"):
                            s.up()
                    self.assertEqual(events, [])
                    self.assertEqual(ready.read_text(), "owned-original-receipt")

    def test_actual_legacy_stack_positive_reaches_original_docker_preflight(self):
        from stack import Stack
        with tempfile.TemporaryDirectory() as td:
            s = Stack.__new__(Stack); s.profile = "core"; s.state = Path(td)
            s.overrides = s.state / "values.json"; events = []
            def docker(**kw):
                events.append("original_docker_preflight")
                raise RuntimeError("bounded_test_stop")
            s.docker = docker
            with patch("stack.shutil.which", return_value="/bin/mock"):
                with self.assertRaisesRegex(RuntimeError, "bounded_test_stop"): s.up()
            self.assertEqual(events, ["original_docker_preflight"])

    def test_official_sql_is_hash_bound_and_refuses_unqualified_includes(self):
        x = selected(); raw = {f: ("-- " + f + "\n").encode() for f in BOOTSTRAP}
        self.assertEqual(official_sql(raw, x, BOOTSTRAP[0]), raw[BOOTSTRAP[0]].decode())
        raw[BOOTSTRAP[0]] += b"-- edited\n"
        with self.assertRaises(NativeRecipeError): official_sql(raw, x, BOOTSTRAP[0])
        raw[BOOTSTRAP[0]] = b"\\ir ../../untrusted.sql\n"
        x["officialBootstrapSha256"][BOOTSTRAP[0]] = hashlib.sha256(raw[BOOTSTRAP[0]]).hexdigest()
        with self.assertRaisesRegex(NativeRecipeError, "unqualified"): official_sql(raw, x, BOOTSTRAP[0])


if __name__ == "__main__":
    unittest.main()
