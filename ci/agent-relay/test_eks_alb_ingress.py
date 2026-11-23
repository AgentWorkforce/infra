#!/usr/bin/env python3
"""The chart's eksIngress renders the Ingress scripts/selfhost/eks-alb-ingress.sh prints.

Every case runs the real script and a real `helm template` with the same
options and compares the parsed objects: annotations and spec deep-equal
(rule and path order included), name and namespace equal. Helm's own labels
are the only allowed difference. Refusals fail in both. Needs the chart's
dependencies built (ci/agent-relay/render.sh does it first in CI).
"""
import json
import os
from pathlib import Path
import subprocess
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
CHART = 'charts/agent-relay'
NAMESPACE = 'relay-eks'
BASE_ENV = {'EKS_ALB_DOMAIN': 'relay.example.com',
            'EKS_ALB_CERT_ARN': 'arn:aws:acm:us-east-1:111111111111:certificate/00000000-0000-0000-0000-000000000000'}

DEFAULT_CONTROL_PATHS = [
    '/cloud/api',
    '/login',
    '/relay-node',
    '/mcp',
    '/cloud/mcp',
    '/.well-known/oauth-protected-resource',
    '/.well-known/oauth-authorization-server',
    '/.well-known/openid-configuration',
    '/cloud/.well-known',
    '/cloud/oauth',
]

# Script variable -> eksIngress option path.
OPTIONS = {
    'EKS_ALB_INGRESS_NAME': 'name',
    'EKS_INGRESS_CLASS': 'className',
    'EKS_ALB_DOMAIN': 'domain',
    'EKS_ALB_CERT_ARN': 'certificateArn',
    'EKS_ALB_HISTORY': 'history.enabled',
    'EKS_ALB_HISTORY_READ_ONLY': 'history.readOnly',
    'EKS_ALB_INGEST': 'ingest.enabled',
    'EKS_ALB_INGEST_SERVICE': 'ingest.serviceName',
    'EKS_ALB_INGEST_PORT': 'ingest.servicePort',
    'EKS_ALB_READ_API_SERVICE': 'readApi.serviceName',
    'EKS_ALB_READ_API_PORT': 'readApi.servicePort',
    'EKS_ALB_RELAYFILE_CONTROL': 'flows.enabled',
    'EKS_ALB_RELAYFILE_CONTROL_SERVICE': 'flows.serviceName',
    'EKS_ALB_RELAYFILE_CONTROL_PORT': 'flows.servicePort',
    'EKS_ALB_CHIEF_SERVICE': 'chief.serviceName',
    'EKS_ALB_CHIEF_PORT': 'chief.servicePort',
    'EKS_ALB_CONTROL_SERVICE': 'control.serviceName',
    'EKS_ALB_WEBAPP_SERVICE': 'webapp.serviceName',
    'EKS_ALB_ALIAS_DOMAINS': 'aliasDomains',
    'EKS_ALB_EXTRA_CERT_ARNS': 'additionalCertificateArns',
}
# Comma-separated in the script, a list in the chart.
LIST_OPTIONS = {'aliasDomains', 'additionalCertificateArns'}
EXTRA_CERT = 'arn:aws:acm:us-east-1:111111111111:certificate/11111111-1111-1111-1111-111111111111'

