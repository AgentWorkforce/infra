"""Causal native core phase tests; no cluster, provider or SQL writes."""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import tempfile
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from native_core import NativeCoreAdapter, image_id_matches, runtime_field, strategy_type
from native_core_values import compose, PLANNING_WORKSPACE
from native_recipe import NativeRecipeError
from test_native_recipe import selected
from test_native_control import contract


TENANT = {"organizationId": "11111111-1111-4111-8111-111111111111",
          "workspaceId": "22222222-2222-4222-8222-222222222222"}


class Core(unittest.TestCase):
    def test_versioned_helm_parser_lists_pending_and_failed_before_any_fresh_claim(self):
        from stack import helm_list_all_args, StackError
        with tempfile.TemporaryDirectory() as directory:
            parser = Path(directory) / "helm.py"
            parser.write_text("""import argparse,json,sys
version,status=sys.argv[1:3];args=sys.argv[3:]
if args==['version','--template','{{.Version}}']:
 print(version);raise SystemExit(0)
p=argparse.ArgumentParser();p.add_argument('list');p.add_argument('-n');p.add_argument('-o')
if version.startswith('v3.'):p.add_argument('--all',action='store_true')
parsed=p.parse_args(args)
rows=[{'name':'agent-relay','namespace':'agent-relay','status':status,'revision':'1'}]
if version.startswith('v3.') and not parsed.all and status.startswith('pending'):rows=[]
print(json.dumps(rows))
""")
            for version in ("v3.17.3+g123", "v4.1.3"):
                for status in ("deployed", "failed", "pending-install", "pending-upgrade"):
                    with self.subTest(version=version, status=status):
                        a = object.__new__(NativeCoreAdapter); a._release_revision = None
                        calls = []
                        def transport(method, argv, **kwargs):
                            self.assertEqual(method, "cmd"); calls.append(argv)
                            result = subprocess.run([sys.executable, str(parser), version, status, *argv[1:]], capture_output=True, text=True, check=True)
                            return result
                        a._transport_call = transport
                        with self.assertRaisesRegex(NativeRecipeError, "existing_app_release"):
                            a._helm_state(absent=True)
                        if status == "deployed": self.assertEqual(a._helm_state(), 1)
                        else:
                            with self.assertRaisesRegex(NativeRecipeError, "must_be_deployed"): a._helm_state()
                        listing = next(c for c in calls if c[1] == "list")
                        self.assertEqual("--all" in listing, version.startswith("v3."))
            for version in ("v2.17.0", "v5.0.0", "v4", "v4.1.3 --all", ""):
                with self.subTest(version=version), self.assertRaises(StackError): helm_list_all_args(version)

    def test_omitted_deployment_strategy_matches_only_kubernetes_rollingupdate_default(self):
        expected = {"spec": {}}
        live = {"spec": {"strategy": {"type": "RollingUpdate", "rollingUpdate": {"maxSurge": "25%", "maxUnavailable": "25%"}}}}
        self.assertEqual(strategy_type(expected), strategy_type(live))
        for actual in ("Recreate", "", None, "Unknown"):
            self.assertNotEqual(strategy_type(expected), strategy_type({"spec": {"strategy": {"type": actual}}}))
        consumer = {"spec": {"strategy": {"type": "Recreate"}}}
        self.assertNotEqual(strategy_type(consumer), strategy_type(expected))
        self.assertEqual(strategy_type(consumer), "Recreate")

    def test_empty_env_api_omission_is_equivalent_without_hiding_valuefrom_or_other_changes(self):
        desired = {"env": [{"name": "SELFHOST_FEATURES", "value": ""},
                           {"name": "SECRET", "valueFrom": {"secretKeyRef": {"name": "owned", "key": "value"}}}]}
        actual = deepcopy(desired); actual["env"][0].pop("value")
        self.assertEqual(runtime_field(actual, "env"), runtime_field(desired, "env"))
        self.assertNotIn("value", actual["env"][0])
        for change in (lambda x: x["env"][0].update(value="flows"),
                       lambda x: x["env"][0].update(valueFrom={"secretKeyRef": {"name": "foreign", "key": "value"}}),
                       lambda x: x["env"].reverse()):
            changed = deepcopy(actual); change(changed)
            self.assertNotEqual(runtime_field(changed, "env"), runtime_field(desired, "env"))
        self.assertNotEqual(runtime_field({"command": []}, "command"), runtime_field({}, "command"))

    def test_public_routes_check_selected_reader_host_path_tls_and_auth_refusal(self):
        s = self.selection(); a = self.adapter(); seen = []
        ca = "synthetic-public-ca"; s["postgresCa"]["sha256"] = hashlib.sha256(ca.encode()).hexdigest()
        a._get = lambda name: {"data": {"ca.crt": ca}}
        context = SimpleNamespace(verify_flags=0)
        class Connection:
            def __init__(self, host, port, **kw):
                self.host = host; self.port = port
                self.status = 401 if host.startswith("history.") else 200
                self.body = b'{"error":{"code":"missing_authorization"}}'
                self.assert_context = kw["context"] is context
            def request(self, method, path): seen.append((self.host, self.port, method, path, self.assert_context))
            def getresponse(self): return SimpleNamespace(status=self.status, read=lambda n: self.body)
            def close(self): pass
        with patch("native_core.ssl.create_default_context", return_value=context) as trust, patch(
                "native_core.http.client.HTTPSConnection", Connection):
            a._verify_public_routes(s)
        trust.assert_called_once_with(cadata=ca)
        self.assertEqual(seen, [("relay.kind.agentrelay.com", 443, "GET", "/", True),
                                ("history.kind.agentrelay.com", 8443, "GET", "/v1/sessions", True)])
        for failure in (200, 404, 503):
            class Broken(Connection):
                def __init__(self, *args, **kw):
                    super().__init__(*args, **kw)
                    if self.host.startswith("history."): self.status = failure
            with self.subTest(status=failure), patch("native_core.ssl.create_default_context", return_value=context), patch(
                    "native_core.http.client.HTTPSConnection", Broken), self.assertRaises(NativeRecipeError):
                a._verify_public_routes(s)
        class ForeignAuth(Connection):
            def __init__(self, *args, **kw):
                super().__init__(*args, **kw); self.body = b'{"error":{"code":"some_other_service"}}'
        with patch("native_core.ssl.create_default_context", return_value=context), patch(
                "native_core.http.client.HTTPSConnection", ForeignAuth), self.assertRaisesRegex(NativeRecipeError, "reader_auth_fence"):
            a._verify_public_routes(s)

    def test_repeat_pipeline_role_oids_are_required_before_mutating_phases(self):
        a = self.adapter(); s = self.selection()
        a.stack = SimpleNamespace(recipe_hash=lambda: "source-bound")
        a.inputs = {"bindingReceipt": "private", "bindingReceiptSha256": "bound", "webappPacketSha256": "webapp"}
        oids = {n: i for i, n in enumerate(s["roles"].values(), 100)}
        binding = {"version": 1, "type": "local-kind-native-core", "selection": s, "recipeSha256": "source-bound",
                   "webapp": {"packetSha256": "webapp"}, "resources": [], "pipelineRoleOids": oids}
        a._pipeline_role_oids = lambda selected: dict(oids)
        with patch("native_pipeline.NativePipelineAdapter.inspect", return_value={"mode": "repeat"}), patch(
                "native_core.document", return_value=binding):
            self.assertEqual(a.inspect(s), {"mode": "repeat"})
            self.assertEqual(a._owner_oid, oids[s["roles"]["owner"]])
            for name in oids:
                changed = dict(oids); changed[name] += 1000
                a._pipeline_role_oids = lambda selected, changed=changed: changed
                with self.subTest(role=name), self.assertRaisesRegex(NativeRecipeError, "role_identity_changed"):
                    a.inspect(s)
                self.assertIsNone(a._pipeline_oids)
            a._pipeline_role_oids = lambda selected: dict(oids)
            binding.pop("pipelineRoleOids")
            with self.assertRaisesRegex(NativeRecipeError, "role_identity_changed"): a.inspect(s)

    def test_repeat_binds_original_admin_server_and_ingress_tls_secret_uids_even_with_identical_bytes(self):
        from native_inspect import NativeReadOnlyAdapter
        from test_native_inspect import NativeInspectTests, write_json
        fixture = NativeInspectTests(); fixture.setUp(); self.addCleanup(fixture.doCleanups)
        fixture.repeat_fixture()
        fixture.stack.recipe_hash = lambda: "source-bound"
        inputs = {**fixture.inputs, "webappPacket": "unused-readonly-test", "webappPacketSha256": "packet-bound",
                  "webappArchive": "unused-readonly-test", "webappBuildMetadata": "unused-readonly-test"}
        a = NativeCoreAdapter(fixture.stack, inputs, contract())
        infrastructure = {a.ADMIN_SECRET, a.SERVER_TLS_SECRET, "kind-tls"}
        original_refs = {r["name"] for r in fixture.s["secretRefs"].values()}
        self.assertEqual(NativeReadOnlyAdapter._selected_secret_names(a, fixture.s), original_refs)
        self.assertTrue(infrastructure <= a._selected_secret_names(fixture.s))
        existing = {o["metadata"]["name"] for o in fixture.stack.objects if o["kind"] == "Secret"}
        for name in a._selected_secret_names(fixture.s) - existing:
            fixture.stack.objects.append({"kind": "Secret", "metadata": {"name": name, "uid": name + "-uid"},
                                          "immutable": True, "data": {"synthetic": "c3ludGhldGlj"}})
        oids = {n: i for i, n in enumerate(fixture.s["roles"].values(), 100)}
        a._pipeline_role_oids = lambda selected: dict(oids)
        binding = json.loads(Path(inputs["bindingReceipt"]).read_text())
        binding.update(version=1, type="local-kind-native-core", selection=fixture.s, recipeSha256="source-bound",
                       webapp={"packetSha256": inputs["webappPacketSha256"]}, pipelineRoleOids=oids,
                       resources=[{"kind": o["kind"], "name": o["metadata"]["name"], "uid": o["metadata"]["uid"]}
                                  for o in fixture.stack.objects])
        inputs["bindingReceiptSha256"] = write_json(inputs["bindingReceipt"], binding)
        self.assertEqual(a.inspect(fixture.s)["mode"], "repeat")
        for name in infrastructure:
            obj = next(o for o in fixture.stack.objects if o["metadata"]["name"] == name)
            old_uid, old_bytes = obj["metadata"]["uid"], deepcopy(obj["data"])
            obj["metadata"]["uid"] = "new-secret-with-same-data"
            with self.subTest(name=name), self.assertRaisesRegex(NativeRecipeError, "resource_uid_changed"):
                a.inspect(fixture.s)
            self.assertEqual(obj["data"], old_bytes)
            obj["metadata"]["uid"] = old_uid
            incomplete = deepcopy(binding)
            incomplete["resources"] = [r for r in incomplete["resources"] if (r["kind"], r["name"]) != ("Secret", name)]
            inputs["bindingReceiptSha256"] = write_json(inputs["bindingReceipt"], incomplete)
            with self.subTest(missing=name), self.assertRaisesRegex(NativeRecipeError, "resource_binding_incomplete"):
                a.inspect(fixture.s)
            inputs["bindingReceiptSha256"] = write_json(inputs["bindingReceipt"], binding)
        self.assertEqual(a.inspect(fixture.s)["mode"], "repeat")
        self.assertTrue(all(args[0] == "get" or args[:2] == ["kind", "get"] for args, kw in fixture.stack.calls))

    def test_pipeline_role_identity_query_is_complete_and_read_only(self):
        a = self.adapter(); s = self.selection(); calls = []
        oids = {n: i for i, n in enumerate(s["roles"].values(), 100)}
        def sql(selected, db, text, **kw):
            calls.append((db, text, kw))
            numeric = "json_object_agg(rolname,oid::bigint)" in text
            return json.dumps({n: oid if numeric else str(oid) for n, oid in oids.items()})
        a._psql = sql
        self.assertEqual(a._pipeline_role_oids(s), oids)
        self.assertEqual(calls[0][0], "hoopdb"); self.assertEqual(calls[0][2], {"read_only": True})
        for role in s["roles"].values(): self.assertIn("'" + role + "'", calls[0][1])
        self.assertIn("json_object_agg(rolname,oid::bigint)", calls[0][1])
        invalid_values = [str(oids[s["roles"]["runtime"]]), True, False, 0, -1, 101.0, None]
        invalid_maps = [{}, {**oids, "foreign": 999}, {**oids, s["roles"]["runtime"]: oids[s["roles"]["owner"]]}]
        invalid_maps += [{**oids, s["roles"]["runtime"]: value} for value in invalid_values]
        for invalid in invalid_maps:
            a._psql = lambda *args, invalid=invalid, **kw: json.dumps(invalid)
            with self.assertRaisesRegex(NativeRecipeError, "role_identity_incomplete"): a._pipeline_role_oids(s)

    def test_credential_identity_drift_clears_serve_admission(self):
        a = self.adapter(); s = self.selection()
        oids = {n: i for i, n in enumerate(s["roles"].values(), 100)}
        a._inspected = {"mode": "repeat"}; a._pipeline_oids = oids
        changed = dict(oids); changed[s["roles"]["consumer"]] += 10
        a._pipeline_role_oids = lambda selected: changed
        def credentials(adapter, selected):
            adapter._completed.add("runtime_credentials_verified"); return {"ok": True}
        with patch("native_pipeline.NativePipelineAdapter.verify_credentials", credentials):
            with self.assertRaisesRegex(NativeRecipeError, "role_identity_changed"): a.verify_credentials(s)
        self.assertNotIn("runtime_credentials_verified", a._completed)

    def test_ready_record_persists_pipeline_role_identity_and_refuses_last_minute_recreation(self):
        a = self.adapter(); s = self.selection(); records = []
        oids = {n: i for i, n in enumerate(s["roles"].values(), 100)}
        a._pipeline_oids = oids; a._pipeline_role_oids = lambda selected: dict(oids)
        a._ready_uids = {"relay-control": "original-control"}
        a._ready_specs = {"relay-control": hashlib.sha256(b"{}").hexdigest()}
        a._selected_secret_names = lambda selected: set()
        def get(name, **kw):
            if name == "deployment/relay-control": return {"metadata": {"uid": "original-control"}, "spec": {}}
            if name == "namespace/kube-system": return {"metadata": {"uid": "original-cluster"}}
            return {"items": []}
        a._get = get; a._control_roles = lambda selected: {"control_owner": {"oid": 200}, "control_api_runtime": {"oid": 201}}
        a._webapp = {k: "bound" for k in ("sourceRevision", "reference", "manifestDigest", "configDigest", "packetSha256", "archiveSha256")}
        a._control_contract_sha = a._base_sha = a._recipe_sha = "bound"
        a._values = lambda selected, phase: {}; a._inspected = {"mode": "fresh"}
        a._public_route = {"service": {"uid": "original-edge"}}
        a._qualify_public_route = lambda selected, expected: expected
        a._exclusive_json = lambda path, record: records.append(deepcopy(record))
        with tempfile.TemporaryDirectory() as directory, patch("native_core.sha", return_value="bound-receipt"):
            a.stack = SimpleNamespace(state=Path(directory))
            self.assertEqual(a.record_ready(s, {"fullAcceptance": False, "sourceRevision": s["sourceRevision"]}),
                             {"ok": True, "receiptSha256": "bound-receipt"})
            self.assertEqual(records[0]["pipelineRoleOids"], oids)
            self.assertEqual(records[0]["controlPublicRoute"], a._public_route)
            changed = dict(oids); changed[s["roles"]["owner"]] += 1
            a._pipeline_role_oids = lambda selected: changed
            with self.assertRaisesRegex(NativeRecipeError, "role_identity_changed"):
                a.record_ready(s, {"fullAcceptance": False, "sourceRevision": s["sourceRevision"]})
        self.assertEqual(len(records), 1)

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
        a._public_route = None
        a._public_route_binding = None
        a._render_values = lambda v: []
        a._transport_call = lambda *a, **kw: self.fail("unexpected mutation/transport")
        return a

    def test_public_gateway_drift_clears_admission_and_precedes_runtime_transport(self):
        from test_native_network import NativeNetwork
        f = NativeNetwork(); f.setUp(); self.addCleanup(f.doCleanups)
        value = f.public_route()
        a = self.adapter(); s = self.selection()
        a._network_stack = lambda selected: f.stack
        a._values = lambda selected, phase: deepcopy(value)
        original = a._qualify_public_route(s)
        self.assertEqual(a._public_route, original)
        f.stack.public_service['metadata']['uid'] = 'recreated-service'
        with self.assertRaisesRegex(ValueError, 'gateway UID'):
            a._qualify_public_route(s, original)
        self.assertIsNone(a._public_route)
        self.assertEqual(a._public_route_binding, original)
        with self.assertRaisesRegex(ValueError, 'gateway UID'): a._qualify_public_route(s)
        self.assertFalse(any(call[0] == 'k' and call[1][0] != 'get' for call in f.stack.calls))

    def test_serve_observes_gateway_before_rendering_alias_and_reuses_bound_identity(self):
        import native_network
        from test_native_network import NativeNetwork
        f = NativeNetwork(); f.setUp(); self.addCleanup(f.doCleanups)
        value = f.public_route(); a = self.adapter(); s = self.selection(); applied = []
        a.stack = f.stack
        a._network_stack = lambda selected: f.stack
        a._values = lambda selected, phase: native_network.public_route_values(value, a._public_route) if a._public_route else deepcopy(value)
        a._ensure_pipeline_image = lambda selected: None
        a._import_webapp = lambda selected: None
        a._upgrade = lambda selected, values: applied.append(deepcopy(values)) or []
        a._release_revision = 1
        with patch('edge.install', return_value=None) as install:
            a.serve(s, {'bootstrapEnabled': False, 'phase': 'serve'})
            self.assertEqual(len(applied), 1)
            self.assertEqual(applied[0]['relay-control']['services']['publicHostAliases'], [
                {'ip': '10.96.42.7', 'hostnames': ['relay.kind.agentrelay.com']}])
            self.assertNotIn('relayhistoryHostAliases', applied[0]['relay-control']['services'])
            f.stack.public_service['metadata']['uid'] = 'replacement-edge'
            with self.assertRaisesRegex(ValueError, 'gateway UID'):
                a.serve(s, {'bootstrapEnabled': False, 'phase': 'serve'})
            self.assertEqual(len(applied), 1)
            self.assertEqual(install.call_count, 1)
        self.assertIsNone(a._public_route)
        self.assertEqual(a._public_route_binding['service']['uid'], 'original-public-service')

    def test_repeat_render_requires_and_rechecks_the_saved_public_gateway_before_chart_hash(self):
        a = self.adapter(); s = self.selection()
        s['reference'] = 'docker.io/' + s['reference']
        a._bind_selection = lambda selected: None
        a._inspected = {'mode': 'repeat'}
        a._control_contract_sha = 'contract'
        a.inputs = {'bindingReceipt': 'private', 'bindingReceiptSha256': 'bound'}
        binding = {'controlContractSha256': 'contract', 'tenant': TENANT}
        with patch('native_core.document', return_value=binding):
            with self.assertRaisesRegex(NativeRecipeError, 'public_gateway_binding_required'): a.render(s)
            binding['controlPublicRoute'] = {'service': {'uid': 'original'}}
            def drift(selected, expected):
                self.assertEqual(expected, binding['controlPublicRoute'])
                raise ValueError('gateway drift')
            a._qualify_public_route = drift
            with self.assertRaisesRegex(ValueError, 'gateway drift'): a.render(s)
        self.assertFalse(a._rendered)

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
        a = self.adapter(); s = self.selection(); a.inputs = {"controlReceipt": "unused", "pipelineArchive": "unused-bound-archive"}
        a._verified = {"old": True}
        a._image = lambda *args, **kwargs: {"Id": "already-bound-native-id"}
        a._probe = lambda *args: {"accessPrefix": "wrong-older-authority"}
        def parent(adapter, selected):
            adapter._verified = {"sourceRevision": selected["sourceRevision"]}
            return adapter._verified
        with patch("native_pipeline.NativePipelineAdapter.verify_artifact", parent), patch(
            "native_inspect.pipeline_coordinates", return_value={"localTag": "qualified", "buildIndexDigest": "bound-index", "archiveSha256": "bound-archive"}), patch("native_core.native_archive_transport", return_value={"config": {}}):
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
