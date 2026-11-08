"""Pure saved-plan admission for the two known AWS roots' module.search.

Consumes native `show -json SAVED_PLAN`, never test UI output or caller mode
assertions. This is plan-history validation, not backend or operator attestation.
"""
import re

PREFIX = 'module.search.'
PROTECTED = PREFIX + 'aws_opensearch_domain.this[0]'
LEGACY = PREFIX + 'aws_opensearch_domain.this'
DISPOSABLE = PREFIX + 'aws_opensearch_domain.disposable[0]'
MARKER = PREFIX + 'terraform_data.creation_mode'
DOMAINS = {PROTECTED, LEGACY, DISPOSABLE}


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
        require(previous is None or (address == PROTECTED and previous == LEGACY), 'unsupported moved address')
        scoped[address] = row
    for row in prior:
        if row.get('type') == 'aws_opensearch_domain':
            require(row['address'] in DOMAINS and row.get('mode') == 'managed', 'unsupported prior domain address')
    drift = plan.get('resource_drift', [])
    require(isinstance(drift, list), 'malformed drift inventory')
    require(all(isinstance(r, dict) and isinstance(r.get('address'), str) and not r['address'].startswith(PREFIX) for r in drift), 'search drift requires reconciliation')
    domain_changes = [a for a in scoped if a in DOMAINS]
    domain_state = [a for a in scoped_state if a in DOMAINS]
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
        require(MARKER not in scoped_state, 'marker without domain is not fresh enrollment')
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
