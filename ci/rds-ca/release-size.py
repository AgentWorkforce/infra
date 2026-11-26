"""Estimate the Helm release Secret for a packaged chart and a rendered manifest.

Helm stores a release as base64(gzip(json(release))) in one Secret, and a
Secret is limited to 1 MiB. Only the top chart's own files go into that JSON:
subcharts are not serialized (helm.sh/helm pkg/chart: dependencies is
unexported). This mirrors that encoding closely enough to catch growth, such
as the RDS CA bundles in charts/agent-relay/files/rds-ca.

  python3 -I ci/rds-ca/release-size.py <chart.tgz> <manifest.yaml>   prints bytes
"""
import base64
import gzip
import io
import json
import sys
import tarfile


def top_chart(tgz):
    tf = tarfile.open(tgz)
    root = tf.getmembers()[0].name.split("/")[0] + "/"
    chart = {"metadata": None, "lock": None, "templates": [], "values": {}, "schema": None, "files": []}
    for m in tf.getmembers():
        if not m.isfile() or not m.name.startswith(root):
            continue
        rel = m.name[len(root):]
        if rel.startswith("charts/"):
            continue
        data = tf.extractfile(m).read()
        b64 = base64.b64encode(data).decode()
        # Helm stores these parsed; their text is a close stand-in for the size.
        if rel in ("Chart.yaml", "Chart.lock", "values.yaml"):
            chart[{"Chart.yaml": "metadata", "Chart.lock": "lock", "values.yaml": "values"}[rel]] = data.decode()
        elif rel == "values.schema.json":
            chart["schema"] = b64
        elif rel.startswith("templates/"):
            chart["templates"].append({"name": rel, "data": b64})
        else:
            chart["files"].append({"name": rel, "data": b64})
    return chart


release = {"name": "agent-relay", "namespace": "agent-relay", "version": 1, "info": {},
           "chart": top_chart(sys.argv[1]), "config": {}, "manifest": open(sys.argv[2]).read()}
raw = json.dumps(release, default=str).encode()
print(len(base64.b64encode(gzip.compress(raw, 9))))
