"""Pure saved-plan admission for the two known AWS roots' module.search.

Consumes native `show -json SAVED_PLAN`, never test UI output or caller mode
assertions. This is plan-history validation, not backend or operator attestation.
"""
import json
import re

PREFIX = 'module.search.'
PROTECTED = PREFIX + 'aws_opensearch_domain.this[0]'
LEGACY = PREFIX + 'aws_opensearch_domain.this'
DISPOSABLE = PREFIX + 'aws_opensearch_domain.disposable[0]'
MARKER = PREFIX + 'terraform_data.creation_mode'
DOMAINS = {PROTECTED, LEGACY, DISPOSABLE}
DOMAIN_POLICY = PREFIX + 'aws_opensearch_domain_policy.this[0]'
# The policy's pre-`enabled` address; the module's moved block maps it to DOMAIN_POLICY.
LEGACY_DOMAIN_POLICY = PREFIX + 'aws_opensearch_domain_policy.this'
DOMAIN_POLICIES = (DOMAIN_POLICY, LEGACY_DOMAIN_POLICY)
# The only reviewed moved blocks: new address -> previous address.
MOVES = {PROTECTED: LEGACY, DOMAIN_POLICY: LEGACY_DOMAIN_POLICY}
WORKLOAD_ROLE = re.compile(re.escape(PREFIX) + r'aws_iam_role\.workload\["([^"]+)"\]')
# Inline policies a workload role may read back, each its own managed resource.
# The first is mandatory; the second exists only when sessions_bucket_read is set.
ROLE_POLICIES = ('workload', 'sessions_read')


class SearchModeError(ValueError):
    pass


def require(value, message):
    if not value:
        raise SearchModeError('Search mode HOLD: ' + message)


def _resources(module, address=""):
    require(isinstance(module, dict), 'malformed state module')
    rows, children = module.get('resources', []), module.get('child_modules', [])
    require(isinstance(rows, list) and isinstance(children, list), 'incomplete state resource/module arrays')
    result = []
    for row in rows:
        require(isinstance(row, dict) and isinstance(row.get('address'), str), 'malformed state resource')
        prefix = address + '.' if address else ''
        require(row['address'].startswith(prefix) and not row['address'][len(prefix):].startswith('module.'), 'resource outside its native state module')
        result.append(row)
    for child in children:
        require(isinstance(child, dict) and isinstance(child.get('address'), str) and child['address'].startswith((address + '.' if address else '') + 'module.'), 'unknown native child module')
        result.extend(_resources(child, child['address']))
    return result


def _id(values):
    require(isinstance(values, dict) and isinstance(values.get('id'), str) and values['id'], 'unknown native before ID')
    return values['id']


def _mode(values):
    require(isinstance(values, dict) and type(values.get('input')) is bool, 'unknown stored/requested marker input')
    return values['input']


def _canonical(value):
    """Compare IAM documents as AWS returns them: key order and one-item lists do not matter."""
    if isinstance(value, dict):
        return {k: _canonical(v) for k, v in sorted(value.items())}
    if isinstance(value, list):
        items = sorted((_canonical(v) for v in value), key=lambda v: json.dumps(v, sort_keys=True))
        return items[0] if len(items) == 1 else items
    return value


def _same_document(left, right):
    try:
        return isinstance(left, str) and isinstance(right, str) and _canonical(json.loads(left)) == _canonical(json.loads(right))
    except (ValueError, RecursionError):
        return False


