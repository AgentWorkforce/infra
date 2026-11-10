"""Control's owned first-boot transport for the native kind orchestrator.

This module neither selects a History credential mode nor implements its own
schema or tenant bootstrap. It uses the qualified Control migration executable
and the application's real first-boot provisioner, then reads the resulting
tenant through the supported operator APIs. No command runs on import.
"""
from copy import deepcopy
import base64
import hashlib
import json
import re
import secrets
from urllib.parse import quote

from native_bootstrap import scram
from native_control_artifact import coordinates as control_coordinates
from native_pipeline import canonical
from native_recipe import NativeRecipeError, nonsecret, require


def control_contract(raw):
    """Validate identity and resource references; credentials are never inputs."""
    value = deepcopy(raw)
    nonsecret(value)
    require(isinstance(value, dict) and set(value) == {
        "version", "administrator", "organizationName", "workspaceName", "owner", "runtime", "cast"
    } and type(value["version"]) is int and value["version"] == 1, "typed_control_bootstrap_contract_required")
    admin = value["administrator"]
    require(isinstance(admin, dict) and set(admin) == {"email", "displayName"} and
            isinstance(admin["email"], str) and len(admin["email"]) <= 254 and
            re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", admin["email"]) and
            all(ord(c) >= 32 and ord(c) != 127 for c in admin["email"]) and
            isinstance(admin["displayName"], str) and 0 < len(admin["displayName"].strip()) <= 128 and
            all(ord(c) >= 32 and ord(c) != 127 for c in admin["displayName"]), "explicit_first_administrator_required")
    require(isinstance(value["organizationName"], str) and
            0 < len(value["organizationName"].strip()) <= 128 and
            all(ord(c) >= 32 and ord(c) != 127 for c in value["organizationName"]) and
            value["workspaceName"] == "Default", "explicit_installation_and_default_workspace_required")
    # Control's first-boot provisioner canonicalizes email addresses this way.
    admin["email"] = admin["email"].lower()
    fields = {
        "owner": {"name", "key", "role"},
        "runtime": {"name", "databaseKey", "role", "bootstrapKey", "encryptionKey", "encryptionKeyId", "castInternalKey", "internalKey", "introspectionKey", "readerIssuerKey"},
        "cast": {"name", "internalKey", "bootstrapKey"},
    }
    for part, names in fields.items():
        item = value[part]
        require(isinstance(item, dict) and set(item) == names, "unexpected_control_secret_reference_fields")
        require(isinstance(item["name"], str) and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", item["name"]),
                "control_secret_name_required")
        for name in names - {"name", "role", "encryptionKeyId"}:
            require(isinstance(item[name], str) and re.fullmatch(r"[A-Za-z0-9._-]{1,128}", item[name]),
                    "control_secret_key_required")
    require(value["owner"]["role"] == "control_owner" and value["runtime"]["role"] == "control_api_runtime" and
            len({value[n]["name"] for n in fields}) == 3, "separate_control_owner_runtime_and_cast_secrets_required")
    runtime = value["runtime"]
    keys = [runtime[n] for n in fields["runtime"] - {"name", "role", "encryptionKeyId"}]
    require(len(set(keys)) == len(keys) and value["owner"]["key"] not in keys and
            value["cast"]["internalKey"] != value["cast"]["bootstrapKey"] and
            re.fullmatch(r"[A-Za-z0-9_-]{1,64}", runtime["encryptionKeyId"]), "separate_control_credential_keys_required")
    return value


