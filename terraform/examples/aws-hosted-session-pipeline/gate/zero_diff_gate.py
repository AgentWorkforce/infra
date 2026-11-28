#!/usr/bin/env python3
"""Refuse a post-import plan unless it changes nothing, apart from explicitly approved attribute changes.

    terraform show -json tfplan > plan.json
    zero_diff_gate.py plan.json [--allow ADDRESS:PATH=BEFORE->AFTER ...]

Every resource change must be a no-op (an import is a no-op with "importing" set). An --allow names one
in-place update to one attribute path (dot-separated, list indexes as numbers) with its exact before
and after values as JSON; that resource may then differ in that path only. Output names addresses and
paths, never values beyond the approved ones. Exit 0 on pass, 1 on refusal.
"""
import argparse
import json
import sys


def parse_allow(spec):
    address, rest = spec.split(":", 1)
    path, values = rest.split("=", 1)
    before, after = values.split("->", 1)
    return address, tuple(int(p) if p.isdigit() else p for p in path.split(".")), json.loads(before), json.loads(after)


def get(obj, path):
    for p in path:
        if isinstance(p, int):
            if not isinstance(obj, list) or p >= len(obj):
                return None
        elif not isinstance(obj, dict):
            return None
        obj = obj[p] if isinstance(p, int) else obj.get(p)
    return obj


def put(obj, path, value):
    obj = json.loads(json.dumps(obj))
    cur = obj
    for p in path[:-1]:
        cur = cur[p]
    cur[path[-1]] = value
    return obj


def check(plan, allows):
    problems = []
    allowed = {}
    for address, path, before, after in allows:
        allowed.setdefault(address, []).append((path, before, after))
    used = set()
    for rc in plan.get("resource_changes", []):
        address, change = rc["address"], rc["change"]
        actions = change.get("actions", [])
        if actions == ["no-op"] or actions == ["read"]:
            continue
        if actions != ["update"] or address not in allowed:
            problems.append(f"{address}: {'+'.join(actions)} is not approved")
            continue
        b, a = change.get("before"), change.get("after")
        for path, before, after in allowed[address]:
            if get(b, path) != before or get(a, path) != after:
                problems.append(f"{address}: {'.'.join(map(str, path))} is not the approved change")
                continue
            b, a = put(b, path, after), a
            used.add((address, path))
        if b != a:
            problems.append(f"{address}: changes beyond the approved attribute(s)")
    for address, path, _, _ in allows:
        if (address, path) not in used:
            problems.append(f"{address}: approved change {'.'.join(map(str, path))} is not in the plan")
    return problems


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("plan")
    ap.add_argument("--allow", action="append", default=[])
    args = ap.parse_args(argv)
    with open(args.plan) as f:
        plan = json.load(f)
    problems = check(plan, [parse_allow(s) for s in args.allow])
    for p in problems:
        print(f"REFUSED {p}")
    if problems:
        return 1
    print(f"PASS: {len(plan.get('resource_changes', []))} resources, no unapproved changes")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
