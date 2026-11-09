"""Execute the production operator wrapper against a causal in-memory API seam.

No PG, filesystem credentials, Docker or Kubernetes is touched. The seam models
transaction abort and session advisory locks, so failures test cleanup rather
than merely asserting text in the wrapper.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from native_pipeline import DRIVER


FIXTURE = r"""
import {createHash}from'node:crypto';
const mode=process.env.NATIVE_PHASE_TEST_CASE;
const trace=[];let transaction=false,aborted=false,locked=false;
const entries=mode==='wrong_checksum'?[['96bulls:001_fixture.sql','c'.repeat(64)]]:[];
const expected={generation:'d'.repeat(64),names:['96bulls:001_fixture.sql'],shas:{'96bulls:001_fixture.sql':'a'.repeat(64)}};
export const generation=async()=>expected.generation;
export const expectedSchema=async()=>expected;
export const migrationProfile=x=>{if(x.HOOPDB_DB_MODE!=='selfhosted'||x.HOOPDB_SUPABASE_SHIM!=='false'||x.HOOPDB_ROLE_BOOTSTRAP!=='false'||x.HOOPDB_ROLE_VERIFY!=='true')throw Error('profile');return x};
export const migrationLedgerSha256=x=>createHash('sha256').update(JSON.stringify([...x].sort())).digest('hex');
export const resolveRenamedLedger=x=>({effective:x,refusals:[]});
export const migrationChecksumMatches=(name,seen,sha)=>seen===sha;
export const postgresTlsOptions=x=>{if(x.SESSION_POSTGRES_TLS_PROFILE!=='custom-ca'||x.SESSION_POSTGRES_CA_FILE!=='/var/run/native-pg-ca/ca.crt'||x.SESSION_POSTGRES_CA_SHA256!=='f'.repeat(64))throw Error('tls');return{rejectUnauthorized:true,ca:'public-test-only'}};
export const postgresConnectionString=raw=>{const u=new URL(raw);for(const k of [...u.searchParams.keys()])if(k.startsWith('ssl'))u.searchParams.delete(k);return String(u)};
const owner='postgresql://hoop:synthetic-test-only@postgres.agent-relay.svc.cluster.local:5432/hoopdb?sslmode=verify-full&sslrootcert=%2Fvar%2Frun%2Fnative-pg-ca%2Fca.crt';
export const readFileSync=()=>owner;
class Client{
 constructor(options){if(!options.ssl.rejectUnauthorized||new URL(options.connectionString).searchParams.has('sslmode'))throw Error('bad-tls-options');trace.push('CLIENT')}
 async connect(){trace.push('CONNECT')}
 async query(sql){
  if(sql==='ROLLBACK'){trace.push('ROLLBACK');transaction=false;aborted=false;return{rows:[]}}
  if(aborted)throw Object.assign(Error('transaction-aborted'),{code:'25P02'});
  if(sql.startsWith('BEGIN')){transaction=true;trace.push('BEGIN_READ_ONLY');return{rows:[]}}
  if(sql.includes('pg_advisory_unlock')){trace.push('UNLOCK');locked=false;return{rows:[]}}
  if(sql.includes('pg_advisory_lock')){trace.push('LOCK');locked=true;return{rows:[]}}
  if(sql==='SELECT PREFLIGHT'){
   trace.push('OFFICIAL_PREFLIGHT');if(mode==='sql_guard_error'){aborted=true;throw Object.assign(Error('guard'),{code:'55000'})}return{rows:[]}}
  if(sql.startsWith('CREATE')){trace.push('WRITE_ATTEMPT');if(transaction)throw Object.assign(Error('readonly'),{code:'25006'});return{rows:[]}}
  if(sql.includes('current_user=session_user'))return{rows:[{identity:mode!=='wrong_identity',direct:true,tls:mode!=='plaintext'}]};
  if(sql.includes('r.oid::int'))return{rows:[{oid:101,temporary:true,owns:true,safe:true}]};
  if(sql.includes('to_regclass'))return{rows:[{yes:entries.length>0}]};
  if(sql.includes('SELECT name,sha256'))return{rows:entries.map(([name,sha256])=>({name,sha256}))};
  throw Error('unexpected fixture query');
 }
 async end(){trace.push('END');console.log('FIXTURE_TRACE '+JSON.stringify({trace,locked}))}
}
export default{Client};
export async function runMigrations(c,opts){
 await c.query('SELECT pg_advisory_lock(961996,1)');
 try{
  await c.query('SELECT PREFLIGHT');
  if(opts.expectedLedgerSha256!==undefined&&opts.expectedLedgerSha256!==migrationLedgerSha256(new Map(entries)))throw Error('ledger-changed');
  await opts.beforeWrite?.();
  await c.query('CREATE TABLE only_after_external_gate()');
  return{applied:1,skipped:0};
 }finally{await c.query('SELECT pg_advisory_unlock(961996,1)').catch(()=>{})}
}
"""


@unittest.skipUnless(shutil.which("bun"), "Bun is required for the executable operator wrapper seam")
class NativeDriverTests(unittest.TestCase):
    def run_driver(self, mode="plan", case="normal", plan=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / "fixture.ts"; fixture.write_text(FIXTURE)
            code = DRIVER.replace("import fs from 'node:fs';", "import * as fs from '" + fixture.as_uri() + "';")
            for name in ("pg", "/app/src/shared/postgres-tls.ts", "/app/src/hoopdb/migrate.ts", "/app/src/hoopdb/migrate-guards.ts"):
                code = code.replace("from '" + name + "'", "from '" + fixture.as_uri() + "'")
            script = root / "driver.ts"; script.write_text(code)
            data = {"operation": mode, "sourceRevision": "a" * 40, "generation": "d" * 64,
                    "host": "postgres.agent-relay.svc.cluster.local", "caSha256": "f" * 64,
                    "temporaryOwner": True, "ownerOid": 101}
            if plan is not None: data["plan"] = plan
            p = subprocess.run([shutil.which("bun"), str(script)], input=json.dumps(data), text=True,
                               capture_output=True, env={**os.environ, "NATIVE_PHASE_TEST_CASE": case}, timeout=10)
            self.assertNotIn("synthetic-test-only", p.stdout + p.stderr)
            trace = [json.loads(line.removeprefix("FIXTURE_TRACE ")) for line in p.stdout.splitlines() if line.startswith("FIXTURE_TRACE ")]
            results = [json.loads(line.removeprefix("NATIVE_OPERATOR_RESULT ")) for line in p.stdout.splitlines() if line.startswith("NATIVE_OPERATOR_RESULT ")]
            return p, trace, results

    def test_plan_runs_official_preflight_readonly_and_stops_before_write(self):
        p, trace, results = self.run_driver()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["plan"]["physicalLedgerSha256"], hashlib.sha256(b"[]").hexdigest())
        self.assertTrue(results[0]["plan"]["inventory"][0]["pending"])
        self.assertNotIn("WRITE_ATTEMPT", trace[0]["trace"])
        self.assertIn("OFFICIAL_PREFLIGHT", trace[0]["trace"])
        self.assertLess(trace[0]["trace"].index("BEGIN_READ_ONLY"), trace[0]["trace"].index("OFFICIAL_PREFLIGHT"))
        self.assertFalse(trace[0]["locked"])
        self.assertEqual(trace[0]["trace"][-3:], ["ROLLBACK", "UNLOCK", "END"])

    def test_sql_guard_refusal_rolls_back_then_releases_session_lock_and_closes(self):
        p, trace, results = self.run_driver(case="sql_guard_error")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(results, [])
        self.assertNotIn("WRITE_ATTEMPT", trace[0]["trace"])
        self.assertEqual(trace[0]["trace"][-3:], ["ROLLBACK", "UNLOCK", "END"])
        self.assertFalse(trace[0]["locked"])

    def test_wrong_applied_checksum_refuses_without_marker_or_ledger_writes(self):
        p, trace, results = self.run_driver(case="wrong_checksum")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(results, [])
        self.assertNotIn("WRITE_ATTEMPT", trace[0]["trace"])
        self.assertFalse(trace[0]["locked"])

    def test_changed_physical_ledger_binding_or_inventory_refuses_before_apply(self):
        _, _, planned = self.run_driver()
        plan = planned[0]["plan"]
        for field in ("physicalLedgerSha256", "inventory"):
            altered = json.loads(json.dumps(plan))
            if field == "inventory": altered[field][0]["pending"] = False
            else: altered[field] = "0" * 64
            p, trace, results = self.run_driver(mode="apply", plan=altered)
            self.assertNotEqual(p.returncode, 0)
            self.assertEqual(results, [])
            self.assertNotIn("WRITE_ATTEMPT", trace[0]["trace"])
            self.assertFalse(trace[0]["locked"])

    def test_plaintext_or_wrong_identity_connection_never_reaches_schema_preflight(self):
        for case in ("plaintext", "wrong_identity"):
            p, trace, results = self.run_driver(case=case)
            self.assertNotEqual(p.returncode, 0)
            self.assertEqual(results, [])
            self.assertNotIn("OFFICIAL_PREFLIGHT", trace[0]["trace"])
            self.assertEqual(trace[0]["trace"][-1], "END")


if __name__ == "__main__":
    unittest.main()
