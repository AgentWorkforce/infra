#!/usr/bin/env python3
"""Compare a live Helm release with the release an upgrade would write, for scripts/selfhost/ci-deploy.sh.

Usage: ci_deploy_plan.py <release> <live dir> <new release JSON> <allow file> <out dir>

<live dir> holds values.json (helm get values -o json), manifest.yaml and hooks.yaml (helm get manifest/hooks),
or is empty when the release does not exist. <new release JSON> is `helm upgrade --dry-run=client -o json`.

Writes <out dir>/<release>.diff (unified diff per resource, Secret data replaced by digests) and
<out dir>/<release>.json (summary). Exit 0: nothing is dropped, or every drop is allowed. Exit 3: the upgrade
would drop a live value or resource that the allow file does not list.

Allow file: one entry per line, '#' comments:
  value <release> <dotted.path>            a user-supplied value that may disappear (the path and everything under it)
  resource <release> <Kind>/<namespace>/<name>   a rendered resource that may disappear
"""
import difflib
import hashlib
import json
import re
import sys
from pathlib import Path

import yaml

SECRET_KINDS = {"Secret"}


def leaves(value, prefix=()):
    """Flatten user-supplied values to {path tuple: value}. Lists are leaves (Helm replaces them whole).
    Tuples keep {"a": {"b": 1}} and {"a.b": 1} apart."""
    if isinstance(value, dict):
        if not value and prefix:
            return {prefix: {}}
        out = {}
        for k, v in value.items():
            out.update(leaves(v, prefix + (str(k),)))
        return out
    return {prefix: value}


def dotted(path):
    return ".".join(path)


def redact(doc):
    if doc.get("kind") in SECRET_KINDS:
        doc = dict(doc)
        for field in ("data", "stringData"):
            if isinstance(doc.get(field), dict):
                doc[field] = {k: "sha256:" + hashlib.sha256(str(v).encode()).hexdigest()[:16]
                              for k, v in doc[field].items()}
    return doc


def resources(*texts):
    """{Kind/namespace/name: redacted YAML} from manifest text(s)."""
    out = {}
    for text in texts:
        for doc in yaml.safe_load_all(text or ""):
            if not isinstance(doc, dict) or "kind" not in doc:
                continue
            meta = doc.get("metadata") or {}
            key = f"{doc['kind']}/{meta.get('namespace', '')}/{meta.get('name', '')}"
            out[key] = yaml.safe_dump(redact(doc), sort_keys=True, default_flow_style=False)
    return out


SECRET_PATH = re.compile(r"(secret|password|passwd|token|credential|dsn|private|apikey|api_key)", re.I)


def show(path, values, absent):
    """A value for the diff. Digest only when any path segment looks secret (dbPassword.value,
    credentials.database.url) or the value is a list or map (extraEnv: [{name: DB_PASSWORD, value: ...}])."""
    if path not in values:
        return absent
    value = values[path]
    text = json.dumps(value, sort_keys=True)
    if any(SECRET_PATH.search(seg) for seg in path) or isinstance(value, (list, dict)):
        return "sha256:" + hashlib.sha256(text.encode()).hexdigest()[:16]
    return text


def load_allow(path, release):
    values, res = set(), set()
    p = Path(path)
    if not p.is_file():
        return values, res
    for n, line in enumerate(p.read_text().splitlines(), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 3 or parts[0] not in ("value", "resource"):
            sys.exit(f"{path}:{n}: expected 'value <release> <path>' or 'resource <release> <Kind/ns/name>'")
        if parts[1] != release:
            continue
        (values if parts[0] == "value" else res).add(parts[2])
    return values, res


def value_allowed(path, allowed):
    """path: tuple; allowed: dotted prefixes from the allow file."""
    name = dotted(path)
    return any(name == a or name.startswith(a + ".") for a in allowed)


def compare(release, live_dir, new_release, allow_values, allow_resources):
    live_dir = Path(live_dir)
    exists = (live_dir / "values.json").is_file()
    live_values = json.loads((live_dir / "values.json").read_text() or "{}") if exists else {}
    live_values = live_values or {}
    new_values = new_release.get("config") or {}
    lv, nv = leaves(live_values), leaves(new_values)

    live_res = resources(*(live_dir.joinpath(f).read_text() for f in ("manifest.yaml", "hooks.yaml")
                           if live_dir.joinpath(f).is_file())) if exists else {}
    new_res = resources(new_release.get("manifest", ""),
                        *(h.get("manifest", "") for h in new_release.get("hooks") or []))

    dropped_values = sorted(p for p in lv if p not in nv)
    changed_values = sorted(p for p in nv if p in lv and nv[p] != lv[p])
    dropped_resources = sorted(k for k in live_res if k not in new_res)
    summary = {
        "release": release,
        "exists": exists,
        "values": {
            "added": [dotted(p) for p in sorted(p for p in nv if p not in lv)],
            "changed": [dotted(p) for p in changed_values],
            "dropped": [dotted(p) for p in dropped_values],
        },
        "resources": {
            "added": sorted(k for k in new_res if k not in live_res),
            "changed": sorted(k for k in new_res if k in live_res and new_res[k] != live_res[k]),
            "dropped": dropped_resources,
        },
        "refused": {
            "values": [dotted(p) for p in dropped_values if not value_allowed(p, allow_values)],
            "resources": [k for k in dropped_resources if k not in allow_resources],
        },
    }
    diff = []
    for key in sorted(set(live_res) | set(new_res)):
        a, b = live_res.get(key, ""), new_res.get(key, "")
        if a != b:
            diff.extend(difflib.unified_diff(a.splitlines(True), b.splitlines(True),
                                             f"live/{key}", f"new/{key}", n=3))
    # Values diff by path. Values files are non-secret by policy, but a live value set by hand might not be:
    # a path that looks secret shows digests only.
    for p in sorted(set(lv) | set(nv)):
        if p not in lv or p not in nv or lv[p] != nv[p]:  # null -> absent is a change
            diff.append(f"value {dotted(p)}: {show(p, lv, '<absent>')} -> {show(p, nv, '<absent>')}\n")
    summary["no_changes"] = not diff
    return summary, "".join(diff)


def main(argv):
    if len(argv) != 6:
        sys.exit(__doc__.splitlines()[2])
    release, live_dir, new_json, allow_file, out_dir = argv[1:]
    new_release = json.loads(Path(new_json).read_text())
    allow_values, allow_resources = load_allow(allow_file, release)
    summary, diff = compare(release, live_dir, new_release, allow_values, allow_resources)
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / f"{release}.diff").write_text(diff)
    (out / f"{release}.json").write_text(json.dumps(summary, indent=2) + "\n")
    v, r = summary["values"], summary["resources"]
    print(f"{release}: {'no changes' if summary['no_changes'] else 'changes'}; "
          f"values +{len(v['added'])} ~{len(v['changed'])} -{len(v['dropped'])}; "
          f"resources +{len(r['added'])} ~{len(r['changed'])} -{len(r['dropped'])}")
    refused = summary["refused"]
    if refused["values"] or refused["resources"]:
        for p in refused["values"]:
            print(f"REFUSED: drops live value {p} (allow with: value {release} {p})", file=sys.stderr)
        for k in refused["resources"]:
            print(f"REFUSED: drops live resource {k} (allow with: resource {release} {k})", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
