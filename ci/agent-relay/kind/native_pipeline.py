"""Concrete native pipeline phases, using only the qualified image's APIs/SQL.

This mixin does not install Control or serve applications. It cannot on its own
be passed to NativeRecipe as a complete deployer. No command runs on import.
Owner credentials are projected from a Secret into a bounded operator Job;
runtime passwords pass only through memory, immutable Secrets and SQL stdin.
"""
from copy import deepcopy
import base64
import hashlib
import json
from pathlib import Path
import re
import secrets
import tempfile
from types import SimpleNamespace
from urllib.parse import quote, unquote, urlsplit

import yaml

from native_bootstrap import NativeBootstrapAdapter, scram
from native_inspect import document, native_archive, sha
from native_recipe import NativeRecipeError, require


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


# This is an operator transport, not a substitute migration implementation.
# runMigrations runs its own full profile/preflight/advisory lock. beforeWrite is
# its supported external gate, reached before even the pending marker is written.
DRIVER = r"""
import fs from 'node:fs';
import pg from 'pg';
import {postgresConnectionString,postgresTlsOptions} from '/app/src/shared/postgres-tls.ts';
import {generation,expectedSchema,runMigrations,migrationProfile,migrationLedgerSha256} from '/app/src/hoopdb/migrate.ts';
import {resolveRenamedLedger,migrationChecksumMatches} from '/app/src/hoopdb/migrate-guards.ts';
const x=await Bun.stdin.json();
const fail=()=>{throw Error('native_operator_refused')};
const equal=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
const profile=migrationProfile({HOOPDB_DB_MODE:'selfhosted',HOOPDB_SUPABASE_SHIM:'false',
 HOOPDB_ROLE_BOOTSTRAP:'false',HOOPDB_ROLE_VERIFY:'true',HOOPDB_RUNTIME_ROLE:'sessions_pipeline_runtime',
 HOOPDB_RUNTIME_ROLE_LOGIN:'true',HOOPDB_FUNCTION_BOUNDARY_MODE:'global-default-revoke'});
if(await generation()!==x.generation)fail();
const tls=postgresTlsOptions({SESSION_POSTGRES_TLS_PROFILE:'custom-ca',
 SESSION_POSTGRES_CA_FILE:'/var/run/native-pg-ca/ca.crt',SESSION_POSTGRES_CA_SHA256:x.caSha256});
async function connect(raw,role,caPath){
 const u=new URL(raw);
 if(!['postgres:','postgresql:'].includes(u.protocol)||decodeURIComponent(u.username)!==role||!u.password||
  u.hostname!==x.host||u.port!=='5432'||u.pathname!=='/hoopdb'||u.hash||
  !equal([...u.searchParams].sort(),[['sslmode','verify-full'],['sslrootcert',caPath]].sort()))fail();
 const c=new pg.Client({connectionString:postgresConnectionString(raw),ssl:tls,connectionTimeoutMillis:15000});
 try{
  await c.connect();
  const identity=(await c.query(`SELECT current_user=session_user AND session_user=$1 AS identity,
   current_setting('role')='none' AS direct,(SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()) AS tls`,[role])).rows[0];
  if(!identity?.identity||!identity.direct||!identity.tls)fail();
 }catch(error){await c.end().catch(()=>{});throw error}
 return c;
}
async function inventory(c){
 const exists=(await c.query("SELECT to_regclass('sessions.__96bulls_migrations') IS NOT NULL AS yes")).rows[0].yes;
 const physical=new Map(exists?(await c.query('SELECT name,sha256 FROM sessions.__96bulls_migrations ORDER BY name')).rows.map(r=>[r.name,r.sha256]):[]);
 const expected=await expectedSchema();
 const resolved=resolveRenamedLedger(physical,n=>expected.shas[n]);
 if(resolved.refusals.length)fail();
 for(const [name,value]of resolved.effective){
  if(!expected.shas[name]||!migrationChecksumMatches(name,value,expected.shas[name]))fail();
 }
 return {sourceRevision:x.sourceRevision,generation:expected.generation,
  physicalLedgerSha256:migrationLedgerSha256(physical),
  inventory:expected.names.map(name=>({name,sha256:expected.shas[name],pending:!resolved.effective.has(name)}))};
}
try{
 if(x.operation==='credentials'){
  if(!Array.isArray(x.credentials)||x.credentials.length!==3)fail();
  const paths={search_consumer_runtime:'/etc/native-consumer-postgres/ca.crt',bulls96_read_api:'/etc/session-read-api-postgres/ca.crt',bulls96_session_ingest:'/etc/session-ingest-postgres/ca.crt'};
  if(new Set(x.credentials.map(v=>v.role)).size!==3||x.credentials.some(v=>!paths[v.role]))fail();
  for(const item of x.credentials){const c=await connect(item.url,item.role,paths[item.role]);
   try{await c.query('BEGIN READ ONLY');await c.query('SELECT 1');await c.query('ROLLBACK')}finally{await c.end()}}
  console.log('NATIVE_OPERATOR_RESULT '+JSON.stringify({ok:true,verified:3}));
 }else{
  const c=await connect(fs.readFileSync('/var/run/native-owner/migration-url','utf8'),'hoop','/var/run/native-pg-ca/ca.crt');
  try{
   const own=(await c.query(`SELECT r.oid::int AS oid, r.rolcreaterole AS temporary,
    (SELECT count(*)=2 FROM pg_namespace WHERE nspname IN ('sessions','search_index') AND nspowner=r.oid) AS owns,
    NOT(r.rolsuper OR r.rolbypassrls OR r.rolcreatedb OR r.rolreplication OR r.rolinherit) AS safe
    FROM pg_roles r WHERE rolname=current_user AND oid=(SELECT datdba FROM pg_database WHERE datname=current_database())`)).rows[0];
   if(!own?.owns||!own.safe||own.temporary!==x.temporaryOwner||(x.ownerOid!==null&&own.oid!==x.ownerOid))fail();
   if(x.operation==='plan'){
    let result;const stop=Error('private_readonly_plan_complete');
    await c.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
    try{await runMigrations(c,{profile,beforeWrite:async()=>{result=await inventory(c);throw stop}});fail()}
    catch(error){if(error!==stop)throw error}finally{
     await c.query('ROLLBACK');
     // A failed SQL preflight can abort the read-only transaction, making the
     // migrator's own unlock fail with 25P02. Release it after rollback too.
     await c.query('SELECT pg_advisory_unlock(961996, 1)');
    }
    console.log('NATIVE_OPERATOR_RESULT '+JSON.stringify({ok:true,plan:result}));
   }else if(x.operation==='apply'||x.operation==='noop'){
    const saved=x.plan;
    if(!saved||saved.sourceRevision!==x.sourceRevision||saved.generation!==x.generation)fail();
    const result=await runMigrations(c,{profile,expectedLedgerSha256:saved.physicalLedgerSha256,beforeWrite:async()=>{
     const current=await inventory(c);
     if(!equal(current,saved)||(x.operation==='noop'&&current.inventory.some(s=>s.pending)))fail();
    }});
    if(x.operation==='noop'&&result.applied!==0)fail();
    console.log('NATIVE_OPERATOR_RESULT '+JSON.stringify({ok:true,...result,generation:await generation()}));
   }else fail();
  }finally{await c.end()}
 }
}catch(error){console.error(JSON.stringify({errorCode:typeof error?.code==='string'&&/^[a-zA-Z0-9_]{1,80}$/.test(error.code)?error.code:'native_operator_failed'}));process.exitCode=1}
"""


