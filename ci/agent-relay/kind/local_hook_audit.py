#!/usr/bin/env python3
"""Read-only Claude hook witnesses for a scoped q7m2k9 reset."""
import argparse
import hashlib
import json
import os
from pathlib import Path


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def snapshot(settings, protected_markers):
    if not isinstance(settings, dict) or not isinstance(settings.get("hooks", {}), dict):
        raise ValueError("Claude hooks must be an object")
    remaining, protected = {}, []
    kind_count = 0
    for event, groups in settings.get("hooks", {}).items():
        if not isinstance(groups, list):
            raise ValueError("Claude hook groups must be lists")
        kept = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                raise ValueError("Claude hook groups must contain a hooks list")
            metadata = {k: v for k, v in group.items() if k != "hooks"}
            hooks = []
            for hook in group["hooks"]:
                if not isinstance(hook, dict):
                    raise ValueError("Claude hook entries must be objects")
                command = hook.get("command", "")
                if not isinstance(command, str):
                    raise ValueError("Claude hook commands must be strings")
                kind = "q7m2k9" in command or "Agent Relay Kind.app/" in command
                other = any(marker in command for marker in protected_markers)
                if kind and other:
                    raise ValueError("one hook names both Kind and a protected profile")
                if kind:
                    kind_count += 1
                    continue
                hooks.append(hook)
                if other:
                    protected.append({"event": event, "group": metadata, "hook": hook})
            if hooks:
                kept.append({**metadata, "hooks": hooks})
        if kept:
            remaining[event] = kept
    return {"version": 1, "protectedMarkers": list(protected_markers),
        "kindHookCount": kind_count, "protectedHookCount": len(protected),
        "protectedHooksSha256": digest(protected), "otherHooksSha256": digest(remaining)}


def verify(before, after):
    keys = ("protectedMarkers", "protectedHookCount", "protectedHooksSha256", "otherHooksSha256")
    if before.get("version") != 1 or after.get("version") != 1 or any(k not in before or k not in after for k in keys):
        raise ValueError("invalid hook witness")
    if any(before[k] != after[k] for k in keys):
        raise ValueError("protected or other non-Kind hooks changed")
    if after.get("kindHookCount") != 0:
        raise ValueError("Kind hooks remain")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    collect = sub.add_parser("snapshot")
    collect.add_argument("--settings", type=Path, default=Path.home() / ".claude/settings.json")
    collect.add_argument("--protected-marker", action="append", default=[])
    collect.add_argument("--require-protected", action="store_true")
    collect.add_argument("--output", type=Path)
    compare = sub.add_parser("verify")
    compare.add_argument("before", type=Path)
    compare.add_argument("after", type=Path)
    args = parser.parse_args()
    if args.action == "verify":
        verify(json.loads(args.before.read_text()), json.loads(args.after.read_text()))
        print("Kind hooks absent; protected and other hooks unchanged.")
        return
    settings = json.loads(args.settings.read_text()) if args.settings.exists() else {}
    witness = snapshot(settings, args.protected_marker)
    if args.require_protected and witness["protectedHookCount"] == 0:
        raise ValueError("no protected hooks matched; inspect the marker before cleanup")
    text = json.dumps(witness, indent=2) + "\n"
    if args.output:
        with os.fdopen(os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as stream:
            stream.write(text)
    else:
        print(text, end="")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from None
