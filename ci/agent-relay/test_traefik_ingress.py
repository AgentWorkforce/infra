#!/usr/bin/env python3
"""The chart's traefikIngress renders the AKS edge docs/azure-install/ingress.yaml held.

With the gate off, `helm template` with traefikIngress on must give the same
edge-deny Service and Ingress as the frozen fixture
(ci/agent-relay/fixtures/aks-traefik-ingress.yaml, the old hand-edited file),
host placeholders filled in: spec and annotations deep-equal, rule and path
order included, name and namespace equal. Helm's labels are the only allowed
difference. With the gate on, the history host (and with scope all the cast
host) reaches relaygate on exactly its routes and denies /internal and /admin.
Needs the chart's dependencies built (ci/agent-relay/render.sh does it).
"""
from pathlib import Path
import subprocess
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / 'ci/agent-relay/fixtures/aks-traefik-ingress.yaml'
HOSTS = {'root': 'relay.example.com', 'api': 'api.relay.example.com',
         'cast': 'cast.relay.example.com', 'history': 'history.relay.example.com'}
NAMESPACE = 'agent-relay'
HISTORY_GATE = [('/v1/events', 'Exact'), ('/v1/ingest', 'Exact'), ('/v1/auth/token/refresh', 'Exact'),
                ('/v1/auth/token/revoke', 'Exact'), ('/v1/onboarding/heartbeat', 'Exact'), ('/v1/upload-consent', 'Exact'),
                ('/v1/sessions', 'Prefix'), ('/v1/delivery', 'Prefix'), ('/v1/digest', 'Prefix'),
                ('/v1/relayfacts', 'Prefix'), ('/v1/coordination', 'Prefix')]
CAST_GATE = [(p, 'Exact') for p in ('/v1/register', '/v1/check', '/v1/whoami', '/v1/agent', '/v1/agent/node-token',
                                    '/v1/node/ws', '/v1/search', '/v1/inbox')] + \
            [(p, 'Prefix') for p in ('/v1/agents', '/v1/channels', '/v1/messages', '/v1/dm', '/v1/streams', '/v1/deliveries')]


def render(*args, check=True):
    cmd = ['helm', 'template', 'agent-relay', 'charts/agent-relay', '-n', NAMESPACE,
           '--show-only', 'templates/traefik-ingress.yaml',
           '-f', 'charts/agent-relay/values-gcp-proof.yaml', '-f', 'charts/agent-relay/ci/traefik-ingress-values.yaml']
    for role, host in HOSTS.items():
        cmd += ['--set', f'traefikIngress.hosts.{role}={host}']
    out = subprocess.run(cmd + list(args), cwd=ROOT, text=True, capture_output=True)
    if not check:
        return out
    if out.returncode:
        raise AssertionError(out.stderr)
    return [d for d in yaml.safe_load_all(out.stdout) if d]


def fixture():
    raw = FIXTURE.read_text()
    for role, host in HOSTS.items():
        raw = raw.replace(f'__HOST_{role.upper()}__', host)
    return [d for d in yaml.safe_load_all(raw) if d]


def routes(docs, host):
    ing = next(d for d in docs if d['kind'] == 'Ingress')
    rule = next(r for r in ing['spec']['rules'] if r['host'] == host)
    return [(p['path'], p['pathType'], '%s:%s' % (p['backend']['service']['name'], p['backend']['service']['port']['number']))
            for p in rule['http']['paths']]


