"""Prove the default (self-host) plan is unchanged by the opt-out flags, and
that opting out of both plans only the sessions-bucket stack.

Runs the plan-only fixtures in tests/default-plan.tftest.hcl with the selected
engine and compares every planned resource (address, type, actions, planned and
unknown/sensitive values) and every output against default-plan.golden.json.
The golden digests were recorded from the configuration *before*
enable_database/enable_search existed, so a match means the defaults plan
byte-identical resources and outputs. It then plans tests/optout.tftest.hcl and
requires the exact address set below for enable_database = enable_search =
false. All providers are mocked; this makes no AWS, SDK, credential or backend
request.

    python3 tests/check_default_plan.py terraform|tofu           # verify
    python3 tests/check_default_plan.py terraform|tofu --write   # re-record (review the diff!)
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = "tests/default-plan.tftest.hcl"
OPTOUT = "tests/optout.tftest.hcl"
GOLDEN = ROOT / "tests/default-plan.golden.json"

# Addresses that a reviewed moved {} block renamed without changing the object.
# Each is compared against its pre-change golden address, so its planned values
# must still match byte-for-byte. Search's `enabled` gave the (previously
# unindexed) domain policy a count; modules/aws/search moves this -> this[0].
MOVED = {"module.search.aws_opensearch_domain_policy.this[0]": "module.search.aws_opensearch_domain_policy.this"}

# enable_database = enable_search = false: the sessions bucket and its storage
# bindings, plus three state-only objects (no AWS API object): the root
# contract, the postgres final-snapshot suffix and the search mode marker,
# which stay unindexed so existing default states keep their addresses.
SESSIONS = "module.sessions_bucket."
BOTH_OFF = {
    "terraform_data.environment_contract",
    "module.postgres.random_id.final_snapshot",
    "module.search.terraform_data.creation_mode",
    "module.search.data.aws_caller_identity.current",
    "module.search.data.aws_partition.current",
    "module.search.data.aws_region.current",
    SESSIONS + "data.aws_caller_identity.upload",
    SESSIONS + "data.aws_partition.current",
    SESSIONS + "data.aws_region.current",
    *(SESSIONS + 'aws_eks_pod_identity_association.access["relay/agent-relay-prod/agent-relay-' + sa + '"]' for sa in ("worker", "alleyoop", "session-ingest-api")),
    SESSIONS + "aws_iam_role.access[0]",
    SESSIONS + "aws_iam_role_policy.access[0]",
    *(SESSIONS + "aws_s3_bucket" + suffix + ".this" for suffix in ("", "_lifecycle_configuration", "_ownership_controls", "_policy", "_public_access_block", "_server_side_encryption_configuration", "_versioning")),
}
BUCKETS = {"both_off_minimal_inputs": "agent-relay-prod-111111111111-us-west-2-sessions", "both_off_existing_bucket_name": "existing-relay-sessions"}


def require(value, message):
    if not value:
        raise SystemExit(message)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def plans(engine, fixture):
    result = subprocess.run([engine, "test", "-no-color", "-filter=" + fixture, "-json", "-verbose"], cwd=ROOT, capture_output=True, text=True, timeout=300)
    require(result.returncode == 0, fixture + " failed: " + result.stdout[-3000:] + result.stderr[-2000:])
    found = {}
    for line in result.stdout.splitlines():
        if not line.startswith("{"):
            continue
        event = json.loads(line)
        if event.get("type") != "test_plan" or event.get("@testfile") != fixture:
            continue
        name = event.get("@testrun")
        require(isinstance(name, str) and name not in found, "Missing or duplicate run plan")
        found[name] = event["test_plan"]
    return found


def actual(engine):
    runs = {}
    for name, plan in plans(engine, FIXTURE).items():
        resources = {}
        for row in plan.get("resource_changes", []):
            address = MOVED.get(row["address"], row["address"])
            require(address not in resources, "Duplicate planned address: " + address)
            change = row["change"]
            resources[address] = digest({"mode": row.get("mode"), "type": row.get("type"), **{k: change.get(k) for k in ("actions", "after", "after_unknown", "after_sensitive")}})
        outputs = {name: digest(value) for name, value in plan.get("output_changes", {}).items()}
        runs[name] = {"resources": resources, "outputs": outputs}
    require(runs, "No run plans found")
    return runs


def check_optout(engine):
    found = plans(engine, OPTOUT)
    rows = found.get("both_off_minimal_inputs", {}).get("resource_changes")
    require(isinstance(rows, list), "Missing both-off plan")
    addresses = {r["address"] for r in rows}
    require(addresses == BOTH_OFF, "Both-off plan differs from the sessions-bucket stack: unexpected " + str(sorted(addresses - BOTH_OFF)) + ", missing " + str(sorted(BOTH_OFF - addresses)))
    require(all(r["change"]["actions"] == (["read"] if r.get("mode") == "data" else ["create"]) for r in rows), "Both-off plan must only create/read")
    for run, bucket in BUCKETS.items():
        matches = [r for r in found.get(run, {}).get("resource_changes", []) if r["address"] == SESSIONS + "aws_s3_bucket.this"]
        require(len(matches) == 1 and matches[0]["change"]["after"].get("bucket") == bucket and matches[0]["change"]["actions"] == ["create"], run + ": sessions bucket must plan as " + bucket)
    return len(addresses)


def main(engine, write):
    key = "tofu" if Path(engine).name == "tofu" else "terraform"
    runs = actual(engine)
    golden = json.loads(GOLDEN.read_text()) if GOLDEN.exists() else {}
    if write:
        golden[key] = runs
        GOLDEN.write_text(json.dumps(golden, indent=2, sort_keys=True) + "\n")
        print(json.dumps({"ok": True, "written": key, "runs": sorted(runs)}))
        return
    expected = golden.get(key)
    require(isinstance(expected, dict), "No golden plan recorded for " + key)
    problems = []
    for run in sorted(set(expected) | set(runs)):
        want, got = expected.get(run), runs.get(run)
        if want is None or got is None:
            problems.append(f"{run}: run {'added' if want is None else 'missing'}")
            continue
        for kind in ("resources", "outputs"):
            for name in sorted(set(want[kind]) | set(got[kind])):
                if want[kind].get(name) != got[kind].get(name):
                    state = "added" if name not in want[kind] else "removed" if name not in got[kind] else "changed"
                    problems.append(f"{run}: {kind[:-1]} {name} {state}")
    require(not problems, "Default plan differs from the recorded pre-opt-out plan:\n  " + "\n  ".join(problems))
    both_off = check_optout(engine)
    print(json.dumps({"ok": True, "engine": key, "runs": len(runs), "resources": sum(len(r["resources"]) for r in runs.values()), "outputs": sum(len(r["outputs"]) for r in runs.values()), "byte_identical": True, "moved_aliases": sorted(MOVED), "both_off_addresses": both_off, "bucket_override": True}))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "terraform", "--write" in sys.argv[2:])