class NativePipelineAdapter(NativeBootstrapAdapter):
    """Pipeline phase transport; Control/serve phases still require composition."""

    def __init__(self, stack, inputs, tls_material=None):
        super().__init__(stack, inputs, tls_material)
        self._operator = None
        self._plan = None
        self._claimed_oids = None
        self._credential_attempted = False

    def _phase(self, selected, prerequisites=(), fresh=False):
        self._preflight(selected, fresh=fresh)
        require(self.stack.arch == selected["architecture"], "native_node_architecture_mismatch")
        require(set(prerequisites) <= self._completed, "native_phase_prerequisite_missing")
        if self._inspected["mode"] == "fresh":
            self._require_created_cluster()
        else:
            self._owned_uid(selected)

    def _ensure_pipeline_image(self, selected):
        """Import the already-qualified native export, then prove CRI identity.

        Docker's own native re-export supplies a real tag for Kind's importer;
        its bytes are checked again, and the digest alias is never retargeted.
        This does not pull a mutable tag or change an application workload.
        """
        receipt = document(self.inputs["pipelineReceipt"], selected["artifactReceiptSha256"])
        tag = receipt["build"]["localTag"]
        require(re.fullmatch(r"agent-relay-kind/[a-z0-9._/-]+:[A-Za-z0-9_.-]+", tag), "local_pipeline_tag_required")
        reference = selected["reference"]
        bare_reference = reference.removeprefix("docker.io/")
        require(bare_reference.startswith("agent-relay-kind/"), "local_pipeline_repository_required")
        with tempfile.TemporaryDirectory(prefix="native-image-", dir=self.stack.state) as directory:
            archive = Path(directory) / "native.tar"
            self._transport_call("cmd", [*self.stack.docker_args, "image", "save", "--platform", "linux/" + selected["architecture"], "-o", archive, tag], timeout=300, sensitive=True)
            native_archive(archive, sha(archive), selected["sourceRevision"], selected["manifestDigest"], selected["configDigest"], selected["architecture"])
            self._transport_call("cmd", ["kind", "load", "image-archive", "--name", self.stack.name, archive], timeout=300, sensitive=True)
        from control import alias
        # alias rechecks the imported tag's exact native manifest before any tag
        # operation and proves the config/platform through the node's CRI.
        bound = SimpleNamespace(cmd=lambda *args, **kwargs: self._transport_call("cmd", *args, **kwargs),
                                docker_args=self.stack.docker_args, name=self.stack.name, arch=self.stack.arch)
        alias(bound, bare_reference, {"tag": tag, "manifestDigest": selected["manifestDigest"], "configDigest": selected["configDigest"]})

    def _operator_pod(self, selected):
        if self._operator is not None:
            require(self._operator.get("pod") is not None, "incomplete_native_operator_requires_review")
            job = self._get("job/" + self._operator["name"])
            require(job["metadata"]["uid"] == self._operator["uid"] and job["spec"] == self._operator["spec"], "native_operator_job_changed")
            return self._operator["pod"]
        self._ensure_pipeline_image(selected)
        name = "native-owner-" + self._selected_sha[:16]
        ref = selected["secretRefs"]["owner"]
        ca = selected["postgresCa"]
        spec = {"backoffLimit": 0, "activeDeadlineSeconds": 1200, "template": {
            "metadata": {"labels": {"app.kubernetes.io/name": "native-owner-operator"}},
            "spec": {"restartPolicy": "Never", "automountServiceAccountToken": False,
                "securityContext": {"runAsNonRoot": True, "runAsUser": 1000, "runAsGroup": 1000, "fsGroup": 1000},
                "containers": [{"name": "operator", "image": selected["reference"], "imagePullPolicy": "Never",
                    "command": ["bun", "-e", "await new Promise(r=>setTimeout(r,1100000))"],
                    "securityContext": {"readOnlyRootFilesystem": True, "allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}},
                    "volumeMounts": [{"name": "owner", "mountPath": "/var/run/native-owner", "readOnly": True},
                        {"name": "ca", "mountPath": "/var/run/native-pg-ca", "readOnly": True}]}],
                "volumes": [{"name": "owner", "secret": {"secretName": ref["name"], "items": [{"key": "migration-url", "path": "migration-url"}], "defaultMode": 0o440}},
                    {"name": "ca", "configMap": {"name": ca["configMap"], "items": [{"key": ca["key"], "path": "ca.crt"}], "defaultMode": 0o440}}]}}}
        job = self._create("Job", name, {"apiVersion": "batch/v1", "spec": spec})
        # Keep the server-defaulted spec, not a hand-written approximation.
        self._operator = {"name": name, "uid": job["metadata"]["uid"], "spec": deepcopy(job["spec"]), "pod": None}
        self._transport_call("k", "wait", "--for=condition=Ready", "pod", "-l", "batch.kubernetes.io/controller-uid=" + job["metadata"]["uid"], "--timeout=120s", sensitive=True, timeout=150)
        pods = self._get("pods")["items"]
        matches = [p for p in pods if any(o.get("kind") == "Job" and o.get("uid") == job["metadata"]["uid"] for o in p["metadata"].get("ownerReferences", []))]
        require(len(matches) == 1 and matches[0].get("status", {}).get("phase") == "Running", "one_running_native_operator_required")
        self._operator["pod"] = matches[0]["metadata"]["name"]
        self._operator["podUid"] = matches[0]["metadata"]["uid"]
        return self._operator["pod"]

    def _driver(self, selected, operation, **payload):
        pod = self._operator_pod(selected)
        live = self._get("pod/" + pod)
        require(live["metadata"]["uid"] == self._operator["podUid"] and live.get("status", {}).get("phase") == "Running" and
                any(o.get("uid") == self._operator["uid"] for o in live["metadata"].get("ownerReferences", [])), "native_operator_pod_changed")
        request = {"operation": operation, "sourceRevision": selected["sourceRevision"], "generation": selected["generation"],
            "host": selected["postgres"]["host"], "caSha256": selected["postgresCa"]["sha256"],
            "temporaryOwner": self._inspected["mode"] == "fresh" and "owner_finalized" not in self._completed,
            "ownerOid": self._owner_oid, **payload}
        result = self._transport_call("k", "exec", "-i", pod, "-c", "operator", "--", "bun", "-e", DRIVER,
                                      data=canonical(request), sensitive=True, timeout=900)
        try:
            lines = [s.removeprefix("NATIVE_OPERATOR_RESULT ") for s in result.stdout.splitlines() if s.startswith("NATIVE_OPERATOR_RESULT ")]
            require(len(lines) == 1, "one_native_operator_result_required")
            value = json.loads(lines[0])
        except (ValueError, TypeError):
            raise NativeRecipeError("native_operator_output_not_json") from None
        require(value.get("ok") is True, "native_operator_phase_refused")
        return value

    def schema_plan(self, selected):
        self._phase(selected, ("owner_prepared",) if self._inspected["mode"] == "fresh" else ())
        reply = self._driver(selected, "plan")
        plan = reply.get("plan", {})
        require(set(plan) == {"sourceRevision", "generation", "physicalLedgerSha256", "inventory"} and
                plan["sourceRevision"] == selected["sourceRevision"] and plan["generation"] == selected["generation"] and
                re.fullmatch(r"[a-f0-9]{64}", plan["physicalLedgerSha256"]), "native_plan_binding_invalid")
        inventory = plan["inventory"]
        require(isinstance(inventory, list) and inventory and all(set(s) == {"name", "sha256", "pending"} and
                isinstance(s["name"], str) and re.fullmatch(r"(?:upstream|96bulls):[A-Za-z0-9_.-]+\.sql", s["name"]) and
                re.fullmatch(r"[a-f0-9]{64}", s["sha256"]) and type(s["pending"]) is bool for s in inventory) and
                len({s["name"] for s in inventory}) == len(inventory), "native_plan_inventory_invalid")
        self._plan = deepcopy(plan)
        self._plan_sha = hashlib.sha256(canonical(plan).encode()).hexdigest()
        self._completed.add("schema_planned")
        return {"ok": True, "pending": sum(s["pending"] for s in inventory), "physicalLedgerSha256": plan["physicalLedgerSha256"],
                "planSha256": self._plan_sha, "generation": selected["generation"]}

    def schema_apply(self, selected, receipt):
        self._phase(selected, ("owner_prepared", "schema_planned"), fresh=True)
        require(receipt.get("planSha256") == self._plan_sha and receipt.get("physicalLedgerSha256") == self._plan["physicalLedgerSha256"] and
                hashlib.sha256(canonical(self._plan).encode()).hexdigest() == self._plan_sha, "saved_native_plan_changed")
        result = self._driver(selected, "apply", plan=self._plan)
        require(type(result.get("applied")) is int and result["applied"] == sum(s["pending"] for s in self._plan["inventory"]) and
                result.get("generation") == selected["generation"], "native_apply_result_mismatch")
        self._completed.add("schema_applied")
        return {"ok": True, "applied": result["applied"], "skipped": result["skipped"], "planSha256": self._plan_sha,
                "generation": selected["generation"], "jobName": self._operator["name"]}

    def schema_noop(self, selected):
        self._phase(selected, ("schema_applied",) if self._inspected["mode"] == "fresh" else ("schema_planned",))
        self.schema_plan(selected)
        require(not any(s["pending"] for s in self._plan["inventory"]), "native_noop_has_pending_migrations")
        result = self._driver(selected, "noop", plan=self._plan)
        require(result.get("applied") == 0 and type(result.get("skipped")) is int and result.get("generation") == selected["generation"], "native_schema_noop_failed")
        self._completed.add("schema_verified")
        return {"ok": True, "applied": 0, "skipped": result["skipped"], "generation": selected["generation"], "jobName": self._operator["name"]}

    def consumer_prepare(self, selected):
        self._phase(selected, ("owner_prepared", "schema_verified"), fresh=True)
        require("consumer_attempted" not in self._completed, "consumer_prepare_attempt_requires_review")
        # Resolve/check the chart job before making the one-time SQL helper.
        overrides = {"sessions-pipeline": {"nativeConsumer": {"bootstrap": {"enabled": True, "phase": "prepare",
            "existingSecret": selected["secretRefs"]["owner"]["name"], "key": selected["secretRefs"]["owner"]["key"], "ownerRole": "hoop"}}}}
        rendered = self._transport_call("cmd", ["helm", "template", "agent-relay", "charts/agent-relay", "-n", "agent-relay",
            *self.stack.values_args(), "-f", "-"], data=yaml.safe_dump(overrides), sensitive=True, timeout=60)
        docs = [d for d in yaml.safe_load_all(rendered.stdout) if d]
        jobs = [d for d in docs if d["kind"] == "Job" and d["metadata"].get("labels", {}).get("app.kubernetes.io/component") == "native-consumer-bootstrap"]
        require(len(jobs) == 1, "one_managed_consumer_bootstrap_job_required")
        job = jobs[0]
        pod = job["spec"]["template"]["spec"]
        require(job["spec"].get("backoffLimit") == 0 and 0 < job["spec"].get("activeDeadlineSeconds", 0) <= 1200 and
                all(c.get("image") == selected["reference"] for c in pod.get("containers", []) + pod.get("initContainers", [])) and
                len(pod.get("containers", [])) == 1, "managed_consumer_bootstrap_contract_changed")
        env = {e["name"]: e for e in pod["containers"][0].get("env", [])}
        require(len(env) == len(pod["containers"][0].get("env", [])) and env.get("SERVICE", {}).get("value") == "session-pipeline-consumer-bootstrap" and
                env.get("RELAYHISTORY_PIPELINE_CONSUMER_SECRET", {}).get("valueFrom", {}).get("secretKeyRef") ==
                {"name": selected["secretRefs"]["owner"]["name"], "key": selected["secretRefs"]["owner"]["key"]}, "bootstrap_owner_secret_or_entrypoint_changed")
        for name, value in {"SEARCH_INDEX_BACKEND": "postgres", "SEARCH_INDEX_POSTGRES_BACKEND_ID": selected["backendId"],
                            "READ_API_COMPLETE_SINCE": selected["completeSince"], "PIPELINE_KEY_PREFIX": selected["keyRoot"],
                            "PIPELINE_ORG_FROM_PREFIX": "true", "SESSION_POSTGRES_TLS_PROFILE": "custom-ca",
                            "SESSION_POSTGRES_CA_SHA256": selected["postgresCa"]["sha256"]}.items():
            require(env.get(name, {}).get("value") == value, "bootstrap_backend_floor_or_tls_changed")
        require(not self._transport_call("k", "get", "job", job["metadata"]["name"], "--ignore-not-found=true", "-o", "name", sensitive=True).stdout.strip(), "prior_consumer_job_requires_review")
        wanted = {v["configMap"]["name"] for v in pod.get("volumes", []) if "configMap" in v}
        public_contracts = [d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] in wanted and
                            d["metadata"]["name"] != selected["postgresCa"]["configMap"]]
        require({d["metadata"]["name"] for d in public_contracts} == wanted - {selected["postgresCa"]["configMap"]} and
                len(public_contracts) == len(wanted - {selected["postgresCa"]["configMap"]}), "consumer_contract_configmap_missing_or_duplicate")
        for cm in public_contracts:
            require(not self._transport_call("k", "get", "configmap", cm["metadata"]["name"], "--ignore-not-found=true", "-o", "name", sensitive=True).stdout.strip(), "prior_consumer_contract_requires_review")
        ca = self._get("configmap/" + selected["postgresCa"]["configMap"])
        require(ca.get("immutable") is True and set(ca.get("data", {})) == {selected["postgresCa"]["key"]} and
                hashlib.sha256(ca["data"][selected["postgresCa"]["key"]].encode()).hexdigest() == selected["postgresCa"]["sha256"], "consumer_ca_reference_changed")
        self._completed.add("consumer_attempted")
        self._psql(selected, "hoopdb", self._official(selected, "session_consumer_credential_probe.sql"))
        # Every ConfigMap is public chart contract data; no Secret/doc outside
        # the Job's exact referenced set is applied as a side effect.
        for cm in public_contracts:
            metadata = deepcopy(cm["metadata"])
            metadata["namespace"] = "agent-relay"
            metadata.setdefault("labels", {})["app.kubernetes.io/managed-by"] = "Helm"
            metadata.setdefault("annotations", {}).update({"meta.helm.sh/release-name": "agent-relay", "meta.helm.sh/release-namespace": "agent-relay"})
            self._create("ConfigMap", cm["metadata"]["name"], {"metadata": metadata,
                **{k: v for k, v in cm.items() if k not in {"apiVersion", "kind", "metadata"}}})
        self._create("Job", job["metadata"]["name"], {"apiVersion": "batch/v1", "spec": job["spec"]})
        status = self._transport_call("wait_job", job["metadata"]["name"], seconds=600)
        require(not status.get("failed", 0), "consumer_bootstrap_failed_attempt")
        self._completed.add("consumer_prepared")
        return {"ok": True, "jobName": job["metadata"]["name"], "sourceRevision": selected["sourceRevision"]}

    def _verify_post_roles(self, selected):
        for name in ("session_ingest_role_verify.sql", "session_ingest_verify.sql", "session_read_api_role_verify.sql"):
            self._psql(selected, "hoopdb", self._official(selected, name), read_only=True)
        self._psql(selected, "hoopdb", "SET LOCAL ROLE hoop;\n" + self._official(selected, "session_consumer_role_verify.sql"), read_only=True)

    def _role_claims(self, selected):
        roles = [selected["roles"][k] for k in ("consumer", "reader", "ingest")]
        raw = self._psql(selected, "hoopdb", "SELECT coalesce(json_agg(json_build_object('name',rolname,'oid',oid,'safe',rolcanlogin AND NOT(rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb OR rolreplication OR rolinherit) AND rolvaliduntil IS NULL,'passwordAbsent',rolpassword IS NULL) ORDER BY rolname),'[]'::json) FROM pg_authid WHERE rolname IN (" + ",".join("'" + r + "'" for r in roles) + ");", read_only=True)
        rows = json.loads(raw)
        require(len(rows) == 3 and {r["name"] for r in rows} == set(roles) and all(r["safe"] is True and type(r["oid"]) is int and r["oid"] > 0 for r in rows), "native_runtime_role_claim_unsafe")
        return {r["name"]: r for r in rows}

    def post_roles(self, selected):
        self._phase(selected, ("consumer_prepared", "schema_verified"), fresh=True)
        for name in ("session_ingest_role.sql", "session_read_api_role.sql"):
            self._psql(selected, "hoopdb", self._official(selected, name))
        self._verify_post_roles(selected)
        claims = self._role_claims(selected)
        require(all(r["passwordAbsent"] is True for r in claims.values()), "fresh_runtime_role_already_has_password")
        self._claimed_oids = {n: r["oid"] for n, r in claims.items()}
        self._completed.add("roles_promoted")
        return {"ok": True, "roleOids": self._claimed_oids}

    def initial_credentials(self, selected):
        self._phase(selected, ("roles_promoted", "owner_finalized"), fresh=True)
        require(not self._credential_attempted, "runtime_credential_attempt_requires_review")
        self.verify_owner_final(selected)
        self._verify_post_roles(selected)
        claims = self._role_claims(selected)
        require({n: r["oid"] for n, r in claims.items()} == self._claimed_oids and
                all(r["passwordAbsent"] is True for r in claims.values()), "runtime_role_no_longer_unclaimed")
        for key in ("consumer", "reader", "ingest"):
            require(not self._transport_call("k", "get", "secret", selected["secretRefs"][key]["name"], "--ignore-not-found=true", "-o", "name", sensitive=True).stdout.strip(), "runtime_secret_already_exists")
        intro = selected["secretRefs"]["introspection"]
        intro_secret = self._get("secret/" + intro["name"])
        try:
            introspection = base64.b64decode(intro_secret["data"][intro["key"]], validate=True).decode()
        except (KeyError, ValueError, UnicodeError):
            raise NativeRecipeError("introspection_secret_invalid") from None
        require(32 <= len(introspection) <= 4096 and not any(c in introspection for c in "\r\n\0"), "introspection_secret_invalid")
        self._credential_attempted = True
        verifiers, uids = {}, {}
        generated = {key: secrets.token_urlsafe(48) for key in ("consumer", "reader", "ingest")}
        owner_ref = selected["secretRefs"]["owner"]
        owner_data = self._get("secret/" + owner_ref["name"])["data"][owner_ref["key"]]
        owner_password = unquote(urlsplit(json.loads(base64.b64decode(owner_data, validate=True).decode())[owner_ref["jsonField"]]).password or "")
        require(owner_password and len({owner_password, *generated.values()}) == 4, "distinct_native_runtime_passwords_required")
        del owner_password, owner_data
        for key, path in (("consumer", "/etc/native-consumer-postgres/ca.crt"), ("reader", "/etc/session-read-api-postgres/ca.crt"), ("ingest", "/etc/session-ingest-postgres/ca.crt")):
            role = selected["roles"][key]
            password = generated.pop(key)
            verifiers[role] = scram(password)
            url = "postgresql://" + role + ":" + password + "@" + selected["postgres"]["host"] + ":5432/hoopdb?sslmode=verify-full&sslrootcert=" + quote(path, safe="")
            ref = selected["secretRefs"][key]
            values = {ref["key"]: json.dumps({ref["jsonField"]: url}) if ref["jsonField"] else url}
            if key == "ingest":
                values["introspect-secret"] = introspection
            obj = self._secret(ref["name"], values)
            uids[key] = obj["metadata"]["uid"]
            del password, url, values
        del introspection
        # All immutable Secrets must exist before any password is assigned.
        # A partial API/SQL failure remains explicit: never rotate/retry blindly.
        checks = " OR ".join("NOT EXISTS(SELECT 1 FROM pg_authid WHERE oid=" + str(oid) + " AND rolname='" + name + "' AND rolcanlogin AND rolpassword IS NULL AND rolvaliduntil IS NULL AND NOT(rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb OR rolreplication OR rolinherit))" for name, oid in self._claimed_oids.items())
        text = "BEGIN; SET LOCAL log_statement='none'; SET LOCAL log_min_error_statement='panic'; SET LOCAL lock_timeout='5s'; SET LOCAL statement_timeout='30s'; LOCK TABLE pg_catalog.pg_authid IN SHARE ROW EXCLUSIVE MODE; DO $$ BEGIN IF " + checks + " THEN RAISE EXCEPTION 'native credential claim changed'; END IF; END $$;\n"
        text += "LOCK TABLE pg_catalog.pg_auth_members, pg_catalog.pg_db_role_setting IN SHARE MODE;\n"
        for name in ("session_ingest_role_verify.sql", "session_read_api_role_verify.sql"):
            text += self._official(selected, name) + "\n"
        text += "SET LOCAL ROLE hoop;\n" + self._official(selected, "session_consumer_role_verify.sql") + "\nRESET ROLE;\n"
        text += "\n".join("ALTER ROLE " + name + " PASSWORD '" + verifier + "';" for name, verifier in verifiers.items()) + "\nCOMMIT;"
        self._psql(selected, "hoopdb", text)
        verifiers.clear()
        self._completed.add("runtime_credentials_created")
        return {"ok": True, "secretUids": uids, "roleOids": self._claimed_oids}

    def verify_credentials(self, selected):
        self._phase(selected, ("runtime_credentials_created",) if self._inspected["mode"] == "fresh" else ())
        self.qualify_references(selected)
        self._verify_post_roles(selected)
        claims = self._role_claims(selected)
        require(all(r["passwordAbsent"] is False for r in claims.values()), "native_runtime_credential_absent")
        credentials, uids = [], {}
        for key in ("consumer", "reader", "ingest"):
            ref = selected["secretRefs"][key]
            obj = self._get("secret/" + ref["name"])
            raw = base64.b64decode(obj["data"][ref["key"]], validate=True).decode()
            url = json.loads(raw)[ref["jsonField"]] if ref["jsonField"] else raw
            credentials.append({"role": selected["roles"][key], "url": url})
            uids[key] = obj["metadata"]["uid"]
        try:
            require(self._driver(selected, "credentials", credentials=credentials) == {"ok": True, "verified": 3}, "native_runtime_tls_login_failed")
        finally:
            credentials.clear()
        self._completed.add("runtime_credentials_verified")
        return {"ok": True, "secretUids": uids, "roleOids": {n: r["oid"] for n, r in claims.items()}}
