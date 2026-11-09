"""Dependency-free causal tests for owned local native network selection."""
import copy
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

import native_network as n

UID = 'original-core-native-uid'

def values(profile='core'):
    origin = 'https://history.kind.agentrelay.com:8443'
    return {'localKind': {'profile': profile, 'enabled': True, 'allowLocalOnly': True}, 'sessions-pipeline': {
        'nativeRouting': {'enabled': True, 'origin': origin, 'className': 'traefik', 'tls': {'existingSecret': 'kind-tls'}},
        'sessionReadApi': {'enabled': True, 'origin': origin, 'login': {'advertisesSync': True}, 'auth': {'mode': 'relaycontrol_only', 'relaycontrol': {'enabled': True}}}, 'ingestEdge': {'enabled': True, 'origin': origin}},
        'relay-control': {'services': {'relayhistoryPublicUrl': origin, 'relayauthEnabled': False, 'relayhistoryReadApiEvents': True}}}


class Fixture:
    def __init__(self, root, profile='core', cluster=True):
        self.state = Path(root)
        self.profile = profile
        self.name = 'agent-relay-' + profile
        self.env = {'DOCKER_HOST': 'unix:///synthetic/docker.sock'}
        self.marker = self.state / 'cluster.json'
        self.calls = []
        self.cluster = cluster
        self.actual_uid = UID
        self.service = None
        self.public_service = None
        self.ingresses = []
        self.policies = []
        self.namespaces = ["kube-system", n.EDGE_NS, n.APP_NS]
        self.gateway = {'metadata': {'name': 'kind-edge', 'namespace': n.EDGE_NS, 'annotations': {
            'meta.helm.sh/release-name': 'kind-edge', 'meta.helm.sh/release-namespace': n.EDGE_NS}},
            'spec': {'template': {'metadata': {'labels': dict(n.SELECTOR)},
                'spec': {'containers': [{'ports': [{'name': 'websecure', 'containerPort': 8443}]}]}}}, 'status': {'readyReplicas': 1}}
        if cluster:
            self.marker.write_text(json.dumps({'version': 1, 'name': self.name, 'profile': profile,
                                               'clusterUid': UID, 'dockerHost': self.env['DOCKER_HOST']}))
        self.ready = self.state / 'ready.json'
        self.ready.write_text('original readiness stays byte identical')
        self.images = self.state / 'images.json'
        self.images.write_text('original image selection stays byte identical')

    def require_owned_cluster(self):
        self.calls.append(('owned-check',))
        if not self.cluster:
            raise ValueError('cluster absent')

    def cmd(self, args, **kw):
        self.calls.append(('cmd', args))
        if args != ['kind', 'get', 'clusters']:
            raise AssertionError(args)
        return SimpleNamespace(stdout=(self.name + '\n' if self.cluster else ''))

    def k(self, *args, namespace=None, **kw):
        self.calls.append(('k', args, namespace))
        if args[:3] == ('get', 'namespace', 'kube-system'):
            return SimpleNamespace(stdout=json.dumps({'metadata': {'uid': self.actual_uid}}))
        if args[:2] == ('get', 'namespace'):
            return SimpleNamespace(stdout=json.dumps({'items': [{'metadata': {'name': name}} for name in self.namespaces]}))
        if args[:2] == ('get', 'ingress'):
            assert namespace == n.APP_NS
            return SimpleNamespace(stdout=json.dumps({'items': self.ingresses}))
        if args[:2] == ('get', 'service'):
            assert namespace == n.EDGE_NS
            if args[2] == n.PUBLIC_SERVICE:
                return SimpleNamespace(stdout=json.dumps(self.public_service))
            return SimpleNamespace(stdout=json.dumps(self.service) if self.service else '')
        if args[:2] == ('get', 'networkpolicy'):
            assert namespace == n.APP_NS
            return SimpleNamespace(stdout=json.dumps({'items': self.policies}))
        if args[:2] == ('get', 'deployment'):
            assert namespace == n.EDGE_NS
            return SimpleNamespace(stdout=json.dumps({'items': [self.gateway] if self.gateway else []}))
        if args[:2] == ('create', '-f'):
            assert namespace == n.EDGE_NS
            if self.service is not None:
                raise ValueError('AlreadyExists')
            self.service = json.loads(kw['data'])
            self.service['metadata']['uid'] = 'created-service-uid'
            self.service['spec'].update(clusterIP='10.96.137.234', clusterIPs=['10.96.137.234'],
                                        ipFamilies=['IPv4'], ipFamilyPolicy='SingleStack',
                                        internalTrafficPolicy='Cluster', sessionAffinity='None')
            return SimpleNamespace(stdout=json.dumps(self.service))
        raise AssertionError(args)

    def seed_owned(self, selection=None):
        result = n.ensure(self, selection or values(self.profile))
        self.calls.clear()
        return result

    def assert_anchors(self, case):
        case.assertEqual(self.ready.read_text(), 'original readiness stays byte identical')
        case.assertEqual(self.images.read_text(), 'original image selection stays byte identical')
        case.assertFalse(any(c[0] == 'k' and c[1][0] in ('apply', 'replace', 'delete', 'patch') for c in self.calls))