CASES = {
    'defaults': {},
    'history off': {'EKS_ALB_HISTORY': 'false'},
    'history read-only': {'EKS_ALB_HISTORY_READ_ONLY': 'true'},
    'read-only, ingest explicitly off, own read API': {
        'EKS_ALB_HISTORY_READ_ONLY': 'true', 'EKS_ALB_INGEST': 'false',
        'EKS_ALB_READ_API_SERVICE': 'other-read-api', 'EKS_ALB_READ_API_PORT': '8080'},
    'ingest off (history off)': {'EKS_ALB_HISTORY': 'false', 'EKS_ALB_INGEST': 'false'},
    'ingest explicitly on': {'EKS_ALB_INGEST': 'true'},
    'flows on': {'EKS_ALB_RELAYFILE_CONTROL': 'true'},
    'chief on': {'EKS_ALB_CHIEF_SERVICE': 'relaychief-control'},
    'flows + chief + read-only': {'EKS_ALB_RELAYFILE_CONTROL': 'true',
                                  'EKS_ALB_CHIEF_SERVICE': 'relaychief-control',
                                  'EKS_ALB_HISTORY_READ_ONLY': 'true'},
    'alias domain, one certificate': {'EKS_ALB_ALIAS_DOMAINS': 'public.example.com'},
    'two alias domains, extra certificate, chief + flows + read-only': {
        'EKS_ALB_ALIAS_DOMAINS': 'public.example.com,public-staging.example.com',
        'EKS_ALB_EXTRA_CERT_ARNS': EXTRA_CERT,
        'EKS_ALB_RELAYFILE_CONTROL': 'true', 'EKS_ALB_CHIEF_SERVICE': 'relaychief-control',
        'EKS_ALB_HISTORY_READ_ONLY': 'true'},
    'alias domain with history off': {'EKS_ALB_ALIAS_DOMAINS': 'public.example.com', 'EKS_ALB_HISTORY': 'false'},
    'overridden names, ports, ingress name and class': {
        'EKS_ALB_INGRESS_NAME': 'relay-edge', 'EKS_INGRESS_CLASS': 'alb-internal',
        'EKS_ALB_DOMAIN': 'edge.example.com',
        'EKS_ALB_INGEST_SERVICE': 'ingest', 'EKS_ALB_INGEST_PORT': '8081',
        'EKS_ALB_READ_API_SERVICE': 'reader', 'EKS_ALB_READ_API_PORT': '8082',
        'EKS_ALB_RELAYFILE_CONTROL': 'true', 'EKS_ALB_RELAYFILE_CONTROL_SERVICE': 'flows-api',
        'EKS_ALB_RELAYFILE_CONTROL_PORT': '9100',
        'EKS_ALB_CHIEF_SERVICE': 'chief-api', 'EKS_ALB_CHIEF_PORT': '9200',
        'EKS_ALB_CONTROL_SERVICE': 'relay-cloud-api', 'EKS_ALB_WEBAPP_SERVICE': 'relay-dashboard'},
}

# (script env, chart-only extra values, message fragment in the chart error).
REFUSALS = {
    'domain missing': ({'EKS_ALB_DOMAIN': ''}, {}, 'eksIngress.domain'),
    'certificate missing': ({'EKS_ALB_CERT_ARN': ''}, {}, 'eksIngress.certificateArn'),
    'read-only with ingest on': ({'EKS_ALB_HISTORY_READ_ONLY': 'true', 'EKS_ALB_INGEST': 'true'}, {}, 'history.readOnly=true needs'),
    'read-only with history off': ({'EKS_ALB_HISTORY_READ_ONLY': 'true', 'EKS_ALB_HISTORY': 'false'}, {}, 'history.readOnly=true needs'),
    'ingest off without read-only': ({'EKS_ALB_INGEST': 'false'}, {}, 'needs eksIngress.history.readOnly=true'),
    'ingest on with history off': ({'EKS_ALB_HISTORY': 'false', 'EKS_ALB_INGEST': 'true'}, {}, 'needs the history host'),
    'control Service not a label': ({'EKS_ALB_CONTROL_SERVICE': 'Relay_Control'}, {}, 'must be DNS labels'),
    'webapp Service not a label': ({'EKS_ALB_WEBAPP_SERVICE': 'a' * 64}, {}, 'must be DNS labels'),
    'ingest Service not a label': ({'EKS_ALB_INGEST_SERVICE': 'ingest.edge'}, {}, 'must be DNS labels'),
    'ingest port 0': ({'EKS_ALB_INGEST_PORT': '0'}, {}, 'must be 1-65535'),
    'read API port 65536': ({'EKS_ALB_READ_API_PORT': '65536'}, {}, 'must be 1-65535'),
    'read-only read API Service not a label': ({'EKS_ALB_HISTORY_READ_ONLY': 'true', 'EKS_ALB_READ_API_SERVICE': '-reader'}, {}, 'readApi.serviceName must be a DNS label'),
    'flows Service not a label': ({'EKS_ALB_RELAYFILE_CONTROL': 'true', 'EKS_ALB_RELAYFILE_CONTROL_SERVICE': 'Flows'}, {}, 'flows.serviceName must be a DNS label'),
    'flows port 70000': ({'EKS_ALB_RELAYFILE_CONTROL': 'true', 'EKS_ALB_RELAYFILE_CONTROL_PORT': '70000'}, {}, 'flows.servicePort must be 1-65535'),
    'chief Service not a label': ({'EKS_ALB_CHIEF_SERVICE': 'chief_control'}, {}, 'chief.serviceName must be a DNS label'),
    'alias repeats the domain': ({'EKS_ALB_ALIAS_DOMAINS': 'relay.example.com'}, {}, 'must not repeat a domain'),
    'alias repeated': ({'EKS_ALB_ALIAS_DOMAINS': 'a.example.com,a.example.com'}, {}, 'must not repeat a domain'),
    'alias not a DNS name': ({'EKS_ALB_ALIAS_DOMAINS': 'https://a.example.com'}, {}, 'aliasDomains entry'),
    'extra certificate not an ARN': ({'EKS_ALB_EXTRA_CERT_ARNS': 'cert-1'}, {}, 'additionalCertificateArns entry'),
    'extra certificate repeats the certificate': ({'EKS_ALB_EXTRA_CERT_ARNS': BASE_ENV['EKS_ALB_CERT_ARN']}, {}, 'must not repeat a certificate'),
    'chief port 0': ({'EKS_ALB_CHIEF_SERVICE': 'relaychief-control', 'EKS_ALB_CHIEF_PORT': '0'}, {}, 'chief.servicePort must be 1-65535'),
}


