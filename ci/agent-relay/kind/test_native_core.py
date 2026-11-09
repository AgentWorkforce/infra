"""Causal native core phase tests; no cluster, provider or SQL writes."""
from copy import deepcopy
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from native_core import NativeCoreAdapter, image_id_matches
from native_core_values import compose, PLANNING_WORKSPACE
from native_recipe import NativeRecipeError
from test_native_recipe import selected
from test_native_control import contract


TENANT = {"organizationId": "11111111-1111-4111-8111-111111111111",
          "workspaceId": "22222222-2222-4222-8222-222222222222"}


class Core(unittest.TestCase):
    def test_running_content_identity_cannot_be_replaced_by_matching_tag_or_other_manifest(self):
        reference = "docker.io/agent-relay-kind/runtime@sha256:" + "a" * 64
        manifest, config = "sha256:" + "a" * 64, "sha256:" + "b" * 64
        for value in (reference, reference.removeprefix("docker.io/"), "docker-pullable://" + reference,
                      config, "containerd://" + config):
            self.assertTrue(image_id_matches(value, reference, manifest, config))
        for value in (None, "runtime:latest", "sha256:" + "c" * 64,
                      "elsewhere.invalid/runtime@" + manifest, reference.replace("a" * 64, "c" * 64)):
            self.assertFalse(image_id_matches(value, reference, manifest, config))

    def selection(self):
        s = selected(); s["control"]["independentIssuer"] = True; s["readerLoginAdvertisesSync"] = False
        return s

    def test_no_native_reader_can_start_before_control_supplies_real_workspace(self):
        s, c = self.selection(), contract()
        plan = compose({}, s, c, "plan")
        self.assertEqual(plan["sessions-pipeline"]["sessionReadApi"]["directoryWorkspaces"], PLANNING_WORKSPACE)
        initial = compose({}, s, c, "control")
        self.assertFalse(initial["components"]["sessionsPipeline"])
        self.assertFalse(initial["components"]["webapp"])
        self.assertTrue(initial["components"]["relaycast"])
        self.assertEqual(initial["relay-control"]["bootstrap"]["adminEmail"], c["administrator"]["email"])
        for slot in ("nativeRouting", "nativeConsumer", "sessionReadApi", "ingestEdge"):
            self.assertIs(initial["sessions-pipeline"][slot]["enabled"], False)
        with self.assertRaisesRegex(NativeRecipeError, "tenant_identity"):
            compose({}, s, c, "serve", {"organizationId": TENANT["organizationId"], "workspaceId": PLANNING_WORKSPACE})

    def test_final_values_bind_real_tenant_distinct_authorities_and_disable_one_shots(self):
        s, c = self.selection(), contract()
        value = compose({}, s, c, "serve", TENANT)
        api, pipeline = value["relay-control"], value["sessions-pipeline"]
        self.assertEqual(pipeline["sessionReadApi"]["directoryWorkspaces"], TENANT["workspaceId"])
        self.assertEqual(pipeline["sessionReadApi"]["auth"]["mode"], "self_issued")
        self.assertFalse(pipeline["sessionReadApi"]["login"]["advertisesSync"])
        self.assertFalse(pipeline["sessionReadApi"]["auth"]["relaycontrol"]["enabled"])
        self.assertEqual(pipeline["sessionReadApi"]["auth"]["selfIssued"]["internalSecret"]["existingSecret"],
                         s["secretRefs"]["readerIssuer"]["name"])
        self.assertEqual(api["services"]["relayhistoryBackend"], "native")
        self.assertEqual(api["services"]["relayhistoryUrl"], "")
        self.assertEqual(api["services"]["relayhistoryPublicUrl"], "")
        self.assertFalse(api["services"]["relayauthEnabled"])
        self.assertEqual(api["selectedFeatures"], [])
        self.assertEqual(api["bootstrap"]["orgName"], "")
        self.assertFalse(api["migrations"]["enabled"])
        self.assertFalse(pipeline["nativeConsumer"]["bootstrap"]["enabled"])
        self.assertEqual(api["existingSecret"], c["runtime"]["name"])
        self.assertNotIn(c["owner"]["name"], str(api))
        self.assertNotIn(PLANNING_WORKSPACE, str(value))
        self.assertNotIn("signedLicenseVerified", str(value))

    def test_legacy_authority_inline_env_and_incomplete_addons_refuse_without_transport(self):
        for kind in ("legacy", "inline-env", "license", "addons", "optional"):
            s, base = self.selection(), {}
            if kind == "legacy": s["control"]["independentIssuer"] = False
            if kind == "addons": s["profile"] = "addons"
            if kind == "inline-env": base = {"relay-control": {"extraEnv": [{"name": "UNKNOWN", "value": "x"}]}}
            if kind == "license": base = {"relay-control": {"license": {"existingSecret": "old-license"}}}
            if kind == "optional": base = {"relay-control": {"selectedFeatures": ["flows"]}}
            with self.subTest(kind=kind), self.assertRaises(NativeRecipeError):
                compose(base, s, contract(), "serve", TENANT)

    def adapter(self):
        a = NativeCoreAdapter.__new__(NativeCoreAdapter)
        a._tenant = deepcopy(TENANT); a._completed = {"runtime_credentials_verified"}; a.effects = []
        a._phase = lambda *args, **kw: None
        a._helm_state = lambda **kw: None
        a._release_revision = None
        a._render_values = lambda v: []
        a._transport_call = lambda *a, **kw: self.fail("unexpected mutation/transport")
        return a

    def test_planning_uuid_and_privileged_runtime_job_refuse_before_helm_mutation(self):
        a = self.adapter(); s = self.selection()
        value = compose({}, s, contract(), "serve", TENANT)
        value["sessions-pipeline"]["sessionReadApi"]["directoryWorkspaces"] = PLANNING_WORKSPACE
        with self.assertRaisesRegex(NativeRecipeError, "must_never_be_deployed"):
            a._upgrade(s, value)
        value = compose({}, s, contract(), "serve", TENANT)
        a._render_values = lambda v: [{"kind": "Job", "metadata": {"name": "unwanted-owner-job"}}]
        with self.assertRaisesRegex(NativeRecipeError, "privileged_jobs"):
            a._upgrade(s, value)

    def test_consumer_prepare_renders_observed_tenant_not_original_planning_values(self):
        a = self.adapter(); s = self.selection(); sent = []
        a._values = lambda s, phase: compose({}, s, contract(), phase, a._tenant)
        a._transport_call = lambda *args, **kw: sent.append((args, kw)) or SimpleNamespace(stdout="")
        a._template(s, {"sessions-pipeline": {"nativeConsumer": {"bootstrap": {"enabled": True}}}})
        self.assertEqual(len(sent), 1)

        self.assertIn(TENANT["workspaceId"], sent[0][1]["data"])
        self.assertNotIn(PLANNING_WORKSPACE, sent[0][1]["data"])
        a._tenant = None
        with self.assertRaisesRegex(NativeRecipeError, "real_tenant_required"):
            a._template(s, {})
        self.assertEqual(len(sent), 1)

    def test_stale_rollout_foreign_replicaset_or_old_pod_image_never_qualifies_ready(self):
        import json
        d = {"metadata": {"uid": "deployment-one", "generation": 2},
             "spec": {"replicas": 1, "selector": {"matchLabels": {"app": "owned"}},
                      "template": {"spec": {"containers": [{"name": "api", "image": "repo@sha256:new"}]}}},
             "status": {"readyReplicas": 1, "updatedReplicas": 1, "availableReplicas": 1, "observedGeneration": 2}}
        p = {"metadata": {"name": "current-pod", "uid": "pod-one", "ownerReferences": [{"kind": "ReplicaSet", "name": "rs", "uid": "rs-one"}]},
             "spec": deepcopy(d["spec"]["template"]["spec"]), "status": {"containerStatuses": [{"ready": True}]}}
        rs = {"metadata": {"uid": "rs-one", "ownerReferences": [{"kind": "Deployment", "uid": "deployment-one"}]}}
        a = self.adapter()
        def bind(workload, pod, replica):
            a._get = lambda name: deepcopy(workload if name.startswith("deployment/") else replica)
            a._transport_call = lambda *args, **kw: SimpleNamespace(stdout=json.dumps({"items": [pod]}))
        bind(d, p, rs)
        self.assertEqual(a._runtime_pod("relay-control")[1]["metadata"]["uid"], "pod-one")
        for case in ("stale-generation", "old-image", "foreign-controller", "second-pod"):
            wd, pod, replica = deepcopy(d), deepcopy(p), deepcopy(rs)
            if case == "stale-generation": wd["status"]["observedGeneration"] = 1
            if case == "old-image": pod["spec"]["containers"][0]["image"] = "repo@sha256:old"
            if case == "foreign-controller": replica["metadata"]["ownerReferences"][0]["uid"] = "foreign"
            bind(wd, pod, replica)
            if case == "second-pod":
                a._transport_call = lambda *args, **kw: SimpleNamespace(stdout=json.dumps({"items": [p, deepcopy(p)]}))
            with self.subTest(case=case), self.assertRaises(NativeRecipeError): a._runtime_pod("relay-control")

    def test_failed_independent_image_capability_clears_previous_artifact_admission(self):
        a = self.adapter(); s = self.selection(); a.inputs = {"controlReceipt": "unused"}
        a._verified = {"old": True}
        a._image = lambda *args: {"Id": "already-bound-native-id"}
        a._probe = lambda *args: {"accessPrefix": "wrong-older-authority"}
        def parent(adapter, selected):
            adapter._verified = {"sourceRevision": selected["sourceRevision"]}
            return adapter._verified
        with patch("native_pipeline.NativePipelineAdapter.verify_artifact", parent), patch(
            "native_inspect.pipeline_coordinates", return_value={"localTag": "qualified", "buildIndexDigest": "bound-index"}):
            with self.assertRaisesRegex(NativeRecipeError, "independent_reader_module"):
                a.verify_artifact(s)
        self.assertIsNone(a._verified)

    def test_runtime_drift_after_readiness_cannot_create_binding_receipt(self):
        a = self.adapter(); s = self.selection()
        a._ready_uids = {"relay-control": "original-deployment"}; a._ready_specs = {"relay-control": "old-spec"}
        a._get = lambda name: {"metadata": {"uid": "replacement-deployment"}, "spec": {}}
        a._exclusive_json = lambda *args: self.fail("drift wrote a binding receipt")
        with self.assertRaisesRegex(NativeRecipeError, "changed_after_final"):
            a.record_ready(s, {"fullAcceptance": False, "sourceRevision": s["sourceRevision"]})


if __name__ == "__main__": unittest.main()
