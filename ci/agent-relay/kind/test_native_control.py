"""Control bootstrap boundary tests; no credentials, cluster or DB access."""
from copy import deepcopy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from native_control import CONTROL_OBSERVER, NativeControlTransport, control_contract
from native_recipe import NativeRecipeError
from test_native_recipe import selected


def contract():
    return {"version": 1, "administrator": {"email": "owner@kind.example", "displayName": "Installation owner"},
        "organizationName": "Local installation", "workspaceName": "Default",
        "owner": {"name": "kind-native-control-owner", "key": "database-migrations-url", "role": "control_owner"},
        "runtime": {"name": "kind-native-control-runtime", "databaseKey": "database-url", "role": "control_api_runtime",
            "bootstrapKey": "selfhost-bootstrap-token", "encryptionKey": "selfhost-encryption-key", "encryptionKeyId": "kind-1",
            "castInternalKey": "relaycast-internal-secret", "internalKey": "selfhost-internal-token",
            "introspectionKey": "introspect-secret", "readerIssuerKey": "reader-internal-secret"},
        "cast": {"name": "kind-native-cast", "internalKey": "internal-secret", "bootstrapKey": "workspace-bootstrap-secret"}}


class Transport(NativeControlTransport):
    ADMIN_SECRET = "admin"; SERVER_TLS_SECRET = "server"; HBA_CONFIG = "hba"
    def __init__(self):
        self._configure_control(contract()); self._completed = set(); self.effects = []; self.assigned = False
    def _control_roles(self, selected):
        return {name: {"name": name, "oid": index, "login": self.assigned, "passwordAbsent": not self.assigned,
                       "safe": True, "settingsAbsent": True, "ownsDatabase": name == "control_owner"}
                for index, name in enumerate(("control_owner", "control_api_runtime"), 20)}
    def _transport_call(self, method, *args, **kw):
        from types import SimpleNamespace
        self.effects.append((method, args)); return SimpleNamespace(stdout="")
    def _secret(self, name, values):
        self.effects.append(("secret", name, set(values)))
    def _psql(self, selected, db, sql, **kw):
        self.effects.append(("sql", db, "SCRAM-SHA-256$" in sql)); self.assigned = True