class NativeNetwork(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.stack = Fixture(self.temp.name)

    def independent(self):
        v = values(); reader = v["sessions-pipeline"]["sessionReadApi"]
        reader.update(login={"advertisesSync": False}, events={"messageIds": True},
            auth={"mode": "self_issued", "relaycontrol": {"enabled": False},
                  "selfIssued": {"internalSecret": {"existingSecret": "reader-issuer", "key": "internal-secret"}}})
        v["relay-control"]["services"].update(relayhistoryBackend="native", relayhistoryReadApiEvents=False,
            sessionReadApiUrl="http://agent-relay-read-api.agent-relay.svc.cluster.local",
            relayhistoryUrl="", relayhistoryPublicUrl="",
            sessionReadApiPublicUrl=reader["origin"])
        v["relay-control"]["secretKeys"] = {"sessionReadApiSecret": "reader-internal", "introspectSecret": "ingest-introspection"}
        return v

    def public_route(self):
        v = self.independent(); v['relay-control']['publicUrl'] = 'https://relay.kind.agentrelay.com'
        self.stack.public_service = {'kind': 'Service', 'metadata': {'name': n.PUBLIC_SERVICE, 'namespace': n.EDGE_NS,
            'uid': 'original-public-service', 'labels': {'app.kubernetes.io/managed-by': 'Helm'},
            'annotations': {'meta.helm.sh/release-name': 'kind-edge', 'meta.helm.sh/release-namespace': n.EDGE_NS}},
            'spec': {'type': 'NodePort', 'selector': dict(n.SELECTOR), 'clusterIP': '10.96.42.7', 'clusterIPs': ['10.96.42.7'],
                'ports': [{'name': 'websecure', 'port': 443, 'targetPort': 'websecure', 'nodePort': 30443}]}}
        return v

    def test_public_route_binds_owned_service_and_literal_control_host_without_mutation(self):
        v = self.public_route(); v['relay-control']['services']['relayhistoryHostAliases'] = [
            {'ip': '10.96.137.234', 'hostnames': ['history.kind.agentrelay.com']}]
        before = copy.deepcopy(v)
        record = n.control_public_route(self.stack, v)
        self.assertEqual(n.control_public_route(self.stack, v, record), record)
        result = n.public_route_values(v, record)
        self.assertEqual(result['relay-control']['services']['publicHostAliases'], [
            {'ip': '10.96.42.7', 'hostnames': ['relay.kind.agentrelay.com']}])
        self.assertEqual(result['relay-control']['services']['relayhistoryHostAliases'],
                         v['relay-control']['services']['relayhistoryHostAliases'])
        self.assertEqual(record['service']['specSha256'], n.digest(self.stack.public_service['spec']))
        self.assertEqual(v, before)
        self.assertTrue(all(c[0] == 'owned-check' or c[0] == 'k' and c[1][0] == 'get' for c in self.stack.calls))

    def test_public_route_refuses_recreated_service_selector_transport_and_record_drift(self):
        v = self.public_route(); record = n.control_public_route(self.stack, v)
        original = copy.deepcopy(self.stack.public_service)
        for change in (lambda s: s['metadata'].update(uid='replacement'),
                       lambda s: s['metadata']['annotations'].update({'meta.helm.sh/release-name': 'foreign'}),
                       lambda s: s['spec']['selector'].update({'app.kubernetes.io/name': 'foreign'}),
                       lambda s: s['spec']['ports'][0].update(port=8443),
                       lambda s: s['spec']['ports'][0].update(targetPort=443),
                       lambda s: s['spec']['ports'][0].update(nodePort=31443),
                       lambda s: s['spec'].update(clusterIP='10.96.42.8', clusterIPs=['10.96.42.8'])):
            self.stack.public_service = copy.deepcopy(original); change(self.stack.public_service)
            with self.subTest(change=change), self.assertRaises(ValueError): n.control_public_route(self.stack, v, record)
        self.stack.public_service = original
        self.stack.gateway['spec']['template']['spec']['containers'][0]['ports'][0]['containerPort'] = 443
        with self.assertRaisesRegex(ValueError, 'Pod port 8443'): n.control_public_route(self.stack, v, record)
        for key, val in (('host', 'other.kind.agentrelay.com'), ('origin', 'https://other.kind.agentrelay.com')):
            changed = copy.deepcopy(record); changed[key] = val
            with self.assertRaisesRegex(ValueError, 'observation'): n.public_route_values(v, changed)

    def test_missing_public_service_is_pending_only_before_first_qualification(self):
        v = self.public_route(); original = n.control_public_route(self.stack, v)
        self.stack.public_service = None
        self.assertIsNone(n.control_public_route(self.stack, v, allow_absent=True))
        with self.assertRaisesRegex(ValueError, 'disappeared'):
            n.control_public_route(self.stack, v, original, allow_absent=True)
        with self.assertRaisesRegex(ValueError, 'disappeared'): n.control_public_route(self.stack, v)
        self.assertFalse(any(c[0] == 'k' and c[1][0] != 'get' for c in self.stack.calls))

    def test_async_exact_admission_route_is_required_without_widening_reader(self):
        # Install the unmodified owned sync fixture, then require the one new
        # exact status path for either async admission mode.
        self.stack.ingresses = []
        cfg = n.selection(values())
        paths = [{'path': path, 'pathType': typ, 'backend': {'service': {'name': service, 'port': {'number': 80}}}}
                 for path, typ, service in [('/v1', 'Prefix', cfg['reader']), ('/v1/delivery/batches', 'Exact', cfg['ingest']),
                    ('/v1/turns/batches', 'Exact', cfg['ingest']), ('/v1/delivery/limits', 'Exact', cfg['ingest'])]]
        self.stack.ingresses = [{'metadata': {'name': cfg['ingress'], 'namespace': n.APP_NS, 'uid': 'owned',
            'labels': {'app.kubernetes.io/managed-by': 'Helm'}, 'annotations': {
                'meta.helm.sh/release-name': 'agent-relay', 'meta.helm.sh/release-namespace': n.APP_NS}},
            'spec': {'ingressClassName': 'traefik', 'tls': [{'hosts': [cfg['host']], 'secretName': cfg['tls']}],
                     'rules': [{'host': cfg['host'], 'http': {'paths': paths}}]}}]
        for mode in ('async', 'drain'):
            v = values(); v['sessions-pipeline']['ingestEdge']['admission'] = {'mode': mode}
            with self.assertRaisesRegex(ValueError, 'path contract'): n._ingresses(self.stack, n.selection(v))
            status = {'path': '/v1/delivery/admission', 'pathType': 'Exact',
                      'backend': {'service': {'name': cfg['ingest'], 'port': {'number': 80}}}}
            paths.append(status); n._ingresses(self.stack, n.selection(v))
            status['pathType'] = 'Prefix'
            with self.assertRaisesRegex(ValueError, 'path contract'): n._ingresses(self.stack, n.selection(v))
            paths.pop()

    def test_independent_private_reader_never_creates_or_injects_public_dns_alias(self):
        v = self.independent(); before = copy.deepcopy(v)
        record = n.ensure(self.stack, v)
        self.assertEqual(record["type"], "local-kind-native-private-reader")
        self.assertIsNone(self.stack.service)
        self.assertFalse((self.stack.state / n.RECORD).exists())
        self.assertEqual(n.selected_values(v, record), before)
        self.assertEqual(n.ensure(self.stack, v), record)
        self.stack.assert_anchors(self)

    def test_independent_authority_mixing_and_legacy_service_refuse_without_mutation(self):
        for change in (lambda v: v["relay-control"]["services"].update(relayhistoryReadApiUrl=v["sessions-pipeline"]["sessionReadApi"]["origin"]),
                       lambda v: v["sessions-pipeline"]["sessionReadApi"]["login"].update(advertisesSync=True),
                       lambda v: v["sessions-pipeline"]["sessionReadApi"]["events"].update(messageIds=False),
                       lambda v: v["sessions-pipeline"]["sessionReadApi"]["auth"]["relaycontrol"].update(enabled=True),
                       lambda v: v["relay-control"]["services"].update(sessionReadApiUrl="http://foreign.agent-relay.svc.cluster.local")):
            v = self.independent(); change(v)
            with self.assertRaises(ValueError): n.ensure(self.stack, v)
        self.assertFalse(any(c[0] == "k" and c[1][0] == "create" for c in self.stack.calls))
        self.stack.seed_owned()
        with self.assertRaisesRegex(ValueError, "silently reuse"):
            n.preflight(self.stack, self.independent())
        self.stack.assert_anchors(self)

    def test_default_off_does_not_inspect_write_or_prepare_any_network(self):
        before = {p.name: p.read_bytes() for p in Path(self.temp.name).iterdir()}
        for v in ({}, {'sessions-pipeline': {'nativeRouting': {'enabled': False}}}):
            self.assertIsNone(n.preflight(self.stack, v))
            self.assertIsNone(n.ensure(self.stack, v))
            self.assertEqual(n.selected_values(v, None), v)
        self.assertEqual(self.stack.calls, [])
        self.assertEqual({p.name: p.read_bytes() for p in Path(self.temp.name).iterdir()}, before)

    def test_fresh_profile_can_preflight_before_cluster_or_gateway_creation(self):
        with tempfile.TemporaryDirectory() as root:
            s = Fixture(root, cluster=False)
            self.assertEqual(n.preflight(s, values()), {'pendingFreshCluster': True, 'origin': values()['sessions-pipeline']['nativeRouting']['origin']})
            with self.assertRaisesRegex(ValueError, 'owned cluster and gateway'):
                n.ensure(s, values())
            self.assertFalse(any(c[0] == 'k' for c in s.calls))
            s.assert_anchors(self)

    def test_cold_service_creation_uses_owned_gateway_and_records_allocated_ip_once(self):
        observation = n.ensure(self.stack, values())
        self.assertEqual(observation['service']['clusterIP'], '10.96.137.234')
        self.assertEqual(json.loads((self.stack.state / n.RECORD).read_text()), observation)
        self.assertEqual(self.stack.service['spec']['selector'], n.SELECTOR)
        self.assertEqual(self.stack.service['spec']['ports'], [{'name': 'history-https', 'port': 8443, 'protocol': 'TCP', 'targetPort': 'websecure'}])
        self.assertEqual(n.ensure(self.stack, values()), observation)
        self.assertEqual(len([c for c in self.stack.calls if c[0] == 'k' and c[1][0] == 'create']), 1)
        self.stack.assert_anchors(self)

    def test_existing_manual_service_refuses_even_when_spec_would_match(self):
        self.stack.service = n.service_document({'name': self.stack.name, 'profile': 'core', 'clusterUid': UID})
        self.stack.service['metadata'] = {'name': n.SERVICE, 'namespace': n.EDGE_NS, 'uid': 'manual'}
        self.stack.service['spec']['clusterIP'] = '10.96.137.234'
        with self.assertRaisesRegex(ValueError, 'qualified private ownership record'):
            n.preflight(self.stack, values())
        with self.assertRaises(ValueError):
            n.record_for_service(self.stack, values(), self.stack.service)
        self.stack.assert_anchors(self)
        self.assertFalse(any(c[0] == 'k' and c[1][0] == 'create' for c in self.stack.calls))

    def test_replaced_service_or_mismatched_cluster_ip_never_updates_receipt_or_alias(self):
        initial = self.stack.seed_owned()
        original = (self.stack.state / n.RECORD).read_bytes()
        for field, value in (('uid', 'replacement-service'), ('clusterIP', '10.96.137.235')):
            with self.subTest(field=field):
                saved = copy.deepcopy(self.stack.service)
                if field == 'uid':
                    self.stack.service['metadata']['uid'] = value
                else:
                    self.stack.service['spec'].update(clusterIP=value, clusterIPs=[value])
                with self.assertRaisesRegex(ValueError, 'UID, origin, spec or ClusterIP'):
                    n.ensure(self.stack, values())
                self.assertEqual((self.stack.state / n.RECORD).read_bytes(), original)
                self.stack.service = saved
        self.stack.assert_anchors(self)
        self.assertEqual(initial['service']['clusterIP'], '10.96.137.234')

    def test_foreign_port_selector_namespace_profile_or_release_refuses_no_mutation(self):
        self.stack.seed_owned()
        mutations = [lambda s: s['spec']['ports'][0].update(port=443),
                     lambda s: s['spec']['selector'].update({'app.kubernetes.io/name': 'other'}),
                     lambda s: s['metadata'].update(namespace='foreign'),
                     lambda s: s['metadata']['labels'].update({'kind.agentrelay.dev/profile': 'addons'}),
                     lambda s: s['metadata']['annotations'].update({'meta.helm.sh/release-name': 'other-release'}),
                     lambda s: s['spec'].update(externalIPs=['1.1.1.1']),
                     lambda s: s['spec'].update(clusterIP='None')]
        for mutate in mutations:
            saved = copy.deepcopy(self.stack.service)
            mutate(self.stack.service)
            with self.assertRaises(ValueError):
                n.preflight(self.stack, values())
            self.stack.service = saved
        self.stack.assert_anchors(self)

    def test_missing_record_replaced_cluster_or_missing_recorded_service_refuses(self):
        self.stack.seed_owned()
        original = (self.stack.state / n.RECORD).read_bytes()
        (self.stack.state / n.RECORD).unlink()
        with self.assertRaisesRegex(ValueError, 'ownership record'):
            n.preflight(self.stack, values())
        (self.stack.state / n.RECORD).write_bytes(original)
        self.stack.actual_uid = 'replacement-cluster'
        with self.assertRaisesRegex(ValueError, 'identity changed'):
            n.preflight(self.stack, values())
        self.stack.actual_uid = UID
        self.stack.service = None
        with self.assertRaisesRegex(ValueError, 'disappeared'):
            n.preflight(self.stack, values())
        self.stack.assert_anchors(self)

    def test_gateway_must_be_owned_ready_and_match_the_fixed_selector_before_create(self):
        for mutate in (lambda g: g['status'].update(readyReplicas=0),
                       lambda g: g['metadata']['annotations'].update({'meta.helm.sh/release-name': 'foreign'}),
                       lambda g: g['spec']['template']['metadata']['labels'].update({'app.kubernetes.io/name': 'other'})):
            saved = copy.deepcopy(self.stack.gateway)
            mutate(self.stack.gateway)
            with self.assertRaises(ValueError):
                n.ensure(self.stack, values())
            self.assertIsNone(self.stack.service)
            self.stack.gateway = saved
        self.stack.assert_anchors(self)

    def test_manual_or_competing_ingress_refuses_before_service_creation(self):
        cfg = n.selection(values())
        for name, annotation in ((cfg['ingress'], {}), ('legacy-history', {'meta.helm.sh/release-name': 'agent-relay'})):
            self.stack.ingresses = [{'metadata': {'name': name, 'namespace': n.APP_NS, 'uid': 'manual-ingress', 'annotations': annotation},
                                     'spec': {'rules': [{'host': cfg['host']} ]}}]
            with self.assertRaisesRegex(ValueError, 'Ingress requires'):
                n.ensure(self.stack, values())
            self.assertIsNone(self.stack.service)
        self.stack.assert_anchors(self)

    def test_existing_owned_ingress_must_match_exact_route_tls_and_backend_contract(self):
        cfg = n.selection(values())
        paths = [{"path": path, "pathType": typ, "backend": {"service": {"name": name, "port": {"number": 80}}}}
                 for path, typ, name in [("/v1", "Prefix", cfg["reader"]), ("/v1/delivery/batches", "Exact", cfg["ingest"]),
                                         ("/v1/turns/batches", "Exact", cfg["ingest"]), ("/v1/delivery/limits", "Exact", cfg["ingest"])]]
        owned = {"metadata": {"name": cfg["ingress"], "namespace": n.APP_NS, "uid": "owned-ingress",
                 "labels": {"app.kubernetes.io/managed-by": "Helm"}, "annotations": {
                 "meta.helm.sh/release-name": "agent-relay", "meta.helm.sh/release-namespace": n.APP_NS}},
                 "spec": {"ingressClassName": "traefik", "tls": [{"hosts": [cfg["host"]], "secretName": cfg["tls"]}],
                          "rules": [{"host": cfg["host"], "http": {"paths": paths}}]}}
        self.stack.ingresses = [owned]
        self.assertTrue(n.preflight(self.stack, values())["pendingFreshService"])
        for mutate in (lambda d: d["spec"].update(ingressClassName="other"),
                       lambda d: d["spec"]["tls"][0].update(secretName="different"),
                       lambda d: d["spec"]["rules"][0].update(host="other.kind.agentrelay.com"),
                       lambda d: d["spec"]["rules"][0]["http"]["paths"][0]["backend"]["service"].update(name=cfg["ingest"])):
            altered = copy.deepcopy(owned);mutate(altered);self.stack.ingresses = [altered]
            with self.assertRaises(ValueError):
                n.preflight(self.stack, values())
        self.stack.assert_anchors(self)

    def test_wildcard_or_wrong_host_manual_selected_name_refuses_before_gateway_or_service_write(self):
        cfg = n.selection(values())
        for name, host in (("wildcard", "*.kind.agentrelay.com"), (cfg["ingress"], "other.kind.agentrelay.com")):
            self.stack.ingresses = [{"metadata": {"name": name, "namespace": n.APP_NS, "uid": "manual"},
                                     "spec": {"rules": [{"host": host}]}}]
            with self.assertRaisesRegex(ValueError, "ownership handoff"):
                n.preflight(self.stack, values())
        self.assertFalse(any(c[0] == "k" and c[1][0] == "create" for c in self.stack.calls))
        self.stack.assert_anchors(self)

    def test_preflight_allows_absent_gateway_but_refuses_existing_foreign_gateway(self):
        self.stack.gateway = None
        self.assertTrue(n.preflight(self.stack, values())["pendingFreshService"])
        self.stack.gateway = {"metadata": {"namespace": n.EDGE_NS, "annotations": {"meta.helm.sh/release-name": "foreign"}},
                              "spec": {"template": {"metadata": {"labels": dict(n.SELECTOR)}}}, "status": {"readyReplicas": 1}}
        with self.assertRaisesRegex(ValueError, "foreign"):
            n.preflight(self.stack, values())
        self.stack.assert_anchors(self)

    def test_profile_mismatch_malformed_bool_and_private_origin_refuse_without_mutation(self):
        for mutate in (lambda v: v["localKind"].update(profile="addons"),
                       lambda v: v["sessions-pipeline"]["nativeRouting"].update(enabled=1),
                       lambda v: [v["sessions-pipeline"][key].update(origin="https://history.internal:8443") for key in ("nativeRouting", "sessionReadApi", "ingestEdge")]):
            selected = values();mutate(selected)
            with self.assertRaises(ValueError):
                n.preflight(self.stack, selected)
        self.stack.assert_anchors(self)

    def test_catchall_hostless_and_default_backend_ingresses_refuse_before_mutation(self):
        for spec in ({"rules": [{"http": {"paths": []}}]}, {"defaultBackend": {"service": {"name": "other", "port": {"number": 80}}}}):
            self.stack.ingresses = [{"metadata": {"name": "catchall", "namespace": n.APP_NS, "uid": "manual"}, "spec": spec}]
            with self.assertRaisesRegex(ValueError, "ownership handoff"):
                n.preflight(self.stack, values())
        self.assertFalse(any(c[0] == "k" and c[1][0] == "create" for c in self.stack.calls))
        self.stack.assert_anchors(self)

    def test_source_owned_policy_must_remain_exact_and_manual_policy_refuses(self):
        policy = {"metadata": {"name": n.CONTROL_EGRESS, "namespace": n.APP_NS, "uid": "owned-policy",
            "labels": {"app.kubernetes.io/managed-by": "Helm"}, "annotations": {
                "meta.helm.sh/release-name": "agent-relay", "meta.helm.sh/release-namespace": n.APP_NS}},
            "spec": n.control_egress_spec(values())}
        self.stack.policies = [policy]
        self.assertTrue(n.preflight(self.stack, values())["pendingFreshService"])
        for mutate in (lambda d: d["metadata"].update(annotations={}),
                       lambda d: d["spec"]["egress"][0]["ports"][0].update(port=443),
                       lambda d: d["spec"]["podSelector"]["matchLabels"].update({"app.kubernetes.io/name": "other"}),
                       lambda d: d["spec"]["egress"][0]["to"][0]["namespaceSelector"]["matchLabels"].update({"kubernetes.io/metadata.name": "other"})):
            bad = copy.deepcopy(policy);mutate(bad);self.stack.policies = [bad]
            with self.assertRaises(ValueError):
                n.preflight(self.stack, values())
        self.stack.assert_anchors(self)

    def test_receipt_creation_race_cannot_overwrite_the_other_record(self):
        target = self.stack.state / n.RECORD
        def raced_link(source, destination):
            Path(destination).write_text("other writer record survives")
            raise FileExistsError("synthetic race")
        with patch.object(n.os, "link", side_effect=raced_link):
            with self.assertRaisesRegex(ValueError, "receipt appeared concurrently"):
                n.ensure(self.stack, values())
        self.assertEqual(target.read_text(), "other writer record survives")
        self.assertIsNotNone(self.stack.service)
        self.assertFalse(list(self.stack.state.glob(".native-network-*")))
        self.stack.assert_anchors(self)

    def test_owned_cluster_without_fresh_edge_or_app_namespaces_can_prepare(self):
        self.stack.namespaces = ["kube-system", "default"]
        self.assertTrue(n.preflight(self.stack, values())["pendingFreshService"])
        self.assertFalse(any(c[0] == "k" and c[2] in (n.APP_NS, n.EDGE_NS) for c in self.stack.calls))
        self.stack.assert_anchors(self)

    def test_pattern_a_auth_events_and_explicit_local_optins_are_required(self):
        mutations = [lambda v: v["localKind"].update(enabled=False),
            lambda v: v["localKind"].update(allowLocalOnly=False),
            lambda v: v["relay-control"]["services"].update(relayauthEnabled=True),
            lambda v: v["relay-control"]["services"].update(relayhistoryReadApiEvents=False),
            lambda v: v["relay-control"]["services"].update(relayhistoryReadApiEvents="true"),
            lambda v: v["sessions-pipeline"]["sessionReadApi"]["login"].update(advertisesSync=False),
            lambda v: v["sessions-pipeline"]["sessionReadApi"]["auth"].update(mode="legacy"),
            lambda v: v["sessions-pipeline"]["sessionReadApi"]["auth"]["relaycontrol"].update(enabled=False)]
        for mutate in mutations:
            selected = values();mutate(selected)
            with self.assertRaises(ValueError):
                n.preflight(self.stack, selected)
        self.assertIsNone(self.stack.service)
        self.stack.assert_anchors(self)

    def test_conflicting_control_alias_refuses_during_preflight_before_gateway_mutation(self):
        bad = values()
        bad["relay-control"]["services"]["relayhistoryHostAliases"] = [{"ip": "10.0.0.1", "hostnames": ["history.kind.agentrelay.com"]}]
        with self.assertRaisesRegex(ValueError, "unallocated edge"):
            n.preflight(self.stack, bad)
        self.assertIsNone(self.stack.service)
        self.stack.seed_owned()
        with self.assertRaisesRegex(ValueError, "aliases differ"):
            n.preflight(self.stack, bad)
        self.stack.assert_anchors(self)

    def test_tls_and_ingress_dns_subdomains_match_the_chart_contract(self):
        selected = values()
        selected["sessions-pipeline"]["nativeRouting"].update(fullnameOverride="kind.native.history")
        selected["sessions-pipeline"]["nativeRouting"]["tls"]["existingSecret"] = "kind.history.tls"
        cfg = n.selection(selected)
        self.assertEqual(cfg["ingress"], "kind.native.history")
        self.assertEqual(cfg["tls"], "kind.history.tls")
        selected["sessions-pipeline"]["sessionReadApi"]["fullnameOverride"] = "invalid.service"
        with self.assertRaisesRegex(ValueError, "Service names"):
            n.selection(selected)

    def test_values_selection_is_pure_scoped_and_preserves_explicit_events_flag(self):
        observation = self.stack.seed_owned()
        selected = values()
        original = copy.deepcopy(selected)
        selected['relay-control']['services']['relayhistoryReadApiEvents'] = True
        result = n.selected_values(selected, observation)
        self.assertEqual(result['relay-control']['services']['relayhistoryHostAliases'], [{'ip': '10.96.137.234', 'hostnames': ['history.kind.agentrelay.com']}])
        self.assertEqual(result['relay-control']['services']['relayhistoryReadApiUrl'], original['relay-control']['services']['relayhistoryPublicUrl'])
        self.assertTrue(result['relay-control']['services']['relayhistoryReadApiEvents'])
        self.assertNotIn('relayhistoryHostAliases', selected['relay-control']['services'])
        result['relay-control']['services']['relayhistoryHostAliases'][0]['ip'] = 'other'
        self.assertEqual(observation['service']['clusterIP'], '10.96.137.234')

    def test_mismatched_origin_alias_or_explicit_control_url_refuses_without_rewriting(self):
        observation = self.stack.seed_owned()
        for mutate in (lambda v: v['sessions-pipeline']['sessionReadApi'].update(origin='https://other.kind.agentrelay.com:8443'),
                       lambda v: v['relay-control']['services'].update(relayhistoryReadApiUrl='http://internal'),
                       lambda v: v['relay-control']['services'].update(relayhistoryHostAliases=[{'ip': '10.1.1.1', 'hostnames': ['other']}])):
            selected = values();mutate(selected);before = copy.deepcopy(selected)
            with self.assertRaises(ValueError):
                n.selected_values(selected, observation)
            self.assertEqual(before, selected)
        self.stack.assert_anchors(self)

    def test_addons_profile_does_not_inherit_core_service_or_record_authority(self):
        self.stack.seed_owned()
        self.stack.profile = 'addons';self.stack.name = 'agent-relay-addons'
        self.stack.marker.write_text(json.dumps({'version': 1, 'name': self.stack.name, 'profile': self.stack.profile, 'clusterUid': UID, 'dockerHost': self.stack.env['DOCKER_HOST']}))
        with self.assertRaises(ValueError):
            n.preflight(self.stack, values('addons'))
        self.stack.assert_anchors(self)


if __name__ == '__main__':
    unittest.main()
