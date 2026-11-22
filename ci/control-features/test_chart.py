"""selectedFeatures renders SELFHOST_FEATURES and refuses names Control does not know."""
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]


class ControlFeatures(unittest.TestCase):
    def render(self, selected, fail=None):
        v = yaml.safe_load((ROOT / "charts/relay-control/ci/default-values.yaml").read_text())
        v["selectedFeatures"] = selected
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder) / "values.yaml"
            p.write_text(yaml.safe_dump(v))
            r = subprocess.run(["helm", "template", "ci", str(ROOT / "charts/relay-control"), "-n", "ci", "-f", str(p)],
                               text=True, capture_output=True)
        if fail:
            self.assertNotEqual(r.returncode, 0)
            self.assertIn(fail, r.stderr)
            return None
        self.assertEqual(r.returncode, 0, r.stderr)
        for doc in yaml.safe_load_all(r.stdout):
            if doc and doc.get("kind") == "Deployment":
                api = next(c for c in doc["spec"]["template"]["spec"]["containers"] if c["name"] == "api")
                return {e["name"]: e.get("value") for e in api["env"]}.get("SELFHOST_FEATURES")
        self.fail("no Control Deployment rendered")

    def test_events_shim_renders(self):
        self.assertEqual(self.render(["events_shim"]), "events_shim")
        self.assertEqual(self.render(["usage", "usage_people", "events_shim"]), "usage,usage_people,events_shim")

    def test_core_and_null(self):
        self.assertEqual(self.render([]), "")
        self.assertIsNone(self.render(None))

    def test_refusals(self):
        self.render(["events-shim"], fail="unknown optional component")
        self.render(["events_shim", "events_shim"], fail="must not contain duplicates")


if __name__ == "__main__":
    unittest.main()
