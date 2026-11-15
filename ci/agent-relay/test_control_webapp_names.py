#!/usr/bin/env python3
"""Real Helm renders and a causal no-mutation check for public chart names."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

import yaml

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent / 'kind'))
import stack


def identity(d):
    s = d.get('spec', {})
    m = d['metadata']
    p = s.get('template', {}).get('spec', {})
    return {'kind': d['kind'], 'name': m['name'], 'namespace': m.get('namespace'),
            'selector': s.get('selector'),
            'podSelectors': {k: v for k, v in s.get('template', {}).get('metadata', {}).get('labels', {}).items()
                             if k in ('app.kubernetes.io/name', 'app.kubernetes.io/instance')},
            'claims': [v['persistentVolumeClaim']['claimName'] for v in p.get('volumes', []) if 'persistentVolumeClaim' in v],
            'servicePorts': s.get('ports') if d['kind'] == 'Service' else None,
            'routeTargets': [x['backend']['service'] for rule in s.get('rules', []) for x in rule.get('http', {}).get('paths', [])]}


class Names(unittest.TestCase):
    def render(self, extra=(), ok=True):
        # The kind base layer renders only through the native core composition
        # (its single-phase kind-up profile ran the removed standalone History).
        import test_stack as kind_profiles
        profiles = kind_profiles.Profiles()
        p = profiles.helm(profiles.compose('serve'), extra, upgrade=True)
        self.assertEqual(p.returncode == 0, ok, p.stderr)
        return [d for d in yaml.safe_load_all(p.stdout) if d] if ok else p.stderr

    def test_new_components_and_services_route_to_new_names(self):
        docs = self.render()
        deployments = {d['metadata']['name']: d for d in docs if d['kind'] == 'Deployment'}
        self.assertTrue({'relay-control', 'relay-webapp'} <= deployments.keys())
        self.assertFalse({'relaycontrol', 'relay-app'} & deployments.keys())
        services = {d['metadata']['name'] for d in docs if d['kind'] == 'Service'}
        self.assertTrue({'relay-control', 'relay-webapp'} <= services)
        self.assertFalse({'relaycontrol', 'relay-app'} & services)
        for name in ('relay-control', 'relay-webapp'):
            self.assertEqual(deployments[name]['spec']['selector']['matchLabels']['app.kubernetes.io/name'], name)
        targets = [x['backend']['service']['name'] for d in docs if d['kind'] == 'Ingress'
                   for rule in d['spec']['rules'] for x in rule['http']['paths']]
        self.assertIn('relay-control', targets)
        self.assertIn('relay-webapp', targets)
        self.assertNotIn('relaycontrol', targets)

    def test_control_credentials_and_container_specific_resource_refs_refuse(self):
        command = ['helm', 'template', 'test', 'charts/relay-control',
                   '-f', 'charts/relay-control/ci/default-values.yaml']
        bad = [({'name': 'CUSTOM_TOKEN', 'valueFrom': {'configMapKeyRef': {'name': 'config', 'key': 'token'}}},
                'require valueFrom.secretKeyRef'),
               ({'name': 'MEMORY', 'valueFrom': {'resourceFieldRef': {'resource': 'limits.memory', 'containerName': 'api'}}},
                'containerName is not supported')]
        for entry, message in bad:
            result = subprocess.run(command + ['--set-json', 'extraEnv=' + json.dumps([entry])],
                                    cwd=ROOT, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stderr)
        good = [{'name': 'CUSTOM_TOKEN', 'valueFrom': {'secretKeyRef': {'name': 'custom', 'key': 'token'}}},
                {'name': 'MEMORY', 'valueFrom': {'resourceFieldRef': {'resource': 'limits.memory'}}}]
        result = subprocess.run(command + ['--set-json', 'extraEnv=' + json.dumps(good)],
                                cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = subprocess.run(command + ['--set', 'image.repository='], cwd=ROOT, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('image.repository is required', result.stderr)

    def test_alb_backends_allow_retained_service_names(self):
        env = {**os.environ, 'EKS_ALB_DOMAIN': 'relay.agentrelay.com',
               'EKS_ALB_CERT_ARN': 'arn:aws:acm:render-only',
               'EKS_ALB_CONTROL_SERVICE': 'relay-cloud-api', 'EKS_ALB_WEBAPP_SERVICE': 'relay-dashboard'}
        result = subprocess.run(['bash', 'scripts/selfhost/eks-alb-ingress.sh'], cwd=ROOT,
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        doc = yaml.safe_load(result.stdout)
        names = [p['backend']['service']['name'] for rule in doc['spec']['rules'] for p in rule['http']['paths']]
        self.assertIn('relay-cloud-api', names)
        self.assertIn('relay-dashboard', names)
        self.assertNotIn('relay-control', names)
        self.assertNotIn('relay-webapp', names)

    def test_eks_alb_flows_routes_are_opt_in(self):
        base = {**os.environ, 'EKS_ALB_DOMAIN': 'relay.example.com', 'EKS_ALB_CERT_ARN': 'arn:aws:acm:test'}
        render = lambda extra: subprocess.run(['bash', 'scripts/selfhost/eks-alb-ingress.sh', 'ns'], cwd=ROOT,
                                              env={**base, **extra}, capture_output=True, text=True)
        def routes(result, host):
            self.assertEqual(result.returncode, 0, result.stderr)
            rule = next(r for r in yaml.safe_load(result.stdout)['spec']['rules'] if r['host'] == host)
            return [(p['path'], p['pathType'], p['backend']['service']['name'], p['backend']['service'].get('port', {}).get('number'))
                    for p in rule['http']['paths']]
        off = render({})
        self.assertNotIn('relayfile-control', off.stdout)
        self.assertNotIn('/api/v1/flows', off.stdout)
        on = render({'EKS_ALB_RELAYFILE_CONTROL': 'true'})
        apex = routes(on, 'relay.example.com')
        api = routes(on, 'api.relay.example.com')
        cloud = [(f'/cloud/api/v1/{r}', 'Prefix', 'relayfile-control', 3100) for r in ('flows', 'workers', 'workflows')]
        plain = [(f'/api/v1/{r}', 'Prefix', 'relayfile-control', 3100) for r in ('flows', 'workers', 'workflows')]
        self.assertEqual(apex[:3], cloud)
        self.assertEqual(apex[3][0], '/cloud/api')
        self.assertEqual(api[2:8], cloud + plain)
        self.assertEqual(api[-1][0], '/*')
        bad = render({'EKS_ALB_RELAYFILE_CONTROL': 'yes'})
        self.assertEqual(bad.returncode, 2)

    def test_eks_alb_history_routes_are_native_and_exact(self):
        base = {**os.environ, 'EKS_ALB_DOMAIN': 'relay.example.com', 'EKS_ALB_CERT_ARN': 'arn:aws:acm:test'}
        render = lambda extra: subprocess.run(['bash', 'scripts/selfhost/eks-alb-ingress.sh', 'ns'], cwd=ROOT,
                                              env={**base, **extra}, capture_output=True, text=True)
        def history_paths(result):
            self.assertEqual(result.returncode, 0, result.stderr)
            doc = yaml.safe_load(result.stdout)
            rule = next(r for r in doc['spec']['rules'] if r['host'] == 'history.relay.example.com')
            return doc, [(p['path'], p['pathType'], p['backend']['service']['name'], p['backend']['service']['port'])
                         for p in rule['http']['paths']]

        # The history host always routes to native History; EKS_ALB_INGEST=true
        # is the default and renders the same Ingress.
        doc, paths = history_paths(render({}))
        self.assertEqual(render({'EKS_ALB_INGEST': 'true'}).stdout, render({}).stdout)
        self.assertNotIn('relayhistory', [p[2] for p in paths])
        ingest = {'number': 80}
        self.assertEqual(paths, [
            ('/v1/delivery/batches', 'Exact', 'agent-relay-ingest-edge', ingest),
            ('/v1/turns/batches', 'Exact', 'agent-relay-ingest-edge', ingest),
            ('/v1/delivery/limits', 'Exact', 'agent-relay-ingest-edge', ingest),
            ('/v1/auth/token/refresh', 'Exact', 'agent-relay-ingest-edge', ingest),
            ('/v1/delivery/records', 'Exact', 'agent-relay-read-api', {'number': 80}),
            ('/v1/cli/login', 'Exact', 'agent-relay-read-api', {'number': 80}),
            ('/v1/events', 'Exact', 'agent-relay-read-api', {'number': 80}),
            ('/v1/auth/token/revoke', 'Exact', 'agent-relay-read-api', {'number': 80}),
            ('/v1/sessions', 'Prefix', 'agent-relay-read-api', {'number': 80}),
            ('/v1/digest', 'Prefix', 'agent-relay-read-api', {'number': 80}),
            ('/v1/delivery', 'Prefix', 'agent-relay-ingest-edge', ingest),
            ('/v1/turns', 'Prefix', 'agent-relay-ingest-edge', ingest),
            ('/v1/onboarding', 'Prefix', 'agent-relay-ingest-edge', ingest),
            ('/internal', 'Prefix', 'edge-deny', {'name': 'use-annotation'}),
            ('//internal*', 'ImplementationSpecific', 'edge-deny', {'name': 'use-annotation'}),
            ('/*', 'ImplementationSpecific', 'edge-deny', {'name': 'use-annotation'}),
        ])
        self.assertEqual(doc['metadata']['annotations']['alb.ingress.kubernetes.io/healthcheck-path'], '/healthz')

        refused = render({'EKS_ALB_INGEST': 'true', 'EKS_ALB_HISTORY': 'false'})
        self.assertEqual(refused.returncode, 2)

        # The standalone RelayHistory backend is gone: no legacy Service, and no
        # history host without the ingest edge unless it is explicitly read-only.
        for extra in ({'EKS_ALB_INGEST': 'true', 'EKS_ALB_HISTORY_LEGACY_SERVICE': 'relayhistory'},
                      {'EKS_ALB_HISTORY_LEGACY_SERVICE': 'relayhistory'},
                      {'EKS_ALB_INGEST': 'false'}):
            self.assertEqual(render(extra).returncode, 2, extra)
        doc, paths = history_paths(render({'EKS_ALB_HISTORY_READ_ONLY': 'true'}))
        self.assertEqual({p[2] for p in paths}, {'agent-relay-read-api', 'edge-deny'})
        none = render({'EKS_ALB_HISTORY': 'false'})
        self.assertEqual(none.returncode, 0, none.stderr)
        self.assertNotIn('history.relay.example.com', none.stdout)

    def test_eks_proof_discovers_the_legacy_control_domain(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'aws').write_text('#!/bin/sh\nexit 0\n')
            (root / 'kubectl').write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['KUBE_CALLS'], 'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
if os.environ.get('EXPECTED_CONTROL', 'relay-cloud-api') not in sys.argv: sys.exit(1)
print('https://api.compat.agentrelay.com')
''')
            for file in root.iterdir(): file.chmod(0o755)
            source = (ROOT / 'scripts/selfhost/e2e-eks-proof.sh').read_text().split('\nDASHBOARD=', 1)[0]
            env = {**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH'],
                   'PIPPEN_SANDBOX_ACCOUNT_ID': 'render-only', 'EKS_PROOF_DOMAIN': '',
                   'KUBE_CALLS': str(root / 'calls.jsonl')}
            result = subprocess.run(['bash', '-c', source + '\nprintf "%s" "$DOMAIN"\n'],
                                    cwd=ROOT, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'compat.agentrelay.com')
            calls = [json.loads(line) for line in (root / 'calls.jsonl').read_text().splitlines()]
            self.assertEqual(len(calls), 2)
            self.assertIn('relay-control', calls[0])
            self.assertIn('relay-cloud-api', calls[1])
            custom = {**env, 'EKS_PROOF_CONTROL_DEPLOYMENT': 'retained-control',
                      'EKS_ALB_CONTROL_SERVICE': 'retained-api', 'EXPECTED_CONTROL': 'retained-control',
                      'E2E_CONTROL_DEPLOYMENT': '', 'E2E_CONTROL_SERVICE': '',
                      'KUBE_CALLS': str(root / 'custom.jsonl')}
            result = subprocess.run(['bash', '-c', source +
                                     '\nprintf "%s|%s|%s" "$DOMAIN" "$E2E_CONTROL_DEPLOYMENT" "$E2E_CONTROL_SERVICE"\n'],
                                    cwd=ROOT, env=custom, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'compat.agentrelay.com|retained-control|retained-api')

    def test_shared_proof_discovers_retained_control_for_worker_routing(self):
        with tempfile.TemporaryDirectory() as tmp:
            tool = Path(tmp) / 'kubectl'
            tool.write_text('''#!/bin/sh
case "$*" in
  *"get deploy relay-cloud-api "*) printf relay-cloud-api ;;
  *"get svc relay-cloud-api "*) exit 0 ;;
  *) exit 1 ;;
esac
''')
            tool.chmod(0o755)
            source = (ROOT / 'scripts/selfhost/e2e-gcp-proof.sh').read_text()
            body = source.split('find_control_deployment() {', 1)[1].split('\n}\n', 1)[0]
            command = 'KN=("' + str(tool) + '")\nfind_control_deployment() {' + body + '\n}\nfind_control_deployment\n'
            result = subprocess.run(['bash', '-c', command], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'relay-cloud-api')
            body = source.split('control_worker_preflight() {', 1)[1].split('\n}\n', 1)[0]
            command = 'KN=("' + str(tool) + '")\ncontrol_worker_preflight() {' + body + '\n}\ncontrol_worker_preflight\n'
            for name, code in [('relay-cloud-api', 0), ('missing-service', 1), ('', 1), ('Bad Name', 1)]:
                with self.subTest(service=name):
                    result = subprocess.run(['bash', '-c', command],
                                            env={**os.environ, 'CONTROL_SERVICE': name},
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, code)

    def test_old_overrides_are_refused_even_when_empty_or_disabled(self):
        for key, value in [('relay-cloud-api', '{}'), ('relay-dashboard', '{}'),
                           ('components.cloudApi', 'false'), ('components.dashboard', 'false')]:
            with self.subTest(key=key):
                error = self.render(extra=['--set-json', key + '=' + value], ok=False)
                self.assertIn('was renamed', error)

    def test_gcp_live_overlay_retains_the_recorded_control_and_webapp_names(self):
        result = subprocess.run(['helm', 'template', 'agent-relay', 'charts/agent-relay',
                                 '-f', 'charts/agent-relay/values-gcp-proof.yaml',
                                 '-f', 'charts/agent-relay/values-gcp-proof-live.yaml'],
                                cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        docs = [d for d in yaml.safe_load_all(result.stdout) if d]
        for name in ['relay-cloud-api', 'relay-dashboard']:
            deployment = next(d for d in docs if d['kind'] == 'Deployment' and d['metadata']['name'] == name)
            self.assertEqual(deployment['spec']['selector']['matchLabels']['app.kubernetes.io/name'], name)
            self.assertTrue(any(d['kind'] == 'Service' and d['metadata']['name'] == name for d in docs))
        # The native ingest edge calls the retained Control Service name.
        edge = next(d for d in docs if d['kind'] == 'Deployment' and
                    any(e.get('name') == 'RELAYCONTROL_INTROSPECT_URL'
                        for e in d['spec']['template']['spec']['containers'][0].get('env', [])))
        env = {e['name']: e.get('value') for e in edge['spec']['template']['spec']['containers'][0]['env']}
        self.assertEqual(env['RELAYCONTROL_INTROSPECT_URL'], 'http://relay-cloud-api.agent-relay.svc')

    def test_default_kind_upgrade_requires_explicit_worker_cutover(self):
        # The native composition retains the generic worker names on upgrade;
        # dropping them without a drained cutover acknowledgement refuses.
        self.render()
        error = self.render(extra=['--set', 'sessions-pipeline.worker.legacyResourceNames=false'], ok=False)
        self.assertIn('workload rename requires a drained cutover', error)

    def test_real_profile_images_are_not_relabelled_as_unpublished_repositories(self):
        # The native composition selects a qualified Control image; render the
        # kind base layer's published Control pin in its place.
        base = yaml.safe_load((ROOT / 'charts/agent-relay/values-kind-core.yaml').read_text())
        docs = self.render(extra=['--set-json', 'relay-control.image=' + json.dumps(base['relay-control']['image'])])
        images = {c['image'] for d in docs for c in stack.pod_spec(d).get('containers', [])}
        self.assertTrue(any(i.startswith('ghcr.io/agentworkforce/relay-control@sha256:') for i in images))
        self.assertTrue(any(i.startswith('ghcr.io/agentworkforce/relay-dashboard@sha256:') for i in images))
        self.assertFalse(any(i.startswith(('ghcr.io/agentworkforce/selfhost-api@', 'ghcr.io/agentworkforce/relay-webapp@')) for i in images))

    def test_old_cluster_is_refused_before_ready_or_images_are_changed(self):
        # The legacy single-phase kind-up (and its old Control/Webapp layout
        # preflight) was retired with the standalone RelayHistory server. It
        # refuses every cluster before any ready, image or cluster access.
        with tempfile.TemporaryDirectory() as tmp, patch.object(stack, 'ROOT', Path(tmp)):
            local = stack.Stack('core')
            ready = local.state / 'ready.json'
            ready.write_text('saved-independent-receipt')
            local.docker = Mock()
            local.require_owned_cluster = Mock()
            local.dependencies = Mock(side_effect=AssertionError('must refuse before dependencies'))
            local.cmd = Mock(return_value=subprocess.CompletedProcess([], 0, 'agent-relay-core\n', ''))
            local.k = Mock(return_value=subprocess.CompletedProcess([], 0, json.dumps({'items': [
                {'kind': 'Deployment', 'metadata': {'name': 'relaycontrol'}}]}), ''))
            with self.assertRaisesRegex(stack.StackError, 'retired.*make local-up'):
                local.up()
            for call in (local.docker, local.require_owned_cluster, local.dependencies, local.cmd, local.k):
                call.assert_not_called()
            self.assertEqual(ready.read_text(), 'saved-independent-receipt')


if __name__ == '__main__':
    unittest.main()
