import copy
import datetime as dt
import json
import unittest
from contract import ADDRESSES, BINDINGS, CONTEXT_KEYS, DOMAIN, POLICY, MARKER, caller, changes, context, domain_name, expected_tags, identities, native_error, _configuration_changes

def inputs():
    return {'account_id': '111111111111', 'region': 'us-west-2', 'pippen': {'agent': 'synthetic-agent', 'session_id': '00000000-0000-4000-8000-000000000000'}, 'source_sha': '0'*40, 'vpc_id': 'vpc-synthetic', 'subnet_ids': ['subnet-synthetic'], 'domain_security_group_id': 'sg-domain', 'client_security_group_ids': ['sg-client'], 'engine_version': 'OpenSearch_2.19', 'roles': {'admin': 'arn:aws:iam::111111111111:role/runtime/admin', 'indexer': 'arn:aws:iam::111111111111:role/runtime/indexer', 'reader': 'arn:aws:iam::111111111111:role/runtime/reader'}, 'approved_tag_keys': ['pippen:sandbox','pippen:agent','pippen:session','proof:source','Environment','EnvironmentClass','ManagedBy']}

def packet():
    return {k: ('0'*40 if k == 'source_commit' else '1'*64) for k in BINDINGS.values()}

def inherited(v, p):
    return {**{k: p[value] for k, value in BINDINGS.items()}, 'profile': 'search-control-v1', 'mode': 'trusted-proof-operator', 'approval_id': '11111111-1111-4111-8111-111111111111', 'approval_fingerprint': 'a'*64, 'profile_expires_at': '2099-01-01T00:00:00.000Z', 'agent_id': v['pippen']['agent'], 'account_id': v['account_id'], 'session_id': v['pippen']['session_id'], 'region': v['region']}

def create_plan(v):
    name = domain_name(v['pippen']['session_id']); tags = expected_tags(v)
    d = {'domain_name': name, 'engine_version': v['engine_version'], 'tags': tags, 'tags_all': tags, 'vpc_options': [{'subnet_ids': v['subnet_ids'], 'security_group_ids': [v['domain_security_group_id']]}], 'advanced_security_options': [{'enabled': True, 'anonymous_auth_enabled': False, 'internal_user_database_enabled': False, 'master_user_options': [{'master_user_arn': v['roles']['admin']}]}], 'encrypt_at_rest': [{'enabled': True}], 'node_to_node_encryption': [{'enabled': True}], 'domain_endpoint_options': [{'enforce_https': True, 'tls_security_policy': 'Policy-Min-TLS-1-2-PFS-2023-10'}], 'cluster_config': [{'instance_type': 't3.small.search', 'instance_count': 1, 'dedicated_master_enabled': False, 'multi_az_with_standby_enabled': False}], 'ebs_options': [{'volume_size': 20, 'volume_type': 'gp3'}], 'log_publishing_options': [], 'advanced_options': {}}
    policy = {'Version': '2012-10-17', 'Statement': [{'Sid': 'AllowListedPrincipals', 'Effect': 'Allow', 'Action': 'es:ESHttp*', 'Principal': {'AWS': list(v['roles'].values())}, 'Resource': f"arn:aws:es:{v['region']}:{v['account_id']}:domain/{name}/*"}]}
    return {'format_version': '1.2', 'resource_changes': [{'address': address, 'mode': 'managed', 'type': ('aws_opensearch_domain' if address == DOMAIN else ('aws_opensearch_domain_policy' if address == POLICY else 'terraform_data')), 'change': {'actions': ['create'], 'before': None, 'after': after}} for address, after in [(DOMAIN, d), (POLICY, {'domain_name': name, 'access_policies': json.dumps(policy)}), ('terraform_data.guard', {'input': {'disposable': True}}), (MARKER, {'input': True})]]}


def destroy_plan(v, ledger):
    before = {DOMAIN: {'id':'synthetic-domain-id', 'domain_name':ledger['domain_name'], 'arn':ledger['domain_arn'], 'tags':expected_tags(v)}, POLICY:{'id':'synthetic-policy-id','domain_name':ledger['domain_name']}, 'terraform_data.guard':{'id':'guard-id','input':{'disposable':True}}, MARKER:{'id':'mode-id','input':True,'output':True}}
    rows = [{'address':a,'mode':'managed','type':('aws_opensearch_domain' if a == DOMAIN else ('aws_opensearch_domain_policy' if a == POLICY else 'terraform_data')),'values':value} for a,value in before.items()]
    return {'format_version':'1.2','prior_state':{'values':{'root_module':{'resources':[r for r in rows if r['address']=='terraform_data.guard'],'child_modules':[{'address':'module.search','resources':[r for r in rows if r['address']!='terraform_data.guard']}]}}},'resource_changes':[{**{k:v for k,v in r.items() if k!='values'},'change':{'actions':['delete'],'before':r['values'],'after':None,'after_unknown':{}}} for r in rows]}


