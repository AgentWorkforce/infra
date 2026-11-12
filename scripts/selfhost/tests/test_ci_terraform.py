"""scripts/selfhost/ci-terraform.sh offline: the real saved-plan runner (aws-environment.py) with fake aws and
terraform. S3 and SSM are directories; the fake Terraform refuses a saved plan whose state serial moved."""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SCRIPT = REPO / "scripts/selfhost/ci-terraform.sh"
_spec = importlib.util.spec_from_file_location("mode_fixtures", REPO / "terraform/modules/aws/search/tests/test_creation_mode.py")
_fixtures = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_fixtures)

ACCOUNT = "111111111111"
SECRET = "SENSITIVE-PASSWORD-VALUE"

FAKE_AWS = r'''
import json, os, sys
from pathlib import Path
root = Path(os.environ["FAKE_ROOT"]); a = sys.argv[1:]
def opt(name):
    return a[a.index(name) + 1] if name in a else None
with open(root / "aws.log", "a") as log: log.write(" ".join(a) + "\n")
if a[:2] == ["sts", "get-caller-identity"]:
    print(json.dumps({"Account": os.environ["FAKE_ACCOUNT"], "Arn": "arn:aws:sts::%s:assumed-role/env-data-github-plan/s" % os.environ["FAKE_ACCOUNT"]}))
elif a[:2] == ["s3api", "head-bucket"]:
    sys.exit(0 if opt("--expected-bucket-owner") == os.environ["FAKE_ACCOUNT"] else 254)
elif a[:2] == ["ssm", "get-parameter"]:
    name, _, version = opt("--name").partition(":")
    versions = sorted((root / "ssm").glob("v*"), key=lambda p: int(p.name[1:]))
    path = root / "ssm" / ("v" + version) if version else versions[-1]
    if not path.exists(): sys.exit(255)
    print(json.dumps({"Parameter": {"Name": name, "Version": int(path.name[1:]), "Value": path.read_text()}}))
elif a[:2] == ["s3api", "put-object"]:
    dest = root / "s3" / opt("--bucket") / opt("--key")
    if "--if-none-match" in a and dest.exists():
        print("PreconditionFailed", file=sys.stderr); sys.exit(254)
    assert opt("--server-side-encryption") == "aws:kms" and opt("--ssekms-key-id"), "unencrypted upload"
    dest.parent.mkdir(parents=True, exist_ok=True); dest.write_bytes(Path(opt("--body")).read_bytes())
elif a[:2] == ["s3api", "get-object"]:
    src = root / "s3" / opt("--bucket") / opt("--key")
    if not src.exists(): sys.exit(254)
    Path(a[-1]).write_bytes(src.read_bytes())
else:
    print("fake aws: unexpected " + " ".join(a), file=sys.stderr); sys.exit(2)
'''

FAKE_TF = r'''
import json, os, sys
from pathlib import Path
root = Path(os.environ["FAKE_ROOT"]); a = [x for x in sys.argv[1:] if not x.startswith("-chdir=")]
serial = root / "state-serial"
with open(root / "tf.log", "a") as log: log.write(" ".join(a) + "\n")
if a[0] == "init":
    Path(os.environ["TF_DATA_DIR"]).mkdir(parents=True, exist_ok=True)
elif a[:2] == ["workspace", "show"]:
    print("default")
elif a[0] == "plan":
    out = next(x for x in a if x.startswith("-out="))[5:]
    Path(out).write_text(json.dumps({"serial": int(serial.read_text()), "nonce": os.urandom(8).hex()}))
    print("Plan: 3 to add, 0 to change, 0 to destroy.")
elif a[:2] == ["show", "-json"]:
    plan = json.loads(os.environ["FAKE_PLAN_JSON"])
    print(json.dumps(plan))
elif a[:2] == ["show", "-no-color"]:
    print("  # aws_eks_pod_identity_association.history_consumer[0] will be created\n  + service_account = \"agent-relay-ingest-edge\"\n  + master_password = (sensitive value)")
elif a[0] == "apply":
    planned = json.loads(Path(a[-1]).read_text())["serial"]
    if planned != int(serial.read_text()):
        print("Error: Saved plan is stale", file=sys.stderr); sys.exit(1)
    serial.write_text(str(planned + 1))
else:
    print("fake terraform: unexpected " + " ".join(a), file=sys.stderr); sys.exit(2)
'''


class CiTerraformTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        os.chmod(self.tmp, 0o700)
        self.fake = self.tmp / "fake"
        (self.fake / "bin").mkdir(parents=True)
        (self.fake / "ssm").mkdir()
        (self.fake / "state-serial").write_text("7")
        for name, body in (("aws", FAKE_AWS), ("terraform", FAKE_TF)):
            p = self.fake / "bin" / name
            p.write_text(f"#!{sys.executable}" + body)
            p.chmod(0o755)
        # A tools checkout: the real runner and search classifier, a stand-in stack.
        self.tools = self.tmp / "tools"
        for rel in ("terraform/scripts/aws-environment.py", "terraform/modules/aws/search/creation_mode.py"):
            (self.tools / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(REPO / rel, self.tools / rel)
        (self.tools / "terraform/examples/aws-environments").mkdir(parents=True)
        (self.tools / "terraform/examples/aws-environments/main.tf").write_text("# stand-in\n")
        git = ["git", "-C", str(self.tools), "-c", "user.email=t@example.com", "-c", "user.name=t"]
        subprocess.run(git[:3] + ["init", "-q"], check=True)
        subprocess.run(git + ["add", "-A"], check=True)
        subprocess.run(git + ["commit", "-qm", "tools"], check=True)
        self.ref = subprocess.check_output(["git", "-C", str(self.tools), "rev-parse", "HEAD"], text=True).strip()
        self.config = self.tmp / "ci.json"
        self.write_config()
        self.put_tfvars({"account_id": ACCOUNT, "region": "us-west-2", "environment": "prod", "history_upload": {"consumer_service_account": "agent-relay-ingest-edge"}})
        self.work = self.tmp / "work"
        plan = _fixtures.fixture(fresh=True)
        plan["resource_changes"].append({"address": "aws_iam_role.history_consumer[0]", "mode": "managed", "type": "aws_iam_role",
                                         "change": {"actions": ["create"], "before": None, "after": {"password": SECRET}}})
        plan["resource_changes"].append({"address": "data.aws_caller_identity.current", "mode": "data", "type": "aws_caller_identity",
                                         "change": {"actions": ["read"], "before": None, "after": {}}})
        self.plan_json = json.dumps(plan)

    def write_config(self, **over):
        cfg = {
            "account_id": ACCOUNT, "aws_region": "us-west-2", "tools_ref": self.ref,
            "tfvars_parameter": "/env-prod/ci-terraform/data-tfvars",
            "backend": {"bucket": "env-tfstate", "key": f"agent-relay/{ACCOUNT}/us-west-2/prod/data.tfstate", "region": "us-west-2",
                        "expected_bucket_owner": ACCOUNT, "encrypt": True, "use_lockfile": True},
            "plan_store": {"bucket": "env-tfstate", "prefix": "ci-plans/prod/data", "kms_key_arn": "arn:aws:kms:us-west-2:111111111111:key/k"},
        }
        cfg.update(over)
        self.config.write_text(json.dumps(cfg))

    def put_tfvars(self, value):
        n = len(list((self.fake / "ssm").glob("v*"))) + 1
        (self.fake / "ssm" / f"v{n}").write_text(json.dumps(value, indent=2))

    def run_script(self, *args, tools_ref=None):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("TF_", "AWS_"))}
        env.update(PATH=f"{self.fake / 'bin'}:{env['PATH']}", FAKE_ROOT=str(self.fake), FAKE_ACCOUNT=ACCOUNT,
                   FAKE_PLAN_JSON=self.plan_json, TOOLS_REF=tools_ref or self.ref, GITHUB_ACTOR="tester")
        return subprocess.run(["bash", str(SCRIPT), args[0], str(self.config), str(self.tools), str(self.work), *args[1:]],
                              env=env, capture_output=True, text=True)

    def fresh_runner(self):
        """A new job: same paths, empty work dir."""
        shutil.rmtree(self.work, ignore_errors=True)

    def plan(self, run_id):
        self.fresh_runner()
        r = self.run_script("plan", run_id)
        self.assertEqual(r.returncode, 0, r.stderr)
        outputs = dict(line.split("=", 1) for line in (self.work / "out/outputs").read_text().split())
        return outputs["plan_sha256"]

    def apply(self, run_id, plan_run, sha):
        self.fresh_runner()
        return self.run_script("apply", run_id, plan_run, sha)

    def store(self, run, name):
        return self.fake / "s3/env-tfstate/ci-plans/prod/data" / run / name

    def tf_applies(self):
        log = self.fake / "tf.log"
        return sum(1 for line in log.read_text().splitlines() if line.startswith("apply")) if log.exists() else 0

    def test_plan_saves_the_run_and_summarizes_without_values(self):
        sha = self.plan("100-1")
        manifest = json.loads(self.store("100-1", "manifest.json").read_text())
        self.assertEqual(manifest["plan_sha256"], sha)
        self.assertEqual(manifest["tools_ref"], self.ref)
        self.assertEqual(manifest["tfvars_version"], "1")
        self.assertTrue(manifest["changes"])
        self.assertTrue(self.store("100-1", "run.tgz").exists())
        summary = (self.work / "out/summary.md").read_text()
        self.assertIn("create  aws_iam_role.history_consumer[0]", summary)
        self.assertIn(sha, summary)
        self.assertNotIn("data.aws_caller_identity", summary)
        for f in (self.work / "out").iterdir():
            self.assertNotIn(SECRET, f.read_text(), f.name)
            if f.name != "plan.txt":  # plan.txt is the reviewed text plan: configuration values, never sensitive ones
                self.assertNotIn("agent-relay-ingest-edge", f.read_text(), f"tfvars values leaked into {f.name}")
        self.assertIn("(sensitive value)", (self.work / "out/plan.txt").read_text())
        self.assertEqual(sorted(p.name for p in (self.work / "out").iterdir()), ["changes.json", "manifest.json", "outputs", "plan.txt", "summary.md"])
        aws_log = (self.fake / "aws.log").read_text()
        self.assertNotIn("apply", (self.fake / "tf.log").read_text())
        self.assertNotIn("data.tfstate --body", aws_log)  # never writes the state object

    def test_apply_runs_the_exact_plan_once(self):
        sha = self.plan("100-1")
        r = self.apply("200-1", "100-1", sha)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.tf_applies(), 1)
        self.assertEqual(json.loads(self.store("100-1", "apply-attempt.json").read_text())["apply_run_id"], "200-1")
        self.assertEqual(json.loads(self.store("100-1", "apply-result.json").read_text())["exit_code"], 0)
        again = self.apply("201-1", "100-1", sha)
        self.assertNotEqual(again.returncode, 0)
        self.assertIn("already had an apply attempt", again.stderr)
        self.assertEqual(self.tf_applies(), 1)

    def test_wrong_digest_is_refused_before_claiming(self):
        self.plan("100-1")
        r = self.apply("200-1", "100-1", "0" * 64)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not the approved", r.stderr)
        self.assertFalse(self.store("100-1", "apply-attempt.json").exists())
        self.assertEqual(self.tf_applies(), 0)

    def test_stale_plan_is_refused_by_terraform(self):
        old = self.plan("100-1")
        new = self.plan("101-1")
        self.assertEqual(self.apply("200-1", "101-1", new).returncode, 0)
        r = self.apply("201-1", "100-1", old)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("stale", r.stderr)
        self.assertEqual(json.loads(self.store("100-1", "apply-result.json").read_text())["exit_code"], 1)

    def test_apply_uses_the_planned_tfvars_version(self):
        sha = self.plan("100-1")
        self.put_tfvars({"account_id": ACCOUNT, "region": "us-west-2", "environment": "prod", "changed": True})
        r = self.apply("200-1", "100-1", sha)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("ssm get-parameter --name /env-prod/ci-terraform/data-tfvars:1", (self.fake / "aws.log").read_text())

    def test_tools_ref_change_requires_a_new_plan(self):
        sha = self.plan("100-1")
        other = "f" * 40
        self.write_config(tools_ref=other)
        r = self.apply("200-1", "100-1", sha)
        self.assertNotEqual(r.returncode, 0)
        r = self.run_script("apply", "200-1", "100-1", sha, tools_ref=other)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("tools checkout is not at TOOLS_REF", r.stderr)
        self.assertEqual(self.tf_applies(), 0)

    def test_tampered_run_is_refused(self):
        sha = self.plan("100-1")
        with open(self.store("100-1", "run.tgz"), "ab") as f:
            f.write(b"x")
        r = self.apply("200-1", "100-1", sha)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("does not match its manifest", r.stderr)
        self.assertEqual(self.tf_applies(), 0)

    def test_backend_change_requires_a_new_plan(self):
        sha = self.plan("100-1")
        cfg = json.loads(self.config.read_text())
        cfg["backend"]["key"] = f"other/{ACCOUNT}/us-west-2/prod/data.tfstate"
        self.config.write_text(json.dumps(cfg))
        r = self.apply("200-1", "100-1", sha)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("backend changed", r.stderr)

    def test_tfvars_for_another_account_are_refused(self):
        self.put_tfvars({"account_id": "222222222222", "region": "us-west-2", "environment": "prod"})
        self.fresh_runner()
        r = self.run_script("plan", "100-1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("differ from ci.json", r.stderr)
        self.assertNotIn("222222222222", r.stdout)

    def test_no_change_plan_cannot_be_applied(self):
        self.plan_json = json.dumps(_fixtures.fixture())
        sha = self.plan("100-1")
        self.assertIn("No changes.", (self.work / "out/summary.md").read_text())
        r = self.apply("200-1", "100-1", sha)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no changes", r.stderr)


if __name__ == "__main__":
    unittest.main()
