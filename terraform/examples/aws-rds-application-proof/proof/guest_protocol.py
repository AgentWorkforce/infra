"""Closed trusted host dialogue. No subprocess/AWS/credential lookup on import.

IO implementations carry private values only in memory/stdin. This state machine
is not remote execution authority, an IAM fence or an untrusted guest sandbox.
"""
import json
import re
import secrets
import uuid
from secret_io import SecretIoError

CONTRACT='rds-activation/v1'
ROLE=r'[a-z_][a-z0-9_]{0,62}'
FRESH_CHECKS=['wrong_hostname_tls_refused','wrong_ca_tls_refused','activation_run','committed_bootstraps','migrate_and_idempotent_rerun','driver_verify','exact_persisted_version_fresh_tls_readiness']
RESTORED_CHECKS=['wrong_hostname_tls_refused','wrong_ca_tls_refused','seed_version_fresh_tls_readiness_BEFORE_bootstrap_or_rotation','activation_already_activated','committed_bootstraps','migrate_and_idempotent_rerun','rotate_self','old_runtime_password_exact_28P01','driver_verify','exact_persisted_version_fresh_tls_readiness']
def require(v,code):
    if not v:raise SecretIoError(code)

def sealed_receipt(value,scope,checks):
    require(isinstance(value,dict) and set(value)=={'format','scope','ok','phase','checks','errorCodes','evidenceSha256','infrastructureRetired','requiresInstanceRetirement'},'guest_receipt_shape')
    require(value['format']=='rds-activation-guest-v1' and value['scope']==scope and value['ok'] is True and value['phase']=='sql_verified_awaiting_parent_retirement','guest_receipt_scope')
    require(value['checks']==checks and value['errorCodes']==[] and value['infrastructureRetired'] is False and value['requiresInstanceRetirement'] is True,'guest_receipt_incomplete')
    require(isinstance(value['evidenceSha256'],str) and re.fullmatch(r'[a-f0-9]{64}',value['evidenceSha256']),'guest_evidence_hash')
    if scope['phase']=='restored':require(value['evidenceSha256']==scope['restoredEvidenceSha256'],'guest_restored_catalog_changed')

def valid_passwords(value,roles):
    return isinstance(value,dict) and set(value)==set(roles) and all(isinstance(p,str) and len(p)>=32 and not re.search(r'[\r\n\0]',p) for p in value.values()) and len(set(value.values()))==len(value)

