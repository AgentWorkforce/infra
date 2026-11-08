import importlib.util
import base64
import contextlib
import io
import os
import subprocess
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("aws_environment", Path(__file__).with_name("aws-environment.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
_mode_test_spec = importlib.util.spec_from_file_location("mode_fixtures", Path(__file__).resolve().parents[1] / "modules/aws/search/tests/test_creation_mode.py")
_mode_fixtures = importlib.util.module_from_spec(_mode_test_spec)
_mode_test_spec.loader.exec_module(_mode_fixtures)



class EnvironmentBoundaryTests(unittest.TestCase):
    def setUp(self):
        cache = Path("/Volumes/T7/Projects/AgentWorkforce/.cache")
        self.temp = tempfile.TemporaryDirectory(dir=cache if cache.exists() else None)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.variables = self.root / "dev.tfvars.json"
        self.backend = self.root / "dev.backend.json"
        self.variables.write_text(json.dumps({"account_id": "111111111111", "environment": "dev", "region": "us-west-2"}))
        self.config = {"bucket": "company-terraform-state", "key": "agent-relay/111111111111/us-west-2/dev/data.tfstate", "region": "us-west-2", "encrypt": True, "use_lockfile": True, "expected_bucket_owner": "111111111111"}
        self.write_backend()

    def write_backend(self):
        self.backend.write_text(json.dumps(self.config))

    def test_environment_pair_is_accepted(self):
        variables, backend = runner.read_inputs(self.variables, self.backend)
        self.assertEqual(variables["environment"], "dev")
        self.assertIn("/dev/", backend["key"])

    def test_production_backend_cannot_be_used_for_dev(self):
        self.config["key"] = self.config["key"].replace("/dev/", "/prod/")
        self.write_backend()
        with self.assertRaises(runner.Refused):
            runner.read_inputs(self.variables, self.backend)

    def test_other_account_backend_cannot_be_used(self):
        self.config["key"] = self.config["key"].replace("111111111111", "222222222222")
        self.write_backend()
        with self.assertRaises(runner.Refused):
            runner.read_inputs(self.variables, self.backend)

    def test_other_region_backend_cannot_be_used(self):
        self.config["key"] = self.config["key"].replace("/us-west-2/", "/us-east-1/")
        self.write_backend()
        with self.assertRaises(runner.Refused):
            runner.read_inputs(self.variables, self.backend)

    def test_backend_cannot_smuggle_credentials_or_a_profile(self):
        for key in ("access_key", "secret_key", "profile", "assume_role"):
            with self.subTest(key=key):
                self.config[key] = "not-a-credential"
                self.write_backend()
                with self.assertRaises(runner.Refused):
                    runner.read_inputs(self.variables, self.backend)
                del self.config[key]

    def test_locking_and_encryption_cannot_be_disabled(self):
        for key in ("encrypt", "use_lockfile"):
            self.config[key] = False
            self.write_backend()
            with self.assertRaises(runner.Refused):
                runner.read_inputs(self.variables, self.backend)
            self.config[key] = True

    def test_wrong_caller_account_is_refused(self):
        with self.assertRaises(runner.Refused):
            runner.verify_caller({"account_id": "111111111111"}, {"Account": "222222222222"}, {})

    def test_pippen_lease_cannot_be_substituted(self):
        variables = {"account_id": "111111111111", "name_prefix": "pippen-sbx-ar", "pippen": {"agent": "aws-proof", "session_id": "00000000-0000-4000-8000-000000000000"}}
        caller = {"Account": "111111111111", "Arn": "arn:aws:sts::111111111111:assumed-role/agent-session/agent-00000000-0000-4000-8000-000000000000"}
        environ = {"PIPPEN_SANDBOX_ACCOUNT_ID": "111111111111", "PIPPEN_SANDBOX_SESSION_ID": "00000000-0000-4000-8000-000000000000", "PIPPEN_SANDBOX_AGENT_ID": "aws-proof"}
        runner.verify_caller(variables, caller, environ)
        environ["PIPPEN_SANDBOX_SESSION_ID"] = "other"
        with self.assertRaises(runner.Refused):
            runner.verify_caller(variables, caller, environ)

    def test_pippen_execution_cannot_omit_lease_configuration(self):
        variables = {"account_id": "111111111111"}
        caller = {"Account": "111111111111", "Arn": "arn:aws:sts::111111111111:assumed-role/agent-session/agent-00000000-0000-4000-8000-000000000000"}
        for key in ("PIPPEN_SANDBOX_ACCOUNT_ID", "PIPPEN_SANDBOX_SESSION_ID", "PIPPEN_SANDBOX_AGENT_ID"):
            with self.subTest(key=key), self.assertRaises(runner.Refused):
                runner.verify_caller(variables, caller, {key: "present"})
        runner.verify_caller(variables, {"Account": "111111111111", "Arn": "arn:aws:sts::111111111111:assumed-role/customer-deployer/session"}, {})

    def test_apply_requires_exact_plan_and_unchanged_inputs(self):
        plan, receipt = self.root / "plan", self.root / "receipt.json"
        plan.write_bytes(b"synthetic plan")
        binding = runner.plan_binding(self.variables, self.backend, self.root)
        sha = runner.digest(plan)
        receipt.write_text(json.dumps({**binding, "plan_sha256": sha}))
        runner.verify_plan(plan, receipt, binding, sha)
        with self.assertRaises(runner.Refused):
            runner.verify_plan(plan, receipt, binding, "wrong-plan")
        self.variables.write_text(self.variables.read_text() + "\n")
        with self.assertRaises(runner.Refused):
            runner.verify_plan(plan, receipt, runner.plan_binding(self.variables, self.backend, self.root), sha)

    def test_changed_module_invalidates_saved_plan(self):
        source = self.root / "main.tf"
        source.write_text('resource "terraform_data" "test" {}')
        before = runner.source_digest(self.root)
        source.write_text('resource "terraform_data" "different" {}')
        self.assertNotEqual(before, runner.source_digest(self.root))

    def test_native_and_json_configuration_create_change_delete_affect_seal(self):
        for filename in ("override.tf.json", "override.tofu", "override.tofu.json"):
            with self.subTest(filename=filename):
                path = self.root / filename
                absent = runner.source_digest(self.root)
                path.write_text('{}')
                created = runner.source_digest(self.root)
                self.assertNotEqual(absent, created)
                path.write_text('{"changed":true}')
                self.assertNotEqual(created, runner.source_digest(self.root))
                path.unlink()
                self.assertEqual(absent, runner.source_digest(self.root))

    def test_native_and_json_configuration_symlink_is_not_a_source_seal(self):
        target = self.root / "untracked.json"
        target.write_text('{}')
        for filename in ("override.tf.json", "override.tofu", "override.tofu.json"):
            with self.subTest(filename=filename):
                link = self.root / filename
                link.symlink_to(target)
                with self.assertRaises(runner.Refused):
                    runner.source_digest(self.root)
                link.unlink()

    def test_private_receipt_permissions(self):
        path = self.root / "receipt.json"
        runner.private_json(path, {"environment": "dev"})
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_dependency_lock_and_runner_changes_invalidate_plan(self):
        for filename in (".terraform.lock.hcl", "aws-environment.py", "terraform.tfvars.json", "override.tf.json", "modules/aws/search/creation_mode.py"):
            with self.subTest(filename=filename):
                path = self.root / filename
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("before")
                before = runner.source_digest(self.root)
                path.write_text("after")
                self.assertNotEqual(before, runner.source_digest(self.root))

    def test_local_lambda_bytes_must_match_package_hash(self):
        import base64
        artifact = self.root / "pipeline.zip"
        artifact.write_bytes(b"reviewed artifact")
        values = json.loads(self.variables.read_text())
        values["lambda_package"] = {"filename": str(artifact), "source_code_hash": base64.b64encode(bytes.fromhex(runner.digest(artifact))).decode()}
        self.variables.write_text(json.dumps(values))
        runner.plan_binding(self.variables, self.backend, self.root)
        artifact.write_bytes(b"different artifact")
        with self.assertRaises(runner.Refused):
            runner.plan_binding(self.variables, self.backend, self.root)

    def test_cached_workspace_stops_before_plan_or_apply(self):
        replies = [json.dumps({"Account": "111111111111"}).encode(), b"prod\n"]
        with patch.dict(runner.os.environ, {"TF_BIN": "terraform", "TF_WORKSPACE": "default"}), patch.object(runner.subprocess, "check_output", side_effect=replies), patch.object(runner.subprocess, "run") as run:
            with self.assertRaises(runner.Refused):
                runner.main(["plan", "--variables", str(self.variables), "--backend", str(self.backend), "--run-dir", str(self.root / "runs")])
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0][2], "init")

    def test_injected_flags_and_variables_are_removed(self):
        replies = [json.dumps({"Account": "111111111111"}).encode(), b"default\n"]
        with patch.dict(runner.os.environ, {"TF_BIN": "terraform", "TF_WORKSPACE": "default", "TF_CLI_ARGS_init": "-backend=false", "TF_VAR_account_id": "222222222222"}), patch.object(runner.subprocess, "check_output", side_effect=replies), patch.object(runner.subprocess, "run") as run:
            runner.main(["init", "--variables", str(self.variables), "--backend", str(self.backend), "--run-dir", str(self.root / "runs")])
            environment = run.call_args.kwargs["env"]
            self.assertNotIn("TF_CLI_ARGS_init", environment)
            self.assertNotIn("TF_VAR_account_id", environment)
            self.assertIn("-lockfile=readonly", run.call_args.args[0])