def _sibling_written_drift(row, state, changes):
    """True only for a field written by a separate managed resource that is not changing.

    Terraform reports these attributes as drift after create, because the domain or
    role reads back what the sibling attached. The control is the sibling itself: an
    out-of-band edit makes the sibling report its own drift, which is never admitted.
    The value comparison only ties the field to the sibling's refreshed read; it does
    not prove the value matches the configuration.
    """
    change, address = row.get('change'), row['address']
    if row.get('mode') != 'managed' or 'deposed' in row or not isinstance(change, dict) or change.get('actions') != ['update'] or change.get('after_unknown'):
        return False
    before, after = change.get('before'), change.get('after')
    if not isinstance(before, dict) or not isinstance(after, dict) or not before.get('id') or before.get('id') != after.get('id'):
        return False
    changed = {key for key in set(before) | set(after) if before.get(key) != after.get(key)}
    role = WORKLOAD_ROLE.fullmatch(address)
    domain_policy = address in (PROTECTED, DISPOSABLE) and changed == {'access_policies'} and row.get('type') == 'aws_opensearch_domain'
    if domain_policy:
        names = [name for name in DOMAIN_POLICIES if name in state]
        if len(names) != 1:
            return False
    elif role and changed == {'inline_policy'} and row.get('type') == 'aws_iam_role':
        required, *optional = [PREFIX + 'aws_iam_role_policy.' + kind + '["' + role.group(1) + '"]' for kind in ROLE_POLICIES]
        names = [required] + [name for name in optional if name in state]
    else:
        return False
    own = state.get(address)
    if not isinstance(own, dict) or own.get('type') != row['type']:
        return False
    siblings = []
    for name in names:
        sibling = state.get(name)
        # Under the reviewed moved block the recorded policy plans at its new address.
        planned = changes.get(name) or (changes.get(DOMAIN_POLICY) if domain_policy else None)
        if not isinstance(sibling, dict) or sibling.get('mode') != 'managed':
            return False
        if not isinstance(planned, dict) or not isinstance(planned.get('change'), dict) or planned['change'].get('actions') != ['no-op']:
            return False
        if not isinstance(sibling.get('values'), dict):
            return False
        siblings.append(sibling['values'])
    if domain_policy:
        return _same_document(after.get('access_policies'), siblings[0].get('access_policies'))
    inline = after.get('inline_policy')
    if not isinstance(inline, list) or len(inline) != len(siblings) or not all(isinstance(entry, dict) for entry in inline):
        return False
    documents = {entry.get('name'): entry.get('policy') for entry in inline}
    return len(documents) == len(siblings) and all(values.get('name') in documents and _same_document(documents[values.get('name')], values.get('policy')) for values in siblings)


def _failed_create_retry(scoped, scoped_state, domain, d, m):
    """Admit the retry of a first apply that recorded the marker but never created the domain.

    The marker has no dependencies, so a first apply whose domain create fails (for
    example, a missing OpenSearch service-linked role) still records it alongside the
    roles, policies, log groups and Pod Identity associations. The retry is admitted
    only when it finishes that same fresh creation: the domain is created in the
    branch the stored marker names, the marker is an exact no-op, and every other
    search object is either unchanged or newly created. The domain policy depends on
    the domain, so its presence in prior state means the domain once existed; that
    lost-domain history still holds. Before IDs were already matched to prior state.
    """
    require(MARKER in scoped_state and not any(a in scoped_state for a in DOMAINS), 'retry requires a recorded marker and no prior domain')
    require(not any(p in scoped_state for p in DOMAIN_POLICIES), 'marker without domain is not fresh enrollment: the domain policy shows a domain existed')
    require(isinstance(d.get('after'), dict) and d['actions'] == ['create'], 'failed-create retry must create the domain')
    require(m['actions'] == ['no-op'], 'marker without domain is not fresh enrollment: the marker must be unchanged')
    stored = _mode(scoped_state[MARKER]['values'])
    require(_mode(m.get('before')) == stored and _mode(m.get('after')) == stored and _id(m.get('after')) == _id(m.get('before')), 'marker identity or mode changed')
    require(stored == (domain == DISPOSABLE), 'stored marker and retried domain mode disagree')
    require(all(r['change']['actions'] in (['no-op'], ['create']) for r in scoped.values()), 'failed-create retry may only create missing search objects')
    require(all(r['change']['actions'] == ['no-op'] for a, r in scoped.items() if a in scoped_state), 'failed-create retry cannot change recorded search objects')
    return 'fresh-retry'