class Broker:
    """IO has deadline(), pending(step,id), restored_auth(), bootstrap(file,password),
    publish(passwords,id)->{passwords,arn,versionId}. All operations bounded.
    pending() MUST durably publish only nonsecret intent before any SQL/SM write.

    Passwords are persisted BEFORE the SQL that makes them live: after activation no
    customer-held login can reset a HoopDb role, so a lost password is unrecoverable.
    """
    def __init__(self,scope,sources,io,prior=None):
        self.scope=scope;self.sources=sources;self.io=io;self.sequence=0;self.bootstrap_index=0;self.published=None;self.result=None;self.failed=False
        self.restored=scope['phase']=='restored';self.restored_ready=not self.restored;self.chain=sources['bootstrapChain']
        require(self.restored==(prior is not None),'prior_credentials_phase')
        require(isinstance(scope['loginRoles'],list) and all(isinstance(r,str) and re.fullmatch(ROLE,r) for r in scope['loginRoles']) and len(set(scope['loginRoles']))==len(scope['loginRoles']) and scope['owner'] in scope['loginRoles'] and scope['runtimeRole'] in scope['loginRoles'] and scope['provisioner'] not in scope['loginRoles'],'login_role_set')
        if self.restored:require(valid_passwords(prior,scope['loginRoles']),'prior_credentials_shape')
        self.passwords=prior
    def expected_checks(self):return RESTORED_CHECKS if self.restored else FRESH_CHECKS
    def chain_done(self):return self.bootstrap_index==len(self.chain)
    def frame(self,line):
        require(not self.failed and self.result is None,'guest_protocol_already_complete')
        try:return self._frame(line)
        except BaseException:
            self.failed=True
            raise
    def _generate(self):
        roles=self.scope['loginRoles']
        if self.restored:
            value=dict(self.passwords);value[self.scope['runtimeRole']]=secrets.token_urlsafe(32)
            require(value[self.scope['runtimeRole']]!=self.passwords[self.scope['runtimeRole']],'runtime_entropy_collision')
        else:value={role:secrets.token_urlsafe(32) for role in roles}
        require(valid_passwords(value,roles),'generated_credentials_shape');return value
    def _frame(self,line):
        self.io.deadline();require(isinstance(line,bytes) and len(line)<=65536,'guest_frame_bound')
        def unique(pairs):
            value={}
            for key,item in pairs:
                require(key not in value,'guest_frame_duplicate_key');value[key]=item
            return value
        try:v=json.loads(line,object_pairs_hook=unique)
        except SecretIoError:raise
        except Exception:raise SecretIoError('guest_frame_json') from None
        require(isinstance(v,dict) and v.get('format')=='actual-rds-io-v2' and type(v.get('sequence')) is int and v['sequence']==self.sequence+1,'guest_frame_sequence')
        op=v.get('operation');self.sequence=v['sequence'];answer={'format':'actual-rds-io-v2','sequence':self.sequence,'ok':True}
        if op=='restored-auth':
            require(set(v)=={'format','sequence','operation'} and self.restored and not self.restored_ready and self.bootstrap_index==0 and self.published is None,'restore_auth_order')
            self.io.restored_auth();self.restored_ready=True
        elif op=='bootstrap':
            require(self.restored_ready,'restore_auth_before_mutation')
            # Fresh: passwords are durable before the role that uses them exists. Restored: the chain precedes rotation.
            require(set(v)=={'format','sequence','operation','file'} and self.bootstrap_index<len(self.chain) and (self.published is None if self.restored else self.published is not None),'bootstrap_order')
            name=self.chain[self.bootstrap_index];f=v['file']
            require(isinstance(f,dict) and set(f)=={'path','sha256'} and f['path']==name and f['sha256']==self.sources['files'].get(name),'bootstrap_payload_refused')
            self.io.pending('bootstrap',str(uuid.uuid4()));self.io.bootstrap(f,self.passwords[self.scope['owner']]);self.bootstrap_index+=1
        elif op=='credentials':
            require(self.restored_ready,'restore_auth_before_mutation')
            require(set(v)=={'format','sequence','operation'} and self.published is None and (self.chain_done() if self.restored else self.bootstrap_index==0),'credentials_order')
            value=self._generate();version=str(uuid.uuid4());self.io.pending('credentials',version);self.published=self.io.publish(value,version)
            require(isinstance(self.published,dict) and set(self.published)=={'passwords','arn','versionId'} and self.published['passwords']==value and self.published['versionId']==version and self.published['arn']==self.io.runtime_secret_arn,'publication_response_mismatch')
            self.passwords=value;answer.update(passwords=value,secretRef={k:self.published[k] for k in ['arn','versionId']})
        elif op=='result':
            require(set(v)=={'format','sequence','operation','ok','receipt','checks','secretRef'} and v['ok'] is True and self.published is not None and self.chain_done(),'guest_result_refused')
            sealed_receipt(v['receipt'],self.scope,self.expected_checks())
            require(v['checks']==self.expected_checks() and v['secretRef']=={k:self.published[k] for k in ['arn','versionId']},'persisted_readiness_missing')
            self.result={k:v[k] for k in ['ok','receipt','checks','secretRef']};return b''
        else:raise SecretIoError('guest_operation_refused')
        self.io.deadline();return (json.dumps(answer)+'\n').encode()
