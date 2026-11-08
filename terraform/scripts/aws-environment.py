#!/usr/bin/env python3
"""Saved-plan AWS wrapper with private artifact staging and explicit lineage.

No account allocation, guardrail changes or secret payload reads. Every plan uses
private derived variables; originals are never rewritten. Local ZIP bytes are
copied to a content-addressed path actually embedded in the plan, and all seals
are checked around init/plan and immediately before apply. Refusals preserve the
active approval; an apply attempt consumes it even when Terraform fails.

This is drift detection, NOT hostile same-UID/privileged mutation isolation.
The operator must exclude concurrent privileged mutation and use an approved PATH
Terraform/OpenTofu executable/runner. A tool-family name and dependency lock are
not binary/provider attestation or remote backend-state attestation. Terraform's
own saved-plan/state locking checks still apply. Receipt renames are atomic for
cooperating live processes, not power-loss durable (directory metadata is not
fsynced). After a host/filesystem crash, reconcile backend/state and attempt
evidence before trusting a recovered approval or retrying. Receipts v1/v2 require a
new reviewed v3 plan.
"""
import argparse
import base64
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
STACK = ROOT / "examples" / "aws-environments"
_MODE_SPEC = importlib.util.spec_from_file_location("search_creation_mode", ROOT / "modules/aws/search/creation_mode.py")
_MODE = importlib.util.module_from_spec(_MODE_SPEC)
_MODE_SPEC.loader.exec_module(_MODE)
BACKEND_KEYS = {"bucket", "key", "region", "encrypt", "use_lockfile", "expected_bucket_owner", "kms_key_id", "allowed_account_ids"}
RC_TEXT = "disable_checkpoint = true\n"
RECEIPT_KEYS = {"schema_version", "search_mode_history", "variables_sha256", "backend_sha256", "source_sha256", "artifact_sha256", "artifact_source_path", "artifact_path", "effective_variables_sha256", "effective_variables_path", "plan_sha256", "plan_path", "attempt_id", "variables_path", "backend_path", "source_root", "stack_path", "tool", "cli_config_sha256", "account_id", "environment", "region"}


class Refused(Exception):
    pass