CONTROL_OBSERVER = r"""
const fs=require('node:fs');
let raw='';process.stdin.on('data',b=>raw+=b);process.stdin.on('end',async()=>{
 try{
  const x=JSON.parse(raw), uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
  const bearer=fs.readFileSync('/var/run/agent-relay/secrets/'+x.bootstrapKey,'utf8').trim();
  if(!bearer||bearer.length<32)throw Error('credential');
  async function get(path,auth=true){
   const r=await fetch('http://127.0.0.1:3000'+path,{method:'GET',redirect:'error',
    signal:AbortSignal.timeout(15000),headers:auth?{authorization:'Bearer '+bearer}:undefined});
   if(r.status!==200)throw Error('status');return r.json();
  }
  const health=await get('/healthz',false),ready=await get('/readyz',false);
  if(health.status!=='ok'&&health.ok!==true)throw Error('health');
  if(!ready.capabilities||Object.keys(ready.capabilities).sort().join(',')!=='chief,flows,relayfile'||Object.values(ready.capabilities).some(v=>v!==false))throw Error('optional-features');
  if(ready.status!=='ready'||!ready.introspection?.enabled||
   !ready.introspection.audiences?.includes(x.historyOrigin))throw Error('ready');
  const orgs=(await get('/api/v1/organizations')).organizations;
  if(!Array.isArray(orgs)||orgs.length!==1||orgs[0].name!==x.organizationName||!uuid.test(orgs[0].id))throw Error('organization');
  const organizationId=orgs[0].id;
  const workspaces=(await get('/api/v1/organizations/'+organizationId+'/workspaces')).workspaces;
  if(!Array.isArray(workspaces)||workspaces.length!==1||workspaces[0].name!=='Default'||!uuid.test(workspaces[0].id))throw Error('workspace');
  const members=(await get('/api/v1/organizations/'+organizationId+'/memberships')).memberships;
  if(!Array.isArray(members)||!members.some(m=>m.email===x.administratorEmail&&m.role==='owner'))throw Error('administrator');
  console.log('NATIVE_CONTROL_OBSERVATION '+JSON.stringify({organizationId,workspaceId:workspaces[0].id}));
 }catch{console.error('native_control_observation_refused');process.exitCode=1}
});
"""


