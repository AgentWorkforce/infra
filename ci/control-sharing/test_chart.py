"""Deployment default session-sharing mode for self-hosted Control."""
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
NAMES = ("SELFHOST_DEFAULT_SHARING_MODE", "SELFHOST_SHARING_MODE_OVERRIDE_ROLES")


class ControlSharing(unittest.TestCase):
    def render(self, sharing=None, umbrella=False, fail=None):
        v = yaml.safe_load((ROOT / "charts/relay-control/ci/default-values.yaml").read_text())
        if sharing is not None:
            v["sharing"] = sharing
        chart = "relay-control"
        if umbrella:
            chart = "agent-relay"
            components = {k: False for k in yaml.safe_load((ROOT / "charts/agent-relay/values.yaml").read_text())["components"]}
            components["control"] = True
            v.setdefault("services", {}).setdefault("relayhistoryBackend", "legacy")
            v = {"components": components, "relay-control": v}
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder) / "values.yaml"
            p.write_text(yaml.safe_dump(v))
            r = subprocess.run(["helm", "template", "ci", str(ROOT / "charts" / chart), "-n", "ci", "-f", str(p)],
                               text=True, capture_output=True)
        if fail:
            self.assertNotEqual(r.returncode, 0, r.stdout[-500:])
            self.assertIn(fail.lower(), r.stderr.lower())
            return None
        self.assertEqual(r.returncode, 0, r.stderr)
        for doc in yaml.safe_load_all(r.stdout):
            if doc and doc.get("kind") == "Deployment" and "control" in doc["metadata"]["name"] and "webapp" not in doc["metadata"]["name"]:
                api = next(c for c in doc["spec"]["template"]["spec"]["containers"] if c["name"] == "api")
                return {e["name"]: e.get("value") for e in api["env"] if e["name"] in NAMES}
        self.fail("no Control Deployment rendered")

    def test_unset_by_default(self):
        self.assertEqual(self.render(), {})
        self.assertEqual(self.render({"defaultMode": "", "overrideRoles": []}), {})

    def test_set_renders_env(self):
        self.assertEqual(self.render({"defaultMode": "selected", "overrideRoles": ["owner"]}),
                         {"SELFHOST_DEFAULT_SHARING_MODE": "selected", "SELFHOST_SHARING_MODE_OVERRIDE_ROLES": "owner"})
        self.assertEqual(self.render({"defaultMode": "all"}), {"SELFHOST_DEFAULT_SHARING_MODE": "all"})
        self.assertEqual(self.render({"overrideRoles": ["owner", "admin"]}),
                         {"SELFHOST_SHARING_MODE_OVERRIDE_ROLES": "owner,admin"})

    def test_umbrella(self):
        self.assertEqual(self.render({"defaultMode": "new", "overrideRoles": ["admin"]}, umbrella=True),
                         {"SELFHOST_DEFAULT_SHARING_MODE": "new", "SELFHOST_SHARING_MODE_OVERRIDE_ROLES": "admin"})

    def test_invalid_refused(self):
        for sharing, msg in [
            ({"defaultMode": "everyone"}, "sharing.defaultMode must be all, new or selected"),
            ({"defaultMode": "All"}, "sharing.defaultMode must be all, new or selected"),
            ({"defaultMode": True}, "sharing.defaultMode must be a string"),
            ({"overrideRoles": "owner"}, "sharing.overrideRoles must be a list"),
            ({"overrideRoles": ["member"]}, "is not owner or admin"),
            ({"overrideRoles": ["owner", "owner"]}, "must not contain duplicates"),
        ]:
            with self.subTest(sharing=sharing):
                self.render(sharing, fail=msg)


if __name__ == "__main__":
    unittest.main()