class TraefikIngress(unittest.TestCase):
    def test_gate_off_equals_the_old_hand_edited_file(self):
        want, got = fixture(), render()
        self.assertEqual([(d['kind'], d['metadata']['name'], d['metadata']['namespace']) for d in got],
                         [(d['kind'], d['metadata']['name'], d['metadata']['namespace']) for d in want])
        for w, g in zip(want, got):
            self.assertEqual(g['spec'], w['spec'], w['kind'])
            self.assertEqual(g['metadata'].get('annotations'), w['metadata'].get('annotations'), w['kind'])

    def _gate(self, *extra):
        # The gate ci file uses the proof hosts; render it as-is.
        cmd = ['helm', 'template', 'ci', 'charts/agent-relay', '-n', 'ci', '--show-only', 'templates/traefik-ingress.yaml',
               '-f', 'charts/agent-relay/values-gcp-proof.yaml', '-f', 'charts/agent-relay/ci/gate-sessions-aks-values.yaml', *extra]
        out = subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True)
        if out.returncode:
            raise AssertionError(out.stderr)
        return [d for d in yaml.safe_load_all(out.stdout) if d]

    def test_sessions_only_routes_history_to_relaygate_and_leaves_cast_direct(self):
        docs = self._gate()
        gate, deny = 'ci-relaygate:8080', 'edge-deny:80'
        self.assertEqual(routes(docs, 'history.gcp-proof.agentrelay.com'),
                         [(p, t, gate) for p, t in HISTORY_GATE] + [('/internal', 'Prefix', deny), ('/admin', 'Prefix', deny), ('/', 'Prefix', deny)])
        self.assertEqual(routes(docs, 'cast.gcp-proof.agentrelay.com'),
                         [('/internal', 'Prefix', deny), ('/v1/workspaces', 'Exact', deny),
                          ('/v1/workspaces/', 'Exact', deny), ('/', 'Prefix', 'relaycast:8787')])

    def test_scope_all_routes_cast_to_relaygate(self):
        out = subprocess.run(['helm', 'template', 'ci', 'charts/agent-relay', '-n', 'ci', '--show-only', 'templates/traefik-ingress.yaml',
                              '-f', 'charts/agent-relay/values-gcp-proof.yaml', '-f', 'charts/agent-relay/ci/gate-only-values.yaml',
                              '--set', 'gkeIngress.enabled=false', '--set', 'traefikIngress.enabled=true',
                              '--set', 'traefikIngress.hosts.root=gcp-proof.agentrelay.com', '--set', 'traefikIngress.hosts.api=api.gcp-proof.agentrelay.com',
                              '--set', 'traefikIngress.hosts.cast=cast.gcp-proof.agentrelay.com', '--set', 'traefikIngress.hosts.history=history.gcp-proof.agentrelay.com',
                              '--set', 'relay-control.services.relaycastPublicUrl=https://cast.gcp-proof.agentrelay.com'],
                             cwd=ROOT, text=True, capture_output=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        docs = [d for d in yaml.safe_load_all(out.stdout) if d]
        gate, deny = 'ci-relaygate:8080', 'edge-deny:80'
        self.assertEqual(routes(docs, 'cast.gcp-proof.agentrelay.com'),
                         [(p, t, gate) for p, t in CAST_GATE] + [('/internal', 'Prefix', deny), ('/admin', 'Prefix', deny), ('/', 'Prefix', deny)])

    def test_no_route_reaches_internal_or_admin(self):
        for docs in (render(), self._gate()):
            ing = next(d for d in docs if d['kind'] == 'Ingress')
            for rule in ing['spec']['rules']:
                for p in rule['http']['paths']:
                    if p['path'].startswith(('/internal', '/admin')):
                        self.assertEqual(p['backend']['service']['name'], 'edge-deny', (rule['host'], p['path']))

    def test_docs_ingress_is_generated_from_the_chart(self):
        # docs/azure-install/ingress.yaml serves releases whose chart predates
        # traefikIngress; it must be exactly what the generator prints.
        out = subprocess.run(['scripts/selfhost/aks-traefik-ingress.sh'], cwd=ROOT, text=True, capture_output=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual((ROOT / 'docs/azure-install/ingress.yaml').read_text(), out.stdout,
                         'regenerate: scripts/selfhost/aks-traefik-ingress.sh > docs/azure-install/ingress.yaml')
        generated = [d for d in yaml.safe_load_all(out.stdout) if d]
        for w, g in zip(fixture(), [yaml.safe_load(yaml.safe_dump(d).replace('__HOST_ROOT__', HOSTS['root']).replace('__HOST_API__', HOSTS['api'])
                                                    .replace('__HOST_CAST__', HOSTS['cast']).replace('__HOST_HISTORY__', HOSTS['history'])) for d in generated]):
            self.assertEqual(g['spec'], w['spec'], w['kind'])

    def test_refusals(self):
        for args, msg in [
            (['--set', 'traefikIngress.hosts.history='], 'traefikIngress.hosts.history is required'),
            (['--set', 'traefikIngress.hosts.cast=relay.example.com'], 'four different hostnames'),
            (['--set', 'traefikIngress.backends.readApi.serviceName=Bad_Name'], 'traefikIngress.backends.readApi.serviceName must be a DNS label'),
            (['--set', 'traefikIngress.clusterIssuer=Bad Issuer'], 'traefikIngress.clusterIssuer must be'),
            (['--set-string', 'traefikIngress.enabled=true'], 'traefikIngress.enabled must be true or false'),
            (['--set', 'eksIngress.enabled=true'], 'traefikIngress.enabled is exclusive'),
        ]:
            with self.subTest(msg=msg):
                out = render(*args, check=False)
                self.assertNotEqual(out.returncode, 0)
                self.assertIn(msg, out.stderr)


if __name__ == '__main__':
    unittest.main()
