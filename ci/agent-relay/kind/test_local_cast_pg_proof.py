from types import SimpleNamespace
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from local_cast_pg_proof import COLLECTOR_SECRET, ROUNDTRIP, prove, prove_owned
from stack import StackError


class PostgresProofBoundaryTests(unittest.TestCase):
    def test_roundtrip_accepts_image_sqlite_fallback_only_with_a_postgres_url(self):
        with tempfile.TemporaryDirectory() as tmp:
            token = Path(tmp) / "internal-secret"
            token.write_text("synthetic-internal-token")
            program = ROUNDTRIP.replace("/run/secrets/relaycast/internal-secret", str(token))
            server = r"""
import http from 'node:http';
let text='',calls=0;
const server=http.createServer(async(req,res)=>{
 calls++;let raw='';for await(const chunk of req)raw+=chunk;
 const body=raw?JSON.parse(raw):{};let data={},status=200;
 if(req.method==='POST'&&req.url==='/internal/workspaces'){data={api_key:'fixture',workspace_id:'fixture'};status=201;}
 else if(req.method==='POST'&&req.url==='/v1/agents'){data={token:'fixture-agent'};status=201;}
 else if(req.method==='POST'&&req.url==='/v1/channels/general/messages'){text=body.text;status=201;}
 else if(req.method==='GET'&&req.url.startsWith('/v1/channels/general/messages'))data={text};
 else if(req.method==='DELETE'&&req.url==='/internal/workspaces/fixture'){res.writeHead(204);res.end();return;}
 else status=404;
 res.writeHead(status,{'content-type':'application/json'});res.end(JSON.stringify({ok:status<400,data}));
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
try{await import('data:text/javascript,'+encodeURIComponent(PROGRAM.replace('http://127.0.0.1:8787','http://127.0.0.1:'+server.address().port)));}
finally{server.closeAllConnections();await new Promise(resolve=>server.close(resolve));console.log(JSON.stringify({calls}));}
"""
            script = server.replace("PROGRAM", json.dumps(program))
            environment = {k: v for k, v in os.environ.items() if not k.startswith("RELAYCAST_")}
            environment["RELAYCAST_DB_PATH"] = "/data/relaycast.db"
            for postgres in (True, False):
                with self.subTest(postgres=postgres):
                    selected = {**environment, **({"RELAYCAST_DATABASE_URL_FILE": "/fixture/runtime-url"} if postgres else {})}
                    result = subprocess.run(["node", "--input-type=module", "-e", script], env=selected,
                        capture_output=True, text=True, timeout=15)
                    observations = [json.loads(line) for line in result.stdout.splitlines()]
                    if postgres:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(observations[0], {"postgresConfigured": True, "agents": 2, "messageRoundTrip": True})
                        self.assertEqual(observations[1], {"calls": 6})
                    else:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("postgres_required", result.stderr)
                        self.assertEqual(observations, [{"calls": 0}])

    def test_foreign_cluster_is_refused_before_credentials_or_resources(self):
        calls = []
        def owned():
            calls.append("owned")
            raise StackError("foreign cluster")
        stack = SimpleNamespace(docker=lambda **kw: calls.append("docker"), owned=owned)
        with self.assertRaisesRegex(StackError, "foreign cluster"):
            prove(stack)
        self.assertEqual(calls, ["docker", "owned"])

    def test_concurrent_companion_cannot_share_the_registered_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            stack = SimpleNamespace(state=state, docker=lambda **kw: None, owned=lambda: None)
            with (state / "postgres-cast-proof.lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaisesRegex(StackError, "already running"):
                    prove(stack)

    def test_leftover_companion_refuses_before_new_resources_or_credentials(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            (state / "selection.json").write_text(json.dumps({"relaycastBackend": "sqlite"}))
            for resource in ({"kind": "Deployment", "spec": {"template": {"metadata": {
                    "labels": {"local.agentrelay.dev/proof": "prior-run"}}}}},
                    {"kind": "Pod", "metadata": {"labels": {"local.agentrelay.dev/proof": "prior-run"}}}):
                stack = SimpleNamespace(state=state, k=lambda *args: SimpleNamespace(stdout=json.dumps({"items": [resource]})))
                with self.assertRaisesRegex(StackError, "prior Postgres companion"):
                    prove_owned(stack)

    def test_missing_collector_secret_refuses_before_any_proof_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            (state / "selection.json").write_text(json.dumps({"relaycastBackend": "postgres"}))
            calls = []
            def read(*args):
                calls.append(args)
                if args == ("get", "deployments,pods", "-o", "json"):
                    return SimpleNamespace(stdout=json.dumps({"items": []}))
                self.assertEqual(args, ("get", "secret", COLLECTOR_SECRET, "--ignore-not-found=true", "-o",
                    "go-template={{if .data.token}}ready{{end}}"))
                return SimpleNamespace(stdout="")
            stack = SimpleNamespace(state=state, k=read,
                secret=lambda *args: self.fail("created proof credentials before preflight"),
                cmd=lambda *args, **kw: self.fail("ran Helm or another command before preflight"))
            with self.assertRaisesRegex(StackError, "collector credential is missing"):
                prove_owned(stack)
            self.assertEqual(len(calls), 2)


if __name__ == "__main__":
    unittest.main()
