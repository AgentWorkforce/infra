"""Pure product guards. No credential provider, AWS SDK, network or side effects."""
import datetime as dt
import hashlib
import importlib.util
from pathlib import Path
import json
import re

PROFILE = 'search-control-v1'
MODE = 'trusted-proof-operator'
CONTEXT_KEYS = set('agent_id account_id session_id region profile mode approval_id profile_expires_at approval_fingerprint source_commit plan_sha256 inputs_sha256 provider_lock_sha256 provider_binaries_sha256 artifact_sha256 backend_state_sha256'.split())
UUID = r'[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}'
DOMAIN = 'module.search.aws_opensearch_domain.disposable[0]'
POLICY = 'module.search.aws_opensearch_domain_policy.this'
MARKER = 'module.search.terraform_data.creation_mode'
ADDRESSES = {DOMAIN, POLICY, 'terraform_data.guard', MARKER}
_MODE_SPEC = importlib.util.spec_from_file_location('search_creation_mode', Path(__file__).resolve().parents[3] / 'modules/aws/search/creation_mode.py')
_MODE = importlib.util.module_from_spec(_MODE_SPEC)
_MODE_SPEC.loader.exec_module(_MODE)
BINDINGS = {
    'source_commit': 'source_commit', 'plan_sha256': 'plan_sha256',
    'inputs_sha256': 'inputs_sha256', 'provider_lock_sha256': 'provider_lock_sha256',
    'provider_binaries_sha256': 'provider_binaries_sha256',
    'artifact_sha256': 'artifact_sha256', 'backend_state_sha256': 'backend_state_sha256',
}

def require(value, message):
    if not value: raise RuntimeError(message)

def digest(value):
    return hashlib.sha256(value).hexdigest()

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()

def domain_name(lease):
    require(re.fullmatch(UUID, lease), 'Invalid lowercase UUIDv4 lease')
    return 'pippen-sbx-' + digest(lease.encode())[:10] + '-search'

def identities(v):
    account = v['account_id']; lease = v['pippen']['session_id']
    return {
        'common': f'arn:aws:sts::{account}:assumed-role/agent-session/agent-{lease}',
        'control': f'arn:aws:sts::{account}:assumed-role/search-control-v1-{lease}/search-{lease}',
        'role': f'arn:aws:iam::{account}:role/pippen/provisioning/search-control-v1-{lease}',
    }

def expected_tags(v):
    return {'pippen:sandbox': 'true', 'pippen:agent': v['pippen']['agent'],
            'pippen:session': v['pippen']['session_id'], 'proof:source': v['source_sha'], 'Environment': 'disposable-search',
            'EnvironmentClass': 'development', 'ManagedBy': 'terraform'}

def variables(v):
    require(isinstance(v, dict) and set(v) == set('account_id region pippen source_sha approved_tag_keys vpc_id subnet_ids domain_security_group_id client_security_group_ids roles engine_version'.split()), 'Closed complete input object required; no defaults/extra operator hooks')
    require(re.fullmatch(r'[0-9]{12}', v['account_id']) and re.fullmatch(r'[a-f0-9]{40}', v['source_sha']) and re.fullmatch(r'[a-z]{2}(-[a-z]+)+-[0-9]', v['region']), 'Invalid explicit account/region/source')
    require(set(v['pippen']) == {'agent', 'session_id'} and re.fullmatch(r'[a-z0-9][a-z0-9-]{1,40}', v['pippen']['agent']), 'Invalid closed lease identity')
    domain_name(v['pippen']['session_id'])
    require(set(v['roles']) == {'admin', 'indexer', 'reader'} and len(set(v['roles'].values())) == 3, 'Distinct external identities required')
    for arn in v['roles'].values():
        require(re.fullmatch(f"arn:aws:iam::{v['account_id']}:role/[A-Za-z0-9+=,.@_/-]+", arn) and '/pippen/provisioning/' not in arn and arn not in [f"arn:aws:iam::{v['account_id']}:role/agent-session", f"arn:aws:iam::{v['account_id']}:role/pippen/agent-session"], 'Foreign or code-control/common role cannot be a data principal')
    require(1 <= len(v['subnet_ids']) <= 2 and len(set(v['subnet_ids'])) == len(v['subnet_ids']) and 1 <= len(set(v['client_security_group_ids'])) <= 3 and v['domain_security_group_id'] not in v['client_security_group_ids'], 'Bounded external subnet/client groups required')
    require(set(expected_tags(v)) <= set(v['approved_tag_keys']) and 7 <= len(v['approved_tag_keys']) <= 8 and len(set(v['approved_tag_keys'])) == len(v['approved_tag_keys']), 'Exact immutable metadata keys must be in the <=8-key approval')
    require(re.fullmatch(r'OpenSearch_[0-9]+\.[0-9]+', v['engine_version']), 'Explicit supported engine version required')

