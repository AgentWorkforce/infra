"""Real Helm core phase composition; synthetic identities, never installed."""
from copy import deepcopy
from pathlib import Path
import subprocess
import unittest

import yaml

from native_core_values import compose
from native_inspect import NativeReadOnlyAdapter
from native_core import NativeCoreAdapter
from native_recipe import NativeRecipeError
from test_native_core import TENANT
from test_native_control import contract
from test_native_recipe import selected

ROOT = Path(__file__).resolve().parents[3]


class Render(unittest.TestCase):
    def setUp(self):
        self.s = selected(); self.s["control"]["independentIssuer"] = True; self.s["readerLoginAdvertisesSync"] = False
        self.s["reference"] = "docker.io/" + self.s["reference"]
        self.s["control"]["reference"] = "docker.io/" + self.s["control"]["reference"]
        self.base = yaml.safe_load((ROOT / "charts/agent-relay/values-kind-core.yaml").read_text())

    def render(self, phase, change=None):
        value = compose(self.base, self.s, contract(), phase, TENANT if phase == "serve" else None)
        if change:
            change(value)
        result = subprocess.run(["helm", "template", "agent-relay", str(ROOT / "charts/agent-relay"),
            "-n", "agent-relay", "-f", "-"], input=yaml.safe_dump(value), capture_output=True, text=True)
        return result

    def test_real_initial_chart_cannot_start_any_pipeline_or_privileged_job(self):
        result = self.render("control"); self.assertEqual(result.returncode, 0, result.stderr)
        docs = [d for d in yaml.safe_load_all(result.stdout) if d]
        self.assertEqual({d["metadata"]["name"] for d in docs if d["kind"] == "Deployment"}, {"relay-control", "relaycast"})
        self.assertFalse(any(d["kind"] in {"Secret", "Job"} for d in docs))
        api = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "relay-control")
        env = {e["name"]: e.get("value") for e in api["spec"]["template"]["spec"]["containers"][0]["env"]}
        self.assertEqual(env["SELFHOST_FEATURES"], "")
        self.assertEqual(env["RELAYHISTORY_BACKEND"], "native")
        self.assertNotIn("RELAYAUTH_URL", env)
        self.assertNotIn("SELFHOST_LICENSE_FILE", env)

    def test_real_final_chart_passes_same_production_native_render_guard(self):
        result = self.render("serve"); self.assertEqual(result.returncode, 0, result.stderr)
        docs = [d for d in yaml.safe_load_all(result.stdout) if d]
        a = NativeCoreAdapter.__new__(NativeCoreAdapter); a.control = contract()
        self.assertFalse(a._validate_render_docs(self.s, docs)["readerLoginAdvertisesSync"])
        self.assertFalse(any(d["kind"] in {"Secret", "Job"} for d in docs))
        reader = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "session-read-api")
        pod = reader["spec"]["template"]["spec"]
        env = {e["name"]: e for e in pod["containers"][0]["env"]}
        self.assertEqual(env["READ_API_DIRECTORY_WORKSPACES"]["value"], TENANT["workspaceId"])
        self.assertEqual(env["SESSION_POSTGRES_CA_FILE"]["value"], "/etc/session-read-postgres/ca.crt")
        self.assertEqual(env["READ_API_EVENT_MESSAGE_IDS"]["value"], "true")
        self.assertNotIn("RELAYCONTROL_INTROSPECT_SECRET", env)
        policies = [d for d in docs if d["kind"] == "NetworkPolicy"]
        self.assertNotIn("kind-control-native-readback-egress", {d["metadata"]["name"] for d in policies})
        routing = next(d for d in docs if d["kind"] == "Ingress" and d["metadata"]["name"] == "agent-relay-native-history")
        paths = routing["spec"]["rules"][0]["http"]["paths"]
        self.assertEqual(paths[0]["path"], "/v1")
        self.assertFalse(any(p["path"] == "/" for p in paths))
        for target in ("relay-control", "session-read-api"):
            changed = deepcopy(docs)
            pod = next(d for d in changed if d["kind"] == "Deployment" and d["metadata"]["name"] == target)["spec"]["template"]["spec"]
            pod.setdefault("volumes", []).append({"name": "hidden-owner", "secret": {"secretName": contract()["owner"]["name"]}})
            with self.subTest(target=target), self.assertRaisesRegex(NativeRecipeError, "owner_or_foreign_secret"):
                a._validate_render_docs(self.s, changed)

    def test_native_phase_cannot_bypass_core_component_or_authority_boundary(self):
        for phase, change in (("control", lambda v: v["components"].update(sessionsPipeline=True)),
                              ("serve", lambda v: v["components"].update(relayhistory=True)),
                              ("serve", lambda v: v["relay-control"]["services"].update(relayauthEnabled=True)),
                              ("serve", lambda v: v["relay-control"].update(selectedFeatures=["unknown"]))):
            result = self.render(phase, change)
            with self.subTest(phase=phase):
                self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__": unittest.main()
