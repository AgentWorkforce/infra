"""Pure saved-plan schema fixtures, not test UI or a claimed live backend."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('creation_mode', Path(__file__).resolve().parents[1] / 'creation_mode.py')
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
POLICY = g.PREFIX + 'aws_opensearch_domain_policy.this'


def row(address, values):
    kind = 'terraform_data' if address == g.MARKER else ('aws_opensearch_domain_policy' if address == POLICY else 'aws_opensearch_domain')
    return {'address': address, 'mode': 'managed', 'type': kind, 'values': values}


def fixture(mode=True, fresh=False, enrolled=True, destroy=False, legacy=False):
    address = g.DISPOSABLE if mode else g.PROTECTED
    old = g.LEGACY if legacy else address
    domain = {'id': 'domain-id', 'domain_name': 'synthetic-domain'}
    policy = {'id': 'policy-id'}
    marker = {'id': 'mode-id', 'input': mode, 'output': mode}
    prior = [] if fresh else [row(old, domain), row(POLICY, policy)]
    if not fresh and enrolled: prior.append(row(g.MARKER, marker))
    changes = []
    for a, values in [(address, domain), (POLICY, policy), (g.MARKER, marker)]:
        before = None if fresh or (a == g.MARKER and not enrolled) else values
        after = None if destroy else {**values}
        if before is None: after['id'] = None
        change = {'actions': ['delete' if destroy else ('create' if before is None else 'no-op')], 'before': before, 'after': after, 'after_unknown': {}}
        r = {k: v for k, v in row(a, values).items() if k != 'values'}
        r['change'] = change
        if a == address and legacy: r['previous_address'] = g.LEGACY
        changes.append(r)
    plan = {'format_version': '1.2', 'errored': False, 'complete': True, 'resource_changes': changes}
    if not fresh: plan['prior_state'] = {'values': {'root_module': {'child_modules': [{'address': 'module.search', 'resources': prior}]}}}
    return plan


def change(plan, address):
    return next(r['change'] for r in plan['resource_changes'] if r['address'] == address)


def state(plan):
    return plan['prior_state']['values']['root_module']['child_modules'][0]['resources']


class History(unittest.TestCase):
    def test_actual_pinned_native_builtin_saved_plan_fragments(self):
        # These are real show-json marker fragments, not a claimed AWS plan.
        samples = json.loads((Path(__file__).parent / 'fixtures/native-marker-shapes.json').read_text())
        for engine, operations in samples.items():
            for operation, sample in operations.items():
                p = fixture(fresh=operation == 'fresh', destroy=operation == 'destroy')
                native = copy.deepcopy(sample['change']); native['address'] = g.MARKER
                p['resource_changes'][-1] = native
                if sample['prior_resource']:
                    prior = copy.deepcopy(sample['prior_resource']); prior['address'] = g.MARKER
                    state(p)[-1] = prior
                with self.subTest(engine=engine, operation=operation):
                    self.assertEqual(g.admit(p), {'fresh':'fresh','noop':'enrolled','destroy':'destroy'}[operation])

    def test_native_schema_fresh_both_modes_and_empty_prior_omission(self):
        for mode in [False, True]:
            p = fixture(mode, fresh=True)
            self.assertEqual(g.admit(p), 'fresh')
            p['prior_state'] = {'values': {}}
            self.assertEqual(g.admit(p), 'fresh')

    def test_enrolled_same_mode_and_full_disposable_destroy(self):
        for mode in [False, True]: self.assertEqual(g.admit(fixture(mode)), 'enrolled')
        self.assertEqual(g.admit(fixture(destroy=True)), 'destroy')
        with self.assertRaises(g.SearchModeError): g.admit(fixture(False, destroy=True))

    def test_unchanged_legacy_enrollment_includes_native_unindexed_move(self):
        for mode, legacy in [(True, False), (False, False), (False, True)]:
            self.assertEqual(g.admit(fixture(mode, enrolled=False, legacy=legacy)), 'legacy-or-missing-marker unchanged-domain')
        p = fixture(False, enrolled=False, legacy=True)
        state(p)[0]['address'] = g.PROTECTED # native engines can expose the moved prior address
        self.assertEqual(g.admit(p), 'legacy-or-missing-marker unchanged-domain')

    def test_legacy_enrollment_cannot_flip_mode_or_mutate_any_search_resource(self):
        for mode in [False, True]:
            p = fixture(mode, enrolled=False); change(p, g.MARKER)['after']['input'] = not mode
            with self.assertRaises(g.SearchModeError): g.admit(p)
        for address in [g.DISPOSABLE, POLICY]:
            p = fixture(enrolled=False); change(p, address)['actions'] = ['update']
            with self.assertRaises(g.SearchModeError): g.admit(p)
        p = fixture(enrolled=False); new = copy.deepcopy(p['resource_changes'][0]); new['address'] = g.PROTECTED; new['change'] = {'actions': ['create'], 'before': None, 'after': {'id': None}}
        change(p, g.DISPOSABLE)['actions'] = ['delete']; p['resource_changes'].append(new)
        with self.assertRaises(g.SearchModeError): g.admit(p)

    def test_before_id_and_inventory_must_match_native_prior_state(self):
        for target in [g.DISPOSABLE, g.MARKER, POLICY]:
            p = fixture(); change(p, target)['before'] = {**change(p, target)['before'], 'id': 'foreign-id'}
            with self.subTest(target=target), self.assertRaises(g.SearchModeError): g.admit(p)
        for mutation in ['missing', 'duplicate', 'mixed', 'unknown-mode', 'deposed']:
            p = fixture()
            if mutation == 'missing': state(p).pop()
            if mutation == 'duplicate': state(p).append(copy.deepcopy(state(p)[0]))
            if mutation == 'mixed': state(p).append(row(g.PROTECTED, {'id': 'other'}))
            if mutation == 'unknown-mode': state(p)[0]['mode'] = None
            if mutation == 'deposed': p['resource_changes'][0]['deposed'] = 'deadbeef'
            with self.subTest(mutation=mutation), self.assertRaises(g.SearchModeError): g.admit(p)

    def test_marker_replacement_update_or_only_removal_never_admitted(self):
        for actions in [['delete', 'create'], ['create', 'delete'], ['update'], ['delete']]:
            p = fixture(); change(p, g.MARKER)['actions'] = actions
            with self.subTest(actions=actions), self.assertRaises(g.SearchModeError): g.admit(p)
        p = fixture(destroy=True); change(p, POLICY)['actions'] = ['no-op']
        with self.assertRaises(g.SearchModeError): g.admit(p)
        p = fixture(); change(p, g.MARKER)['after']['input'] = False
        with self.assertRaises(g.SearchModeError): g.admit(p)

    def test_unknown_missing_lost_or_foreign_history_is_hold(self):
        cases = []
        p = fixture(); del p['prior_state']; cases.append(p)
        p = fixture(); p['prior_state'] = None; cases.append(p)
        p = fixture(); state(p).pop(0); cases.append(p) # marker without domain
        p = fixture(); p['resource_changes'].pop(0); cases.append(p)
        p = fixture(); change(p, g.MARKER)['after']['input'] = 1; cases.append(p)
        p = fixture(); change(p, g.MARKER)['after_unknown'] = {'input': True}; cases.append(p)
        p = fixture(); p['resource_changes'][0]['address'] = 'module.search[0].aws_opensearch_domain.disposable[0]'; cases.append(p)
        p = fixture(); p['resource_changes'][0]['previous_address'] = g.PROTECTED; cases.append(p)
        p = fixture(); p['resource_drift'] = [{'address': g.DISPOSABLE}]; cases.append(p)
        p = fixture(); p['deferred_changes'] = [{}]; cases.append(p)
        p = fixture(); p['deferred_changes'] = None; cases.append(p)
        p = fixture(); p['prior_state']['values']['root_module']['child_modules'][0].pop('address'); cases.append(p)
        p = fixture(); change(p, g.MARKER)['after_unknown'] = None; cases.append(p)
        p = fixture(); p['complete'] = False; cases.append(p)
        p = fixture(); p['errored'] = True; cases.append(p)
        p = fixture(); p['format_version'] = '2.0'; cases.append(p)
        p = fixture(); p['prior_state']['format_version'] = '2.0'; cases.append(p)
        p = fixture(); p['resource_changes'][0]['change']['importing'] = {'id': 'foreign'}; cases.append(p)
        for i, p in enumerate(cases):
            with self.subTest(case=i), self.assertRaises(g.SearchModeError): g.admit(p)


if __name__ == '__main__': unittest.main()
