#!/usr/bin/env python3
"""Gate-only edges route /v1/relayfacts and /v1/coordination to relaygate by default.

Without these routes the history host answers a fixed deny (503 on the AKS
Traefik edge, 404 on the ALB) and never reaches the read API, so a client that
maps 501 relayfacts_disabled to "disabled" reports "temporarily unavailable".
Every edge the chart renders (GKE, EKS ALB, AKS Traefik) must send both paths to
relaygate (Prefix: the exact path plus subpaths, not /v1/relayfactsX) with the
gate on, and global.relaygate.gateOnly.relayfactsRoutes=false must drop them
again for an external relaygate image that does not proxy them. Needs the
chart's dependencies built (ci/agent-relay/render.sh does it).
"""
from pathlib import Path
import subprocess
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
HOST = 'history.gcp-proof.agentrelay.com'
PATHS = ('/v1/relayfacts', '/v1/coordination')
EDGES = {'gke': 'ci-agent-relay-gate', 'eks': 'ci-relaygate', 'aks': 'ci-relaygate'}


def history_routes(edge, *extra):
    cmd = ['helm', 'template', 'ci', 'charts/agent-relay', '-n', 'ci', '--no-hooks',
           '-f', 'charts/agent-relay/values-gcp-proof.yaml', '-f', f'charts/agent-relay/ci/gate-sessions-{edge}-values.yaml', *extra]
    out = subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True)
    if out.returncode:
        raise AssertionError(out.stderr)
    routes = []
    for doc in yaml.safe_load_all(out.stdout):
        if doc and doc.get('kind') == 'Ingress':
            for rule in doc['spec'].get('rules', []):
                if rule.get('host') == HOST:
                    for p in rule['http']['paths']:
                        routes.append((p['path'], p['pathType'], p['backend']['service']['name']))
    return routes


class GateRelayfactsRoutes(unittest.TestCase):
    def test_default_routes_both_to_relaygate_on_every_edge(self):
        for edge in EDGES:
            with self.subTest(edge=edge):
                routes = history_routes(edge)
                sessions = [r for r in routes if r[0] == '/v1/sessions']
                self.assertEqual(len(sessions), 1, routes)
                for path in PATHS:
                    self.assertEqual([r for r in routes if r[0] == path], [(path, 'Prefix', sessions[0][2])], f'{edge}: {path}')

    def test_false_denies_both_at_the_edge(self):
        for edge in EDGES:
            with self.subTest(edge=edge):
                routes = history_routes(edge, '--set', 'global.relaygate.gateOnly.relayfactsRoutes=false')
                self.assertTrue(any(r[0] == '/v1/sessions' for r in routes), routes)
                for path in PATHS:
                    self.assertEqual([r for r in routes if r[0] == path], [], f'{edge}: {path}')

    def test_ungated_history_host_still_routes_both_to_the_read_api(self):
        # No gate: the read-API edge owns both, with no flag involved.
        for edge in EDGES:
            with self.subTest(edge=edge):
                routes = history_routes(edge, '--set', 'global.relaygate.gateOnly.enabled=false', '--set', 'components.relaygate=false')
                reader = {r[2] for r in routes if r[0] == '/v1/sessions'}
                self.assertEqual(len(reader), 1, routes)
                for path in PATHS:
                    self.assertEqual([r for r in routes if r[0] == path], [(path, 'Prefix', reader.copy().pop())], f'{edge}: {path}')


if __name__ == '__main__':
    unittest.main()
