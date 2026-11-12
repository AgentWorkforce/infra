from types import SimpleNamespace
import fcntl
import json
from pathlib import Path
import tempfile
import unittest

from local_cast_pg_proof import prove, prove_owned
from stack import StackError


class PostgresProofBoundaryTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
