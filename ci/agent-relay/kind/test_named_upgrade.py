"""Causal admission, preservation and rollback-boundary tests; no daemon used."""
import base64
import copy
import hashlib
import io
import json
from contextlib import redirect_stdout
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import control
import named_upgrade as named
import stack
import test_control as control_tests

HERE = Path(__file__).resolve().parent
DEFAULT_LEGACY = {"relay-control", "relay-webapp", "session-ingest-api", "session-summary-worker", "session-metadata-indexer", "session-status-worker"}


class NamedUpgrade(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="kind-named-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        root = patch.object(stack, "ROOT", self.root)
        root.start(); self.addCleanup(root.stop)
        # The early native bootstrap guard reads the selected profile layers.
        # This fixture exercises the separate retained naming boundary.
        charts = self.root / "charts/agent-relay"
        charts.mkdir(parents=True)
        for name in ("values.yaml", "values-kind-core.yaml", "values-kind-addons.yaml"):
            (charts / name).write_text("{}\n")
        self.prepare("core")

    def prepare(self, profile):
        self.local = stack.Stack(profile)
        self.local.env["DOCKER_HOST"] = "unix:///fixture/docker.sock"
        self.local.arch = "arm64"
        self.local.docker = lambda **kwargs: None
        self.local.require_owned_cluster = lambda: None
        self.local.dependencies = lambda: None
        self.calls = []
        self.uid = "fixture-native-uid"
        self.ready = {"profile": profile, "clusterUid": self.uid, "recipeSha256": "a"*64, "renderSha256": "b"*64}
        self.ownership = {"version": 1, "name": self.local.name, "profile": profile, "nodeImage": stack.NODE,
                          "dockerHost": self.local.env["DOCKER_HOST"], "clusterUid": self.uid}
        named.write(self.local.marker, self.ownership)
        named.write(self.local.state/"ready.json", self.ready)
        named.write(self.local.state/"images.json", {"historical": True})
        named.write(self.local.state/"proof.json", {"result": "PENDING", "historicalChecks": 60})
        named.write(self.local.state/"control-build.json", {"historical": True})
        self.archive = self.local.state/"native-control.tar"
        native = control_tests.ControlArchive().archive(self.archive)
        self.values = {"localKind": {"profile": profile},
                       "components": {"relayflows": profile == "addons", "relayfile": profile == "addons"},
                       "sessions-pipeline": {"session-object-storage": {"enabled": False},
                                             "worker": {"locker": {"endpoint": "http://locker:9000"}},
                                             "alleyoop": {"locker": {"endpoint": "http://locker:9000"}}},
                       "relay-control": {"image": {"repository": control.REPOSITORY, "digest": native, "pullPolicy": "Never"}}}
        control.select_local_entrypoints(self.values, control.REVISION)
        named.write(self.local.overrides, {"historical": "selection"})
        self.objects = {}
        def add(kind, name, spec, release=None):
            obj = {"kind": kind, "metadata": {"name": name, "uid": "uid-"+name}, "spec": spec}
            if release:
                obj["metadata"]["annotations"] = {"meta.helm.sh/release-name": release, "meta.helm.sh/release-namespace": "agent-relay"}
            self.objects[(kind, name)] = obj
            return obj
        storage = add("Deployment", named.NAME,
                      {"replicas": 1, "selector": {"matchLabels": {"app": "minio", "release": "kind-locker"}},
                       "template": {"metadata": {"name": named.NAME}, "spec": {
                           "containers": [{"name": "minio", "image": "fixture-minio@sha256:"+"c"*64}],
                           "volumes": [{"name": "export", "persistentVolumeClaim": {"claimName": "locker"}}]}}}, "kind-locker")
        storage["status"] = {"readyReplicas": 1}
        pvc = add("PersistentVolumeClaim", "locker", {"volumeName": "original-native-volume"}, "kind-locker")
        pvc["status"] = {"phase": "Bound"}
        for name in ("locker", "locker-console"):
            add("Service", name, {"selector": {"app": "minio", "release": "kind-locker"}}, "kind-locker")
        add("StatefulSet", "postgres", {"template": {"spec": {"containers": [{"name": "postgres", "args": ["-c", "ssl=on"]}]}}})
        add("PersistentVolumeClaim", "data-postgres-0", {"volumeName": "original-pg-volume"})
        add("Service", "postgres", {"ports": [{"port": 5432}]})
        self.rendered = []
        for name in sorted(DEFAULT_LEGACY):
            image = control.REPOSITORY+"@"+native if name == "relay-control" else "fixture-service@sha256:"+"d"*64
            container = {"name": "api" if name == "relay-control" else "service", "image": image}
            if name == "relay-control":
                container.update(self.values["relay-control"]["server"])
            obj = add("Deployment", name, {"replicas": 1, "selector": {"matchLabels": {"app": name}},
                       "template": {"spec": {"containers": [container]}}}, "agent-relay")
            obj["status"] = {"readyReplicas": 1}
            self.rendered.append(copy.deepcopy(obj))
        self.pods = [{"metadata": {"name": "one-original-minio-pod"}}]
        self.storage_values = {"fullnameOverride": "locker", "persistence": {"enabled": True, "size": "2Gi"}}
        self.storage_manifest = [{"kind": "ServiceAccount", "metadata": {"name": "minio-sa"}},
                                 {"kind": "ConfigMap", "metadata": {"name": "locker"}},
                                 *[copy.deepcopy(self.objects[k]) for k in [("PersistentVolumeClaim", "locker"),
                                     ("Service", "locker"), ("Service", "locker-console"), ("Deployment", named.NAME)]]]
        self.storage_manifest.sort(key=lambda d: (d["kind"], d["metadata"]["name"]))
        self.storage_chart = "minio-5.4.0"
        self.payload = "synthetic retained sentinel\n"
        self.seed = {"key": "__kind_naming_proof__/storage-"+"a"*32+".txt", "size": len(self.payload), "etag": "fixture-etag", "versionId": None}
        self.inventory = [self.seed.copy()]
        self.credentials = {k: "fixture-"+k for k in ("postgres", "hoop", "runtime", "history_owner", "history_runtime", "control_owner", "control_api_runtime",
                            "relayfile", "bootstrap", "encryption", "internal", "auth_internal", "auth_key", "cast", "cast_bootstrap", "locker")}
        named.write(self.local.state/"credentials.json", self.credentials)
        (self.local.state/"auth-signing.pem").write_text("synthetic-signing-material")
        for name in ("ca.crt", "ca.key", "tls.crt", "tls.key"):
            (self.local.state/name).write_text('synthetic-fixture-'+name)
        self.secrets = {n: {"data": {k: base64.b64encode(v.encode()).decode() for k, v in values.items()}}
                        for n, values in self.local.credential_values(self.credentials, "synthetic-signing-material").items()}
        self.secrets['kind-tls']={'data':{name:base64.b64encode((self.local.state/name).read_bytes()).decode() for name in ('tls.crt','tls.key')}}
        self.local.k = self.k
        self.local.cmd = self.cmd
        self.proof = {"result": "PASS", "phase": "CLIENT_WRITERS_RESUMED", "oneStoragePodVerified": True,
                      "pvcPreserved": True, "imageUnchanged": True, "postRendererRequiredForFutureUpgrade": True,
                      "rollback": None, "servicesRetained": ["locker", "locker-console"],
                      "pvcUid": "uid-locker", "oldDeploymentUid": "uid-old-locker", "newDeploymentUid": "uid-"+named.NAME,
                      "seededInventory": named.inventory_summary([self.seed]), "afterInventory": named.inventory_summary([self.seed]),
                      "sentinelKey": self.seed["key"], "sentinelSha256": hashlib.sha256(self.payload.encode()).hexdigest()}
        history = self.local.state/('named-history-'+"b"*16)
        history.mkdir(exist_ok=True)
        named.write(history/"ready.json", self.ready)
        chart = self.root/"charts/sessions-pipeline/charts/minio-5.4.0.tgz"
        chart.parent.mkdir(parents=True, exist_ok=True);chart.write_bytes(b"pinned synthetic chart")
        plugin = self.root/"ci/agent-relay/kind/storage-name-renderer"
        plugin.mkdir(parents=True, exist_ok=True)
        (plugin/'postrender.py').write_bytes((HERE/'storage-name-renderer/postrender.py').read_bytes())
        self.record = {"version": 1, "type": "local-kind-named-layout", "name": self.local.name, "profile": profile,
                       "clusterUid": self.uid, "dockerHost": self.local.env["DOCKER_HOST"], "history": history.name,
                       "readyAnchorSha256": named.sha_file(history/"ready.json"),
                       "storage": named.storage_snapshot(self.local, self.objects), "postgres": named.postgres_snapshot(self.objects),
                       "privateState": named.private_state(self.local), "postgresSecrets": named.postgres_secret_snapshot(self.local,self.objects),
                       "storageValues": copy.deepcopy(self.storage_values), "storageValuesSha256": named.digest(self.storage_values),
                       "storageManifestSha256": named.digest(self.storage_manifest), "storageChartSha256": named.sha_file(chart),
                       "storageRendererSha256": named.sha_file(plugin/'postrender.py'),
                       "activeValuesSha256": named.digest(self.values), "controlBuildSha256": None,
                       "seedObjects": [self.seed.copy()], "sentinelKey": self.seed["key"], "sentinelSha256": self.proof["sentinelSha256"]}
        named.write(self.local.overrides, self.values)
        named.write(self.local.state/named.RECORD, self.record)
        self.calls.clear()

    def result(self, args, value=""):
        return subprocess.CompletedProcess(args, 0, value, "")

    def k(self, *args, **kwargs):
        self.calls.append(list(args))
        if args[:2] == ("get", "namespace"):
            return self.result(args, json.dumps({"metadata": {"name": "agent-relay"}}))
        if args[:2] in (("get", "deploy,pvc"), ("get", "deploy,pvc,svc,statefulset")):
            return self.result(args, json.dumps({"items": list(self.objects.values())}))
        if args[:2] == ("get", "pods"):
            return self.result(args, json.dumps({"items": self.pods}))
        if args[:2] == ("get", "secret"):
            return self.result(args, json.dumps(self.secrets[args[2]]))
        if args and args[0] == "exec":
            if "ls" in args:
                return self.result(args, '\n'.join(json.dumps({"status": "success", "type": "file", **r}) for r in self.inventory))
            if "cat" in args:
                return self.result(args, self.payload)
        if args[:2] == ("rollout", "status"):
            return self.result(args)
        self.fail("Unexpected or mutating Kubernetes call: "+repr(args))

    def cmd(self, args, **kwargs):
        args=[str(x) for x in args];self.calls.append(args)
        if args[:3] == ["kind", "get", "clusters"]:
            return self.result(args, self.local.name+'\n')
        if args[:2] == ["helm", "list"]:
            return self.result(args, json.dumps([{"name": "kind-locker", "namespace": "agent-relay", "status": "deployed", "chart": self.storage_chart},
                                                   {"name": "agent-relay", "namespace": "agent-relay", "status": "deployed", "chart": "agent-relay-0.5.1"}]))
        if args[:3] == ["helm", "get", "values"]:
            return self.result(args, json.dumps(self.storage_values if args[3] == "kind-locker" else self.values))
        if args[:3] == ["helm", "get", "manifest"]:
            return self.result(args, yaml.safe_dump_all(self.storage_manifest))
        if args[:2] == ["helm", "template"]:
            return self.result(args, yaml.safe_dump_all(self.rendered))
        if args[:2] == ["helm", "version"]:
            return self.result(args, "v4.3.1")
        if args[:2] == ["helm", "upgrade"]:
            return self.result(args)
        if args[:2] == ['openssl','verify']:
            return self.result(args,'verified fixture')
        self.fail("Unexpected command: "+repr(args))

    def assert_refused_without_state_change(self):
        paths=[self.local.state/n for n in ("ready.json", "images.json", "values.json", "proof.json")]
        before={p:p.read_bytes() for p in paths}
        with self.assertRaises(stack.StackError):named.validate(self.local)
        self.assertEqual(before,{p:p.read_bytes() for p in paths})
        self.assertFalse(any(c[0] in ("apply","replace","delete","create","scale") or c[:2]==["helm","upgrade"] for c in self.calls))

    def test_qualified_owned_core_and_addons_are_admitted_without_mutation(self):
        for profile in ("core","addons"):
            with self.subTest(profile=profile):
                if profile == "addons":
                    license_path=self.root/'synthetic-license';license_path.write_text('synthetic-license')
                    with patch.dict('os.environ',KIND_LICENSE_FILE=str(license_path)):
                        self.prepare(profile);self.local.require_no_legacy_storage()
                else:self.local.require_no_legacy_storage()
                self.assertEqual(self.local.named_layout,self.record)
                self.assertFalse(any(c[0] in ("apply","replace","delete","create","scale") for c in self.calls))

    def test_untyped_or_foreign_profile_receipts_cannot_admit_a_legacy_fixture(self):
        for change in ({"version":True},{"type":"PASS"},{"profile":"addons"},{"clusterUid":"replacement"},{"dockerHost":"unix:///other"}):
            with self.subTest(change=change):
                named.write(self.local.state/named.RECORD,{**self.record,**change});self.assert_refused_without_state_change()
        (self.local.state/named.RECORD).unlink()
        with self.assertRaisesRegex(stack.StackError,"legacy kind-locker"):self.local.require_no_legacy_storage()

    def test_original_ready_anchor_is_required_even_when_live_resources_match(self):
        p=self.local.state/self.record['history']/'ready.json';p.write_text('{}')
        self.assert_refused_without_state_change()

    def test_empty_owned_cluster_is_fresh_only_without_a_prior_cutover_record(self):
        self.objects.clear()
        with self.assertRaises(stack.StackError):self.local.require_no_legacy_storage()
        (self.local.state/named.RECORD).unlink()
        self.local.require_no_legacy_storage()
        self.assertIsNone(self.local.named_layout)

    def test_malformed_record_refuses_before_state_invalidation(self):
        for value in ([],None,{},dict(self.record,storageValues=None),dict(self.record,seedObjects=[])):
            with self.subTest(value=value):
                named.write(self.local.state/named.RECORD,value)
                self.assert_refused_without_state_change()

    def test_storage_uid_claim_writer_count_or_helm_mismatch_refuses(self):
        for mutation in (lambda:self.objects[('PersistentVolumeClaim','locker')]['metadata'].update(uid='other-pvc'),
                         lambda:self.objects[('Deployment',named.NAME)]['metadata'].update(uid='replacement'),
                         lambda:self.objects[('Deployment',named.NAME)]['spec']['template']['spec']['volumes'][0]['persistentVolumeClaim'].update(claimName='empty'),
                         lambda:self.pods.append({'metadata':{'name':'second-writer'}}),
                         lambda:self.storage_values['persistence'].update(existingClaim='locker'),
                         lambda:setattr(self,'storage_chart','minio-9.9.9')):
            with self.subTest(mutation=mutation):
                original=copy.deepcopy((self.objects,self.pods,self.storage_values,self.storage_chart))
                mutation();self.assert_refused_without_state_change()
                self.objects,self.pods,self.storage_values,self.storage_chart=original

    def test_foreign_release_and_plaintext_postgres_regression_refuse(self):
        for mutation in (lambda:self.objects[('Deployment',named.NAME)]['metadata']['annotations'].update({'meta.helm.sh/release-name':'other-release'}),
                         lambda:self.objects[('StatefulSet','postgres')]['spec']['template']['spec']['containers'][0].update(args=['-c','ssl=off'])):
            original=copy.deepcopy(self.objects);mutation();self.assert_refused_without_state_change();self.objects=original

    def test_missing_private_ca_or_changed_tls_secret_refuses_before_up(self):
        path=self.local.state/'ca.key';key=path.read_bytes();path.unlink()
        self.assert_refused_without_state_change()
        path.write_bytes(key)
        self.secrets['kind-tls']['data']['tls.crt']=base64.b64encode(b'unreviewed replacement').decode()
        self.assert_refused_without_state_change()

    def test_seeded_deletion_content_or_metadata_change_refuses_but_new_data_is_allowed(self):
        self.inventory.append({'key':'new-session/object','size':3,'etag':'new-data','versionId':None})
        named.validate(self.local)
        self.inventory[0]['size']+=1;self.assert_refused_without_state_change()
        self.inventory[0]=self.seed.copy();self.payload='other payload';self.assert_refused_without_state_change()

    def test_changed_active_selection_or_credential_refuses_before_up_invalidation(self):
        self.secrets['kind-pipeline']['data']['rootPassword']=base64.b64encode(b'rotated').decode()
        before=(self.local.state/'ready.json').read_bytes()
        with patch.object(stack.shutil,'which',return_value='fixture-tool'):
            with self.assertRaises(stack.StackError):self.local.up()
        self.assertEqual((self.local.state/'ready.json').read_bytes(),before)
        self.assertFalse(any(c[:2]==['helm','upgrade'] for c in self.calls))
        self.secrets['kind-pipeline']['data']['rootPassword']=base64.b64encode(self.credentials['locker'].encode()).decode()
        named.write(self.local.overrides,{**self.values,'unexpected':'changed'});self.assert_refused_without_state_change()

    def test_named_secret_reuse_preserves_additional_keys_and_never_replaces_secret(self):
        self.local.named_layout=self.record
        self.secrets['kind-pipeline']['data']['another_owner_key']=base64.b64encode(b'retain').decode()
        before=copy.deepcopy(self.secrets)
        self.local.secret('kind-pipeline',{'rootUser':'locker','rootPassword':self.credentials['locker']})
        self.assertEqual(before,self.secrets)
        with self.assertRaises(stack.StackError):self.local.secret('kind-pipeline',{'rootUser':'different'})

    def test_named_postgres_reuse_retains_tls_and_does_not_apply_statefulset(self):
        self.local.named_layout=self.record;called=[]
        self.local.apply=lambda *a,**kw:self.fail('existing Postgres was reapplied')
        self.local.postgres_roles=lambda *a:called.append(a)
        self.local.postgres(self.credentials,'fixture-services-image')
        self.assertEqual(called,[(self.credentials,'fixture-services-image')])
        self.assertEqual(self.objects[('StatefulSet','postgres')]['spec']['template']['spec']['containers'][0]['args'],['-c','ssl=on'])

    def test_same_release_upgrades_keep_rendered_claim_and_private_plugin_selection(self):
        self.local.named_layout=self.record;self.local.env['HELM_PLUGINS']='original-private-plugins'
        named.install_storage(self.local)
        upgrade=next(c for c in self.calls if c[:2]==['helm','upgrade'])
        self.assertEqual(upgrade[2],'kind-locker');self.assertNotIn('--install',upgrade)
        self.assertEqual(upgrade[upgrade.index('--post-renderer')+1],'kind-storage-names')
        self.assertIn('--server-side=false',upgrade)
        self.assertEqual(self.local.env['HELM_PLUGINS'],'original-private-plugins')
        self.assertNotIn('existingClaim',json.loads((self.local.state/'named-storage-values.json').read_text())['persistence'])

    def test_interrupted_tenant_update_admits_either_side_but_never_an_image_change(self):
        selected=stack.tenant_values(copy.deepcopy(self.values),{'orgId':'discovered-org','workspaceId':'discovered-workspace'},
                                     self.local.profile,self.local.arch,'e'*64)
        named.stage_selection(self.local,selected)
        named.validate(self.local)  # interrupted before values.json replacement
        named.write(self.local.overrides,selected)
        named.validate(self.local)  # interrupted after replacement, before ready
        before=(self.local.state/named.RECORD).read_bytes()
        changed=copy.deepcopy(selected);changed['relay-control']['image']['digest']='sha256:'+'9'*64
        with self.assertRaisesRegex(stack.StackError,'more than discovered tenant'):named.stage_selection(self.local,changed)
        self.assertEqual((self.local.state/named.RECORD).read_bytes(),before)

    def native_replacement(self):
        worker=self.values['sessions-pipeline']['worker']
        worker['components']={'hoopdb-indexer':{'enabled':False,'fullnameOverride':'session-metadata-indexer'}}
        self.values['sessions-pipeline']['nativeConsumer']={'enabled':True,'legacyIndexerDrained':True}
        self.rendered=[d for d in self.rendered if d['metadata']['name']!='session-metadata-indexer']
        self.objects.pop(('Deployment','session-metadata-indexer'))
        env={'SERVICE':'session-pipeline-consumer','RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER':'true',
             'SEARCH_INDEX_BACKEND':'postgres','PIPELINE_FANOUT':'off','NATIVE_CONSUMER_PREFLIGHT_MODE':'runtime',
             'NATIVE_CONSUMER_EXPECTED_ROLE':'search_consumer_runtime'}
        # A custom public name must work; deployment identity comes from render,
        # not a frozen list of the previous profile's worker implementation.
        doc={'kind':'Deployment','metadata':{'name':'qualified-native-writer','labels':{'app.kubernetes.io/name':'session-pipeline-consumer'}},
             'spec':{'replicas':1,'selector':{'matchLabels':{'role':'native-consumer'}},'template':{'spec':{'containers':[
                 {'name':'consumer','image':'fixture-native@sha256:'+'8'*64,'env':[{'name':k,'value':v} for k,v in env.items()]}]}}},
             'status':{'readyReplicas':1}}
        self.rendered.append(copy.deepcopy(doc));self.objects[('Deployment',doc['metadata']['name'])]=copy.deepcopy(doc)

    def test_selected_legacy_default_requires_every_rendered_workload(self):
        selected=named.verify_selection(self.local,self.values,self.objects)
        self.assertTrue(DEFAULT_LEGACY<={d['metadata']['name'] for d in selected})
        self.objects.pop(('Deployment','session-status-worker'))
        with self.assertRaisesRegex(stack.StackError,'missing or unready'):named.verify_selection(self.local,self.values,self.objects)

    def test_selected_native_writer_can_replace_the_disabled_legacy_indexer(self):
        self.native_replacement()
        selected=named.verify_selection(self.local,self.values,self.objects)
        self.assertNotIn('session-metadata-indexer',{d['metadata']['name'] for d in selected})
        self.assertIn('qualified-native-writer',{d['metadata']['name'] for d in selected})
        self.objects.pop(('Deployment','qualified-native-writer'))
        with self.assertRaisesRegex(stack.StackError,'missing or unready'):named.verify_selection(self.local,self.values,self.objects)

    def test_disabling_legacy_indexer_without_a_serving_native_replacement_refuses(self):
        self.native_replacement()
        self.values['sessions-pipeline']['nativeConsumer']['enabled']=False
        with self.assertRaisesRegex(stack.StackError,'drained native replacement'):named.verify_selection(self.local,self.values,self.objects)
        self.values['sessions-pipeline']['nativeConsumer']['enabled']=True
        self.rendered=[d for d in self.rendered if d['metadata']['name']!='qualified-native-writer']
        with self.assertRaisesRegex(stack.StackError,'no single rendered runtime'):named.verify_selection(self.local,self.values,self.objects)

    def test_native_label_alone_cannot_admit_the_owner_bootstrap_role(self):
        self.native_replacement()
        for doc in (self.rendered[-1],self.objects[('Deployment','qualified-native-writer')]):
            for entry in stack.pod_spec(doc)['containers'][0]['env']:
                if entry['name']=='NATIVE_CONSUMER_EXPECTED_ROLE':entry['value']='schema_owner'
        with self.assertRaisesRegex(stack.StackError,'no single rendered runtime'):named.verify_selection(self.local,self.values,self.objects)

    def test_native_replacement_refuses_an_undrained_or_remaining_legacy_indexer(self):
        self.native_replacement()
        self.values['sessions-pipeline']['nativeConsumer']['legacyIndexerDrained']=False
        with self.assertRaisesRegex(stack.StackError,'drained native replacement'):named.verify_selection(self.local,self.values,self.objects)
        self.values['sessions-pipeline']['nativeConsumer']['legacyIndexerDrained']=True
        self.objects[('Deployment','session-metadata-indexer')]={'kind':'Deployment','metadata':{'name':'session-metadata-indexer'},'spec':{'replicas':0}}
        with self.assertRaisesRegex(stack.StackError,'still present'):named.verify_selection(self.local,self.values,self.objects)

    def test_foreign_plugin_symlink_cannot_mutate_global_helm_configuration(self):
        self.local.named_layout=self.record
        foreign=self.root/'foreign-global-helm-plugins';foreign.mkdir()
        (self.local.state/'helm-named-plugins').symlink_to(foreign,target_is_directory=True)
        with self.assertRaisesRegex(stack.StackError,'must not redirect'):named.install_storage(self.local)
        self.assertEqual(list(foreign.iterdir()),[])
        self.assertFalse(any(c[:2]==['helm','upgrade'] for c in self.calls))

    def test_completed_proof_needs_causal_seed_and_distinct_resource_identity(self):
        self.assertEqual(named.completed_proof(self.proof,[self.seed],[self.seed]),[self.seed])
        for change in ({'result':'PENDING'},{'oneStoragePodVerified':1},{'afterInventory':{}},
                       {'pvcPreserved':False},{'newDeploymentUid':self.proof['oldDeploymentUid']},
                       {'sentinelKey':'../../somewhere'}):
            with self.subTest(change=change),self.assertRaises(stack.StackError):
                named.completed_proof({**self.proof,**change},[self.seed],[self.seed])

    def test_explicit_reconcile_archives_prior_state_and_issues_no_new_proof(self):
        (self.local.state/named.RECORD).unlink()
        packet=self.local.state/'cutover-packet';packet.mkdir()
        named.write(packet/'activation-receipt.json',self.proof)
        for label in ('before','after'):named.write(packet/(label+'-inventory-normalized-private.json'),[self.seed])
        named.write(packet/'values-before.json',self.storage_values)
        chart=self.root/'charts/sessions-pipeline/charts/minio-5.4.0.tgz'
        (packet/'minio-5.4.0.tgz').write_bytes(chart.read_bytes())
        packet_renderer=packet/'plugins/storage-public-name/post-render-storage-name.py';packet_renderer.parent.mkdir(parents=True)
        packet_renderer.write_bytes((HERE/'storage-name-renderer/postrender.py').read_bytes())
        named.write(packet/'render-review-receipt.json',{'result':'PASS','release':'kind-locker','chart':'minio-5.4.0',
                    'onlyChangedFields':['Deployment.metadata.name','Deployment.spec.template.metadata.name'],
                    'valuesSha256':named.sha_file(packet/'values-before.json'),'chartSha256':named.sha_file(chart),
                    'rendererSha256':named.sha_file(packet_renderer)})
        # A later, independently qualified site-origin change remains selected;
        # the storage cutover must not restore an obsolete application URL.
        self.values['relay-control']['publicUrl']='https://relay.kind.example'
        old={n:(self.local.state/n).read_bytes() for n in ('ready.json','images.json','control-build.json','values.json','proof.json')}
        with redirect_stdout(io.StringIO()):named.reconcile(self.local,packet/'activation-receipt.json',self.archive)
        self.assertFalse((self.local.state/'ready.json').exists());self.assertFalse((self.local.state/'images.json').exists())
        current=named.read(self.local.state/named.RECORD);history=self.local.state/current['history']
        for name,data in old.items():self.assertEqual((history/name).read_bytes(),data)
        self.assertEqual((self.local.state/'proof.json').read_bytes(),old['proof.json'])
        self.assertEqual(named.read(self.local.overrides),self.values)
        self.assertEqual(named.read(self.local.overrides)['relay-control']['publicUrl'],'https://relay.kind.example')
        self.assertEqual(named.read(self.local.state/'control-build.json')['sourceRevision'],control.REVISION)
        self.assertEqual((self.local.state/named.RECORD).stat().st_mode&0o777,0o600)
        named.validate(self.local)
        self.assertFalse(any(c[0] in ('apply','replace','delete','scale','create') or c[:2]==['helm','upgrade'] for c in self.calls))
        # A later interrupted up may have no active ready.json. Recovery must
        # explicitly name the retained independent anchor, never guess from
        # matching live labels/UIDs.
        with self.assertRaises(OSError):named.reconcile(self.local,packet/'activation-receipt.json',self.archive)
        with redirect_stdout(io.StringIO()):
            named.reconcile(self.local,packet/'activation-receipt.json',self.archive,history/'ready.json')
        named.validate(self.local)


class StorageRenderer(unittest.TestCase):
    def test_pinned_minio_chart_retains_the_claim_and_only_renames_the_deployment(self):
        root=HERE.parents[2]
        rendered=subprocess.run(['helm','template','kind-locker','charts/sessions-pipeline/charts/minio-5.4.0.tgz',
            '-n','agent-relay','--set','mode=standalone','--set','fullnameOverride=locker',
            '--set','existingSecret=kind-pipeline','--set','persistence.enabled=true'],cwd=root,
            text=True,capture_output=True,check=True).stdout
        renderer=HERE/'storage-name-renderer/postrender.py'
        result=subprocess.run([sys.executable,str(renderer)],input=rendered,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        before={(d['kind'],d['metadata']['name']):d for d in yaml.safe_load_all(rendered) if d}
        after={(d['kind'],d['metadata']['name']):d for d in yaml.safe_load_all(result.stdout) if d}
        changed=after.pop(('Deployment','session-object-storage'))
        changed['metadata']['name']='locker';changed['spec']['template']['metadata']['name']='locker'
        after[('Deployment','locker')]=changed
        self.assertEqual(before,after)
        self.assertIn(('PersistentVolumeClaim','locker'),after)
        for text in (rendered.replace('claimName: locker','claimName: empty-new-claim'),
                     rendered.replace('release: kind-locker','release: foreign-release'),
                     rendered.replace('kind: PersistentVolumeClaim','kind: UnexpectedResource')):
            refused=subprocess.run([sys.executable,str(renderer)],input=text,text=True,capture_output=True)
            self.assertNotEqual(refused.returncode,0)
            self.assertEqual(refused.stdout,'','refusal must emit no partially rewritten resources')


if __name__=='__main__':unittest.main()
