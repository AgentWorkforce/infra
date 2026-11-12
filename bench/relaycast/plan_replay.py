#!/usr/bin/env python3
"""Compile aggregate traffic into bounded replay steps. Never opens a network connection."""
import argparse
import datetime
import hashlib
import json
import math
from pathlib import Path
import re
import sys


DEFAULTS = {"workspaces_active_peak": 5, "agents_per_workspace": 10,
            "ws_connections_peak": 50, "channel_members": 10, "upload": 0}
DEFAULT_CAPS = {"rps": 1000, "websockets": 500, "agents": 500, "workspaces": 100}
OPAQUE_ID = re.compile(r"/(?:inv_idem_[a-f0-9]{32,}|[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12})(?=/|$)", re.IGNORECASE)
PATH = re.compile(r"/(?:v1|internal)/(?:[A-Za-z0-9_:-]+/?)+")


def number(value, positive=False):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError("invalid_number")
    if value < 0 or (positive and value == 0):
        raise ValueError("invalid_number")
    return value


def window(value):
    start, end = [datetime.datetime.fromisoformat(s.replace("Z", "+00:00")) for s in value.split("/")]
    if not start.tzinfo or not end.tzinfo or end <= start:
        raise ValueError("invalid_window")
    return value


def route_mix(profile):
    rows = profile["routes"]
    if not isinstance(rows, list) or not 0 < len(rows) <= 256:
        raise ValueError("invalid_routes")
    grouped = {}
    for row in rows:
        method, path = row["method"], row["path"]
        if method not in {"GET", "POST", "PATCH", "PUT", "DELETE", "HEAD", "OPTIONS"}:
            raise ValueError("invalid_method")
        path = OPAQUE_ID.sub(lambda match: "/:invocation_id" if "inv_idem_" in match.group() else "/:id", path)
        if not PATH.fullmatch(path) or ".." in path:
            raise ValueError("invalid_route_template")
        rate = number(row["rps_avg"])
        # These may be estimates rather than simultaneous measured route peaks.
        number(row["rps_peak"])
        if "share" in row:
            number(row["share"])
        key = method, path
        grouped[key] = grouped.get(key, 0) + rate
    total = sum(grouped.values())
    number(total, positive=True)
    return total, [(method, path, rate / total) for (method, path), rate in sorted(grouped.items())]


