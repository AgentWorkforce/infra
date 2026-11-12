"""Shared golden-plan comparison for the examples' check_default_plan.py.

Runs a plan-only, fully mocked fixture with `<engine> test -json -verbose`,
reduces every planned resource (address, mode, type, actions, after,
after_unknown, after_sensitive) and every output to a SHA-256 digest, and
compares them with a golden file recorded from earlier, unchanged source.
`moved` maps a new address to the golden address a reviewed moved {} block
renamed, so that object must still match byte-for-byte. No AWS, SDK,
credential or backend request is made.
"""
import hashlib
import json
from pathlib import Path
import subprocess


def require(value, message):
    if not value:
        raise SystemExit(message)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def engine_key(engine):
    return "tofu" if Path(engine).name == "tofu" else "terraform"


def plans(root, engine, fixture):
    result = subprocess.run([engine, "test", "-no-color", "-filter=" + fixture, "-json", "-verbose"], cwd=root, capture_output=True, text=True, timeout=300)
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
    require(found, "No run plans found in " + fixture)
    return found


def reduce(found, moved):
    runs = {}
    for name, plan in found.items():
        resources = {}
        for row in plan.get("resource_changes", []):
            address = moved.get(row["address"], row["address"])
            require(address not in resources, "Duplicate planned address: " + address)
            change = row["change"]
            resources[address] = digest({"mode": row.get("mode"), "type": row.get("type"), **{k: change.get(k) for k in ("actions", "after", "after_unknown", "after_sensitive")}})
        outputs = {output: digest(value) for output, value in plan.get("output_changes", {}).items()}
        runs[name] = {"resources": resources, "outputs": outputs}
    return runs


def check(root, engine, fixture, golden_path, moved, write=False):
    """Compare (or with write=True re-record) the fixture's plans. Returns the raw plans and a summary."""
    key = engine_key(engine)
    found = plans(root, engine, fixture)
    runs = reduce(found, moved)
    golden = json.loads(golden_path.read_text()) if golden_path.exists() else {}
    if write:
        golden[key] = runs
        golden_path.write_text(json.dumps(golden, indent=2, sort_keys=True) + "\n")
        return found, {"ok": True, "written": key, "runs": sorted(runs)}
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
    require(not problems, "Default plan differs from the recorded golden plan:\n  " + "\n  ".join(problems))
    return found, {"ok": True, "engine": key, "runs": len(runs), "resources": sum(len(r["resources"]) for r in runs.values()), "outputs": sum(len(r["outputs"]) for r in runs.values()), "byte_identical": True, "moved_aliases": sorted(moved)}
