#!/usr/bin/env python3
"""Bind a verified full-suite receipt to an Agent Relay candidate ledger."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys


SHA = re.compile(r"^[a-f0-9]{40}$")
COMPONENT_CONTEXT = {
    "relay-control": "control",
    "relay-webapp": "webapp",
    "sessions-pipeline": "pipeline",
}


def fail(message: str) -> None:
    raise ValueError(message)


def load(path: pathlib.Path):
    return json.loads(path.read_text(encoding="utf-8"))


def validate(receipt_path: pathlib.Path, pins_path: pathlib.Path, trusted_source: str) -> dict[str, object]:
    if not SHA.fullmatch(trusted_source):
        fail("trusted observer source is not a full lowercase commit")
    receipt = load(receipt_path)
    ledger = load(pins_path)
    payload = receipt.get("payload") if isinstance(receipt, dict) else None
    if not isinstance(payload, dict):
        fail("acceptance receipt payload is malformed")
    checks = payload.get("checks")
    if (
        payload.get("schema") != "agent-relay.local-acceptance/v1"
        or payload.get("suite") != "full"
        or payload.get("status") != "pass"
        or payload.get("qualificationComplete") is not True
        or payload.get("pendingQualificationChecks") != []
        or not isinstance(checks, list)
        or not checks
        or not all(isinstance(check, dict) and check.get("status") == "pass" for check in checks)
    ):
        fail("acceptance receipt does not prove complete full-suite qualification")
    context = payload.get("context")
    if not isinstance(context, dict) or context.get("sourceRevision") != trusted_source:
        fail("acceptance receipt observer source does not match trusted main")
    observed = context.get("pins")
    candidate = ledger.get("pins") if isinstance(ledger, dict) else None
    if not isinstance(observed, dict) or not isinstance(candidate, dict):
        fail("acceptance or candidate pin map is malformed")
    if set(candidate) != set(COMPONENT_CONTEXT):
        fail("candidate ledger must contain exactly the three published components")
    for component, context_key in COMPONENT_CONTEXT.items():
        pin = candidate.get(component)
        if not isinstance(pin, dict):
            fail(f"candidate pin is malformed for {component}")
        repository = pin.get("repository")
        digest = pin.get("digest")
        if not isinstance(repository, str) or not isinstance(digest, str):
            fail(f"candidate image identity is malformed for {component}")
        if observed.get(context_key) != f"{repository}@{digest}":
            fail(f"observed runtime pin does not match candidate {component}")
    return {
        "qualificationComplete": True,
        "trustedSource": trusted_source,
        "components": sorted(candidate),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--receipt", type=pathlib.Path, required=True)
    parser.add_argument("--pins", type=pathlib.Path, required=True)
    parser.add_argument("--trusted-source", required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(validate(args.receipt, args.pins, args.trusted_source), sort_keys=True))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"validate-release-acceptance: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