def _disabled(scoped, scoped_state):
    """Admit a root that does not create search (module enabled = false).

    Only the unindexed local marker may exist: no domain, domain policy, role,
    log group or association is planned or recorded. A domain that once existed
    is never admitted here: its removal plans a delete and takes the domain path.
    The marker is created once or stays an exact no-op, so a later enablement
    is admitted as the reviewed fresh-retry.
    """
    require(set(scoped) <= {MARKER} and set(scoped_state) <= {MARKER}, 'search-disabled plan must not plan or retain any search object besides the marker')
    if MARKER not in scoped:
        require(MARKER not in scoped_state, 'lost marker')
        return 'search-disabled'
    m = scoped[MARKER]['change']
    require(scoped[MARKER].get('type') == 'terraform_data' and isinstance(m.get('after_unknown', {}), dict) and m.get('after_unknown', {}).get('input', False) is False, 'unknown marker input')
    if MARKER in scoped_state:
        stored = _mode(scoped_state[MARKER]['values'])
        require(m['actions'] == ['no-op'] and scoped[MARKER].get('previous_address') is None, 'marker replacement/update/removal is forbidden')
        require(_mode(m.get('before')) == stored and _mode(m.get('after')) == stored and _id(m.get('before')) == _id(scoped_state[MARKER].get('values')) and _id(m.get('after')) == _id(m.get('before')), 'marker identity or mode changed')
    else:
        require(m['actions'] == ['create'] and m.get('before') is None, 'search-disabled marker must be created or unchanged')
        _mode(m.get('after'))
    return 'search-disabled'