def script(env, namespace=NAMESPACE):
    full = {k: v for k, v in os.environ.items() if not k.startswith(('EKS_ALB_', 'EKS_INGRESS_'))}
    full.update(BASE_ENV)
    full.update(env)
    return subprocess.run(['bash', 'scripts/selfhost/eks-alb-ingress.sh', namespace], cwd=ROOT,
                          env=full, capture_output=True, text=True)


def chart_values(env):
    values = {'enabled': True}
    for key, value in {**BASE_ENV, **env}.items():
        node = values
        *parents, leaf = OPTIONS[key].split('.')
        for part in parents:
            node = node.setdefault(part, {})
        if leaf in LIST_OPTIONS:
            value = [v for v in value.split(',') if v]
        elif value in ('true', 'false'):
            value = value == 'true'
        elif leaf == 'servicePort' and value.isdigit():
            value = int(value)
        node[leaf] = value
    return values


def helm(values, namespace=NAMESPACE, extra=()):
    command = ['helm', 'template', 'proof', CHART, '-n', namespace, '--no-hooks',
               '-f', f'{CHART}/values-eks.yaml', '-f', f'{CHART}/values-eks-rds-native.yaml',
               '--set-json', 'eksIngress=' + json.dumps(values),
               '--show-only', 'templates/eks-alb-ingress.yaml', *extra]
    return subprocess.run(command, cwd=ROOT, capture_output=True, text=True)


def ingress(stdout):
    docs = [d for d in yaml.safe_load_all(stdout) if d]
    assert len(docs) == 1 and docs[0]['kind'] == 'Ingress', docs
    return docs[0]


def comparable(doc):
    meta = doc['metadata']
    return {'apiVersion': doc['apiVersion'], 'kind': doc['kind'], 'name': meta['name'],
            'namespace': meta['namespace'], 'annotations': meta.get('annotations', {}), 'spec': doc['spec']}


def paths(doc, host):
    rule = next(r for r in doc['spec']['rules'] if r['host'] == host)
    return [(p['path'], p['pathType']) for p in rule['http']['paths']]