def compile_plan(profile, scales=(1, 3, 10), caps=None, assumptions=None):
    caps = {**DEFAULT_CAPS, **(caps or {})}
    assumptions = {**DEFAULTS, **(assumptions or {})}
    if set(caps) != set(DEFAULT_CAPS) or set(assumptions) != set(DEFAULTS):
        raise ValueError("unknown_limit_or_assumption")
    for key, value in caps.items():
        number(value, positive=True)
        if key != "rps" and (not isinstance(value, int) or isinstance(value, bool)):
            raise ValueError("integer_limit_required")
    for key, value in assumptions.items():
        number(value, positive=key != "upload")
        if not isinstance(value, int) or isinstance(value, bool):
            raise ValueError("integer_assumption_required")
    peak = number(profile["rps_peak_minute_max"], positive=True)
    average = number(profile["rps_avg"])
    peak_hour = number(profile["rps_peak_hour"])
    percentile = number(profile["rps_peak_minute_p99"])
    if percentile > peak or peak_hour > peak:
        raise ValueError("inconsistent_peak")
    windows = {name: window(profile["window"][name]) for name in ("hourly_and_totals", "routes_and_minute_peaks")}
    hourly = profile["hourly_curve"]
    if not isinstance(hourly, list) or len(hourly) != 24 or not any(number(v) > 0 for v in hourly):
        raise ValueError("invalid_hourly_curve")
    # Validate every bin even if an early positive value satisfied any().
    for value in hourly:
        number(value)
    total, mix = route_mix(profile)
    status_mix = profile["status_mix"]
    for key in ("2xx", "4xx", "5xx", "1xx_ws_upgrade"):
        if number(status_mix[key]) > 1:
            raise ValueError("invalid_status_mix")
    if not .98 <= sum(status_mix.values()) <= 1.02:
        raise ValueError("invalid_status_mix")
    number(profile["burst"]["max_1min_over_avg"], positive=True)
    number(profile["messages_per_s"]["writes_avg"])
    for key in ("node_ws", "ws"):
        number(profile["ws_upgrades_per_s"][key])
    workspaces = assumptions["workspaces_active_peak"]
    agents = workspaces * assumptions["agents_per_workspace"]
    sockets = assumptions["ws_connections_peak"]
    maximum_scale = min(caps["rps"] / peak, caps["websockets"] / sockets,
                        caps["agents"] / agents, caps["workspaces"] / workspaces)
    steps = []
    for scale in scales:
        number(scale, positive=True)
        effective = min(scale, maximum_scale)
        target = peak * effective
        active = min(caps["workspaces"], caps["agents"], max(1, math.ceil(workspaces * effective)))
        steps.append({"requestedScale": scale, "effectiveScale": effective, "capped": effective < scale,
            "requestedPeakRps": peak * scale, "targetPeakRps": target,
            "assumedPopulation": {"workspaces": active,
                "agents": min(caps["agents"], max(active, math.ceil(agents * effective))),
                "websockets": min(caps["websockets"], max(1, math.ceil(sockets * effective)))},
            "routes": [{"method": method, "pathTemplate": path, "share": share,
                "targetRps": target * share,
                "websocket": path in {"/v1/node/ws", "/v1/ws", "/v1/node/terminal/ws"},
                "requiresInternalFixture": path.startswith("/internal/")}
                for method, path, share in mix]})
    if not steps:
        raise ValueError("empty_steps")
    return {"schema": "agent-relay.relaycast-replay-plan/v1", "execution": "not_run",
        "providedMeasurements": {"averageRps": average, "peakHourRps": peak_hour,
            "minutePeakRps": peak, "minuteP99Rps": percentile, "windows": windows,
            "routeWindowAverageRps": total, "statusMix": status_mix},
        "assumptions": assumptions, "caps": caps, "steps": steps,
        "hourlyCurve": hourly, "oneSecondBurstShape": None,
        "interpretation": ["route averages normalized to the supplied global minute peak",
            "route-window and aggregate-window averages are not interchangeable",
            "provided burst factor is not applied again to the minute peak",
            "message and WebSocket rates are subsets of route traffic, not additional requests",
            "population and upload defaults are assumed, not measured",
            "production status mix is reference data, not a request to reproduce errors",
            "no production IDs, credentials or content may be used by an executor"],
        "measuredSaturation": None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--scales", default="1,3,10")
    parser.add_argument("--max-rps", type=float, default=DEFAULT_CAPS["rps"])
    parser.add_argument("--max-websockets", type=int, default=DEFAULT_CAPS["websockets"])
    parser.add_argument("--max-agents", type=int, default=DEFAULT_CAPS["agents"])
    parser.add_argument("--max-workspaces", type=int, default=DEFAULT_CAPS["workspaces"])
    args = parser.parse_args()
    try:
        with args.profile.open("rb") as stream:
            raw = stream.read(1048577)
        if len(raw) > 1048576:
            raise ValueError("profile_too_large")
        plan = compile_plan(json.loads(raw), [float(s) for s in args.scales.split(",")],
            {"rps": args.max_rps, "websockets": args.max_websockets,
             "agents": args.max_agents, "workspaces": args.max_workspaces})
        plan["profileSha256"] = hashlib.sha256(raw).hexdigest()
        print(json.dumps(plan, indent=2, allow_nan=False))
    except (OSError, ValueError, KeyError, TypeError, AttributeError, OverflowError):
        print("Invalid replay profile or limits; no workload executed.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
