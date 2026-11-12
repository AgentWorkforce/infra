"""Inspect the native mocked plan of sessions_bucket_import = true.

Runs the "import_existing_bucket" run of tests/sessions-bucket-import.tftest.hcl
(enable_database = enable_search = false, history_upload on) and requires:
the bucket and its configuration resources are imported by the bucket name and
only kept or updated in place; nothing anywhere is deleted or replaced; and the
only creates are exactly CREATES below. Terraform only: OpenTofu 1.11's test
framework cannot import with mock providers. All providers are mocked; this
makes no AWS request.

    python3 tests/check_sessions_bucket_import.py terraform|tofu
"""
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = "tests/sessions-bucket-import.tftest.hcl"
RUN = "import_existing_bucket"
UNMANAGED_RUN = "import_unmanaged_policy_and_lifecycle"
BUCKET = "existing-relay-sessions"
_SPEC = importlib.util.spec_from_file_location("golden_plan", ROOT.parents[1] / "scripts/golden_plan.py")
golden = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(golden)

S = "module.sessions_bucket."
# The mocked run skips the policy import (a mock cannot fill its resource
# identity); import_targets in the fixture proves its import ID instead.
IMPORTS = {S + "aws_s3_bucket" + suffix + ".this" for suffix in ("", "_public_access_block", "_ownership_controls", "_server_side_encryption_configuration", "_versioning")} | {S + "aws_s3_bucket_lifecycle_configuration.this[0]"}
CREATES = {
    # history_upload
    "aws_iam_role.history_control[0]", "aws_eks_pod_identity_association.history_control[0]",
    "aws_iam_role.history_consumer[0]", "aws_iam_role_policy.history_consumer[0]", "aws_eks_pod_identity_association.history_consumer[0]",
    S + "aws_iam_role.history_upload[0]", S + "aws_iam_role_policy.history_upload[0]", S + "aws_iam_role_policy.history_upload_issuer[0]",
    # the sessions storage role and its worker/alleyoop/session-ingest-api Pod Identity associations
    S + "aws_iam_role.access[0]", S + "aws_iam_role_policy.access[0]",
    *(S + 'aws_eks_pod_identity_association.access["relay/agent-relay-prod/agent-relay-' + sa + '"]' for sa in ("worker", "alleyoop", "session-ingest-api")),
    # state-only, no AWS object
    "terraform_data.environment_contract", "module.postgres.random_id.final_snapshot", "module.search.terraform_data.creation_mode",
    # skipped import in this mocked run (see above)
    S + "aws_s3_bucket_policy.this[0]",
}


def main(engine):
    if golden.engine_key(engine) == "tofu":
        print(json.dumps({"ok": True, "engine": "tofu", "skipped": "OpenTofu 1.11 tests cannot import with mock providers; validation runs live in sessions-bucket-import.tofutest.hcl"}))
        return
    found = golden.plans(ROOT, engine, FIXTURE)
    rows = found[RUN]["resource_changes"]
    managed = [r for r in rows if r.get("mode") == "managed"]
    imported = {r["address"]: r["change"] for r in managed if r["change"].get("importing")}
    golden.require(set(imported) == IMPORTS, "Import targets differ: " + str(sorted(set(imported) ^ IMPORTS)))
    golden.require(all(c["importing"].get("id") == BUCKET and c["actions"] in (["no-op"], ["update"]) for c in imported.values()), "Imports must use the bucket name and only keep or update in place")
    golden.require(not [r["address"] for r in managed if "delete" in r["change"]["actions"]], "Nothing may be destroyed or replaced")
    created = {r["address"] for r in managed if r["change"]["actions"] == ["create"]}
    golden.require(created == CREATES, "Unexpected creates: " + str(sorted(created - CREATES)) + ", missing " + str(sorted(CREATES - created)))
    golden.require(all(r["change"]["actions"] in (["no-op"], ["update"], ["create"]) for r in managed), "Only create, update or no-op is allowed")
    unmanaged = check_unmanaged(found[UNMANAGED_RUN]["resource_changes"])
    print(json.dumps({"ok": True, "engine": "terraform", "imports": len(imported), "import_id": BUCKET, "deletes": 0, "replaces": 0, "creates": len(created), "unmanaged": unmanaged}))


def check_unmanaged(rows):
    """sessions_bucket_unmanaged = [policy, lifecycle_configuration]: neither planned at all."""
    managed = [r for r in rows if r.get("mode") == "managed"]
    addresses = {r["address"] for r in managed}
    golden.require(not any(a.startswith((S + "aws_s3_bucket_policy", S + "aws_s3_bucket_lifecycle_configuration")) for a in addresses), "Unmanaged policy/lifecycle must not be imported, created or replaced")
    imported = {r["address"] for r in managed if r["change"].get("importing")}
    golden.require(imported == IMPORTS - {S + "aws_s3_bucket_lifecycle_configuration.this[0]"}, "Unmanaged run imports differ: " + str(sorted(imported)))
    golden.require(not [r["address"] for r in managed if "delete" in r["change"]["actions"]], "Nothing may be destroyed or replaced")
    golden.require("terraform_data.sessions_policy_wall[0]" in addresses, "The live-policy wall check must plan with history_upload")
    return {"imports": len(imported), "policy_or_lifecycle_planned": 0, "wall_check": True}


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "terraform")
