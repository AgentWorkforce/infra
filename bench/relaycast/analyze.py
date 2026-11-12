#!/usr/bin/env python3
"""Summarize private benchmark receipts without exporting credentials or bodies."""
import argparse
from datetime import datetime
import json
from pathlib import Path


def epoch(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def peaks(samples, start, end):
    result = {}
    for sample in samples:
        for pod in sample.get("nodeStats", {}).get("pods", []):
            if pod.get("podRef", {}).get("namespace") != "relaycast-bench":
                continue
            for container in pod.get("containers", []):
                current = result.setdefault(container["name"], {"cpuCores": None, "workingSetMiB": None})
                # Kubelet caches samples. Use their metric time, not the time
                # the observer fetched an old value during a later rate step.
                for field, key, divisor in (("cpu", "usageNanoCores", 1e9), ("memory", "workingSetBytes", 1024**2)):
                    metric = container.get(field, {})
                    if metric.get("time") and start <= epoch(metric["time"]) <= end:
                        output = "cpuCores" if field == "cpu" else "workingSetMiB"
                        current[output] = max(current[output] or 0, metric.get(key, 0) / divisor)
    return result


def summarize(directory):
    report = json.loads((directory / "report.json").read_text())
    identity = json.loads((directory / "identity.json").read_text())
    samples = json.loads((directory / "resources.json").read_text())
    rows = []
    for step in report.get("steps", []):
        start = epoch(step["startedAt"])
        row = {key: step.get(key) for key in ("requestedScale", "requestedGlobalRps", "offeredSupportedRps", "routeCoverageShare",
            "seconds", "achievedRps", "drainAdjustedRps", "errorFraction", "latencyMs", "sloPass", "limitSignal",
            "activeSocketsAtEnd", "drainSeconds", "maximumInflight", "generator")}
        row["resources"] = peaks(samples, start, start + step["seconds"] + step["drainSeconds"])
        row["failedRoutes"] = [{"method": r["method"], "pathTemplate": r["pathTemplate"], "status": r["status"],
            "errorCodes": r.get("errorCodes", {})} for r in step["routes"]
            if any(code != "101" and not (code.isdigit() and 200 <= int(code) < 300) for code in r["status"])]
        rows.append(row)
    first = next(iter(report.get("steps", [])), {})
    return {"run": directory.name, "workloadKind": report.get("workloadKind"), "status": report["status"],
        "failureCode": report.get("failureCode"),
        "sourceRevision": identity["infraRevision"], "build": identity["build"], "harness": report.get("harness"),
        "population": report.get("population"), "payloadModel": report.get("payloadModel"), "slo": report.get("slo"),
        "actorMessageRoundTrip": report.get("actorMessageRoundTrip"), "postLoadMessageRoundTrip": report.get("postLoadMessageRoundTrip"),
        "websockets": report.get("websockets"), "workspaceCleanup": report.get("workspaceCleanup"),
        "auxiliaryRegistrations": report.get("auxiliaryRegistrations"), "steps": rows,
        "excludedRoutes": [{"method": r["method"], "pathTemplate": r["pathTemplate"], "probeStatus": r["probeStatus"]}
            for r in first.get("routes", []) if not r["supported"]]}


def markdown(reports):
    lines = ["# Local actor benchmark", "", "Private measurement receipt; no production equivalence or release qualification is claimed.", "",
             "| Workload | Requested RPS | Supported RPS | Achieved RPS | p95 ms | Errors | SLO | Limit signal |",
             "|---|---:|---:|---:|---:|---:|---|---|"]
    for report in reports:
        for row in report["steps"]:
            latency = row["latencyMs"]["p95"]
            lines.append("| {} | {:.1f} | {:.1f} | {:.1f} | {} | {:.2%} | {} | {} |".format(
                report["workloadKind"], row["requestedGlobalRps"], row["offeredSupportedRps"], row["achievedRps"],
                "n/a" if latency is None else f"{latency:.0f}", row["errorFraction"], "pass" if row["sloPass"] else "fail", row["limitSignal"]))
    lines.extend(["", "Population, body sizes and socket lifetimes are assumptions. CPU/memory ceilings and co-resident workloads matter.",
                  "In-flight backpressure or generator scheduling pressure alone cannot establish backend saturation.", ""])
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runs", nargs="+", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    reports = [summarize(directory) for directory in args.runs]
    args.output.mkdir(mode=0o700, parents=True, exist_ok=True)
    for name, value in (("summary.json", json.dumps({"schema": "agent-relay.actor-benchmark-summary/v1", "runs": reports}, indent=2)),
                        ("summary.md", markdown(reports))):
        path = args.output / name;path.write_text(value + "\n");path.chmod(0o600)
    print(json.dumps({"reports": len(reports), "directory": str(args.output)}))


if __name__ == "__main__":
    main()
