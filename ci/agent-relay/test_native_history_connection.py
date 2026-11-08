"""Causal chart tests for the opt-in Control native History connection."""
from copy import deepcopy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]
ORIGIN = "https://history.kind.agentrelay.com:8443"


class HistoryConnection(unittest.TestCase):
    def render(self, override, refuses=None):
        with tempfile.TemporaryDirectory() as directory:
            values = Path(directory) / "values.json"
            values.write_text(json.dumps(override))
            result = subprocess.run([
                "helm", "template", "proof", "charts/relay-control", "-n", "agent-relay",
                "-f", "charts/relay-control/ci/default-values.yaml", "-f", str(values),
            ], cwd=ROOT, capture_output=True, text=True)
        if refuses:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(refuses.lower(), result.stderr.lower())
            return []
        self.assertEqual(result.returncode, 0, result.stderr)
        return [d for d in yaml.safe_load_all(result.stdout) if d]

    def selected(self):
        return {"services": {
            "relayhistoryReadApiUrl": ORIGIN,
            "relayhistoryReadApiEvents": True,
            "relayhistoryHostAliases": [{"ip": "10.96.137.234", "hostnames": ["history.kind.agentrelay.com"]}],
        }, "extraEnv": [
            {"name": "RELAYCONTROL_INTROSPECT_SECRET", "valueFrom": {"secretKeyRef": {"name": "introspection", "key": "secret"}}},
            {"name": "SELFHOST_INTROSPECT_AUDIENCES", "value": ORIGIN},
        ]}

    def test_dormant_connection_does_not_change_pod_dns_or_env(self):
        for d in self.render({}):
            if d['kind'] not in ('Deployment', 'Job'):
                continue
            pod = d['spec']['template']['spec']
            self.assertNotIn('hostAliases', pod)
            names = {e['name'] for c in pod['containers'] for e in c.get('env', [])}
            self.assertNotIn('RELAYHISTORY_READ_API_URL', names)
            self.assertNotIn('RELAYHISTORY_READ_API_EVENTS', names)

    def test_enabled_connection_is_owned_by_api_only(self):
        docs = self.render(self.selected())
        api = next(d for d in docs if d['kind'] == 'Deployment')['spec']['template']['spec']
        self.assertEqual(api['hostAliases'], self.selected()['services']['relayhistoryHostAliases'])
        env = {e['name']: e for e in api['containers'][0]['env']}
        self.assertEqual(env['RELAYHISTORY_READ_API_URL']['value'], ORIGIN)
        self.assertEqual(env['RELAYHISTORY_READ_API_EVENTS']['value'], 'true')
        job = next(d for d in docs if d['kind'] == 'Job')['spec']['template']['spec']
        self.assertNotIn('hostAliases', job)
        names = {e['name'] for c in job['containers'] for e in c.get('env', [])}
        self.assertNotIn('RELAYHISTORY_READ_API_URL', names)
        self.assertNotIn('RELAYHISTORY_READ_API_EVENTS', names)

    def test_url_keeps_public_https_authority(self):
        for value in ('http://history.kind.agentrelay.com', 'https://127.0.0.1',
                      'https://history.kind.agentrelay.com/', 'https://user@history.kind.agentrelay.com',
                      'https://history.kind.agentrelay.com:0', 'https://history.kind.agentrelay.com:65536', False):
            with self.subTest(value=value):
                selected = self.selected()
                selected['services']['relayhistoryReadApiUrl'] = value
                self.render(selected, 'services.relayhistoryReadApiUrl')

    def test_events_requires_connection_and_strict_bool(self):
        self.render({'services': {'relayhistoryReadApiEvents': True}}, 'requires services.relayhistoryReadApiUrl')
        for value in ('true', 'false', 1):
            with self.subTest(value=value):
                selected = self.selected()
                selected['services']['relayhistoryReadApiEvents'] = value
                self.render(selected, 'must be a boolean')

    def test_scoped_dns_refuses_wrong_shape_and_foreign_host(self):
        for aliases in ({'ip': '10.96.1.1'},
                        [{'ip': '10.96.1.1', 'hostnames': []}],
                        [{'ip': '10.96.1.1', 'hostnames': ['other.kind.agentrelay.com']}],
                        [{'ip': '10.96.1.1', 'hostnames': ['history.kind.agentrelay.com', 'other.kind.agentrelay.com']}],
                        [{'ip': '10.96.1.1', 'hostnames': ['history.kind.agentrelay.com'], 'extra': 'refused'}],
                        [{'ip': '10.96.1.1', 'hostnames': ['history.kind.agentrelay.com']}] * 2):
            with self.subTest(aliases=aliases):
                selected = self.selected()
                selected['services']['relayhistoryHostAliases'] = aliases
                self.render(selected, 'hostAlias')

    def test_ip_is_canonical_literal(self):
        for ip in ('10.96.1.256', '010.96.1.1', 'dns.kind.agentrelay.com', '10.1.1.1/32', ''):
            with self.subTest(ip=ip):
                selected = self.selected()
                selected['services']['relayhistoryHostAliases'][0]['ip'] = ip
                self.render(selected, 'hostAlias.ip')

    def test_managed_env_cannot_be_duplicated_or_bypassed(self):
        for name in ('RELAYHISTORY_READ_API_URL', 'RELAYHISTORY_READ_API_EVENTS'):
            with self.subTest(name=name):
                selected = self.selected()
                selected['extraEnv'].append({'name': name, 'value': ORIGIN if name.endswith('URL') else 'false'})
                self.render(selected, 'managed by structured chart values')

    def test_managed_connection_requires_secret_reference_and_matching_audience(self):
        selected = self.selected()
        selected['extraEnv'] = []
        self.render(selected, 'requires RELAYCONTROL_INTROSPECT_SECRET')
        selected = self.selected()
        selected['extraEnv'][1]['value'] = 'https://another.kind.agentrelay.com:8443'
        self.render(selected, 'must include the exact managed')
        selected = self.selected()
        selected['extraEnv'][1] = {'name': 'SELFHOST_INTROSPECT_AUDIENCES', 'valueFrom': {'configMapKeyRef': {'name': 'unknown-audiences', 'key': 'origins'}}}
        self.render(selected, 'literal matching origin list')
        selected = self.selected()
        selected['services']['relayhistoryPublicUrl'] = ORIGIN
        selected['extraEnv'].pop()  # Control's default audience is this public URL.
        self.render(selected)

    def test_existing_extra_env_transport_remains_explicitly_compatible(self):
        docs = self.render({'extraEnv': [{'name': 'RELAYHISTORY_READ_API_URL', 'value': ORIGIN}]})
        api = next(d for d in docs if d['kind'] == 'Deployment')['spec']['template']['spec']
        self.assertNotIn('hostAliases', api)
        env = [e for e in api['containers'][0]['env'] if e['name'] == 'RELAYHISTORY_READ_API_URL']
        self.assertEqual(env, [{'name': 'RELAYHISTORY_READ_API_URL', 'value': ORIGIN}])


if __name__ == '__main__':
    unittest.main()