def read_json(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise Refused("Duplicate JSON fields are not a reviewed input")
            result[key] = value
        return result
    return json.loads(checked_path(path).read_text(), object_pairs_hook=unique)


def checked_path(path, *, exists=True, directory=False):
    """Reject links before resolve() can hide them, including parent components."""
    path = Path(path)
    raw = path if path.is_absolute() else Path.cwd() / path
    current = Path(raw.anchor)
    for part in raw.parts[1:]:
        current = current / part
        if current.is_symlink():
            raise Refused("Symlink paths are not reviewed execution inputs")
    result = raw.resolve(strict=exists)
    if exists:
        info = result.stat()
        if directory:
            valid = stat.S_ISDIR(info.st_mode)
        else:
            valid = stat.S_ISREG(info.st_mode) and info.st_nlink == 1
        if not valid or info.st_mode & 0o022:
            raise Refused("Require regular, non-shared-writable reviewed paths")
    return result


def private_directory(path):
    path = checked_path(path, exists=False)
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    checked_path(path, directory=True)
    if path.stat().st_uid != os.geteuid() or path.stat().st_mode & 0o077:
        raise Refused("Run-owned directories must be private to the current operator")
    return path


def digest(path):
    return hashlib.sha256(checked_path(path).read_bytes()).hexdigest()


def source_digest(root=ROOT):
    root = checked_path(root, directory=True)
    h = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        rel = path.relative_to(root)
        if any(p.startswith(".") for p in rel.parts[:-1]):
            continue
        if path.is_symlink() and (path.is_dir() or path.name.endswith((".tf", ".tf.json", ".tofu", ".tofu.json", ".tftpl", ".tfvars", ".tfvars.json"))):
            raise Refused("Source symlinks are not a complete source seal")
        if not path.is_file():
            continue
        if not (path.name.endswith((".tf", ".tf.json", ".tofu", ".tofu.json", ".tftpl", ".tfvars", ".tfvars.json")) or path.name in (".terraform.lock.hcl", "aws-environment.py") or path == root / "modules/aws/search/creation_mode.py"):
            continue
        h.update(str(rel).encode() + b"\0" + checked_path(path).read_bytes() + b"\0")
    return h.hexdigest()


def read_inputs(variables_path, backend_path):
    variables = read_json(variables_path)
    backend = read_json(backend_path)
    if not isinstance(variables, dict) or not isinstance(backend, dict):
        raise Refused("Variable and backend files must be JSON objects")
    account, environment, region = (variables.get(k, "") for k in ("account_id", "environment", "region"))
    if not isinstance(account, str) or not re.fullmatch(r"[0-9]{12}", account):
        raise Refused("Set an exact 12-digit account_id")
    if not isinstance(environment, str) or not re.fullmatch(r"[a-z][a-z0-9]*(?:-[a-z0-9]+)*", environment) or len(environment) > 16:
        raise Refused("Set an explicit environment slug")
    if not isinstance(region, str) or not re.fullmatch(r"[a-z]{2}(?:-[a-z]+)+-[0-9]+", region):
        raise Refused("Set an explicit AWS region")
    if set(backend) - BACKEND_KEYS:
        raise Refused("Backend contains unsupported settings; credentials/profiles belong only in the runner")
    if backend.get("encrypt") is not True or backend.get("use_lockfile") is not True:
        raise Refused("The backend requires encryption and native S3 state locking")
    key = backend.get("key", "")
    suffix = f"/{account}/{region}/{environment}/data.tfstate"
    if not isinstance(key, str) or not key.endswith(suffix) or ".." in key.split("/") or key.startswith("/"):
        raise Refused("Backend key must end in /<account_id>/<region>/<environment>/data.tfstate")
    if not isinstance(backend.get("bucket"), str) or not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", backend["bucket"]):
        raise Refused("Set the approved existing state bucket")
    if not re.fullmatch(r"[0-9]{12}", str(backend.get("expected_bucket_owner", ""))):
        raise Refused("Set the exact expected_bucket_owner for the state bucket")
    return variables, backend


def verify_caller(variables, caller, environ):
    account = variables["account_id"]
    if not isinstance(caller, dict) or caller.get("Account") != account:
        raise Refused("AWS caller account does not match the environment")
    pippen = variables.get("pippen")
    markers = any(key.startswith("PIPPEN_SANDBOX_") for key in environ)
    reserved_role = bool(re.fullmatch(r"arn:aws:sts::[0-9]{12}:assumed-role/agent-session/[^/]+", (caller.get("Arn") if isinstance(caller.get("Arn"), str) else "")))
    if pippen is None and (markers or reserved_role):
        raise Refused("Pippen execution requires the declared complete lease identity")
    if pippen is not None:
        if not isinstance(pippen, dict) or set(pippen) != {"agent", "session_id"} or not isinstance(pippen.get("agent"), str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,40}", pippen["agent"]) or not isinstance(pippen.get("session_id"), str) or not re.fullmatch(r"[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}", pippen["session_id"]):
            raise Refused("Pippen agent/session identity is incomplete")
        expected = f"arn:aws:sts::{account}:assumed-role/agent-session/agent-{pippen['session_id']}"
        if caller.get("Arn") != expected or environ.get("PIPPEN_SANDBOX_ACCOUNT_ID") != account or environ.get("PIPPEN_SANDBOX_SESSION_ID") != pippen["session_id"] or environ.get("PIPPEN_SANDBOX_AGENT_ID") != pippen["agent"]:
            raise Refused("Run under the exact allocated Pippen lease with pippen sandbox exec")
        if not isinstance(variables.get("name_prefix"), str) or not variables["name_prefix"].startswith("pippen-sbx-"):
            raise Refused("Pippen resources require a pippen-sbx- prefix")


def plan_binding(variables_path, backend_path, source_root=ROOT):
    binding = {"variables_sha256": digest(variables_path), "backend_sha256": digest(backend_path), "source_sha256": source_digest(source_root), "artifact_sha256": None, "artifact_source_path": None}
    values = read_json(variables_path)
    if not isinstance(values, dict):
        raise Refused("Variables must be a JSON object")
    package = values.get("lambda_package")
    if package is not None and not isinstance(package, dict):
        raise Refused("Lambda package must be an object")
    if package is not None and package.get("filename") is not None and (not isinstance(package["filename"], str) or not package["filename"]):
        raise Refused("Local Lambda filename must be a nonempty path")
    if package and package.get("filename"):
        path = Path(package["filename"])
        if not path.is_absolute():
            path = source_root / "examples" / "aws-environments" / path
        path = checked_path(path)
        artifact_sha = digest(path)
        if base64.b64encode(bytes.fromhex(artifact_sha)).decode() != package.get("source_code_hash"):
            raise Refused("Local Lambda package does not match its reviewed source_code_hash")
        binding.update(artifact_sha256=artifact_sha, artifact_source_path=str(path))
    return binding


def verify_plan(plan, receipt, binding, approved_sha):
    recorded = read_json(receipt)
    if not isinstance(recorded, dict):
        raise Refused("Saved-plan receipt must be a JSON object")
    actual = digest(plan)
    if approved_sha != actual or recorded.get("plan_sha256") != actual:
        raise Refused("Approval must name the exact saved plan SHA-256")
    if any(recorded.get(k) != v for k, v in binding.items()):
        raise Refused("Environment/backend/source/artifact changed since planning; create a new plan")


def admit_search_plan(prefix, plan, environment):
    before = digest(plan)
    payload = json.loads(subprocess.check_output(prefix + ["show", "-json", str(plan)], env=environment))
    try:
        history = _MODE.admit(payload)
    except _MODE.SearchModeError as exc:
        raise Refused(str(exc)) from exc
    if digest(plan) != before:
        raise Refused("Saved plan changed during search history admission")
    return history


def private_bytes(path, data, *, mode=0o600):
    path = checked_path(path, exists=False)
    temporary = path.with_name("." + path.name + "." + uuid.uuid4().hex)
    try:
        with temporary.open("xb") as stream:
            os.chmod(temporary, mode)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def private_json(path, value):
    private_bytes(path, (json.dumps(value, indent=2) + "\n").encode())


def assert_sealed(before, variables_path, backend_path, rc, tool):
    now = {**plan_binding(variables_path, backend_path, ROOT), "cli_config_sha256": digest(rc), "tool": tool}
    if now != before:
        raise Refused("Reviewed inputs changed during operation; no plan/apply approval is published or consumed")


def stage(variables, binding, directory, attempt):
    effective = json.loads(json.dumps(variables))
    artifact = None
    if binding["artifact_sha256"]:
        destination = private_directory(directory / "artifacts" / ("sha256-" + binding["artifact_sha256"]))
        artifact = destination / "package.zip"
        if not artifact.exists():
            private_bytes(artifact, checked_path(binding["artifact_source_path"]).read_bytes(), mode=0o400)
        if digest(artifact) != binding["artifact_sha256"] or artifact.stat().st_mode & 0o777 != 0o400:
            raise Refused("Staged artifact changed; preserve this attempt for review")
        effective["lambda_package"]["filename"] = str(artifact)
    path = attempt / "variables.json"
    private_bytes(path, (json.dumps(effective, indent=2) + "\n").encode(), mode=0o400)
    return path, artifact


def staged_binding(effective, artifact):
    if checked_path(effective).stat().st_mode & 0o777 != 0o400:
        raise Refused("Derived variables changed permissions")
    return {"effective_variables_sha256": digest(effective), "artifact_path": str(artifact) if artifact else None, "staged_artifact_sha256": digest(artifact) if artifact else None}


def load_receipt(directory, variables_path, backend_path, tool):
    receipt = checked_path(directory / "plan-receipt.json")
    recorded = read_json(receipt)
    if not isinstance(recorded, dict) or set(recorded) != RECEIPT_KEYS or type(recorded.get("schema_version")) is not int or recorded["schema_version"] != 3:
        raise Refused("Unsupported/corrupt saved-plan receipt; create a new plan")
    if not isinstance(recorded["search_mode_history"], str) or recorded["search_mode_history"] not in {"fresh", "enrolled", "legacy-or-missing-marker unchanged-domain", "destroy"}:
        raise Refused("Invalid search history qualification")
    attempt_id = recorded["attempt_id"]
    if not isinstance(attempt_id, str) or not re.fullmatch(r"[a-f0-9]{12}4[a-f0-9]{3}[89ab][a-f0-9]{15}", attempt_id):
        raise Refused("Invalid saved-plan attempt identity")
    attempt = checked_path(directory / "plans" / attempt_id, directory=True)
    expected = {"variables_path": str(variables_path), "backend_path": str(backend_path), "source_root": str(ROOT), "stack_path": str(STACK), "tool": tool, "plan_path": str(attempt / "data.tfplan"), "effective_variables_path": str(attempt / "variables.json")}
    if any(recorded.get(k) != v for k, v in expected.items()):
        raise Refused("Saved plan path/selector lineage differs from this invocation")
    artifact_sha = recorded.get("artifact_sha256")
    if artifact_sha is not None and (not isinstance(artifact_sha, str) or not re.fullmatch(r"[a-f0-9]{64}", artifact_sha)):
        raise Refused("Invalid saved artifact digest")
    expected_artifact = directory / "artifacts" / ("sha256-" + artifact_sha) / "package.zip" if artifact_sha else None
    if recorded.get("artifact_path") != (str(expected_artifact) if expected_artifact else None):
        raise Refused("Artifact path is not owned by this receipt")
    for key in ("variables_sha256", "backend_sha256", "source_sha256", "effective_variables_sha256", "plan_sha256", "cli_config_sha256"):
        if not isinstance(recorded[key], str) or not re.fullmatch(r"[a-f0-9]{64}", recorded[key]):
            raise Refused("Malformed saved-plan digest")
    checked_path(attempt / "data.tfplan")
    checked_path(attempt / "variables.json")
    if expected_artifact:
        checked_path(expected_artifact)
    return receipt, recorded, attempt / "data.tfplan", attempt / "variables.json", expected_artifact


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["init", "plan", "show", "apply", "output"])
    parser.add_argument("--variables", required=True, type=Path, help="Private non-secret .tfvars.json file")
    parser.add_argument("--backend", required=True, type=Path, help="Private non-secret S3 backend JSON file")
    parser.add_argument("--approve-plan", help="Exact reviewed plan SHA-256, required for apply")
    parser.add_argument("--run-dir", type=Path, default=ROOT / ".runs")
    args = parser.parse_args(argv)
    os.umask(0o077)
    variables_path, backend_path = checked_path(args.variables), checked_path(args.backend)
    # Read and seal before any caller command; refuse even selection drift here.
    initial = plan_binding(variables_path, backend_path, ROOT)
    variables, _ = read_inputs(variables_path, backend_path)
    if plan_binding(variables_path, backend_path, ROOT) != initial:
        raise Refused("Inputs changed while selecting the installation")
    tool = os.environ.get("TF_BIN", "terraform")
    if tool not in ("terraform", "tofu"):
        raise Refused("TF_BIN must be terraform or tofu from the approved runner")
    if os.environ.get("TF_WORKSPACE", "default") != "default":
        raise Refused("Use separate backend keys/configuration, not a selected CLI workspace")
    child_env = {k: v for k, v in os.environ.items() if not k.startswith("TF_")}
    child_env.update(TF_IN_AUTOMATION="1", TF_INPUT="0", AWS_REGION=variables["region"], AWS_DEFAULT_REGION=variables["region"])
    directory = private_directory(checked_path(args.run_dir, exists=False) / variables["account_id"] / variables["region"] / variables["environment"])
    child_env["TF_DATA_DIR"] = str(private_directory(directory / ".terraform"))
    rc = directory / "terraform.rc"
    if rc.exists():
        if checked_path(rc).read_text() != RC_TEXT:
            raise Refused("Controlled Terraform CLI configuration changed")
    elif args.command in ("apply", "show"):
        raise Refused("Missing reviewed Terraform CLI configuration")
    else:
        private_bytes(rc, RC_TEXT.encode(), mode=0o400)
    child_env["TF_CLI_CONFIG_FILE"] = str(rc)
    prefix = [tool, f"-chdir={STACK}"]
    binding = {**initial, "cli_config_sha256": digest(rc), "tool": tool}
    lock_path = checked_path(directory / "operation.lock", exists=False)
    if lock_path.exists():
        checked_path(lock_path)
    with lock_path.open("a") as lock:
        if lock_path.stat().st_nlink != 1:
            raise Refused("Operation lock is not a private regular file")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise Refused("Another operation is active for this environment") from exc
        caller = json.loads(subprocess.check_output(["aws", "sts", "get-caller-identity", "--output", "json"], env=child_env, stderr=subprocess.DEVNULL))
        verify_caller(variables, caller, child_env)
        assert_sealed(binding, variables_path, backend_path, rc, tool)
        selected = None
        if args.command in ("apply", "show"):
            selected = load_receipt(directory, variables_path, backend_path, tool)
            receipt, recorded, plan, effective, artifact = selected
            expected_identity = {k: variables[k] for k in ("account_id", "environment", "region")}
            if any(recorded[k] != v for k, v in expected_identity.items()):
                raise Refused("Saved receipt belongs to another installation")
            verify_plan(plan, receipt, binding, args.approve_plan if args.command == "apply" else digest(plan))
            seals = staged_binding(effective, artifact)
            if seals["effective_variables_sha256"] != recorded["effective_variables_sha256"] or seals["staged_artifact_sha256"] != recorded["artifact_sha256"]:
                raise Refused("Staged plan inputs changed since review")
        elif args.command == "plan":
            attempt_id = uuid.uuid4().hex
            attempt = private_directory(directory / "plans" / attempt_id)
            effective, artifact = stage(variables, binding, directory, attempt)
            seals = staged_binding(effective, artifact)
            assert_sealed(binding, variables_path, backend_path, rc, tool)
        subprocess.run(prefix + ["init", "-reconfigure", "-input=false", "-lockfile=readonly", f"-backend-config={backend_path}"], env=child_env, check=True)
        actual_workspace = subprocess.check_output(prefix + ["workspace", "show"], env=child_env).decode().strip()
        if actual_workspace != "default":
            raise Refused("Cached Terraform CLI workspace is not default; refuse environment aliasing")
        assert_sealed(binding, variables_path, backend_path, rc, tool)
        if args.command in ("plan", "apply", "show") and staged_binding(effective, artifact) != seals:
            raise Refused("Staged inputs changed during initialization")
        if args.command == "plan":
            plan = attempt / "data.tfplan"
            subprocess.run(prefix + ["plan", "-input=false", f"-var-file={effective}", f"-out={plan}"], env=child_env, check=True)
            history = admit_search_plan(prefix, plan, child_env)
            assert_sealed(binding, variables_path, backend_path, rc, tool)
            if staged_binding(effective, artifact) != seals:
                raise Refused("Staged inputs changed during planning")
            checked_path(plan)
            private_json(directory / "plan-receipt.json", {**binding, "schema_version": 3, "search_mode_history": history, "artifact_path": seals["artifact_path"], "effective_variables_sha256": seals["effective_variables_sha256"], "effective_variables_path": str(effective), "attempt_id": attempt_id, "plan_sha256": digest(plan), "plan_path": str(plan), "variables_path": str(variables_path), "backend_path": str(backend_path), "source_root": str(ROOT), "stack_path": str(STACK), **{k: variables[k] for k in ("account_id", "environment", "region")}})
            print(f"Saved plan: {plan}\nSHA-256: {digest(plan)}\nReview this plan before invoking apply --approve-plan <SHA-256>.")
        elif args.command in ("apply", "show"):
            # Recheck the receipt, plan and all original/staged seals AFTER init.
            if load_receipt(directory, variables_path, backend_path, tool)[1] != recorded:
                raise Refused("Active approval changed during initialization")
            verify_plan(plan, receipt, binding, args.approve_plan if args.command == "apply" else digest(plan))
            if args.command == "apply":
                history = admit_search_plan(prefix, plan, child_env)
                if history != recorded["search_mode_history"]:
                    raise Refused("Search history qualification differs from reviewed plan receipt")
                if load_receipt(directory, variables_path, backend_path, tool)[1] != recorded:
                    raise Refused("Active approval changed during search history admission")
                verify_plan(plan, receipt, binding, args.approve_plan)
            assert_sealed(binding, variables_path, backend_path, rc, tool)
            if staged_binding(effective, artifact) != seals:
                raise Refused("Staged inputs changed immediately before execution")
            if args.command == "apply":
                consumed = plan.parent / "apply-attempt-receipt.json"
                checked_path(consumed, exists=False)
                if consumed.exists():
                    raise Refused("This plan has already had an apply attempt")
                os.replace(receipt, consumed)
                subprocess.run(prefix + ["apply", "-input=false", str(plan)], env=child_env, check=True)
            else:
                subprocess.run(prefix + ["show", "-no-color", str(plan)], env=child_env, check=True)
        elif args.command == "output":
            value = json.loads(subprocess.check_output(prefix + ["output", "-json", "verification"], env=child_env))
            if any(value.get(k) != variables[k] for k in ("account_id", "environment", "region")):
                raise Refused("State outputs belong to another environment")
            private_json(directory / "verification.json", value)
            print(f"Non-secret verification references: {directory / 'verification.json'}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (Refused, ValueError, OSError, subprocess.SubprocessError) as exc:
        reason = str(exc) if isinstance(exc, Refused) else type(exc).__name__
        print(f"Refused: {reason}", file=sys.stderr)
        sys.exit(1)