class StagedPlanLifecycleTests(unittest.TestCase):
    write_backend = EnvironmentBoundaryTests.write_backend

    def setUp(self):
        EnvironmentBoundaryTests.setUp(self)
        self.source = self.root / "source"
        self.stack = self.source / "examples" / "aws-environments"
        self.stack.mkdir(parents=True)
        (self.stack / "main.tf").write_text('terraform { backend "s3" {} }')
        (self.stack / ".terraform.lock.hcl").write_text("reviewed lock")
        self.artifact = self.root / "pipeline.zip"
        self.artifact.write_bytes(b"reviewed ZIP bytes")
        value = json.loads(self.variables.read_text())
        value["lambda_package"] = {"filename": str(self.artifact), "source_code_hash": base64.b64encode(bytes.fromhex(runner.digest(self.artifact))).decode()}
        self.variables.write_text(json.dumps(value))
        self.directory = self.root / "runs" / "111111111111" / "us-west-2" / "dev"
        self.calls = []
        self.hook = None
        self.fail_apply = False
        self.plan_payload = _mode_fixtures.fixture(False, fresh=True)
        self.shows = []
        self.environment = {"TF_BIN": "terraform"}

    def command(self, command, approval=None):
        args = [command, "--variables", str(self.variables), "--backend", str(self.backend), "--run-dir", str(self.root / "runs")]
        if approval is not None:
            args += ["--approve-plan", approval]
        def output(args, **kwargs):
            if args[0] == "aws":
                return json.dumps({"Account": "111111111111", "Arn": "arn:aws:sts::111111111111:assumed-role/customer-deployer/test"}).encode()
            if args[2:4] == ["show", "-json"]:
                self.shows.append(args)
                if self.hook:
                    self.hook("show", args, kwargs["env"])
                return json.dumps(self.plan_payload).encode()
            self.assertEqual(args[2:], ["workspace", "show"])
            return b"default\n"
        def run(args, **kwargs):
            self.calls.append((args, kwargs["env"]))
            operation = args[2]
            if operation == "plan":
                variables = Path(next(x.split("=", 1)[1] for x in args if x.startswith("-var-file=")))
                effective = json.loads(variables.read_text())
                package = effective.get("lambda_package")
                staged = Path(package["filename"]) if package and package.get("filename") else None
                if staged:
                    self.assertNotEqual(staged, self.artifact)
                    self.assertEqual(staged.read_bytes(), b"reviewed ZIP bytes")
                target = Path(next(x.split("=", 1)[1] for x in args if x.startswith("-out=")))
                target.write_bytes(b"synthetic saved plan using " + str(staged).encode())
            if self.hook:
                self.hook(operation, args, kwargs["env"])
            if operation == "apply" and self.fail_apply:
                raise subprocess.CalledProcessError(1, args)
        with patch.dict(runner.os.environ, self.environment, clear=True), patch.object(runner, "ROOT", self.source), patch.object(runner, "STACK", self.stack), patch.object(runner.subprocess, "check_output", side_effect=output), patch.object(runner.subprocess, "run", side_effect=run), contextlib.redirect_stdout(io.StringIO()):
            return runner.main(args)

    def receipt(self):
        return json.loads((self.directory / "plan-receipt.json").read_text())

    def applied(self):
        return any(args[2] == "apply" for args, _ in self.calls)

    def test_search_history_gate_precedes_receipt_and_apply_consumption(self):
        self.plan_payload = _mode_fixtures.fixture(True, enrolled=False)
        _mode_fixtures.change(self.plan_payload, _mode_fixtures.g.MARKER)["after"]["input"] = False
        with self.assertRaises(runner.Refused): self.command("plan")
        self.assertFalse((self.directory / "plan-receipt.json").exists())
        self.plan_payload = _mode_fixtures.fixture(False, enrolled=False, legacy=True)
        self.command("plan")
        receipt = self.receipt()
        self.assertEqual(receipt["schema_version"], 3)
        self.assertEqual(receipt["search_mode_history"], "legacy-or-missing-marker unchanged-domain")
        original = (self.directory / "plan-receipt.json").read_bytes()
        self.plan_payload["resource_changes"][0]["change"]["before"] = {"id":"foreign-id"}
        with self.assertRaises(runner.Refused): self.command("apply", receipt["plan_sha256"])
        self.assertEqual((self.directory / "plan-receipt.json").read_bytes(), original)
        self.assertFalse(self.applied())
        self.assertGreaterEqual(len(self.shows), 3)

    def test_show_side_effects_cannot_bypass_final_seals(self):
        for kind in ("plan", "source", "staged", "derived"):
            with self.subTest(kind=kind):
                self.setUp(); self.command("plan"); receipt=self.receipt()
                self.hook=lambda op,args,env:self.mutate(kind) if op == "show" else None
                with self.assertRaises(runner.Refused): self.command("apply",receipt["plan_sha256"])
                self.assertFalse(self.applied())
                self.assertTrue((self.directory / "plan-receipt.json").exists())

    def test_plan_references_staged_bytes_and_private_derived_variables(self):
        original = self.variables.read_bytes()
        self.command("plan")
        receipt = self.receipt()
        effective = Path(receipt["effective_variables_path"])
        artifact = Path(receipt["artifact_path"])
        self.assertEqual(json.loads(effective.read_text())["lambda_package"]["filename"], str(artifact))
        self.assertEqual(artifact.read_bytes(), self.artifact.read_bytes())
        self.assertEqual(effective.stat().st_mode & 0o777, 0o400)
        self.assertEqual(artifact.stat().st_mode & 0o777, 0o400)
        self.assertEqual(self.variables.read_bytes(), original)
        self.assertEqual(receipt["variables_path"], str(self.variables))
        self.command("apply", receipt["plan_sha256"])
        self.assertTrue(self.applied())
        self.assertFalse((self.directory / "plan-receipt.json").exists())
        self.assertTrue((Path(receipt["plan_path"]).parent / "apply-attempt-receipt.json").is_file())

    def mutate(self, kind):
        if kind == "artifact":
            self.artifact.write_bytes(b"different ZIP")
        elif kind == "variables":
            self.variables.write_text(self.variables.read_text() + "\n")
        elif kind == "backend":
            self.backend.write_text(self.backend.read_text() + "\n")
        elif kind == "source":
            (self.stack / "main.tf").write_text("changed source")
        elif kind in ("json_source", "tofu_source", "tofu_json_source"):
            filename = {"json_source": "override.tf.json", "tofu_source": "override.tofu", "tofu_json_source": "override.tofu.json"}[kind]
            (self.stack / filename).write_text('{"terraform": {"required_version": ">= 9.0"}}')
        elif kind == "rc":
            (self.directory / "terraform.rc").chmod(0o600)
            (self.directory / "terraform.rc").write_text("provider_installation {}")
        elif kind == "staged":
            staged = next((self.directory / "artifacts").glob("*/package.zip"))
            staged.chmod(0o600)
            staged.write_bytes(b"changed staged ZIP")
        elif kind == "derived":
            effective = next((self.directory / "plans").glob("*/variables.json"))
            effective.chmod(0o600)
            effective.write_text("{}")
        elif kind == "plan":
            Path(self.receipt()["plan_path"]).write_bytes(b"changed saved plan")

    def test_init_swaps_refuse_apply_and_preserve_unconsumed_approval(self):
        for kind in ("artifact", "variables", "backend", "source", "json_source", "tofu_source", "tofu_json_source", "rc", "staged", "derived", "plan"):
            with self.subTest(kind=kind):
                self.setUp()
                self.command("plan")
                receipt_path = self.directory / "plan-receipt.json"
                before = receipt_path.read_bytes()
                approval = self.receipt()["plan_sha256"]
                self.calls = []
                self.hook = lambda op, args, env: self.mutate(kind) if op == "init" else None
                with self.assertRaises(runner.Refused):
                    self.command("apply", approval)
                self.assertFalse(self.applied())
                self.assertEqual(receipt_path.read_bytes(), before)

    def test_plan_swaps_do_not_publish_preplan_digest_receipt(self):
        for operation in ("init", "plan"):
            for kind in ("artifact", "variables", "backend", "source", "json_source", "tofu_source", "tofu_json_source", "rc", "staged", "derived"):
                with self.subTest(operation=operation, kind=kind):
                    self.setUp()
                    self.hook = lambda op, args, env: self.mutate(kind) if op == operation else None
                    with self.assertRaises(runner.Refused):
                        self.command("plan")
                    self.assertFalse((self.directory / "plan-receipt.json").exists())
                    self.assertFalse(self.applied())

    def test_nonzip_configuration_still_uses_sealed_derived_variables(self):
        for package in (None, {"filename": None, "image_uri": "repo@sha256:" + "a" * 64}):
            self.setUp()
            value = json.loads(self.variables.read_text())
            value["lambda_package"] = package
            self.variables.write_text(json.dumps(value))
            self.command("plan")
            receipt = self.receipt()
            self.assertIsNone(receipt["artifact_path"])
            self.assertIsNone(receipt["artifact_sha256"])
            self.assertEqual(json.loads(Path(receipt["effective_variables_path"]).read_text()), value)
            self.command("apply", receipt["plan_sha256"])
            self.assertTrue(self.applied())

    def test_corrupt_duplicate_or_changed_engine_receipt_preserves_approval(self):
        self.command("plan")
        receipt = self.receipt()
        path = self.directory / "plan-receipt.json"
        original = path.read_bytes()
        for body in (b"{truncated", b'{"schema_version":2,"schema_version":2}'):
            path.write_bytes(body)
            self.calls = []
            with self.assertRaises((runner.Refused, ValueError)):
                self.command("apply", receipt["plan_sha256"])
            self.assertEqual(self.calls, [])
            self.assertEqual(path.read_bytes(), body)
        path.write_bytes(original)
        self.environment["TF_BIN"] = "tofu"
        with self.assertRaises(runner.Refused):
            self.command("apply", receipt["plan_sha256"])
        self.assertEqual(path.read_bytes(), original)
        self.assertFalse(self.applied())

    def test_failed_replacement_plan_preserves_previous_approval(self):
        self.command("plan")
        path = self.directory / "plan-receipt.json"
        original = path.read_bytes()
        self.hook = lambda op, args, env: self.mutate("backend") if op == "plan" else None
        with self.assertRaises(runner.Refused):
            self.command("plan")
        self.assertEqual(path.read_bytes(), original)
        self.assertTrue(Path(json.loads(original)["plan_path"]).is_file())

    def test_failed_apply_attempt_consumes_approval_without_retry(self):
        self.command("plan")
        receipt = self.receipt()
        self.fail_apply = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.command("apply", receipt["plan_sha256"])
        self.assertFalse((self.directory / "plan-receipt.json").exists())
        self.assertTrue((Path(receipt["plan_path"]).parent / "apply-attempt-receipt.json").is_file())
        self.calls = []
        with self.assertRaises(OSError):
            self.command("apply", receipt["plan_sha256"])
        self.assertFalse(self.applied())

    def test_receipt_changed_during_init_cannot_be_applied_or_consumed(self):
        self.command("plan")
        receipt = self.receipt()
        active = self.directory / "plan-receipt.json"
        self.calls = []
        self.hook = lambda op, args, env: active.write_text("{}") if op == "init" else None
        with self.assertRaises(runner.Refused):
            self.command("apply", receipt["plan_sha256"])
        self.assertFalse(self.applied())
        self.assertTrue(active.exists())
        self.assertFalse((Path(receipt["plan_path"]).parent / "apply-attempt-receipt.json").exists())

    def test_malformed_or_foreign_receipt_paths_never_reach_init(self):
        self.command("plan")
        original = self.receipt()
        for patch_value in ({"schema_version": 1}, {"schema_version": 2.0}, {"schema_version": 2}, {"search_mode_history": []}, {"search_mode_history": "never-lost"}, {"attempt_id": "0" * 32}, {"plan_path": "/foreign/plan"}, {"effective_variables_path": "../foreign"}, {"artifact_path": str(self.artifact)}, {"unknown": True}, {"artifact_sha256": "../escape"}):
            path = self.directory / "plan-receipt.json"
            path.write_text(json.dumps({**original, **patch_value}))
            self.calls = []
            with self.subTest(patch_value=patch_value), self.assertRaises(runner.Refused):
                self.command("apply", original["plan_sha256"])
            self.assertEqual(self.calls, [])
            self.assertTrue(path.exists())

    def test_symlinked_inputs_artifacts_and_staged_paths_refuse(self):
        alias = self.root / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(runner.Refused):
            runner.read_inputs(alias / self.variables.name, self.backend)
        original = self.artifact.read_bytes()
        self.artifact.unlink()
        target = self.root / "target.zip"
        target.write_bytes(original)
        self.artifact.symlink_to(target)
        with self.assertRaises(runner.Refused):
            self.command("plan")
        self.artifact.unlink()
        self.artifact.write_bytes(original)
        self.command("plan")
        receipt = self.receipt()
        staged = Path(receipt["artifact_path"])
        staged.unlink()
        staged.symlink_to(target)
        self.calls = []
        with self.assertRaises(runner.Refused):
            self.command("apply", receipt["plan_sha256"])
        self.assertEqual(self.calls, [])

    def test_inherited_provider_and_cli_overrides_are_not_forwarded(self):
        self.environment.update(TF_REATTACH_PROVIDERS="foreign", TF_CLI_CONFIG_FILE="/foreign/config", TF_DATA_DIR="/foreign/data", TF_PLUGIN_CACHE_DIR="/foreign/cache", TF_VAR_region="foreign", TF_CLI_ARGS_apply="-auto-approve")
        self.command("plan")
        for _, env in self.calls:
            self.assertEqual({k for k in env if k.startswith("TF_")}, {"TF_IN_AUTOMATION", "TF_INPUT", "TF_DATA_DIR", "TF_CLI_CONFIG_FILE"})
            self.assertEqual(Path(env["TF_CLI_CONFIG_FILE"]).read_text(), runner.RC_TEXT)
            self.assertTrue(Path(env["TF_DATA_DIR"]).is_relative_to(self.directory))