class EksAlbIngress(unittest.TestCase):
    def assert_same(self, env, chart_extra=None):
        want = script(env)
        self.assertEqual(want.returncode, 0, want.stderr)
        values = chart_values(env)
        values.update(chart_extra or {})
        got = helm(values)
        self.assertEqual(got.returncode, 0, got.stderr)
        g, w = ingress(got.stdout), ingress(want.stdout)
        self.assertEqual(comparable(g), comparable(w))
        return g, w

    def test_matrix_equals_script(self):
        for name, env in CASES.items():
            with self.subTest(case=name):
                self.assert_same(env)

    def test_off_by_default(self):
        result = subprocess.run(['helm', 'template', 'proof', CHART, '-n', NAMESPACE, '--no-hooks',
                                 '-f', f'{CHART}/values-eks.yaml', '-f', f'{CHART}/values-eks-rds-native.yaml'],
                                cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        docs = [d for d in yaml.safe_load_all(result.stdout) if d]
        self.assertFalse([d for d in docs if d['kind'] == 'Ingress' and d['spec'].get('ingressClassName') == 'alb'])
        self.assertNotIn('templates/eks-alb-ingress.yaml', result.stdout)

    def test_enabled_must_be_a_boolean(self):
        # A string is truthy in a template: "false" would otherwise render the edge.
        for value in ('false', 'true', 'no'):
            with self.subTest(enabled=value):
                result = helm(chart_values({}), extra=['--set-string', f'eksIngress.enabled={value}'])
                self.assertNotEqual(result.returncode, 0, f'chart accepted enabled={value!r}')
                self.assertIn('eksIngress.enabled must be true or false', result.stderr)
                self.assertNotIn('kind: Ingress', result.stdout)

    def test_chart_only_labels_differ(self):
        got = ingress(helm(chart_values({})).stdout)
        self.assertEqual(got['metadata']['labels'],
                         {'app.kubernetes.io/name': 'agent-relay', 'app.kubernetes.io/instance': 'proof'})

    def test_namespace_is_the_release_namespace(self):
        want = ingress(script({}, namespace='other-ns').stdout)
        got = ingress(helm(chart_values({}), namespace='other-ns').stdout)
        self.assertEqual(got['metadata']['namespace'], 'other-ns')
        self.assertEqual(comparable(got), comparable(want))

    def test_backends_need_no_component_of_this_release(self):
        # Flows, Chief and a foreign read API on a release that installs none of
        # them (and with the sessions pipeline's own Services absent).
        env = CASES['flows + chief + read-only']
        values = chart_values(env)
        result = helm(values, extra=['--set', 'components.sessionsPipeline=false'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(comparable(ingress(result.stdout)), comparable(ingress(script(env).stdout)))

    def test_control_paths_default_is_the_script_list(self):
        for env in ({}, {'EKS_ALB_CHIEF_SERVICE': 'relaychief-control'}):
            with self.subTest(env=env):
                self.assert_same(env, {'controlPaths': DEFAULT_CONTROL_PATHS})

    def test_control_paths_missing_or_null_use_defaults(self):
        for env in ({}, {'EKS_ALB_CHIEF_SERVICE': 'relaychief-control'}):
            with self.subTest(env=env):
                self.assert_same(env)
                # Helm removes the null key during coalescing, just as older
                # saved defaults lack it when upgrading with --reuse-values.
                self.assert_same(env, {'controlPaths': None})
                result = helm(chart_values(env), extra=['--set', 'eksIngress.controlPaths=null'])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(comparable(ingress(result.stdout)), comparable(ingress(script(env).stdout)))

    def test_control_paths_can_be_empty(self):
        for env in ({}, {'EKS_ALB_CHIEF_SERVICE': 'relaychief-control'}):
            with self.subTest(env=env):
                want = ingress(script(env).stdout)
                result = helm({**chart_values(env), 'controlPaths': []})
                self.assertEqual(result.returncode, 0, result.stderr)
                removed = {path for p in DEFAULT_CONTROL_PATHS for path in (p, p + '/*')}
                for rule in want['spec']['rules']:
                    if rule['host'] == 'relay.example.com':
                        rule['http']['paths'] = [p for p in rule['http']['paths'] if p['path'] not in removed]
                self.assertEqual(comparable(ingress(result.stdout)), comparable(want))

    def test_control_paths_drop_only_the_relay_node_rules(self):
        for env in ({}, {'EKS_ALB_CHIEF_SERVICE': 'relaychief-control'}, {'EKS_ALB_RELAYFILE_CONTROL': 'true'}):
            with self.subTest(env=env):
                want = ingress(script(env).stdout)
                result = helm({**chart_values(env), 'controlPaths': [p for p in DEFAULT_CONTROL_PATHS if p != '/relay-node']})
                self.assertEqual(result.returncode, 0, result.stderr)
                got = ingress(result.stdout)
                for rule in want['spec']['rules']:
                    if rule['host'] == 'relay.example.com':
                        rule['http']['paths'] = [p for p in rule['http']['paths']
                                                 if not p['path'].startswith('/relay-node')]
                self.assertEqual(comparable(got), comparable(want))
                self.assertFalse([p for p in paths(got, 'relay.example.com') if 'relay-node' in p[0]])

    def test_control_paths_can_pin_legacy_lists(self):
        for pinned in (DEFAULT_CONTROL_PATHS[:3], DEFAULT_CONTROL_PATHS[:2]):
            for env in ({}, {'EKS_ALB_CHIEF_SERVICE': 'relaychief-control'}, {'EKS_ALB_RELAYFILE_CONTROL': 'true'}):
                with self.subTest(pinned=pinned, env=env):
                    want = ingress(script(env).stdout)
                    result = helm({**chart_values(env), 'controlPaths': pinned})
                    self.assertEqual(result.returncode, 0, result.stderr)
                    removed = {path for p in DEFAULT_CONTROL_PATHS if p not in pinned for path in (p, p + '/*')}
                    for rule in want['spec']['rules']:
                        if rule['host'] == 'relay.example.com':
                            rule['http']['paths'] = [p for p in rule['http']['paths'] if p['path'] not in removed]
                    self.assertEqual(comparable(ingress(result.stdout)), comparable(want))

    def test_control_paths_extend_in_order(self):
        result = helm({**chart_values({}), 'controlPaths': ['/cloud/api', '/login', '/relay-node', '/mcp', '/.well-known/openid-configuration']})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(paths(ingress(result.stdout), 'relay.example.com'),
                         [('/cloud/api', 'Prefix'), ('/login', 'Prefix'), ('/relay-node', 'Prefix'), ('/mcp', 'Prefix'),
                          ('/.well-known/openid-configuration', 'Prefix'), ('/', 'Prefix')])

    def test_refusals_match_the_script(self):
        for name, (env, extra, message) in REFUSALS.items():
            with self.subTest(case=name):
                self.assertNotEqual(script(env).returncode, 0, f'script accepted {name}')
                values = {**chart_values(env), **extra}
                result = helm(values)
                self.assertNotEqual(result.returncode, 0, f'chart accepted {name}')
                self.assertIn(message, result.stderr)

    def test_chart_only_refusals(self):
        bad = {
            'both edges': ({}, ['--set', 'gkeIngress.enabled=true'], 'exclusive'),
            'string boolean': ({'history': {'enabled': 'yes'}}, [], 'history.enabled must be true or false'),
            'string ingest': ({'ingest': {'enabled': 'true'}}, [], 'ingest.enabled must be true, false or null'),
            'control path /': ({'controlPaths': ['/']}, [], 'controlPaths entry'),
            'control path wildcard': ({'controlPaths': ['/cloud/*']}, [], 'controlPaths entry'),
            'control path trailing slash': ({'controlPaths': ['/login/']}, [], 'controlPaths entry'),
            'control path relative': ({'controlPaths': ['login']}, [], 'controlPaths entry'),
            'control path repeated': ({'controlPaths': ['/login', '/login']}, [], 'must not repeat'),
            'control paths not a list': ({'controlPaths': '/login'}, [], 'must be a list'),
            'domain with scheme': ({'domain': 'https://relay.example.com'}, [], 'lowercase DNS name'),
            'domain with an empty label': ({'domain': 'relay..example.com'}, [], 'lowercase DNS name'),
            'domain label starting with a hyphen': ({'domain': 'relay.-example.com'}, [], 'lowercase DNS name'),
            'domain label ending with a hyphen': ({'domain': 'relay-.example.com'}, [], 'lowercase DNS name'),
            'domain label over 63': ({'domain': 'a' * 64 + '.example.com'}, [], 'lowercase DNS name'),
            'domain over 245': ({'domain': '.'.join(['a' * 60] * 4) + '.com'}, [], 'lowercase DNS name'),
            'name with an empty label': ({'name': 'agent..relay'}, [], 'eksIngress.name must be a DNS subdomain name'),
            'class label starting with a hyphen': ({'className': 'alb.-x'}, [], 'eksIngress.className must be an IngressClass name'),
        }
        for name, (values, extra, message) in bad.items():
            with self.subTest(case=name):
                result = helm({**chart_values({}), **values}, extra=extra)
                self.assertNotEqual(result.returncode, 0, f'chart accepted {name}')
                self.assertIn(message, result.stderr)


if __name__ == '__main__':
    unittest.main()
