"""Causal harness checks; no Docker daemon, database or cluster contacted."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import proof
import stack


class Harness(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="kind-harness-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        scope = patch.object(stack, "ROOT", self.root)
        scope.start()
        self.addCleanup(scope.stop)
        self.local = stack.Stack("core")

    def test_each_acl_attempt_is_fresh_and_a_later_failure_is_not_hidden(self):
        jobs, waited = [], []
        self.local.apply = jobs.append
        def wait(name, seconds):
            waited.append(name)
            if len(waited) == 2:
                raise stack.StackError("current ACL drift")
        self.local.wait_job = wait
        self.local.verify_combined_acl("image@sha256:example")
        with self.assertRaisesRegex(stack.StackError, "current ACL drift"):
            self.local.verify_combined_acl("image@sha256:example")
        self.assertEqual(len(jobs), 2)
        self.assertNotEqual(jobs[0]["metadata"]["name"], jobs[1]["metadata"]["name"])
        self.assertEqual(waited, [j["metadata"]["name"] for j in jobs])

    def test_unexpected_run_and_cleanup_errors_replace_old_success(self):
        report = self.local.state / "proof.json"
        report.write_text('{"result":"PASS","checks":[]}')
        p = proof.Proof(self.local)
        p.state["a"] = {"accessToken": "never-print-this"}
        def run():
            self.assertFalse(report.exists(), "old receipt must be invalidated before preflight")
            raise TypeError("never-print-this")
        def cleanup(phase):
            self.assertEqual(phase, "cleanup")
            raise AttributeError("another-private-value")
        p.run, p.phase = run, cleanup
        self.local.recipe_hash = lambda: "recipe"
        self.local.cmd = lambda args: subprocess.CompletedProcess(args, 0, "revision\n", "")
        self.assertEqual(proof.execute(p), 1)
        result = json.loads(report.read_text())
        self.assertEqual(result["result"], "FAIL")
        self.assertEqual([c["detail"] for c in result["checks"]], ["TypeError", "AttributeError"])
        self.assertNotIn("private", report.read_text())
        self.assertNotIn("never-print", report.read_text())

    def test_leaf_failing_expiry_check_is_reissued_with_the_existing_host_ca(self):
        applied = []
        self.local.apply = lambda doc, chart=False: applied.append(doc)
        self.local.tls()
        ca = (self.local.state / "ca.crt").read_bytes()
        old_key = (self.local.state / "tls.key").read_bytes()
        command = self.local.cmd
        def expiring_leaf(args, **kwargs):
            # Simulate OpenSSL's negative expiry verdict, then exercise real
            # certificate issuance and strict chain verification portably.
            if "-checkend" in args and self.local.state / "tls.crt" in args:
                return subprocess.CompletedProcess(args, 1, "Certificate will expire", "")
            return command(args, **kwargs)
        self.local.cmd = expiring_leaf
        self.local.tls()
        self.local.cmd = command
        self.assertEqual((self.local.state / "ca.crt").read_bytes(), ca)
        self.assertNotEqual((self.local.state / "tls.key").read_bytes(), old_key)
        valid = command(["openssl", "x509", "-in", self.local.state / "tls.crt",
                         "-checkend", "86400", "-noout"], check=False)
        self.assertEqual(valid.returncode, 0)
        self.assertEqual(len(applied), 2)

    def test_scheduled_writer_drains_before_manual_flow_starts(self):
        calls = []
        scheduled = {"metadata": {"name": "scheduled", "ownerReferences": [{"kind": "CronJob", "uid": "owned"}]}, "status": {}}
        listings = iter([[scheduled], [dict(scheduled, status={"conditions": [{"type": "Complete", "status": "True"}]})]])
        p = proof.Proof(self.local)
        def k(*args, **kwargs):
            calls.append(args)
            self.assertEqual(args[:2], ("get", "jobs"))
            return subprocess.CompletedProcess(args, 0, json.dumps({"items": next(listings)}), "")
        self.local.k = k
        with patch.object(proof.time, "sleep") as sleep:
            p.drain_scheduled_flows("owned")
        self.assertEqual(len(calls), 2)
        sleep.assert_called_once_with(2)

    def test_active_scheduled_writer_timeout_refuses_manual_run_and_restores_schedule(self):
        calls = []
        p = proof.Proof(self.local)
        def k(*args, **kwargs):
            calls.append(args)
            if args[:2] == ("get", "cronjob"):
                return subprocess.CompletedProcess(args, 0, json.dumps({"metadata": {"uid": "owned"}, "spec": {}}), "")
            self.assertEqual(args[:2], ("patch", "cronjob"))
            return subprocess.CompletedProcess(args, 0, "", "")
        self.local.k = k
        def refuse(uid):
            raise stack.StackError("scheduled Flow still owns the journal")
        p.drain_scheduled_flows = refuse
        with self.assertRaisesRegex(stack.StackError, "owns the journal"):
            p.flows()
        self.assertFalse(any(c[0] == "create" for c in calls))
        self.assertIn('"suspend":false', calls[-1][-1])


if __name__ == "__main__":
    unittest.main()
