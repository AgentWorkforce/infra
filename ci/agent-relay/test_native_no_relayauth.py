#!/usr/bin/env python3
"""Render checks for the install without RelayAuth or standalone RelayHistory."""
import json
import subprocess
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
NATIVE = {'services': {
    'relayauthEnabled': False, 'relayauthUrl': '', 'relayhistoryUrl': '', 'relayhistoryPublicUrl': '',
    'relayhistoryBackend': 'native', 'sessionReadApiUrl': 'http://agent-relay-read-api',
    'sessionReadApiPublicUrl': 'https://history.placeholder.company',
}, 'secretKeys': {'relayauthApiKey': '', 'introspectSecret': 'introspect', 'sessionReadApiSecret': 'read'}}


def merge(base, overlay):
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            merge(base[key], value)
        else:
            base[key] = value
    return base


def control(overrides):
    defaults = yaml.safe_load((ROOT / 'charts/relay-control/values.yaml').read_text())
    ci = yaml.safe_load((ROOT / 'charts/relay-control/ci/default-values.yaml').read_text())
    values = merge(merge(json.loads(json.dumps(merge(defaults, ci))), NATIVE), overrides)
    args = ['--set-json', 'services=' + json.dumps(values['services']),
            '--set-json', 'secretKeys=' + json.dumps(values['secretKeys']),
            '--set-json', 'introspection=' + json.dumps(values.get('introspection', {'audiences': []}))]
    return subprocess.run(['helm', 'template', 'test', 'charts/relay-control',
                           '-f', 'charts/relay-control/ci/default-values.yaml', *args],
                          cwd=ROOT, capture_output=True, text=True)


class NativeNoRelayauth(unittest.TestCase):
    def test_gcp_native_profile_routes_reader_ingest_and_postgres_search(self):
        result = subprocess.run([
            'helm', 'template', 'proof', 'charts/agent-relay', '-n', 'agent-relay', '--no-hooks',
            '-f', 'charts/agent-relay/values-gcp.yaml',
            '-f', 'charts/agent-relay/values-gcp-native.yaml',
            '-f', 'charts/agent-relay/ci/gcp-native-values.yaml',
        ], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        docs = [doc for doc in yaml.safe_load_all(result.stdout) if doc]
        deployments = {doc['metadata']['name']: doc for doc in docs if doc.get('kind') == 'Deployment'}
        self.assertNotIn('relayauth', deployments)
        self.assertNotIn('relayhistory', deployments)
        for name in ('agent-relay-read-api', 'proof-ingest-edge', 'proof-search-indexer'):
            self.assertIn(name, deployments)
            self.assertTrue(deployments[name]['spec']['template']['spec']['containers'][0]['image'].startswith(
                'ghcr.io/agentworkforce/sessions-pipeline@sha256:77022c5b'))
        services = {doc['metadata']['name']: doc for doc in docs if doc.get('kind') == 'Service'}
        self.assertIn('agent-relay-read-api', services)
        self.assertEqual(
            deployments['relay-control']['spec']['template']['spec']['containers'][0]['image'],
            'ghcr.io/agentworkforce/relay-control@sha256:0b9c5a077b49b31178cc669e7c1d532f39e64c840087ca41636bb84a6c62631c')
        self.assertEqual(
            deployments['relay-webapp']['spec']['template']['spec']['containers'][0]['image'],
            'ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d1323965dce890f19d0b7f857d706c00d7756f719c713763fdb49f3')
        control_env = {
            item['name']: item.get('value')
            for item in deployments['relay-control']['spec']['template']['spec']['containers'][0]['env']
        }
        self.assertEqual(control_env['SESSION_READ_API_URL'], 'http://agent-relay-read-api')

        ingress = next(doc for doc in docs if doc.get('kind') == 'Ingress' and doc['metadata']['name'] == 'example-agent-relay')
        history = next(rule for rule in ingress['spec']['rules'] if rule['host'] == 'history.placeholder.company')
        routes = {(path['path'], path['pathType']): path['backend']['service']['name'] for path in history['http']['paths']}
        self.assertEqual(routes[('/v1/delivery/batches', 'Exact')], 'example-agent-relay-history-ingest')
        self.assertEqual(routes[('/v1/sessions', 'Prefix')], 'example-agent-relay-history-read')
        self.assertEqual(routes[('/', 'Prefix')], 'example-agent-relay-cast-edge-deny')
        kinds = {(doc.get('kind'), doc.get('metadata', {}).get('name')) for doc in docs}
        for name in ('example-agent-relay-history-read', 'example-agent-relay-history-ingest'):
            self.assertIn(('Service', name), kinds)
            self.assertIn(('BackendConfig', name), kinds)
        self.assertFalse(any(doc.get('kind') == 'Secret' for doc in docs))

    def test_umbrella_overlay_renders_without_relayauth_or_history(self):
        result = subprocess.run(['helm', 'template', 'proof', 'charts/agent-relay', '-n', 'agent-relay', '--no-hooks',
                                 '-f', 'charts/agent-relay/values-eks.yaml', '-f', 'charts/agent-relay/values-eks-native.yaml'],
                                cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        docs = [doc for doc in yaml.safe_load_all(result.stdout) if doc]
        names = {doc['metadata']['name'] for doc in docs if doc.get('kind') == 'Deployment'}
        self.assertNotIn('relayauth', names)
        self.assertNotIn('relayhistory', names)
        control_deploy = next(doc for doc in docs if doc.get('kind') == 'Deployment' and doc['metadata']['name'] == 'relay-control')
        env = {e['name']: e.get('value') for e in control_deploy['spec']['template']['spec']['containers'][0]['env']}
        self.assertEqual(env['RELAYHISTORY_BACKEND'], 'native')
        self.assertEqual(env['SESSION_READ_API_PUBLIC_URL'], 'https://history.placeholder.company')
        for absent in ('RELAYAUTH_URL', 'RELAYAUTH_API_KEY_FILE', 'RELAYHISTORY_URL', 'RELAYHISTORY_PUBLIC_URL'):
            self.assertNotIn(absent, env)
        self.assertEqual(env['SELFHOST_INTROSPECT_AUDIENCES'], 'https://history.placeholder.company')

    def test_control_refuses_a_native_install_missing_its_requirements(self):
        cases = [
            ({'services': {'relayauthEnabled': True, 'relayauthUrl': 'http://relayauth:8787'},
              'secretKeys': {'relayauthApiKey': 'relayauth-api-key'}}, 'relayauthEnabled=false'),
            ({'services': {'relayhistoryUrl': 'http://relayhistory:8080'}}, 'leave services.relayhistoryUrl'),
            ({'services': {'sessionReadApiUrl': '', 'sessionReadApiPublicUrl': ''}, 'secretKeys': {'sessionReadApiSecret': ''}}, 'requires the session read API handoff'),
            ({'secretKeys': {'introspectSecret': ''}}, 'requires secretKeys.introspectSecret'),
            ({'introspection': {'audiences': ['https://other.placeholder.company']}}, 'must include services.sessionReadApiPublicUrl'),
        ]
        for overrides, message in cases:
            result = control(overrides)
            self.assertNotEqual(result.returncode, 0, overrides)
            self.assertIn(message, result.stderr)
        self.assertEqual(control({}).returncode, 0, control({}).stderr)

    def test_control_refuses_an_unknown_history_backend(self):
        result = control({'services': {'relayhistoryBackend': 'maybe'}})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('services.relayhistoryBackend must be legacy or native', result.stderr)


if __name__ == '__main__':
    unittest.main()
