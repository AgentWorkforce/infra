#!/usr/bin/env python3
"""Render checks for issue-610 Phase 2 streaming reconcile: tri-state enabled, consumer only, refusals."""
import unittest

from test_search_limits import env, render

NAMES = ('SEARCH_INDEX_STREAMING_ENABLED', 'SEARCH_INDEX_STREAM_MAX_READ_BYTES', 'SEARCH_INDEX_STREAM_MAX_READ_EVENTS')
CONSUMER = 'proof-search-indexer'


def bootstrap_names(stdout):
    import yaml
    return sorted(d['metadata']['name'] for d in yaml.safe_load_all(stdout)
                  if d and d.get('kind') == 'Job' and '-bootstrap-' in d['metadata']['name'])


class SearchStreaming(unittest.TestCase):
    def test_unset_by_default(self):
        result = render()
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in NAMES:
            self.assertNotIn(name, result.stdout)

    def test_true_and_false_render_explicitly_on_the_consumer_only(self):
        for value, rendered in ((True, 'true'), (False, 'false')):
            with self.subTest(enabled=value):
                result = render({'searchIndexer': {'streaming': {'enabled': value}}})
                self.assertEqual(result.returncode, 0, result.stderr)
                consumer = env(result.stdout, CONSUMER)
                self.assertEqual(consumer['SEARCH_INDEX_STREAMING_ENABLED'], rendered)
                self.assertNotIn('SEARCH_INDEX_STREAM_MAX_READ_BYTES', consumer)
                self.assertEqual(result.stdout.count('SEARCH_INDEX_STREAMING_ENABLED'), 1)

    def test_budgets_render_without_enabled(self):
        result = render({'searchIndexer': {'streaming': {'maxReadBytes': '1GiB', 'maxReadEvents': 800000}}})
        self.assertEqual(result.returncode, 0, result.stderr)
        consumer = env(result.stdout, CONSUMER)
        self.assertNotIn('SEARCH_INDEX_STREAMING_ENABLED', consumer)
        self.assertEqual(consumer['SEARCH_INDEX_STREAM_MAX_READ_BYTES'], '1GiB')
        self.assertEqual(consumer['SEARCH_INDEX_STREAM_MAX_READ_EVENTS'], '800000')

    def test_output_facts_with_unset_streaming_renders(self):
        result = render({'searchIndexer': {'outputFacts': {'enabled': True}}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('SEARCH_INDEX_STREAMING_ENABLED', result.stdout)

    def test_budgets_render_when_set(self):
        result = render({'searchIndexer': {
            'limits': {'maxScopeBytes': '128MiB', 'maxScopeEvents': 200000},
            'streaming': {'enabled': True, 'maxReadBytes': '2GiB', 'maxReadEvents': 2000000},
        }})
        self.assertEqual(result.returncode, 0, result.stderr)
        consumer = env(result.stdout, CONSUMER)
        self.assertEqual(consumer['SEARCH_INDEX_STREAM_MAX_READ_BYTES'], '2GiB')
        self.assertEqual(consumer['SEARCH_INDEX_STREAM_MAX_READ_EVENTS'], '2000000')

    def test_bootstrap_job_names_do_not_move(self):
        base, on = render(), render({'searchIndexer': {'streaming': {'enabled': True, 'maxReadBytes': '1GiB'}}})
        self.assertEqual(base.returncode, 0, base.stderr)
        self.assertEqual(on.returncode, 0, on.stderr)
        self.assertEqual(bootstrap_names(base.stdout), bootstrap_names(on.stdout))

    def test_invalid_values_are_refused(self):
        cases = [
            ({'streaming': {'enabled': 'yes'}}, 'searchIndexer.streaming.enabled must be null, true or false'),
            ({'streaming': {'enabled': False, 'maxReadBytes': '1GiB'}}, 'have no effect with searchIndexer.streaming.enabled=false'),
            ({'streaming': {'maxReadEvents': 100}}, 'maxReadEvents must be an integer from 400000'),
            ({'streaming': {'enabled': True}, 'outputFacts': {'enabled': True}}, 'cannot be combined with searchIndexer.outputFacts.enabled=true'),
            ({'streaming': {'enabled': True, 'maxReadBytes': '10TB'}}, 'maxReadBytes must be bytes or a MiB/GiB size'),
            ({'streaming': {'enabled': True, 'maxReadBytes': '3GiB'}}, 'maxReadBytes must be from 256MiB'),
            ({'streaming': {'enabled': True, 'maxReadBytes': '200MiB'}}, 'maxReadBytes must be from 256MiB'),
            ({'limits': {'maxScopeBytes': '256MiB'}, 'streaming': {'enabled': True, 'maxReadBytes': '512MiB'}}, 'maxReadBytes must be from 1024MiB'),
            ({'streaming': {'enabled': True, 'maxReadEvents': 399999}}, 'maxReadEvents must be an integer from 400000'),
            ({'streaming': {'enabled': True, 'maxReadEvents': 2000001}}, 'maxReadEvents must be an integer from 400000'),
            ({'streaming': {'enabled': True, 'maxReadEvents': 'many'}}, 'maxReadEvents must be an integer'),
        ]
        for overrides, message in cases:
            with self.subTest(overrides=overrides):
                result = render({'searchIndexer': overrides})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)


if __name__ == '__main__':
    unittest.main()
