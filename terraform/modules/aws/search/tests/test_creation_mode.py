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


ROLE = g.PREFIX + 'aws_iam_role.workload["indexer"]'
ROLE_POLICY = g.PREFIX + 'aws_iam_role_policy.workload["indexer"]'
DOC = json.dumps({'Version': '2012-10-17', 'Statement': [{'Effect': 'Allow', 'Action': ['es:ESHttpGet'], 'Resource': '*'}]})
SAME_DOC = json.dumps({'Statement': {'Resource': '*', 'Action': 'es:ESHttpGet', 'Effect': 'Allow'}, 'Version': '2012-10-17'})


def sibling_plan():
    p = fixture(mode=False)
    next(r for r in state(p) if r['address'] == POLICY)['values']['access_policies'] = DOC
    for address, kind, values in [(ROLE, 'aws_iam_role', {'id': 'role'}), (ROLE_POLICY, 'aws_iam_role_policy', {'id': 'role:p', 'name': 'p', 'policy': DOC})]:
        state(p).append({'address': address, 'mode': 'managed', 'type': kind, 'values': values})
        p['resource_changes'].append({'address': address, 'mode': 'managed', 'type': kind, 'change': {'actions': ['no-op'], 'before': values, 'after': values, 'after_unknown': {}}})
    p['resource_drift'] = [
        {'address': g.PROTECTED, 'mode': 'managed', 'type': 'aws_opensearch_domain', 'change': {'actions': ['update'], 'before': {'id': 'domain-id', 'access_policies': None}, 'after': {'id': 'domain-id', 'access_policies': SAME_DOC}}},
        {'address': ROLE, 'mode': 'managed', 'type': 'aws_iam_role', 'change': {'actions': ['update'], 'before': {'id': 'role', 'inline_policy': []}, 'after': {'id': 'role', 'inline_policy': [{'name': 'p', 'policy': SAME_DOC}]}}},
    ]
    return p


class SiblingDrift(unittest.TestCase):
    def test_sibling_written_fields_are_admitted(self):
        self.assertEqual(g.admit(sibling_plan()), 'enrolled')

    def test_everything_else_still_holds(self):
        def domain(p): return p['resource_drift'][0]['change']
        def role(p): return p['resource_drift'][1]['change']
        cases = {
            'other field': lambda p: domain(p)['after'].update(engine_version='x'),
            'domain value differs': lambda p: domain(p)['after'].update(access_policies=json.dumps({'Statement': []})),
            'invalid document': lambda p: domain(p)['after'].update(access_policies='{'),
            'replace action': lambda p: domain(p).update(actions=['delete', 'create']),
            'identity changed': lambda p: domain(p)['after'].update(id='other'),
            'unknown after': lambda p: domain(p).update(after_unknown={'access_policies': True}),
            'domain policy absent': lambda p: state(p).__setitem__(1, {**state(p)[1], 'address': g.PREFIX + 'aws_opensearch_domain_policy.gone'}),
            'extra inline policy': lambda p: role(p)['after']['inline_policy'].append({'name': 'extra', 'policy': DOC}),
            'inline name differs': lambda p: role(p)['after'].update(inline_policy=[{'name': 'q', 'policy': DOC}]),
            'inline value differs': lambda p: role(p)['after'].update(inline_policy=[{'name': 'p', 'policy': json.dumps({'Statement': []})}]),
            'role field': lambda p: role(p)['after'].update(max_session_duration=7200),
            'sibling drift': lambda p: p['resource_drift'].append({'address': POLICY, 'change': {'actions': ['update'], 'before': {'id': 'policy-id'}, 'after': {'id': 'policy-id'}}}),
            'other search object': lambda p: p['resource_drift'].append({'address': g.PREFIX + 'aws_iam_role.other', 'change': {'actions': ['update'], 'before': {'id': 'x'}, 'after': {'id': 'x', 'inline_policy': []}}}),
            'no change object': lambda p: p['resource_drift'][0].pop('change'),
            'data mode': lambda p: p['resource_drift'][0].update(mode='data'),
            'deposed': lambda p: p['resource_drift'][0].update(deposed='abc'),
            'wrong type': lambda p: p['resource_drift'][0].update(type='aws_iam_role'),
            'other-mode address': lambda p: p['resource_drift'][0].update(address=g.DISPOSABLE),
            'domain policy changing': lambda p: change(p, POLICY).update(actions=['update']),
            'role policy deleted': lambda p: change(p, ROLE_POLICY).update(actions=['delete']),
            'null sibling values': lambda p: next(r for r in state(p) if r['address'] == POLICY).update(values=None),
            'after lacks field': lambda p: domain(p)['after'].pop('access_policies'),
            'domain replaced': lambda p: change(p, g.PROTECTED).update(actions=['delete', 'create']),
            'marker flipped': lambda p: change(p, g.MARKER)['after'].update(input=True),
        }
        for name, mutate in cases.items():
            p = sibling_plan(); mutate(p)
            with self.subTest(case=name), self.assertRaises(g.SearchModeError): g.admit(p)


