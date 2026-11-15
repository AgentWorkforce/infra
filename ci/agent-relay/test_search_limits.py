#!/usr/bin/env python3
"""Render checks for the issue-610 search limits: unset by default, explicit when set."""
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
BASE = [
    'helm', 'template', 'proof', 'charts/agent-relay', '-n', 'agent-relay', '--no-hooks',
    '-f', 'charts/agent-relay/values-gcp.yaml',
    '-f', 'charts/agent-relay/values-gcp-native.yaml',
    '-f', 'charts/agent-relay/ci/gcp-native-values.yaml',
]
NAMES = ('SEARCH_INDEX_MAX_SCOPE_BYTES', 'SEARCH_INDEX_MAX_SCOPE_EVENTS', 'SEARCH_INDEX_MAX_ROWS',
         'READ_API_SEARCH_PARTIAL_SESSIONS')


def render(overrides=None):
    with tempfile.TemporaryDirectory() as folder:
        args = list(BASE)
        if overrides is not None:
            path = Path(folder) / 'overrides.yaml'
            path.write_text(yaml.safe_dump({'sessions-pipeline': overrides}))
            args += ['-f', str(path)]
        return subprocess.run(args, cwd=ROOT, capture_output=True, text=True)


def env(stdout, name):
    docs = [doc for doc in yaml.safe_load_all(stdout) if doc]
    deployment = next(doc for doc in docs if doc.get('kind') == 'Deployment' and doc['metadata']['name'] == name)
    return {item['name']: item.get('value') for item in deployment['spec']['template']['spec']['containers'][0]['env']}


class SearchLimits(unittest.TestCase):
    def test_unset_by_default(self):
        result = render()
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in NAMES:
            self.assertNotIn(name, result.stdout)

    def test_explicit_values_render_on_the_consumer_and_reader(self):
        result = render({
            'searchIndexer': {'limits': {'maxScopeBytes': '128MiB', 'maxScopeEvents': 400000, 'maxRows': 800000}},
            'sessionReadApi': {'search': {'partialSessions': 'skip'}},
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        indexer = env(result.stdout, 'proof-search-indexer')
        self.assertEqual(indexer['SEARCH_INDEX_MAX_SCOPE_BYTES'], '128MiB')
        self.assertEqual(indexer['SEARCH_INDEX_MAX_SCOPE_EVENTS'], '400000')
        self.assertEqual(indexer['SEARCH_INDEX_MAX_ROWS'], '800000')
        self.assertEqual(env(result.stdout, 'agent-relay-read-api')['READ_API_SEARCH_PARTIAL_SESSIONS'], 'skip')

    def test_invalid_values_are_refused(self):
        cases = [
            ({'searchIndexer': {'limits': {'maxRows': 5}}}, 'searchIndexer.limits.maxRows must be an integer'),
            ({'searchIndexer': {'limits': {'maxScopeEvents': 'many'}}}, 'searchIndexer.limits.maxScopeEvents must be an integer'),
            ({'searchIndexer': {'limits': {'maxScopeBytes': '10TB'}}}, 'searchIndexer.limits.maxScopeBytes must be'),
            ({'sessionReadApi': {'search': {'partialSessions': 'maybe'}}}, 'search.partialSessions must be refuse or skip'),
        ]
        for overrides, message in cases:
            with self.subTest(overrides=overrides):
                result = render(overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)


if __name__ == '__main__':
    unittest.main()
