"""Prove the default (self-host) plan is unchanged by the opt-out flags.

Runs the plan-only fixtures in tests/default-plan.tftest.hcl with the selected
engine and compares every planned resource (address, type, actions, planned and
unknown/sensitive values) and every output against default-plan.golden.json.
The golden digests were recorded from the configuration *before*
enable_database/enable_search existed, so a match means the defaults plan
byte-identical resources and outputs. All providers are mocked; this makes no
AWS, SDK, credential or backend request.

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
GOLDEN = ROOT / "tests/default-plan.golden.json"

# Addresses that a reviewed moved {} block renamed without changing the object.
# Each is compared against its pre-change golden address.
MOVED = {}


def require(value, message):
    if not value:
        raise SystemExit(message)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def actual(engine):
    result = subprocess.run([engine, "test", "-no-color", "-filter=" + FIXTURE, "-json", "-verbose"], cwd=ROOT, capture_output=True, text=True, timeout=300)
    require(result.returncode == 0, "Default-plan fixture failed: " + result.stdout[-3000:] + result.stderr[-2000:])
    runs = {}
    for line in result.stdout.splitlines():
        if not line.startswith("{"):
            continue
        event = json.loads(line)
        if event.get("type") != "test_plan" or event.get("@testfile") != FIXTURE:
            continue
        name = event.get("@testrun")
        require(isinstance(name, str) and name not in runs, "Missing or duplicate run plan")
        plan = event["test_plan"]
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
    print(json.dumps({"ok": True, "engine": key, "runs": len(runs), "resources": sum(len(r["resources"]) for r in runs.values()), "outputs": sum(len(r["outputs"]) for r in runs.values()), "byte_identical": True, "moved_aliases": sorted(MOVED)}))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "terraform", "--write" in sys.argv[2:])
