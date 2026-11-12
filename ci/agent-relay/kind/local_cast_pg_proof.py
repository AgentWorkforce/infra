"""Isolated Postgres Relaycast messaging/collector proof beside the local actor lane."""
from datetime import datetime, timezone
import fcntl
import json
from pathlib import Path
import secrets
import sys
import time

from stack import ROOT, NS, StackError, private_json

COLLECTOR_SECRET = "local-telemetry-cast-proof"

ROUNDTRIP = r"""
import fs from 'node:fs';import {randomUUID} from 'node:crypto';
const base='http://127.0.0.1:8787';
async function request(method,path,token,body){
 const response=await fetch(base+path,{method,headers:{authorization:'Bearer '+token,'content-type':'application/json'},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(10000)});
 if(!response.ok)throw Error('request_failed');return await response.json();
}
if(!process.env.RELAYCAST_DATABASE_URL_FILE||process.env.RELAYCAST_DB_PATH)throw Error('postgres_required');
const internal=fs.readFileSync('/run/secrets/relaycast/internal-secret','utf8').trim(),suffix=randomUUID().slice(0,8);
const workspace=await request('POST','/internal/workspaces',internal,{name:'pg-proof-'+suffix});
try{
const a=await request('POST','/v1/agents',workspace.data.api_key,{name:'proof-a-'+suffix});
const b=await request('POST','/v1/agents',workspace.data.api_key,{name:'proof-b-'+suffix});
const marker='local-postgres-proof-'+suffix;
await request('POST','/v1/channels/general/messages',a.data.token,{text:marker});
const messages=await request('GET','/v1/channels/general/messages?limit=50',b.data.token);
if(!JSON.stringify(messages).includes(marker))throw Error('roundtrip_missing');
}finally{
 const response=await fetch(base+'/internal/workspaces/'+encodeURIComponent(workspace.data.workspace_id),{
  method:'DELETE',headers:{authorization:'Bearer '+internal},signal:AbortSignal.timeout(10000)});
 if(response.status!==204)throw Error('workspace_cleanup_failed');
}
console.log(JSON.stringify({postgresConfigured:true,agents:2,messageRoundTrip:true}));
"""


