#!/usr/bin/env python3
"""Discover actual installed identities from Kubernetes JSON, without guessing names."""
import json
import sys

STAGES = {"bob-costas", "hoopdb-indexer", "referee"}


def stages(item):
    spec = item.get("spec", {})
    pod = spec.get("template", {}).get("spec", spec)
    return {env.get("value") for container in pod.get("containers", [])
            for env in container.get("env", []) if env.get("name") == "SERVICE"}


def ingest_pod(items):
    matches = [item["metadata"]["name"] for item in items if "alleyoop-ingest" in stages(item)
               and item.get("status", {}).get("phase") == "Running"
               and any(condition.get("type") == "Ready" and condition.get("status") == "True"
                       for condition in item.get("status", {}).get("conditions", []))]
    if len(matches) != 1:
        raise ValueError("expected exactly one ready ingest pod")
    return matches[0]


def worker_deployment(items, stage):
    if stage not in STAGES:
        raise ValueError("unknown worker stage")
    matches = [item["metadata"]["name"] for item in items if stage in stages(item)]
    if len(matches) != 1:
        raise ValueError("expected exactly one deployment for the engine stage")
    return "deploy/" + matches[0]


def service_accounts(items):
    return sorted({item["spec"]["template"]["spec"].get("serviceAccountName", "default") for item in items if stages(item) & (STAGES | {"alleyoop-ingest"})})


if __name__ == "__main__":
    try:
        items = json.load(sys.stdin)["items"]
        if sys.argv[1] == "worker":
            print(worker_deployment(items, sys.argv[2]))
        elif sys.argv[1] == "ingest-pod":
            print(ingest_pod(items))
        elif sys.argv[1] == "service-accounts":
            print("\n".join(service_accounts(items)))
        else:
            raise ValueError("unknown discovery mode")
    except (KeyError, ValueError, TypeError, IndexError):
        print("session identity discovery failed; inspect the installed release", file=sys.stderr)
        sys.exit(1)
