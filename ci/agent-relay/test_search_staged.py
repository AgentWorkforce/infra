#!/usr/bin/env python3
"""Render checks for issue-610 Phase 3 staged reconcile: tri-state enabled, consumer only, refusals."""
import unittest

from test_search_limits import env, render
from test_search_streaming import bootstrap_names

NAME = 'SEARCH_INDEX_STAGED_RECONCILE_ENABLED'
CONSUMER = 'proof-search-indexer'


class SearchStaged(unittest.TestCase):
    def test_unset_by_default(self):
        result = render()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(NAME, result.stdout)

    def test_true_and_false_render_explicitly_on_the_consumer_only(self):
        for value, rendered in ((True, 'true'), (False, 'false')):
            with self.subTest(enabled=value):
                result = render({'searchIndexer': {'stagedReconcile': {'enabled': value}}})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(env(result.stdout, CONSUMER)[NAME], rendered)
                self.assertEqual(result.stdout.count(NAME), 1)

    def test_false_with_streaming_off_renders(self):
        result = render({'searchIndexer': {'streaming': {'enabled': False}, 'stagedReconcile': {'enabled': False}}})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_output_facts_allowed(self):
        result = render({'searchIndexer': {'outputFacts': {'enabled': True}, 'stagedReconcile': {'enabled': True}}})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_refusals(self):
        for values, message in (
            ({'stagedReconcile': {'enabled': 'true'}}, 'stagedReconcile.enabled must be null, true or false'),
            ({'stagedReconcile': True}, 'stagedReconcile must be a map'),
            ({'stagedReconcile': False}, 'stagedReconcile must be a map'),
            ({'stagedReconcile': ''}, 'stagedReconcile must be a map'),
            ({'streaming': {'enabled': False}, 'stagedReconcile': {'enabled': True}}, 'needs streaming on'),
        ):
            with self.subTest(values=values):
                result = render({'searchIndexer': values})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_bootstrap_job_names_do_not_move(self):
        base, on = render(), render({'searchIndexer': {'stagedReconcile': {'enabled': False}}})
        self.assertEqual(base.returncode, 0, base.stderr)
        self.assertEqual(on.returncode, 0, on.stderr)
        self.assertEqual(bootstrap_names(base.stdout), bootstrap_names(on.stdout))


if __name__ == '__main__':
    unittest.main()
