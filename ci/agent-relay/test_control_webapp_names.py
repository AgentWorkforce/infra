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
    def render(self, profile='core', extra=(), ok=True):
        cmd = ['helm', 'template', 'agent-relay', 'charts/agent-relay', '-n', 'agent-relay',
               '-f', 'charts/agent-relay/values-kind-core.yaml']
        if profile == 'addons':
            cmd += ['-f', 'charts/agent-relay/values-kind-addons.yaml']
        p = subprocess.run([*cmd, *extra], cwd=ROOT, text=True, capture_output=True, timeout=30)
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

    def test_historical_eks_installer_uses_its_selected_chart_values(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tools = root / 'bin'; tools.mkdir()
            (tools / 'aws').write_text('#!/bin/sh\nexit 0\n')
            (tools / 'helm').write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args=sys.argv[1:]
call={'args':args}
if args[0]=='pull':
    target=Path(args[args.index('--untardir')+1])/'agent-relay'
    target.mkdir()
    (target/'values-eks.yaml').write_text('relay-cloud-api: {}\\nrelay-dashboard: {}\\n')
elif args[0]=='upgrade':
    call['base_values']=Path(args[args.index('-f')+1]).read_text()
with open(os.environ['HELM_CALLS'], 'a') as f: f.write(json.dumps(call)+'\\n')
''')
            for file in tools.iterdir(): file.chmod(0o755)
            (root / 'tmp').mkdir()
            source = (ROOT / 'scripts/selfhost/eks-proof-install.sh').read_text()
            definitions = source.rsplit('\ncase "${1:-}" in', 1)[0]
            env = {**os.environ, 'PATH': str(tools) + os.pathsep + os.environ['PATH'],
                   'PIPPEN_SANDBOX_ACCOUNT_ID': 'render-only', 'EKS_PROOF_CHART_VERSION': '0.3.11',
                   'TMPDIR': str(root / 'tmp'),
                   'EKS_PROOF_STATE_DIR': str(root / 'state'), 'HELM_CALLS': str(root / 'helm.jsonl')}
            result = subprocess.run(['bash', '-c', definitions + '\nproof_overlay\nhelm_apply\nprintf "%s" "$WORK_TMP"\n'],
                                    cwd=ROOT, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [json.loads(line) for line in (root / 'helm.jsonl').read_text().splitlines()]
            self.assertEqual([call['args'][0] for call in calls], ['pull', 'upgrade'])
            for call in calls:
                args = call['args']
                self.assertEqual(args[args.index('--version') + 1], '0.3.11')
            args = calls[1]['args']
            base = Path(args[args.index('-f') + 1])
            self.assertTrue(base.is_relative_to(Path(result.stdout.strip())))
            self.assertFalse(base.exists())
            self.assertIn('relay-cloud-api', yaml.safe_load(calls[1]['base_values']))
            overlay = yaml.safe_load((root / 'state/values-eks-proof.yaml').read_text())
            self.assertTrue({'relay-cloud-api', 'relay-dashboard'} <= overlay.keys())
            self.assertFalse({'relay-control', 'relay-webapp'} & overlay.keys())
            future = {**env, 'EKS_PROOF_CHART_VERSION': '0.5.0'}
            loaded = subprocess.run(['bash', '-c', definitions + '\ntrue\n'], cwd=ROOT,
                                    env=future, capture_output=True, text=True)
            self.assertEqual(loaded.returncode, 0, loaded.stderr)
            refused = subprocess.run(['bash', '-c', definitions + '\nhelm_apply\n'], cwd=ROOT,
                                     env=future, capture_output=True, text=True)
            self.assertEqual(refused.returncode, 2)

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
        client = next(d for d in docs if d['kind'] == 'ConfigMap' and
                      'AGENT_RELAY_CLOUD_API_URL' in d.get('data', {}))
        self.assertEqual(client['data']['AGENT_RELAY_CLOUD_API_URL'], 'http://relay-cloud-api')

    def test_kind_compatibility_keeps_all_old_selectors_services_claims_and_jobs(self):
        fixture = json.loads((ROOT / 'ci/agent-relay/fixtures/control-webapp-legacy-identities.json').read_text())
        for profile in ('core', 'addons'):
            with self.subTest(profile=profile):
                docs = self.render(profile, ['--is-upgrade', '-f', 'charts/agent-relay/upgrade/kind-control-webapp-identities.yaml'])
                actual = sorted([identity(d) for d in docs], key=lambda d: (d['kind'], d['name']))
                self.assertEqual(actual, fixture['profiles'][profile])

    def test_default_kind_upgrade_requires_explicit_worker_cutover(self):
        error = self.render(extra=['--is-upgrade'], ok=False)
        self.assertIn('workload rename requires a drained cutover', error)

    def test_real_profile_images_are_not_relabelled_as_unpublished_repositories(self):
        docs = self.render()
        images = {c['image'] for d in docs for c in stack.pod_spec(d).get('containers', [])}
        self.assertTrue(any(i.startswith('ghcr.io/agentworkforce/selfhost-api@sha256:') for i in images))
        self.assertTrue(any(i.startswith('ghcr.io/agentworkforce/relay-dashboard@sha256:') for i in images))
        self.assertFalse(any(i.startswith(('ghcr.io/agentworkforce/relay-control@', 'ghcr.io/agentworkforce/relay-webapp@')) for i in images))

    def test_old_cluster_is_refused_before_ready_or_images_are_changed(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(stack, 'ROOT', Path(tmp)), patch.object(stack.shutil, 'which', return_value='/fixture/tool'):
            # Read-only native selection admission precedes runtime calls.
            # Keep this fixture non-native so the real legacy-name guard is
            # still reached, with all original no-mutation assertions intact.
            charts = Path(tmp) / 'charts/agent-relay'
            charts.mkdir(parents=True)
            (charts / 'values.yaml').write_text('{}\n')
            (charts / 'values-kind-core.yaml').write_text('{}\n')
            local = stack.Stack('core')
            ready = local.state / 'ready.json'
            ready.write_text('saved-independent-receipt')
            local.docker = Mock()
            local.require_owned_cluster = Mock()
            local.require_no_legacy_storage = Mock()
            local.dependencies = Mock(side_effect=AssertionError('must refuse before dependencies'))
            local.cmd = Mock(return_value=subprocess.CompletedProcess([], 0, 'agent-relay-core\n', ''))
            local.k = Mock(return_value=subprocess.CompletedProcess([], 0, json.dumps({'items': [
                {'kind': 'Deployment', 'metadata': {'name': 'relaycontrol'}}]}), ''))
            with self.assertRaisesRegex(stack.StackError, 'existing Control/Webapp layout'):
                local.up()
            local.require_owned_cluster.assert_called_once()
            local.dependencies.assert_not_called()
            self.assertEqual(ready.read_text(), 'saved-independent-receipt')
            local.require_no_legacy_storage.assert_called_once()
            self.assertEqual(local.k.call_count, 2)
            self.assertEqual(local.k.call_args_list[0].args, ('get', 'namespace', 'agent-relay', '--ignore-not-found', '-o', 'json'))
            self.assertEqual(local.k.call_args_list[1].args, ('get', 'deployments,services', '-o', 'json'))

    def test_control_webapp_preflight_allows_an_empty_owned_cluster(self):
        local = object.__new__(stack.Stack)
        local.k = Mock(return_value=subprocess.CompletedProcess([], 0, '', ''))
        local.require_control_webapp_layout()
        local.k.assert_called_once_with('get', 'namespace', 'agent-relay', '--ignore-not-found', '-o', 'json', namespace=None)

    def test_new_layout_preflight_accepts_only_observed_new_resources(self):
        local = object.__new__(stack.Stack)
        local.k = Mock(return_value=subprocess.CompletedProcess([], 0, json.dumps({'items': [
            {'kind': 'Deployment', 'metadata': {'name': 'relay-control', 'labels': {'app.kubernetes.io/name': 'relay-control'}}},
            {'kind': 'Service', 'metadata': {'name': 'relay-webapp'}}]}), ''))
        local.require_control_webapp_layout()


if __name__ == '__main__':
    unittest.main()