class PippenOptOutTests(unittest.TestCase):
    def test_recognized_pippen_caller_cannot_strip_all_markers(self):
        caller = {"Account": "111111111111", "Arn": "arn:aws:sts::111111111111:assumed-role/agent-session/agent-00000000-0000-4000-8000-000000000000"}
        with self.assertRaises(runner.Refused):
            runner.verify_caller({"account_id": "111111111111"}, caller, {})

    def test_any_marker_or_incomplete_tuple_refuses_customer_optout(self):
        caller = {"Account": "111111111111", "Arn": "arn:aws:sts::111111111111:assumed-role/customer-deployer/session"}
        for markers in ({"PIPPEN_SANDBOX_CAPABILITY_CONTEXT": "present"}, {"PIPPEN_SANDBOX_ACCOUNT_ID": ""}, {"PIPPEN_SANDBOX_UNKNOWN": "present"}):
            with self.subTest(markers=markers), self.assertRaises(runner.Refused):
                runner.verify_caller({"account_id": "111111111111"}, caller, markers)
        for pippen in ({}, {"agent": "test"}, {"session_id": "00000000-0000-4000-8000-000000000000"}, {"agent": "test", "session_id": "not-a-uuid"}):
            with self.subTest(pippen=pippen), self.assertRaises(runner.Refused):
                runner.verify_caller({"account_id": "111111111111", "name_prefix": "pippen-sbx-test", "pippen": pippen}, caller, {})
        runner.verify_caller({"account_id": "111111111111"}, caller, {})


if __name__ == "__main__":
    unittest.main()
