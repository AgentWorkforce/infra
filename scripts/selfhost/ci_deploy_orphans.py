#!/usr/bin/env python3
"""Orphan checks for ci-deploy.sh (env/replace-orphans.txt).

An orphan is a live object that a release now renders, under the same name, but that carries no Helm ownership
for that release (it was created outside Helm, for example a hand-run bootstrap Job). `helm upgrade` refuses to
adopt it. replace-orphans.txt lists, after review, the hash-named Jobs the apply may delete so Helm re-creates them:

    job <release> <namespace>/<name>   # why, who approved

  objects <dry-run.json> <namespace>        print "kind<TAB>name<TAB>namespace" for every object the dry run renders
  check <release> <live.json> <list> <out>  live.json: the concatenated `kubectl get -o json` of those objects.
                                            Exit 4 if an unowned object is not listed (or a listed one is not a
                                            finished Job); write the listed orphans the apply will replace to <out>.
"""
import json
import sys

import yaml


def rendered(dry_run, default_ns):
    doc = json.loads(open(dry_run).read())
    for text in (doc.get("manifest") or "", *[h.get("manifest") or "" for h in doc.get("hooks") or []]):
        for o in yaml.safe_load_all(text):
            if isinstance(o, dict) and o.get("kind") and (o.get("metadata") or {}).get("name"):
                yield o["kind"], o["metadata"]["name"], o["metadata"].get("namespace") or default_ns


def live_objects(path):
    text, dec, i, out = open(path).read(), json.JSONDecoder(), 0, []
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text):
            return out
        o, i = dec.raw_decode(text, i)
        out.extend(o.get("items", []) if o.get("kind", "").endswith("List") else [o])


def listed(path, release):
    out = set()
    for line in open(path):
        f = line.split("#", 1)[0].split()
        if f and f[0] == "job" and len(f) >= 3 and f[1] == release:
            out.add(f[2])
    return out


def finished(job):
    return any(c.get("type") == "Complete" and c.get("status") == "True" for c in (job.get("status") or {}).get("conditions") or [])


def check(release, live_path, list_path, out_path):
    allowed, replace, bad = listed(list_path, release), [], []
    for o in live_objects(live_path):
        m = o.get("metadata") or {}
        if (m.get("annotations") or {}).get("meta.helm.sh/release-name") == release:
            continue  # owned: a normal upgrade
        key = f"{m.get('namespace', '')}/{m.get('name', '')}"
        if o.get("kind") == "Job" and key in allowed:
            (replace if finished(o) else bad).append(key if finished(o) else f"Job {key} is listed but not finished")
        else:
            bad.append(f"{o.get('kind')} {key} exists without Helm ownership of {release} and is not in replace-orphans.txt")
    with open(out_path, "w") as f:
        f.writelines(k + "\n" for k in sorted(replace))
    for b in bad:
        print(b, file=sys.stderr)
    return 4 if bad else 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "objects" and len(sys.argv) == 4:
        for k, n, ns in rendered(sys.argv[2], sys.argv[3]):
            print(f"{k}\t{n}\t{ns}")
    elif cmd == "check" and len(sys.argv) == 6:
        sys.exit(check(*sys.argv[2:6]))
    else:
        sys.exit(__doc__)