class NativeControlTransport:
    """Mixin over NativePipelineAdapter; intentionally not a standalone deployer."""

    def _configure_control(self, raw):
        self.control = control_contract(raw)
        self._control_contract_sha = hashlib.sha256(canonical(self.control).encode()).hexdigest()
        self._control_claim_attempted = False
        self._control_migration = None
        self._tenant = None

    def _control_bound(self, selected):
        require(control_contract(self.control) == self.control and
                hashlib.sha256(canonical(self.control).encode()).hexdigest() == self._control_contract_sha,
                "control_bootstrap_contract_changed")
        reserved = {r["name"] for r in selected["secretRefs"].values()} | {
            self.ADMIN_SECRET, self.SERVER_TLS_SECRET, self.HBA_CONFIG, "kind-tls", selected["postgresCa"]["configMap"]}
        require(not reserved.intersection({self.control[n]["name"] for n in ("owner", "runtime", "cast")}),
                "control_secret_reference_collision")

    def _control_roles(self, selected):
        raw = self._psql(selected, "relaycontrol", """SELECT coalesce(json_agg(json_build_object(
'name',rolname,'oid',oid::int,'login',rolcanlogin,'passwordAbsent',rolpassword IS NULL,
'safe',NOT(rolsuper OR rolbypassrls OR rolcreatedb OR rolcreaterole OR rolreplication OR rolinherit),
'settingsAbsent',NOT EXISTS(SELECT 1 FROM pg_db_role_setting WHERE setrole=r.oid) AND rolvaliduntil IS NULL,
'ownsDatabase',oid=(SELECT datdba FROM pg_database WHERE datname=current_database())))::text,'[]')
FROM pg_authid r WHERE rolname IN ('control_owner','control_api_runtime');""", read_only=True)
        rows = json.loads(raw.strip())
        require(isinstance(rows, list) and len(rows) == 2 and
                {r.get("name") for r in rows} == {"control_owner", "control_api_runtime"} and
                all(type(r.get("oid")) is int and r["oid"] > 0 and r.get("safe") is True and
                    r.get("settingsAbsent") is True for r in rows), "exact_control_role_identity_required")
        result = {r["name"]: r for r in rows}
        require(result["control_owner"]["ownsDatabase"] is True and
                result["control_api_runtime"]["ownsDatabase"] is False, "control_database_owner_runtime_boundary_required")
        return result

    def _claim_control_credentials(self, selected):
        self._control_bound(selected)
        require(not self._control_claim_attempted, "partial_control_claim_requires_explicit_review")
        roles = self._control_roles(selected)
        require(all(r["login"] is False and r["passwordAbsent"] is True for r in roles.values()),
                "control_roles_must_be_unclaimed_before_credentials")
        names = [self.control[n]["name"] for n in ("owner", "runtime", "cast")]
        introspect = selected["secretRefs"]["introspection"]
        issuer = selected["secretRefs"]["readerIssuer"]
        names.extend((introspect["name"], issuer["name"]))
        for name in names:
            require(not self._transport_call("k", "get", "secret", name, "--ignore-not-found=true", "-o", "name", sensitive=True).stdout.strip(),
                    "prior_control_credential_requires_review")
        self._control_claim_attempted = True
        passwords = {r: secrets.token_urlsafe(48) for r in roles}
        require(len(set(passwords.values())) == 2, "control_passwords_must_differ")
        def url(role):
            return ("postgresql://" + role + ":" + passwords[role] + "@" + selected["postgres"]["host"] +
                    ":5432/relaycontrol?sslmode=verify-full&sslrootcert=" + quote("/etc/postgres-ca/ca.crt", safe=""))
        owner, runtime, cast = (self.control[n] for n in ("owner", "runtime", "cast"))
        cast_internal = secrets.token_urlsafe(48)
        introspection = secrets.token_urlsafe(48)
        reader_issuer = secrets.token_urlsafe(48)
        require(len({cast_internal, introspection, reader_issuer}) == 3, "distinct_service_authorities_required")
        self._secret(owner["name"], {owner["key"]: url("control_owner")})
        self._secret(runtime["name"], {runtime["databaseKey"]: url("control_api_runtime"),
            runtime["bootstrapKey"]: secrets.token_urlsafe(48), runtime["encryptionKey"]: secrets.token_hex(32),
            runtime["castInternalKey"]: cast_internal, runtime["internalKey"]: secrets.token_urlsafe(48),
            runtime["introspectionKey"]: introspection, runtime["readerIssuerKey"]: reader_issuer})
        self._secret(cast["name"], {cast["internalKey"]: cast_internal, cast["bootstrapKey"]: secrets.token_urlsafe(48)})
        self._secret(introspect["name"], {introspect["key"]: introspection})
        self._secret(issuer["name"], {issuer["key"]: reader_issuer})
        del introspection, reader_issuer, cast_internal
        statements = ["BEGIN; SET LOCAL log_statement='none'; SET LOCAL log_min_error_statement='panic';",
                      "SET LOCAL lock_timeout='5s'; LOCK TABLE pg_catalog.pg_authid IN SHARE ROW EXCLUSIVE MODE;",
                      "LOCK TABLE pg_catalog.pg_db_role_setting IN SHARE MODE;"]
        for role in ("control_owner", "control_api_runtime"):
            oid = roles[role]["oid"]
            statements.append("DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_authid r WHERE oid=" + str(oid) +
                " AND rolname='" + role + "' AND NOT(rolcanlogin OR rolsuper OR rolbypassrls OR rolcreatedb OR rolcreaterole OR rolreplication OR rolinherit) AND rolpassword IS NULL AND NOT EXISTS(SELECT 1 FROM pg_db_role_setting WHERE setrole=r.oid) AND rolvaliduntil IS NULL) THEN RAISE EXCEPTION 'control role claim changed'; END IF; END $$;")
            statements.append("ALTER ROLE " + role + " LOGIN PASSWORD '" + scram(passwords[role]) + "';")
        self._psql(selected, "relaycontrol", "\n".join(statements) + "\nCOMMIT;\n")
        passwords.clear()
        claimed = self._control_roles(selected)
        require(all(r["login"] is True and r["passwordAbsent"] is False and r["oid"] == roles[n]["oid"]
                    for n, r in claimed.items()), "control_role_claim_unconfirmed")
        self._completed.add("control_credentials")

    def _control_migration_document(self, selected):
        owner = self.control["owner"]
        identity = hashlib.sha256(canonical({"control": selected["control"], "owner": owner,
            "runtime": self.control["runtime"]["role"], "ca": selected["postgresCa"]}).encode()).hexdigest()[:16]
        name = "native-control-migrate-" + identity
        container = {"name": "migrate", "image": selected["control"]["reference"], "imagePullPolicy": "Never",
            "command": ["node", "/app/node_modules/relay-control/dist/migrate-cli.js"],
            "env": [{"name": "DATABASE_MIGRATIONS_URL_FILE", "value": "/var/run/native-control-owner/" + owner["key"]},
                    {"name": "SELFHOST_RUNTIME_DATABASE_ROLE", "value": "control_api_runtime"},
                    {"name": "NODE_EXTRA_CA_CERTS", "value": "/etc/postgres-ca/ca.crt"}],
            "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}},
            "volumeMounts": [{"name": "owner", "mountPath": "/var/run/native-control-owner", "readOnly": True},
                             {"name": "ca", "mountPath": "/etc/postgres-ca", "readOnly": True},
                             {"name": "tmp", "mountPath": "/tmp"}],
            "resources": {"requests": {"cpu": "50m", "memory": "128Mi"}, "limits": {"memory": "512Mi"}}}
        return {"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": name, "namespace": "agent-relay"},
            "spec": {"backoffLimit": 0, "activeDeadlineSeconds": 600,
                "template": {"metadata": {"labels": {"kind.agentrelay.dev/native-phase": "control-migrate"}}, "spec": {
                    "restartPolicy": "Never", "automountServiceAccountToken": False,
                    "securityContext": {"runAsNonRoot": True, "runAsUser": 1000, "runAsGroup": 1000, "fsGroup": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
                    "containers": [container], "volumes": [
                        {"name": "owner", "secret": {"secretName": owner["name"], "defaultMode": 0o440,
                            "items": [{"key": owner["key"], "path": owner["key"]}]}},
                        {"name": "ca", "configMap": {"name": selected["postgresCa"]["configMap"],
                            "items": [{"key": selected["postgresCa"]["key"], "path": "ca.crt"}]}},
                        {"name": "tmp", "emptyDir": {"sizeLimit": "64Mi"}}]}}}}

    def _verify_control_ledger(self, selected):
        expected = control_coordinates(self.inputs, selected["control"], selected["architecture"])["migration"]
        require(expected["source"] == selected["control"]["sourceRevision"], "control_schema_source_changed")
        require(expected["ledger"] in {"selfhost_schema_migrations", "control_schema_migrations"}, "qualified_control_ledger_required")
        actual = self._psql(selected, "relaycontrol", "SELECT coalesce(json_object_agg(name,checksum)::text,'{}') FROM public." + expected["ledger"] + ";", read_only=True)
        require(json.loads(actual.strip()) == expected["sql"], "control_schema_ledger_must_match_qualified_source_exactly")

    def _observe_control(self, selected, pod):
        runtime = self.control["runtime"]
        data = {"bootstrapKey": runtime["bootstrapKey"], "organizationName": self.control["organizationName"],
                "administratorEmail": self.control["administrator"]["email"], "historyOrigin": selected["historyOrigin"]}
        output = self._transport_call("k", "exec", "-i", pod, "-c", "api", "--", "node", "-e", CONTROL_OBSERVER,
                                      data=json.dumps(data), sensitive=True, timeout=90).stdout
        lines = [line.removeprefix("NATIVE_CONTROL_OBSERVATION ") for line in output.splitlines()
                 if line.startswith("NATIVE_CONTROL_OBSERVATION ")]
        require(len(lines) == 1, "official_control_tenant_observation_required")
        value = json.loads(lines[0])
        require(set(value) == {"organizationId", "workspaceId"} and all(re.fullmatch(
            r"[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}", x) for x in value.values()),
            "real_control_tenant_identity_required")
        return value
