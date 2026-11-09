#!/usr/bin/env python3
"""Check routing prerequisites in Terraform's offline plan dependency graph.

Run after init -backend=false. No variables, credentials, plan, or cloud API calls
are needed. --graph accepts an existing DOT file for regression verification.
"""
import argparse
from collections import deque
import os
from pathlib import Path
import re
import subprocess
import sys


def dependency_path(edges, start, prerequisite):
    queue = deque([(start, [start])])
    seen = {start}
    while queue:
        node, path = queue.popleft()
        if node == prerequisite:
            return path
        for dependency in sorted(edges.get(node, ())):
            if dependency not in seen:
                seen.add(dependency)
                queue.append((dependency, path + [dependency]))
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--graph", type=Path, help="Read an existing plan DOT graph")
    args = parser.parse_args()
    if args.graph:
        graph = args.graph.read_text()
    else:
        graph = subprocess.run(
            [os.environ.get("TF_BIN", "terraform"), "graph", "-type=plan"],
            cwd=Path(__file__).resolve().parents[1],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    edges = {}
    for dependent, prerequisite in re.findall(r'^\s*"([^"\n]+)"\s*->\s*"([^"\n]+)"', graph, re.MULTILINE):
        edges.setdefault(dependent, set()).add(prerequisite)
    consumers = ["aws_eks_cluster.this", "aws_eks_addon.bootstrap", "aws_eks_node_group.this", "aws_eks_addon.storage_dns"]
    prerequisites = ["aws_route.internet", "aws_route.nat", "aws_route_table_association.public", "aws_route_table_association.private"]
    failures = []
    for consumer in consumers:
        for prerequisite in prerequisites:
            path = dependency_path(edges, f"[root] {consumer} (expand)", f"[root] {prerequisite} (expand)")
            if path is None:
                failures.append(f"{consumer} has no dependency path to {prerequisite}")
            else:
                print(" -> ".join(node.removeprefix("[root] ").removesuffix(" (expand)") for node in path))
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    if failures:
        return 1
    print(f"PASS: all {len(consumers) * len(prerequisites)} routing dependency paths exist; reverse deletion retains routes and associations until EKS consumers retire.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