SESSIONS = g.PREFIX + 'aws_iam_role_policy.sessions_read["indexer"]'
SESSIONS_DOC = json.dumps({'Version': '2012-10-17', 'Statement': [{'Effect': 'Allow', 'Action': ['s3:GetObject'], 'Resource': 'arn:aws:s3:::b/*'}]})


def creation(address):
    return {'address': address, 'mode': 'managed', 'type': 'aws_iam_role_policy', 'change': {'actions': ['create'], 'before': None, 'after': {'id': None}, 'after_unknown': {'id': True}}}


def adding_sessions_read():
    """The first plan once sessions_bucket_read is set on existing enrolled state."""
    p = sibling_plan()
    p['resource_changes'] += [creation(SESSIONS), creation(SESSIONS.replace('indexer', 'reader'))]
    return p


def after_sessions_read():
    """The next plan: the role reads back both inline policies, its state holding one."""
    p = sibling_plan()
    values = {'id': 'role:s', 'name': 's', 'policy': SESSIONS_DOC}
    state(p).append({'address': SESSIONS, 'mode': 'managed', 'type': 'aws_iam_role_policy', 'values': values})
    p['resource_changes'].append({'address': SESSIONS, 'mode': 'managed', 'type': 'aws_iam_role_policy', 'change': {'actions': ['no-op'], 'before': values, 'after': values, 'after_unknown': {}}})
    drift = p['resource_drift'][1]['change']
    drift['before']['inline_policy'] = [{'name': 'p', 'policy': DOC}]
    drift['after']['inline_policy'] = [{'name': 's', 'policy': SESSIONS_DOC}, {'name': 'p', 'policy': SAME_DOC}]
    return p


class SessionsRead(unittest.TestCase):
    def inline(self, p): return p['resource_drift'][1]['change']['after']['inline_policy']

    def test_adding_the_sibling_policy_to_existing_state_is_admitted(self):
        self.assertEqual(g.admit(adding_sessions_read()), 'enrolled')

    def test_the_following_plan_admits_both_inline_policies(self):
        self.assertEqual(g.admit(after_sessions_read()), 'enrolled')

    def test_adding_the_sibling_holds_with_any_domain_or_marker_change(self):
        for address, actions in [(g.PROTECTED, ['delete', 'create']), (g.MARKER, ['update']), (POLICY, ['delete'])]:
            p = adding_sessions_read(); change(p, address)['actions'] = actions
            with self.subTest(address=address), self.assertRaises(g.SearchModeError): g.admit(p)

    def test_unenrolled_state_must_enroll_before_adding_the_sibling(self):
        p = fixture(mode=False, enrolled=False); p['resource_changes'].append(creation(SESSIONS))
        with self.assertRaises(g.SearchModeError): g.admit(p)

    def test_read_back_must_match_every_managed_policy_exactly(self):
        cases = {
            'second policy missing': lambda p: self.inline(p).pop(0),
            'unmanaged third policy': lambda p: self.inline(p).append({'name': 'extra', 'policy': DOC}),
            'duplicate name': lambda p: self.inline(p).__setitem__(0, {'name': 'p', 'policy': DOC}),
            'name differs': lambda p: self.inline(p)[0].update(name='other'),
            'document differs': lambda p: self.inline(p)[0].update(policy=DOC),
            'malformed entry': lambda p: self.inline(p).__setitem__(0, 'extra'),
            'sibling changing': lambda p: change(p, SESSIONS).update(actions=['update']),
            'sibling deleted': lambda p: change(p, SESSIONS).update(actions=['delete']),
            'sibling not managed here': lambda p: state(p).pop(),
            'null sibling values': lambda p: next(r for r in state(p) if r['address'] == SESSIONS).update(values=None),
            'sibling own drift': lambda p: p['resource_drift'].append({'address': SESSIONS, 'change': {'actions': ['update'], 'before': {'id': 'role:s'}, 'after': {'id': 'role:s'}}}),
        }
        for name, mutate in cases.items():
            p = after_sessions_read(); mutate(p)
            with self.subTest(case=name), self.assertRaises(g.SearchModeError): g.admit(p)

    def test_unmanaged_read_back_holds_while_no_sibling_exists(self):
        p = sibling_plan(); self.inline(p).append({'name': 's', 'policy': SESSIONS_DOC})
        with self.assertRaises(g.SearchModeError): g.admit(p)


if __name__ == '__main__': unittest.main()