def prove(stack):
    # Establish the owned cluster before reading credentials or writing resources.
    stack.docker(require_space=False)
    stack.owned()
    # Only one companion may emit this fixture's dedicated producer identity.
    # Keep the lock through observation and cleanup, including failed installs.
    with (stack.state / "postgres-cast-proof.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise StackError("Postgres companion proof is already running") from None
        return prove_owned(stack)


def prove_owned(stack):
    selected = json.loads((stack.state / "selection.json").read_text())
    if not selected.get("relaycastBackend"):
        raise StackError("Postgres companion requires a fresh local backend-aware fixture")
    leftovers = json.loads(stack.k("get", "deployments,pods", "-o", "json").stdout)
    for resource in leftovers.get("items", []):
        metadata = resource.get("spec", {}).get("template", {}).get("metadata", {}) if resource.get("kind") == "Deployment" else resource.get("metadata", {})
        if metadata.get("labels", {}).get("local.agentrelay.dev/proof"):
            raise StackError("A prior Postgres companion still exists; verify its cleanup before retrying")
    # Return only a presence marker, never the collector token. Refuse before
    # creating proof resources instead of waiting for a missing Secret mount.
    ready = stack.k("get", "secret", COLLECTOR_SECRET, "--ignore-not-found=true", "-o",
        "go-template={{if .data.token}}ready{{end}}").stdout.strip()
    if ready != "ready":
        raise StackError("Postgres companion collector credential is missing; run local-up before retrying")
    from local_stack import AA_VALUES, CAST_PROOF_DEPLOYMENT, reference, image, pgurl
    c = json.loads((stack.state / "credentials.json").read_text())
    if not all(c.get(key) for key in ("relaycast_owner", "relaycast_runtime")):
        raise StackError("Postgres companion credentials are unavailable; no existing roles are adopted")
    source = stack.cmd(["git", "rev-parse", "HEAD"]).stdout.strip()
    if stack.cmd(["git", "status", "--porcelain", "--untracked-files=no"]).stdout.strip():
        raise StackError("Postgres companion requires a clean tracked observer checkout")
    cluster = stack.cluster_uid(stack.kubeconfig)
    run_id = secrets.token_hex(16)
    release = "cast-pg-proof-" + run_id[:8]
    secret_name = release + "-credentials"
    image_ref = reference(AA_VALUES["relaycast"]["image"])
    started = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    directory = stack.state / "proofs"
    directory.mkdir(mode=0o700, exist_ok=True)
    values_file = directory / (release + ".json")
    record = {"schema": "agent-relay.postgres-cast-proof/v1", "status": "fail", "sourceRevision": source,
              "clusterUid": cluster, "image": image_ref, "startedAt": started}
    uid = None
    try:
        if stack.k("get", "secret", secret_name, "--ignore-not-found=true", "-o", "name").stdout.strip():
            raise StackError("Postgres proof Secret already exists; no resource is adopted")
        stack.secret(secret_name, {"internal-secret": secrets.token_hex(32), "workspace-bootstrap-secret": secrets.token_hex(32),
            "database-owner-url": pgurl("relaycast_owner", c, None, "relaycast"),
            "database-runtime-url": pgurl("relaycast_runtime", c, None, "relaycast")})
        uid = stack.k("get", "secret", secret_name, "-o", "jsonpath={.metadata.uid}").stdout.strip()
        values = {"fullnameOverride": release, "image": image(image_ref), "existingSecret": secret_name,
            "baseUrl": "https://cast.kind.agentrelay.com", "runtime": {"backend": "postgres", "postgres": {"image": image(image_ref)}},
            "postgresCa": {"enabled": True, "configMap": "local-ca", "key": "ca.crt"},
            "analytics": {"enabled": True, "deploymentId": CAST_PROOF_DEPLOYMENT, "collectorUrl": "https://telemetry-collector.agent-relay.svc.cluster.local:8443/v1/events",
                "existingSecret": COLLECTOR_SECRET, "caConfigMap": "local-ca"},
            "persistence": {"size": "64Mi", "annotations": {"helm.sh/resource-policy": None}},
            "podLabels": {"local.agentrelay.dev/proof": run_id}, "networkPolicy": {"enabled": False}, "ingress": {"enabled": False}}
        private_json(values_file, values)
        stack.cmd(["helm", "install", release, "charts/relaycast", "-n", NS, "-f", values_file, "--wait", "--timeout", "10m"], timeout=660)
        observation = json.loads(stack.k("exec", "deployment/" + release, "--", "node", "--input-type=module", "-e", ROUNDTRIP,
            sensitive=True, timeout=60).stdout)
        if observation != {"postgresConfigured": True, "agents": 2, "messageRoundTrip": True}:
            raise StackError("Postgres companion round trip was not proven")
        sys.path.insert(0, str(ROOT / "ci/agent-relay/kind/acceptance"))
        from telemetry import cast_collector
        deadline = time.monotonic() + 30
        while True:
            try:
                collector = cast_collector({"kubeconfig": str(stack.kubeconfig), "historySince": started}, "postgres",
                    deployment_id=CAST_PROOF_DEPLOYMENT)
                break
            except Exception:
                if time.monotonic() >= deadline:
                    raise StackError("Postgres companion collector event was not proven") from None
                time.sleep(1)
        record.update(status="pass", roundTrip=observation, castCollector=collector)
    finally:
        original_failed = sys.exc_info()[0] is not None
        cleanup_failed = False
        # A failed install can still leave a Helm release. Only our unique proof
        # label in its stored values authorizes cleanup of that release.
        try:
            installed = stack.cmd(["helm", "get", "values", release, "-n", NS, "-o", "json"], check=False)
            if installed.returncode == 0:
                owned = json.loads(installed.stdout).get("podLabels", {}).get("local.agentrelay.dev/proof") == run_id
                if owned:
                    stack.cmd(["helm", "uninstall", release, "-n", NS, "--wait", "--timeout", "3m"], timeout=210)
                else:
                    cleanup_failed = True
            elif record["status"] == "pass":
                cleanup_failed = True
        except Exception:
            cleanup_failed = True
        try:
            if uid:
                observed_uid = stack.k("get", "secret", secret_name, "--ignore-not-found=true", "-o", "jsonpath={.metadata.uid}").stdout.strip()
                if observed_uid == uid:
                    stack.k("delete", "secret", secret_name)
                elif observed_uid:
                    cleanup_failed = True
            values_file.unlink(missing_ok=True)
        except Exception:
            cleanup_failed = True
        if cleanup_failed:
            record.update(status="fail", code="postgres_cast_proof_cleanup_failed")
        private_json(directory / "postgres-cast.json", record)
        if cleanup_failed and not original_failed:
            raise StackError("Postgres companion cleanup could not be verified")
    print("Postgres companion: " + json.dumps(record), flush=True)
    return record
