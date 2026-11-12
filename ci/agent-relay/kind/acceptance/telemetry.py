"""Read persisted collector counters; never return event bodies or identifiers."""
import json
import subprocess

from api import Failure, require

ACTOR_REASON = "unsupported on durable-actors (charts/relaycast rejects analytics with actors)"
ACTOR_ISSUE = "https://github.com/AgentWorkforce/relaycast/issues/648"
SCRIPT = r"""
const fs=require('node:fs'),path=require('node:path');
const input=JSON.parse(fs.readFileSync(0,'utf8')),since=Date.parse(input.since),now=Date.now();
if(!Number.isFinite(since)||since>now||typeof input.deploymentId!=='string'||!input.deploymentId)process.exit(2);
const directory='/var/lib/telemetry/segments';
const names=fs.readdirSync(directory).filter(n=>/^\d{13}-\d{10}-[0-9a-f-]{36}\.ndjson$/.test(n));
if(names.length>100000)process.exit(2);
let matchingEvents=0,scannedSegments=0;
for(const name of names){
 const fd=fs.openSync(path.join(directory,name),fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);
 try{
  const stat=fs.fstatSync(fd);
  if(!stat.isFile()||(stat.mode&0o7777)!==0o600||stat.size>262144)process.exit(2);
  scannedSegments++;
  for(const line of fs.readFileSync(fd,'utf8').split('\n')){
   if(!line)continue;
   const event=JSON.parse(line),at=Date.parse(event.occurred_at);
   if(event.component==='relaycast'&&event.deployment_id===input.deploymentId&&Number.isFinite(at)&&at>=since&&at<=now+300000)matchingEvents++;
  }
 }finally{fs.closeSync(fd);}
}
console.log(JSON.stringify({matchingEvents,scannedSegments,privateSegments:true}));
"""


def cast_collector(config, backend, *, deployment_id="local-kind"):
    if backend == "durable-actors":
        return {"id": "cast_collector", "status": "skipped", "reason": ACTOR_REASON,
                "issue": ACTOR_ISSUE, "seconds": 0}
    require(backend in {"sqlite", "postgres"}, "unknown_cast_backend")
    result = subprocess.run(["kubectl", "--kubeconfig", config["kubeconfig"], "-n", "agent-relay",
        "exec", "-i", "deployment/telemetry-collector", "-c", "collector", "--", "node", "-e", SCRIPT],
        input=json.dumps({"since": config["historySince"], "deploymentId": deployment_id}), capture_output=True, text=True, timeout=45)
    require(result.returncode == 0, "cast_collector_observation_failed")
    observed = json.loads(result.stdout)
    require(set(observed) == {"matchingEvents", "scannedSegments", "privateSegments"}
            and observed["privateSegments"] is True
            and type(observed["matchingEvents"]) is int and observed["matchingEvents"] > 0
            and type(observed["scannedSegments"]) is int and observed["scannedSegments"] > 0,
            "cast_collector_events_not_proven")
    return {"id": "cast_collector", "status": "pass", "evidence": {**observed, "deploymentId": deployment_id}}