class NativeControlTests(unittest.TestCase):
    def test_typed_operator_identity_is_explicit_and_contains_no_credentials(self):
        good = contract(); self.assertEqual(control_contract(good), good)
        for mutate in [lambda x: x.update(password="not-allowed"), lambda x: x.pop("administrator"),
                       lambda x: x["administrator"].update(email="missing-domain"),
                       lambda x: x["administrator"].update(email="bad\x00@kind.example"),
                       lambda x: x["administrator"].update(displayName="name\rcontrol"),
                       lambda x: x.update(workspaceName="arbitrary-existing-workspace"),
                       lambda x: x["runtime"].update(role="control_owner"),
                       lambda x: x["runtime"].update(name=x["owner"]["name"]),
                       lambda x: x["runtime"].update(databaseKey=x["owner"]["key"])]:
            changed = deepcopy(good); mutate(changed)
            with self.subTest(changed=sorted(changed)), self.assertRaises(NativeRecipeError): control_contract(changed)

    def test_changed_contract_and_reserved_secret_names_refuse_before_effects(self):
        t = Transport(); t.control["organizationName"] = "changed"
        with self.assertRaisesRegex(NativeRecipeError, "contract_changed"): t._claim_control_credentials(selected())
        self.assertEqual(t.effects, [])
        t = Transport(); s = selected(); s["secretRefs"]["reader"]["name"] = t.control["owner"]["name"]
        with self.assertRaisesRegex(NativeRecipeError, "collision"): t._claim_control_credentials(s)
        self.assertEqual(t.effects, [])

    def test_existing_password_or_login_is_not_reset_and_creates_no_secret(self):
        t = Transport(); t.assigned = True
        with self.assertRaisesRegex(NativeRecipeError, "unclaimed"): t._claim_control_credentials(selected())
        self.assertEqual(t.effects, [])

    def test_separate_immutable_secret_payloads_precede_only_new_scram_assignments(self):
        t = Transport(); t._claim_control_credentials(selected())
        secrets = [x for x in t.effects if x[0] == "secret"]
        self.assertEqual(len(secrets), 5)
        self.assertEqual(secrets[0][2], {t.control["owner"]["key"]})
        self.assertNotIn(t.control["owner"]["key"], secrets[1][2])
        self.assertEqual(t.effects[-1], ("sql", "relaycontrol", True))
        self.assertIn("control_credentials", t._completed)
        prior = deepcopy(t.effects)
        with self.assertRaisesRegex(NativeRecipeError, "partial_control_claim"): t._claim_control_credentials(selected())
        self.assertEqual(t.effects, prior)

    def test_real_catalog_query_and_locked_claim_guard_use_role_setting_catalog(self):
        t = Transport(); inventory = list(t._control_roles(selected()).values()); queries = []
        def query(s, database, sql, **kwargs):
            queries.append((database, sql, kwargs)); return json.dumps(inventory)
        t._psql = query
        observed = NativeControlTransport._control_roles(t, selected())
        self.assertEqual(set(observed), {"control_owner", "control_api_runtime"})
        self.assertEqual(queries[0][0], "relaycontrol")
        self.assertTrue(queries[0][2]["read_only"])
        self.assertIn("FROM pg_authid r", queries[0][1])
        predicate = "NOT EXISTS(SELECT 1 FROM pg_db_role_setting WHERE setrole=r.oid)"
        self.assertIn(predicate, queries[0][1])
        self.assertNotIn("rolconfig", queries[0][1])
        # Keep every per-role/per-database override in scope, not just global.
        self.assertNotIn("setdatabase=0", queries[0][1])
        statements = []
        t = Transport(); original_psql = t._psql
        def claim(s, database, sql, **kwargs):
            statements.append(sql); return original_psql(s, database, sql, **kwargs)
        t._psql = claim; t._claim_control_credentials(selected()); sql = statements[0]
        lock = "LOCK TABLE pg_catalog.pg_db_role_setting IN SHARE MODE;"
        self.assertLess(sql.index(lock), sql.index("DO $$"))
        self.assertEqual(sql.count(predicate), 2)
        self.assertNotIn("rolconfig", sql)
        self.assertEqual(sql.count("ALTER ROLE "), 2)

    def test_catalog_settings_or_malformed_identity_refuse_before_credentials(self):
        for bad in ("settings", "oid-string", "oid-bool", "settings-not-bool"):
            with self.subTest(bad=bad):
                t = Transport(); rows = list(t._control_roles(selected()).values())
                if bad == "settings": rows[0]["settingsAbsent"] = False
                if bad == "oid-string": rows[0]["oid"] = str(rows[0]["oid"])
                if bad == "oid-bool": rows[0]["oid"] = True
                if bad == "settings-not-bool": rows[0]["settingsAbsent"] = "true"
                t._psql = lambda *a, **k: json.dumps(rows)
                t._control_roles = lambda s: NativeControlTransport._control_roles(t, s)
                with self.assertRaisesRegex(NativeRecipeError, "exact_control_role_identity"):
                    t._claim_control_credentials(selected())
                self.assertEqual(t.effects, [])
                self.assertFalse(t._control_claim_attempted)

    def test_api_failure_leaves_new_secret_for_review_and_does_not_assign_passwords(self):
        t = Transport(); seen = []
        def fail(name, value):
            seen.append(name)
            if len(seen) == 2: raise RuntimeError("synthetic Secret API outage")
        t._secret = fail
        with self.assertRaises(RuntimeError): t._claim_control_credentials(selected())
        self.assertFalse(any(x[0] == "sql" for x in t.effects))
        with self.assertRaisesRegex(NativeRecipeError, "partial_control_claim"): t._claim_control_credentials(selected())

    def test_official_migration_executable_gets_only_owner_secret_and_pinned_public_ca(self):
        t = Transport(); s = selected(); job = t._control_migration_document(s)
        spec = job["spec"]["template"]["spec"]; container = spec["containers"][0]
        self.assertEqual(container["command"], ["node", "/app/node_modules/relay-control/dist/migrate-cli.js"])
        self.assertEqual(container["image"], s["control"]["reference"])
        self.assertFalse(spec["automountServiceAccountToken"])
        self.assertEqual(job["spec"]["backoffLimit"], 0)
        self.assertEqual(spec["volumes"][0]["secret"]["secretName"], t.control["owner"]["name"])
        self.assertNotIn(t.control["runtime"]["name"], json.dumps(job))
        self.assertEqual(container["env"][1], {"name": "SELFHOST_RUNTIME_DATABASE_ROLE", "value": "control_api_runtime"})

    def test_real_bootstrap_api_metadata_accepts_only_one_expected_org_default_and_owner(self):
        org = "11111111-1111-4111-8111-111111111111"; workspace = "22222222-2222-4222-8222-222222222222"
        good = {"/healthz": {"ok": True}, "/readyz": {"status": "ready", "capabilities": {"flows": False, "relayfile": False, "chief": False}, "introspection": {"enabled": True, "audiences": [selected()["historyOrigin"]]}},
            "/api/v1/organizations": {"organizations": [{"id": org, "name": contract()["organizationName"]}]},
            "/api/v1/organizations/" + org + "/workspaces": {"workspaces": [{"id": workspace, "name": "Default"}]},
            "/api/v1/organizations/" + org + "/memberships": {"memberships": [{"email": contract()["administrator"]["email"], "role": "owner"}]}}
        data = {"bootstrapKey": "synthetic-bootstrap", "organizationName": contract()["organizationName"],
                "administratorEmail": contract()["administrator"]["email"], "historyOrigin": selected()["historyOrigin"]}
        def run(responses):
            with tempfile.TemporaryDirectory() as d:
                preload = Path(d) / "preload.cjs"
                preload.write_text("const fs=require('node:fs');const orig=fs.readFileSync;fs.readFileSync=function(p,...a){if(p==='/var/run/agent-relay/secrets/synthetic-bootstrap')return 'synthetic-operator-bearer-32-characters';return orig.call(this,p,...a)};const responses=" + json.dumps(responses) + ";global.fetch=async(u,o)=>{if(o.method!=='GET'||o.redirect!=='error'||!u.startsWith('http://127.0.0.1:3000/'))throw Error('unsafe request');const path=new URL(u).pathname;return {status:responses[path]?200:404,json:async()=>responses[path]}};")
                return subprocess.run(["node", "--require", str(preload), "-e", CONTROL_OBSERVER], input=json.dumps(data),
                    capture_output=True, text=True, timeout=5)
        result = run(good); self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout.split("NATIVE_CONTROL_OBSERVATION ")[1]), {"organizationId": org, "workspaceId": workspace})
        self.assertNotIn(data["administratorEmail"], result.stdout)
        for kind in ("foreign-org", "second-workspace", "nonowner", "wrong-audience"):
            bad = deepcopy(good)
            if kind == "foreign-org": bad["/api/v1/organizations"]["organizations"][0]["name"] = "other"
            if kind == "second-workspace": bad["/api/v1/organizations/" + org + "/workspaces"]["workspaces"].append({"id": org, "name": "Other"})
            if kind == "nonowner": bad["/api/v1/organizations/" + org + "/memberships"]["memberships"][0]["role"] = "member"
            if kind == "wrong-audience": bad["/readyz"]["introspection"]["audiences"] = ["https://other.example"]
            result = run(bad)
            with self.subTest(kind=kind):
                self.assertNotEqual(result.returncode, 0); self.assertEqual(result.stdout, "")
                self.assertNotIn(data["administratorEmail"], result.stderr)


if __name__ == "__main__": unittest.main()