def caller(value, v, phase):
    require(value.get('Account') == v['account_id'] and value.get('Arn') == identities(v)[phase],
            'Fresh CLI caller does not match the exact account/lease/phase')

def context_provenance(raw, original, v):
    require(isinstance(raw, str) and len(raw) <= 16384, 'Missing inherited capability context')
    c = json.loads(raw)
    require(isinstance(c, dict) and set(c) == CONTEXT_KEYS and all(isinstance(x, str) for x in c.values()), 'Closed sanitized capability context required')
    require(c['profile'] == PROFILE and c['mode'] == MODE, 'Wrong capability profile/operator mode')
    require(c['agent_id'] == v['pippen']['agent'] and c['account_id'] == v['account_id'] and c['session_id'] == v['pippen']['session_id'] and c['region'] == v['region'], 'Foreign capability account/region/agent/lease')
    require(re.fullmatch(UUID, c['approval_id']) and re.fullmatch(UUID, c['session_id']), 'Invalid capability IDs')
    require(re.fullmatch(r'[a-f0-9]{40}', c['source_commit']), 'Invalid source commitment')
    require(all(re.fullmatch(r'[a-f0-9]{64}', c[k]) for k in CONTEXT_KEYS if k.endswith('_sha256') or k == 'approval_fingerprint'), 'Invalid capability digest')
    require(re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z', c['profile_expires_at']), 'Canonical immutable profile expiry required')
    dt.datetime.fromisoformat(c['profile_expires_at'].replace('Z', '+00:00')) # Validate historical timestamp without granting live authority.
    require(all(c[key] == original[binding] for key, binding in BINDINGS.items()), 'Capability does not match ORIGINAL create packet')
    return c

def context(raw, original, v, now=None):
    c = context_provenance(raw, original, v)
    expiry = dt.datetime.fromisoformat(c['profile_expires_at'].replace('Z', '+00:00'))
    now = now or dt.datetime.now(dt.timezone.utc)
    require(expiry > now, 'Profile expired; preserve state for separately approved recovery, never extend/rebind identity')
    return c

def changes(plan, v, destroy=False, ledger=None):
    try:
        history = _MODE.admit(plan)
    except _MODE.SearchModeError as exc:
        raise RuntimeError(str(exc)) from exc
    _configuration_changes(plan, v, destroy, ledger)
    return history


def _configuration_changes(plan, v, destroy=False, ledger=None):
    """Fixed product payload checks, shared with native compiler tests only.

    This private function establishes no prior-state/history or apply authority.
    Every runtime caller must use changes(), which always admits history first.
    """
    require(plan.get('errored', False) is False and plan.get('complete', True) is True, 'Errored/incomplete plan cannot be reviewed as a complete operation')
    managed = [r for r in plan.get('resource_changes', []) if r.get('mode') == 'managed']
    require(managed and all(r['address'] in ADDRESSES for r in managed), 'Unexpected managed address; no IAM/log/network authoring is allowed')
    expected_types = {DOMAIN: 'aws_opensearch_domain', POLICY: 'aws_opensearch_domain_policy', MARKER: 'terraform_data', 'terraform_data.guard': 'terraform_data'}
    require(all(r.get('type') == expected_types[r['address']] for r in managed), 'Wrong fixed product resource type')
    changed = [r for r in managed if r['change']['actions'] != ['no-op']]
    if destroy:
        require(ledger and ledger.get('domain_name') == domain_name(v['pippen']['session_id']), 'Captured exact owned domain required')
        require({r['address'] for r in changed} == ADDRESSES and all(r['change']['actions'] == ['delete'] for r in changed), 'Teardown must delete exactly the reviewed domain/policy and two builtin markers; no updates/creates/replacements')
        rows = {r['address']: r['change']['before'] for r in changed}
        require(rows[DOMAIN]['domain_name'] == ledger['domain_name'] and rows[DOMAIN]['arn'] == ledger['domain_arn'] and rows[DOMAIN]['tags'] == expected_tags(v), 'Destroy before-identity is not the captured owned domain')
        require(rows[POLICY]['domain_name'] == ledger['domain_name'], 'Foreign policy destroy')
        _disposable_inputs(rows)
        return
    require({r['address'] for r in managed} == ADDRESSES and all(r['change']['actions'] == ['create'] for r in managed), 'Creation must be fresh; no adoption/update/import/replacement')
    require(not plan.get('resource_drift') and not plan.get('deferred_changes') and not any(r['change'].get('importing') for r in managed), 'Drift/import/deferred work is not an empty-state create proof')
    rows = {r['address']: r['change']['after'] for r in managed}; d = rows[DOMAIN]
    _disposable_inputs(rows)
    for r in managed:
        if r['address'] not in {MARKER, 'terraform_data.guard'}: continue
        unknown = r['change'].get('after_unknown', {})
        require(isinstance(unknown, dict), 'Unknown fixed disposable configuration')
        input_unknown = unknown.get('input', False)
        require(input_unknown is False or (r['address'] == 'terraform_data.guard' and isinstance(input_unknown, dict) and input_unknown.get('disposable', False) is False), 'Disposable mode must be known in native configuration')
    require(d['domain_name'] == domain_name(v['pippen']['session_id']) and d['engine_version'] == v['engine_version'], 'Wrong exact domain/version')
    require(d['tags'] == expected_tags(v) and d.get('tags_all') == expected_tags(v), 'Metadata must be immutable and exact')
    require(set(expected_tags(v)) <= set(v['approved_tag_keys']) and 7 <= len(set(v['approved_tag_keys'])) <= 8, 'Tags exceed the approved closed key set')
    network = d['vpc_options']; require(len(network) == 1 and set(network[0]['subnet_ids']) == set(v['subnet_ids']) and network[0]['security_group_ids'] == [v['domain_security_group_id']], 'Wrong external network prerequisites')
    security = d['advanced_security_options']; require(len(security) == 1, 'Missing FGAC')
    security = security[0]
    require(security['enabled'] is True and security['anonymous_auth_enabled'] is False and security['internal_user_database_enabled'] is False and security['master_user_options'][0]['master_user_arn'] == v['roles']['admin'], 'Wrong explicit IAM administrator or security mode')
    require(d['encrypt_at_rest'][0]['enabled'] is True and d['node_to_node_encryption'][0]['enabled'] is True and d['domain_endpoint_options'][0]['enforce_https'] is True and d['domain_endpoint_options'][0]['tls_security_policy'] == 'Policy-Min-TLS-1-2-PFS-2023-10', 'Encryption/TLS prerequisite changed')
    cluster = d['cluster_config'][0]
    require(cluster['instance_type'] == 't3.small.search' and cluster['instance_count'] == len(v['subnet_ids']) and cluster['dedicated_master_enabled'] is False and cluster['multi_az_with_standby_enabled'] is False, 'Unbounded domain capacity')
    require(d['ebs_options'][0]['volume_size'] == 20 and d['ebs_options'][0]['volume_type'] == 'gp3' and not d.get('log_publishing_options') and not d.get('advanced_options'), 'Unexpected storage/log/advanced payload')
    p = json.loads(rows[POLICY]['access_policies']); statement = p['Statement']
    arn = f"arn:aws:es:{v['region']}:{v['account_id']}:domain/{d['domain_name']}/*"
    require(p.get('Version') == '2012-10-17' and len(statement) == 1, 'Unexpected domain policy statements')
    s = statement[0]
    require(set(s) == {'Sid', 'Effect', 'Principal', 'Action', 'Resource'} and s['Effect'] == 'Allow' and s['Action'] == 'es:ESHttp*' and s['Resource'] == arn and set(s['Principal']) == {'AWS'} and set(s['Principal']['AWS']) == set(v['roles'].values()) and len(s['Principal']['AWS']) == 3, 'Domain policy must name exactly the external admin/indexer/reader; no public/session/control grant')


def _disposable_inputs(rows):
    require(isinstance(rows[MARKER], dict) and rows[MARKER].get('input') is True, 'Mode marker must contain literal boolean true')
    guard = rows['terraform_data.guard'].get('input')
    require(isinstance(guard, dict) and guard.get('disposable') is True, 'Root configuration must contain literal disposable boolean true')


def native_error(stderr, operation, code):
    match = re.search(r'An error occurred \(([^)]+)\) when calling the ([A-Za-z0-9]+) operation', stderr)
    return bool(match and match[1] == code and match[2] == operation)
