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
    def test_eks_rds_native_profile_is_reader_first_and_customer_neutral(self):
        result = subprocess.run([
            'helm', 'template', 'proof', 'charts/agent-relay', '-n', 'agent-relay-placeholder', '--no-hooks',
            '-f', 'charts/agent-relay/values-eks.yaml',
            '-f', 'charts/agent-relay/values-eks-rds-native.yaml',
        ], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        docs = [doc for doc in yaml.safe_load_all(result.stdout) if doc]
        deployments = {doc['metadata']['name']: doc for doc in docs if doc.get('kind') == 'Deployment'}
        jobs = {doc['metadata']['name']: doc for doc in docs if doc.get('kind') == 'Job'}
        self.assertNotIn('relayauth', deployments)
        self.assertNotIn('relayhistory', deployments)
        for name in ('proof-read-api', 'proof-ingest-edge', 'proof-search-indexer'):
            self.assertIn(name, deployments)

        services_image = ('ghcr.io/agentworkforce/sessions-pipeline@sha256:'
                          '77022c5b6a1d30f96f921d703eb27a1acada8ec273ad84aebdde24f8eddce305')
        services_pods = []
        for workload in [*deployments.values(), *jobs.values()]:
            pod = workload['spec']['template']['spec']
            for container in pod.get('containers', []):
                if container['image'] == services_image:
                    services_pods.append((workload['metadata']['name'], pod, container))
        self.assertEqual(len(services_pods), 8)
        for name, _, container in services_pods:
            env = {item['name']: item.get('value') for item in container.get('env', [])}
            self.assertEqual(env.get('READER_MAX_RULESET'), '10', name)
            self.assertNotIn('SCRUB_ENGINE', env, name)
            self.assertNotIn('SCRUB_ENGINE_REQUIRED', env, name)

        expected_accounts = {
            'proof-read-api': 'agent-relay-session-read',
            'proof-ingest-edge': 'agent-relay-session-ingest-api',
            'proof-search-indexer': 'agent-relay-search-indexer',
            'proof-worker-session-summary-worker': 'agent-relay-worker',
        }
        for name, account in expected_accounts.items():
            self.assertEqual(deployments[name]['spec']['template']['spec']['serviceAccountName'], account)
        service_accounts = {doc['metadata']['name'] for doc in docs if doc.get('kind') == 'ServiceAccount'}
        self.assertTrue(set(expected_accounts.values()).issubset(service_accounts))

        reader = deployments['proof-read-api']['spec']['template']['spec']['containers'][0]
        reader_env = {item['name']: item.get('value') for item in reader['env']}
        self.assertEqual(reader_env['READ_API_SESSION_QUERY'], 'true')
        self.assertEqual(reader_env['READ_API_TIMING_ASSUME_NO_TURNS'], 'true')
        self.assertEqual(reader_env['READ_API_CANONICAL_PIN_LAGGING_POINTER'], 'true')
        self.assertEqual(reader_env['READ_API_OUTPUT_ENABLED'], '1')
        self.assertEqual(reader_env['READ_API_OUTPUT_BACKEND'], 'postgres')
        self.assertEqual(reader_env['READ_API_DIGEST_ENABLED'], '1')
        self.assertEqual(reader_env['READ_API_DIGEST_BACKEND'], 'postgres')
        self.assertEqual(reader_env['READ_API_COORDINATION_OVERLAPS_ENABLED'], 'true')
        self.assertEqual(reader_env['READ_API_COORDINATION_OVERLAPS_BACKEND'], 'postgres')
        self.assertFalse(any('NARRATIVE' in name for name in reader_env))

        indexer = deployments['proof-search-indexer']['spec']['template']['spec']['containers'][0]
        indexer_env = {item['name']: item.get('value') for item in indexer['env']}
        self.assertEqual(indexer_env['RELAYHISTORY_SELFHOST_OUTPUT_FACTS'], 'true')
        self.assertFalse(any('output-facts' in name for name in jobs))

        control = deployments['relay-control']['spec']['template']['spec']['containers'][0]
        control_env = {item['name']: item.get('value') for item in control['env']}
        self.assertEqual(control_env['RELAYHISTORY_BACKEND'], 'native')
        self.assertEqual(control_env['SELFHOST_SIGNIN_METHODS'], 'password')
        self.assertEqual(control_env['SELFHOST_TRUSTED_PROXIES'], '1')
        self.assertEqual(control_env['SELFHOST_SETUP_KEY_FILE'], '/var/run/agent-relay/secrets/selfhost-setup-key')
        self.assertEqual(control_env['SELFHOST_FEATURES'], 'usage,launch')
        control_migrate = next(job for name, job in jobs.items() if name.startswith('relay-control-migrate-'))
        migrate_env = {item['name'] for item in control_migrate['spec']['template']['spec']['containers'][0]['env']}
        self.assertNotIn('SELFHOST_SETUP_KEY_FILE', migrate_env)

        webapp = deployments['relay-webapp']['spec']['template']['spec']['containers'][0]
        webapp_env = {item['name']: item.get('value') for item in webapp['env']}
        self.assertEqual(webapp_env['DASHBOARD_SESSION_READ_API_ENABLED'], 'true')
        self.assertNotIn('DASHBOARD_COORDINATION_OVERLAPS_ENABLED', webapp_env)
        self.assertFalse(any(doc.get('kind') == 'Secret' for doc in docs))
        pvc = next(doc for doc in docs if doc.get('kind') == 'PersistentVolumeClaim'
                   and doc['metadata']['name'] == 'relaycast-data')
        self.assertNotIn('storageClassName', pvc['spec'])

    def test_eks_rds_native_private_overlay_replaces_every_shared_input(self):
        paths = [
            'charts/agent-relay/values-eks.yaml',
            'charts/agent-relay/values-eks-rds-native.yaml',
            'ci/agent-relay/eks-rds-native-site-values.yaml',
        ]
        values = {}
        for path in paths:
            merge(values, yaml.safe_load((ROOT / path).read_text()))
        sessions = values['sessions-pipeline']
        ca_hash = '1' * 64
        self.assertEqual({
            sessions['worker']['postgresCa']['sha256'],
            sessions['alleyoop']['postgresCa']['sha256'],
            sessions['sessionReadApi']['postgresCa']['sha256'],
            sessions['ingestEdge']['postgres']['caSha256'],
            sessions['searchIndexer']['postgres']['caSha256'],
        }, {ca_hash})
        reader_extra = {item['name']: item['value'] for item in sessions['sessionReadApi']['extraEnv']}
        self.assertEqual({
            sessions['worker']['locker']['bucket'],
            sessions['alleyoop']['locker']['bucket'],
            reader_extra['LOCKER_BUCKET'],
            sessions['ingestEdge']['locker']['bucket'],
            sessions['searchIndexer']['locker']['bucket'],
        }, {'ci-agent-relay-sessions'})
        self.assertEqual({
            sessions['worker']['locker']['region'],
            sessions['alleyoop']['locker']['region'],
            reader_extra['LOCKER_REGION'],
            sessions['ingestEdge']['locker']['region'],
            sessions['searchIndexer']['locker']['region'],
        }, {'us-east-1'})
        reader_search = sessions['sessionReadApi']['search']
        indexer_search = sessions['searchIndexer']['search']
        self.assertEqual(reader_search['backendId'], indexer_search['backendId'])
        self.assertEqual(reader_search['opensearch'], indexer_search['opensearch'])
        self.assertEqual(sessions['sessionReadApi']['origin'], sessions['ingestEdge']['origin'])

        result = subprocess.run([
            'helm', 'template', 'proof', 'charts/agent-relay', '-n', 'agent-relay-ci', '--no-hooks',
            *sum((['-f', path] for path in paths), []),
        ], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for placeholder in ('0' * 64, 'example-agent-relay-sessions',
                            'example-agent-relay-secrets', '.placeholder.company'):
            self.assertNotIn(placeholder, result.stdout)
        deployments = {doc['metadata']['name']: doc for doc in yaml.safe_load_all(result.stdout)
                       if doc and doc.get('kind') == 'Deployment'}
        envs = {}
        for name, deployment in deployments.items():
            container = deployment['spec']['template']['spec']['containers'][0]
            envs[name] = {item['name']: item.get('value') for item in container.get('env', [])}
        for name, env in envs.items():
            if 'LOCKER_BUCKET' in env:
                self.assertEqual(env['LOCKER_BUCKET'], 'ci-agent-relay-sessions', name)
                self.assertEqual(env['LOCKER_REGION'], 'us-east-1', name)
            if 'SESSION_POSTGRES_CA_SHA256' in env:
                self.assertEqual(env['SESSION_POSTGRES_CA_SHA256'], ca_hash, name)
        for name in ('proof-read-api', 'proof-search-indexer'):
            self.assertEqual(envs[name]['SEARCH_INDEX_POSTGRES_BACKEND_ID'], 'ci-opensearch')
            self.assertEqual(envs[name]['SEARCH_INDEX_OPENSEARCH_URL'], 'https://search.ci.company')
            self.assertEqual(envs[name]['SEARCH_INDEX_OPENSEARCH_AWS_REGION'], 'us-east-1')

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
            'ghcr.io/agentworkforce/relay-webapp@sha256:da0cc80476eac734299c0c6ceb94e2bca7dae7913cce56a8ca8592cf086dd02e')
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
        webapp_deploy = next(doc for doc in docs if doc.get('kind') == 'Deployment' and doc['metadata']['name'] == 'relay-webapp')
        self.assertEqual(
            control_deploy['spec']['template']['spec']['containers'][0]['image'],
            'ghcr.io/agentworkforce/relay-control@sha256:0b9c5a077b49b31178cc669e7c1d532f39e64c840087ca41636bb84a6c62631c')
        self.assertEqual(
            webapp_deploy['spec']['template']['spec']['containers'][0]['image'],
            'ghcr.io/agentworkforce/relay-webapp@sha256:da0cc80476eac734299c0c6ceb94e2bca7dae7913cce56a8ca8592cf086dd02e')
        env = {e['name']: e.get('value') for e in control_deploy['spec']['template']['spec']['containers'][0]['env']}
        self.assertEqual(env['SELFHOST_FEATURES'], 'usage,launch')
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