class Contracts(unittest.TestCase):
    def setUp(self): self.v=inputs(); self.p=packet(); self.c=inherited(self.v,self.p)

    def test_closed_context_and_all_original_hashes(self):
        self.assertEqual(set(self.c), CONTEXT_KEYS)
        context(json.dumps(self.c),self.p,self.v)
        for key in BINDINGS:
            altered={**self.c,key:'f'*(40 if key=='source_commit' else 64)}
            with self.subTest(key=key), self.assertRaises(RuntimeError):context(json.dumps(altered),self.p,self.v)
        for delta in [{'credentials': {}},{'profile':'other'},{'agent_id':'foreign'},{'account_id':'222222222222'},{'region':'us-east-1'},{'profile_expires_at':'2000-01-01T00:00:00.000Z'}]:
            with self.subTest(delta=delta),self.assertRaises(RuntimeError):context(json.dumps({**self.c,**delta}),self.p,self.v)

    def test_cleanup_keeps_original_server_scope_not_destroy_hash(self):
        context(json.dumps(self.c),self.p,self.v)
        destroy={**self.p,'plan_sha256':'d'*64,'backend_state_sha256':'e'*64}
        with self.assertRaisesRegex(RuntimeError,'ORIGINAL'):context(json.dumps(self.c),destroy,self.v)

    def test_fresh_identity_cannot_use_cached_common_plan_caller(self):
        caller({'Account':self.v['account_id'],'Arn':identities(self.v)['control']},self.v,'control')
        for arn in [identities(self.v)['common'], identities(self.v)['control']+'-foreign']:
            with self.assertRaises(RuntimeError):caller({'Account':self.v['account_id'],'Arn':arn},self.v,'control')

    def test_actual_product_shape_accepts_fresh_domain_policy_only(self):
        changes(create_plan(self.v),self.v)
        for mutation in ['iam','replace','public','capacity','metadata','master','plaintext','logs']:
            p=create_plan(self.v);d=p['resource_changes'][0]['change']['after']
            if mutation=='iam':p['resource_changes'].append({'mode':'managed','address':'aws_iam_role.forbidden','change':{'actions':['create']}})
            if mutation=='replace':p['resource_changes'][0]['change']['actions']=['delete','create']
            if mutation=='capacity':d['cluster_config'][0]['instance_count']=3
            if mutation=='metadata':d['tags']={**d['tags'],'extra':'unapproved'}
            if mutation=='master':d['advanced_security_options'][0]['master_user_options'][0]['master_user_arn']=self.v['roles']['reader']
            if mutation=='plaintext':d['domain_endpoint_options'][0]['enforce_https']=False
            if mutation=='logs':d['log_publishing_options']=[{'log_type':'AUDIT_LOGS'}]
            if mutation=='public':
                policy=json.loads(p['resource_changes'][1]['change']['after']['access_policies']);policy['Statement'][0]['Principal']={'AWS':['*']};p['resource_changes'][1]['change']['after']['access_policies']=json.dumps(policy)
            with self.subTest(mutation=mutation),self.assertRaises(RuntimeError):changes(p,self.v)

    def test_native_ui_configuration_does_not_establish_saved_plan_history(self):
        plan=create_plan(self.v);plan.pop('format_version')
        _configuration_changes(plan,self.v)
        with self.assertRaisesRegex(RuntimeError,'saved-plan JSON format'):changes(plan,self.v)

    def test_configuration_requires_known_disposable_boolean_literals(self):
        for target in [MARKER,'terraform_data.guard']:
            for value in [False,1,None,'true']:
                p=create_plan(self.v)
                row=next(r for r in p['resource_changes'] if r['address']==target)
                if target==MARKER:row['change']['after']['input']=value
                else:row['change']['after']['input']['disposable']=value
                with self.subTest(target=target,value=value),self.assertRaises(RuntimeError):_configuration_changes(p,self.v)
                with self.assertRaises(RuntimeError):changes(p,self.v)
            p=create_plan(self.v);row=next(r for r in p['resource_changes'] if r['address']==target)
            row['change']['after_unknown']={'input':True if target==MARKER else {'disposable':True}}
            with self.assertRaises(RuntimeError):_configuration_changes(p,self.v)

    def test_destroy_requires_exact_owned_full_delete_only(self):
        ledger={'domain_name':domain_name(self.v['pippen']['session_id']),'domain_arn':'arn:aws:es:us-west-2:111111111111:domain/'+domain_name(self.v['pippen']['session_id'])}
        p=destroy_plan(self.v,ledger)
        changes(p,self.v,True,ledger)
        for actions in [['update'],['create'],['delete','create']]:
            broken=copy.deepcopy(p);broken['resource_changes'][0]['change']['actions']=actions
            with self.assertRaises(RuntimeError):changes(broken,self.v,True,ledger)
        p['resource_changes'].pop()
        with self.assertRaises(RuntimeError):changes(p,self.v,True,ledger)

    def test_native_absence_operation_class_not_nested_credentials(self):
        self.assertTrue(native_error('An error occurred (ResourceNotFoundException) when calling the DescribeDomain operation','DescribeDomain','ResourceNotFoundException'))
        self.assertFalse(native_error('An error occurred (ResourceNotFoundException) when calling the AssumeRole operation','DescribeDomain','ResourceNotFoundException'))
        self.assertFalse(native_error('AccessDenied','DescribeDomain','ResourceNotFoundException'))

if __name__ == '__main__': unittest.main()