def admit(plan):
    """Return a qualified history classification; raise on ambiguous history.

    No path, mode, digest, skip, or enrollment-approval argument is accepted.
    Only the exact module.search path used by aws-environments/aws-search-proof
    is supported. Fresh native plans may omit prior_state; null is malformed.
    """
    require(isinstance(plan, dict) and isinstance(plan.get('format_version'), str) and re.fullmatch(r'1\.[0-9]+', plan['format_version']), 'unsupported saved-plan JSON format')
    for key, expected in [('errored', False), ('complete', True)]:
        require(key not in plan or plan[key] is expected, 'errored/incomplete plan')
    require('deferred_changes' not in plan or (isinstance(plan['deferred_changes'], list) and not plan['deferred_changes']), 'deferred/unknown work')
    changes = plan.get('resource_changes')
    require(isinstance(changes, list), 'missing resource_changes')
    prior = []
    if 'prior_state' in plan:
        state = plan['prior_state']
        require(isinstance(state, dict) and isinstance(state.get('values'), dict), 'missing/incomplete prior_state values')
        require('format_version' not in state or (isinstance(state['format_version'], str) and re.fullmatch(r'1\.[0-9]+', state['format_version'])), 'unsupported native prior_state format')
        values = state['values']
        if 'root_module' in values:
            prior = _resources(values['root_module'])
    all_state = {}
    for row in prior:
        address = row['address']
        require(address not in all_state, 'duplicate prior-state address')
        if address.startswith(PREFIX):
            require(row.get('mode') in ['managed', 'data'] and 'deposed' not in row, 'unknown/deposed prior search object')
            if address in DOMAINS:
                require(row.get('type') == 'aws_opensearch_domain', 'incorrect prior domain type')
            if address == MARKER:
                require(row.get('type') == 'terraform_data', 'incorrect prior marker type')
        all_state[address] = row
    scoped_state = {a: r for a, r in all_state.items() if a.startswith(PREFIX) and r.get('mode') == 'managed'}
    scoped = {}
    for row in changes:
        require(isinstance(row, dict) and isinstance(row.get('address'), str), 'malformed resource change')
        address = row['address']
        if row.get('type') == 'aws_opensearch_domain' or address.startswith(PREFIX + 'aws_opensearch_domain.'):
            require(address in DOMAINS and row.get('mode') == 'managed' and row.get('type') == 'aws_opensearch_domain', 'unsupported domain address/type/mode')
        if address.startswith(PREFIX):
            require(row.get('mode') in ['managed', 'data'], 'unknown search change mode')
        if not address.startswith(PREFIX) or row.get('mode') != 'managed':
            continue
        require(address not in scoped and 'deposed' not in row, 'duplicate/deposed search change')
        change = row.get('change')
        require(isinstance(change, dict) and isinstance(change.get('actions'), list), 'malformed search change')
        require(change.get('importing') is None, 'import/adoption is not mode enrollment')
        previous = row.get('previous_address')
        require(previous is None or MOVES.get(address) == previous, 'unsupported moved address')
        scoped[address] = row
    for row in prior:
        if row.get('type') == 'aws_opensearch_domain':
            require(row['address'] in DOMAINS and row.get('mode') == 'managed', 'unsupported prior domain address')
    drift = plan.get('resource_drift', [])
    require(isinstance(drift, list), 'malformed drift inventory')
    require(all(isinstance(r, dict) and isinstance(r.get('address'), str) and (not r['address'].startswith(PREFIX) or _sibling_written_drift(r, all_state, scoped)) for r in drift), 'search drift requires reconciliation')
    domain_changes = [a for a in scoped if a in DOMAINS]
    domain_state = [a for a in scoped_state if a in DOMAINS]
    if not domain_changes and not domain_state:
        return _disabled(scoped, scoped_state)
    require(len(domain_changes) == 1 and len(domain_state) <= 1 and MARKER in scoped, 'mixed/lost/missing domain or marker')
    domain = domain_changes[0]
    require(domain != LEGACY, 'legacy configuration must use the reviewed moved block')
    d = scoped[domain]['change']; m = scoped[MARKER]['change']
    unknown = m.get('after_unknown', {})
    require(isinstance(unknown, dict) and unknown.get('input', False) is False, 'unknown marker input')
    require(scoped[domain].get('type') == 'aws_opensearch_domain' and scoped[MARKER].get('type') == 'terraform_data', 'incorrect native resource types')

    # Match native before IDs to the complete native prior-state inventory.
    # Engines may present a moved prior object at its old or its new address.
    matched = set()
    for address, row in scoped.items():
        before = row['change'].get('before')
        candidates = [a for a in {address, row.get('previous_address')} if a in scoped_state]
        if before is None:
            require(row['change']['actions'] == ['create'] and not candidates, 'lost before object or conflicting creation')
            continue
        require(len(candidates) == 1, 'before object missing/ambiguous in prior_state')
        old = candidates[0]
        require(old not in matched and _id(before) == _id(scoped_state[old].get('values')), 'before ID differs from prior_state')
        matched.add(old)
        if address == MARKER:
            require(_mode(before) == _mode(scoped_state[old]['values']), 'stored marker before differs from prior_state')
    require(matched == set(scoped_state), 'prior search objects missing from changes')

    if not domain_state:
        if MARKER in scoped_state:
            return _failed_create_retry(scoped, scoped_state, domain, d, m)
        require(isinstance(d.get('after'), dict), 'unknown fresh domain')
        require(d['actions'] == ['create'] and m['actions'] == ['create'], 'fresh enrollment must create both domain and marker')
        require(all(r['change']['actions'] == ['create'] for r in scoped.values()), 'fresh state cannot adopt old search objects')
        wanted = _mode(m.get('after'))
        require(wanted == (domain == DISPOSABLE), 'fresh marker/domain mode mismatch')
        return 'fresh'

    old_domain = domain_state[0]
    old_mode = old_domain == DISPOSABLE
    require(domain == (DISPOSABLE if old_mode else PROTECTED), 'legacy/existing domain mode changed')
    if MARKER not in scoped_state:
        require(m['actions'] == ['create'] and _mode(m.get('after')) == old_mode, 'wrong-mode legacy enrollment')
        require(all(a == MARKER or r['change']['actions'] == ['no-op'] for a, r in scoped.items()), 'legacy enrollment must leave every AWS search object unchanged')
        require(_id(d.get('after')) == _id(d.get('before')), 'legacy domain ID changed')
        return 'legacy-or-missing-marker unchanged-domain'

    require(_mode(scoped_state[MARKER]['values']) == old_mode, 'stored marker and prior domain mode disagree')
    if d['actions'] == ['delete']:
        require(old_mode and m['actions'] == ['delete'], 'only full disposable teardown may remove marker/domain')
        require(all(r['change']['actions'] == ['delete'] for r in scoped.values()), 'disposable teardown leaves search objects alive')
        return 'destroy'
    require(m['actions'] == ['no-op'], 'marker replacement/update/removal is forbidden')
    require(_mode(m.get('after')) == old_mode and _id(m.get('after')) == _id(m.get('before')), 'marker identity or mode changed')
    require(d['actions'] in [['no-op'], ['update']] and _id(d.get('after')) == _id(d.get('before')), 'domain replacement/lost identity requires separate review')
    return 'enrolled'
