#!/usr/bin/env python3
"""Real Helm renders and a causal no-mutation check for public chart names."""
import json
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
        for name in ('relay-control', 'relay-webapp'):
            self.assertEqual(deployments[name]['spec']['selector']['matchLabels']['app.kubernetes.io/name'], name)
        targets = [x['backend']['service']['name'] for d in docs if d['kind'] == 'Ingress'
                   for rule in d['spec']['rules'] for x in rule['http']['paths']]
        self.assertIn('relay-control', targets)
        self.assertIn('relay-webapp', targets)
        self.assertNotIn('relaycontrol', targets)

    def test_old_overrides_are_refused_even_when_empty_or_disabled(self):
        for key, value in [('relay-cloud-api', '{}'), ('relay-dashboard', '{}'),
                           ('components.cloudApi', 'false'), ('components.dashboard', 'false')]:
            with self.subTest(key=key):
                error = self.render(extra=['--set-json', key + '=' + value], ok=False)
                self.assertIn('was renamed', error)

    def test_kind_compatibility_keeps_all_old_selectors_services_claims_and_jobs(self):
        fixture = json.loads((ROOT / 'ci/agent-relay/fixtures/control-webapp-legacy-identities.json').read_text())
        for profile in ('core', 'addons'):
            with self.subTest(profile=profile):
                docs = self.render(profile, ['-f', 'charts/agent-relay/upgrade/kind-control-webapp-identities.yaml'])
                actual = sorted([identity(d) for d in docs], key=lambda d: (d['kind'], d['name']))
                self.assertEqual(actual, fixture['profiles'][profile])

    def test_real_profile_images_are_not_relabelled_as_unpublished_repositories(self):
        docs = self.render()
        images = {c['image'] for d in docs for c in stack.pod_spec(d).get('containers', [])}
        self.assertTrue(any(i.startswith('ghcr.io/agentworkforce/selfhost-api@sha256:') for i in images))
        self.assertTrue(any(i.startswith('ghcr.io/agentworkforce/relay-dashboard@sha256:') for i in images))
        self.assertFalse(any(i.startswith(('ghcr.io/agentworkforce/relay-control@', 'ghcr.io/agentworkforce/relay-webapp@')) for i in images))

    def test_old_cluster_is_refused_before_ready_or_images_are_changed(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(stack, 'ROOT', Path(tmp)), patch.object(stack.shutil, 'which', return_value='/fixture/tool'):
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
