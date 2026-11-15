#!/usr/bin/env python3
"""Kind acceptance foundation; the full qualification suite fails closed until complete."""
import argparse
import datetime
import json
from pathlib import Path
import sys
import time
import uuid

from api import Api, CHECKS, Failure, load_config
from context import collect
from report import archive_previous, verify, write_signed
from telemetry import cast_collector

ROOT = Path(__file__).resolve().parents[4]
PENDING = ["desktop_manual_evidence", "upload_wasm_drain", "playwright_ui", "telemetry_brief",
           "mcp_launch_refusal_release", "two_way_messaging", "catalog_activation_agent_filter",
           "dev_loop_restore", "cold_install_and_scoped_cleanup_evidence"]


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def execute(config_path, output, key, suite="full", snapshotter=collect):
    archive_previous(output)
    started = time.monotonic()
    payload = {"schema": "agent-relay.local-acceptance/v1", "runId": str(uuid.uuid4()),
               "suite": suite, "startedAt": now(), "site": "https://relay.kind.agentrelay.com",
               "qualificationComplete": False, "checks": []}

    def check(name, function):
        before = time.monotonic()
        result = {"id": name, "status": "fail"}
        try:
            result["evidence"] = function()
            result["status"] = "pass"
        except Failure as error:
            result["code"] = error.code
        except Exception:
            # Exception strings may contain HTTP bodies, auth headers or filesystem paths.
            result["code"] = "observation_failed"
        result["seconds"] = round(time.monotonic() - before, 6)
        payload["checks"].append(result)
        return result["status"] == "pass"

    state = {}

    def setup():
        config = load_config(config_path)
        payload["fixture"] = {field: config[field] for field in ["organizationId", "workspaceId", "sessionId", "source"]}
        payload["context"] = snapshotter(config, ROOT)
        state["config"] = config
        state["api"] = Api(config["caFile"], config["ownerState"], config["memberState"])
        return {"publishedPinsMatch": True, "sourceClean": True}

    if check("preflight", setup):
        for name, function in CHECKS:
            check(name, lambda f=function: f(state["api"], state["config"]))
        backend = payload["context"].get("relaycastBackend")
        if backend:
            before = time.monotonic()
            try:
                result = cast_collector(state["config"], backend)
            except Failure as error:
                result = {"id": "cast_collector", "status": "fail", "code": error.code}
            except Exception:
                result = {"id": "cast_collector", "status": "fail", "code": "observation_failed"}
            result["seconds"] = round(time.monotonic() - before, 6)
            payload["checks"].append(result)
            if result["status"] == "skipped":
                payload["requiredCompanionProfiles"] = ["postgres_cast_collector"]
    else:
        for name, _ in CHECKS:
            payload["checks"].append({"id": name, "status": "fail", "code": "preflight_failed", "seconds": 0})
    if suite == "full":
        for name in PENDING:
            payload["checks"].append({"id": name, "status": "fail", "code": "not_implemented", "seconds": 0})
    payload["pendingQualificationChecks"] = PENDING
    failed = any(c["status"] == "fail" for c in payload["checks"])
    skipped = any(c["status"] == "skipped" for c in payload["checks"])
    payload["status"] = "fail" if failed else "pass_with_skips" if skipped else "pass"
    payload["finishedAt"] = now()
    payload["seconds"] = round(time.monotonic() - started, 6)
    envelope = write_signed(output, payload, key)
    return (1 if failed else 0), envelope


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run")
    run.add_argument("--config", type=Path, default=ROOT / ".kind/acceptance/config.json")
    run.add_argument("--output", type=Path, default=ROOT / ".kind/acceptance/acceptance.json")
    run.add_argument("--key", type=Path, default=ROOT / ".kind/acceptance/signing_key")
    run.add_argument("--suite", choices=["api", "full"], default="full")
    check = sub.add_parser("verify")
    check.add_argument("receipt", type=Path)
    check.add_argument("--trusted-key", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "verify":
            payload = verify(args.receipt, args.trusted_key)
            print(json.dumps({"signatureValid": True, "suite": payload["suite"], "status": payload["status"],
                              "qualificationComplete": payload["qualificationComplete"]}))
            return 0
        code, envelope = execute(args.config, args.output, args.key, args.suite)
        payload = envelope["payload"]
        print(json.dumps({"suite": args.suite, "status": payload["status"], "keyId": envelope["signature"]["keyId"],
                          "qualificationComplete": False, "checks": [{k: c[k] for k in ["id", "status"]} for c in payload["checks"]]}))
        return code
    except Exception:
        print("Acceptance report/signature could not be written or verified.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
