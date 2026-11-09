import json
import unittest
from guest_protocol import Broker,FRESH_CHECKS,RESTORED_CHECKS
from secret_io import SecretIoError

CHAIN=['supabase/bootstrap/a.sql','supabase/bootstrap/b.sql']
ROLES=['hoop','sessions_pipeline_runtime','bulls96_read_api']
class Io:
    runtime_secret_arn='arn:aws:secretsmanager:us-west-2:111111111111:secret:synthetic-runtime-abcdef'
    def __init__(self):self.events=[];self.fail=None
    def deadline(self):pass
    def pending(self,step,identifier):self.events.append(('pending',step,identifier))
    def restored_auth(self):self.events.append(('restore_auth',))
    def bootstrap(self,file,password):
        self.events.append(('bootstrap',file['path'],password))
        if self.fail=='bootstrap':raise SecretIoError('synthetic_partial_bootstrap')
    def publish(self,passwords,identifier):
        self.events.append(('publish',identifier))
        if self.fail=='publish':raise SecretIoError('synthetic_publication_timeout')
        return {'passwords':passwords,'arn':self.runtime_secret_arn,'versionId':identifier}
PRIOR={r:r+'-synthetic-prior-value-0123456789abcdef' for r in ROLES}
class Protocol(unittest.TestCase):
    def setup_broker(self,restored=False,roles=None):
        scope={'phase':'restored' if restored else 'fresh','provisioner':'proof_admin','owner':'hoop','runtimeRole':'sessions_pipeline_runtime','loginRoles':roles or ROLES}
        if restored:scope['restoredEvidenceSha256']='a'*64
        self.sources={'bootstrapChain':CHAIN,'files':{n:'1'*64 for n in CHAIN}};self.io=Io();self.b=Broker(scope,self.sources,self.io,dict(PRIOR) if restored else None)
    def send(self,operation,**fields):
        frame={'format':'actual-rds-io-v2','sequence':self.b.sequence+1,'operation':operation,**fields}
        r=self.b.frame(json.dumps(frame).encode());return json.loads(r) if r else None
    def bootstrap(self):
        for name in CHAIN:self.send('bootstrap',file={'path':name,'sha256':'1'*64})
    def receipt(self):
        return {'format':'rds-activation-guest-v1','scope':self.b.scope,'ok':True,'phase':'sql_verified_awaiting_parent_retirement','checks':self.b.expected_checks(),'errorCodes':[],'evidenceSha256':'a'*64,'infrastructureRetired':False,'requiresInstanceRetirement':True}
    def full_ready(self,restored=False):
        self.setup_broker(restored)
        if restored:
            self.send('restored-auth');self.bootstrap();self.credentials=self.send('credentials')
        else:
            self.credentials=self.send('credentials');self.bootstrap()
        return self.receipt()
    def finish(self,receipt,checks=None):
        return self.send('result',ok=True,receipt=receipt,checks=self.b.expected_checks() if checks is None else checks,secretRef=self.credentials['secretRef'])
    def test_fresh_generates_distinct_persisted_passwords_before_any_sql(self):
        receipt=self.full_ready();passwords=self.credentials['passwords']
        self.assertEqual(set(passwords),set(ROLES));self.assertEqual(len(set(passwords.values())),len(ROLES));self.assertTrue(all(len(p)>=32 for p in passwords.values()))
        kinds=[e[0] for e in self.io.events];self.assertEqual(kinds[:2],['pending','publish']);self.assertEqual(self.io.events[0][1],'credentials')
        self.finish(receipt);self.assertTrue(self.b.result['ok']);self.assertEqual(self.b.result['checks'],FRESH_CHECKS)
    def test_every_write_is_preceded_by_durable_intent(self):
        for restored in [False,True]:
            with self.subTest(restored=restored):
                self.full_ready(restored)
                for i,event in enumerate(self.io.events):
                    if event[0] in ['bootstrap','publish']:self.assertEqual(self.io.events[i-1][0],'pending')
    def test_chain_runs_as_migration_owner_password_never_provisioner(self):
        self.full_ready();owner=self.credentials['passwords']['hoop']
        self.assertTrue(all(e[2]==owner for e in self.io.events if e[0]=='bootstrap'))
    def test_restored_rotates_only_runtime_after_chain(self):
        receipt=self.full_ready(True);new=self.credentials['passwords']
        self.assertEqual([k for k in ROLES if new[k]!=PRIOR[k]],['sessions_pipeline_runtime'])
        self.assertTrue(all(e[2]==PRIOR['hoop'] for e in self.io.events if e[0]=='bootstrap'))
        self.assertEqual(self.io.events[0],('restore_auth',));self.finish(receipt);self.assertEqual(self.b.result['checks'],RESTORED_CHECKS)
    def test_restore_auth_is_required_before_any_mutation(self):
        for op in ['bootstrap','credentials']:
            self.setup_broker(True)
            with self.subTest(op=op),self.assertRaisesRegex(SecretIoError,'restore_auth_before_mutation'):
                self.bootstrap() if op=='bootstrap' else self.send('credentials')
            self.assertEqual(self.io.events,[])
    def test_fresh_bootstrap_before_credentials_refused(self):
        self.setup_broker()
        with self.assertRaisesRegex(SecretIoError,'bootstrap_order'):self.bootstrap()
        self.assertEqual(self.io.events,[])
    def test_unknown_bootstrap_and_duplicate_sequence_block_before_mutation(self):
        self.setup_broker();self.send('credentials');count=len(self.io.events)
        with self.assertRaisesRegex(SecretIoError,'bootstrap_payload'):self.send('bootstrap',file={'path':'unreviewed.sql','sha256':'1'*64})
        self.assertEqual(len(self.io.events),count)
        self.setup_broker()
        self.send('credentials')
        with self.assertRaisesRegex(SecretIoError,'sequence'):self.b.frame(json.dumps({'format':'actual-rds-io-v2','sequence':self.b.sequence,'operation':'credentials'}).encode())
        with self.assertRaisesRegex(SecretIoError,'already_complete'):self.send('credentials')
    def test_credentials_are_issued_once(self):
        self.setup_broker();self.send('credentials')
        with self.assertRaisesRegex(SecretIoError,'credentials_order'):self.send('credentials')
    def test_master_cannot_be_a_login_role(self):
        with self.assertRaisesRegex(SecretIoError,'login_role_set'):self.setup_broker(roles=ROLES+['proof_admin'])
        with self.assertRaisesRegex(SecretIoError,'login_role_set'):self.setup_broker(roles=['sessions_pipeline_runtime'])
    def test_restored_needs_complete_prior_credentials(self):
        scope={'phase':'restored','provisioner':'proof_admin','owner':'hoop','runtimeRole':'sessions_pipeline_runtime','loginRoles':ROLES,'restoredEvidenceSha256':'a'*64}
        sources={'bootstrapChain':CHAIN,'files':{}}
        partial=dict(PRIOR);partial.pop('bulls96_read_api')
        for prior,code in [(None,'prior_credentials_phase'),(partial,'prior_credentials_shape'),({**PRIOR,'hoop':PRIOR['bulls96_read_api']},'prior_credentials_shape')]:
            with self.subTest(code=code),self.assertRaisesRegex(SecretIoError,code):Broker(scope,sources,Io(),prior)
    def test_incomplete_or_changed_receipt_cannot_succeed(self):
        for mutate in ['receipt','checks','catalog']:
            receipt=self.full_ready(True);checks=self.b.expected_checks()
            if mutate=='receipt':receipt['checks']=receipt['checks'][:-1]
            if mutate=='checks':checks=checks[:-1]
            if mutate=='catalog':receipt['evidenceSha256']='b'*64
            with self.subTest(mutate=mutate),self.assertRaises(SecretIoError):self.finish(receipt,checks)
            self.assertIsNone(self.b.result)
    def test_result_requires_complete_chain_and_matching_secret(self):
        self.setup_broker();self.credentials=self.send('credentials');receipt=self.receipt()
        with self.assertRaisesRegex(SecretIoError,'guest_result_refused'):self.finish(receipt)
        receipt=self.full_ready()
        with self.assertRaisesRegex(SecretIoError,'persisted_readiness_missing'):self.send('result',ok=True,receipt=receipt,checks=self.b.expected_checks(),secretRef={'arn':'x','versionId':'y'})
        self.assertIsNone(self.b.result)
    def test_partial_sql_and_ambiguous_secret_write_leave_pending_and_quarantine(self):
        self.setup_broker();self.send('credentials');self.io.fail='bootstrap'
        with self.assertRaisesRegex(SecretIoError,'partial_bootstrap'):self.bootstrap()
        self.assertEqual(self.io.events[-2][:2],('pending','bootstrap'))
        with self.assertRaisesRegex(SecretIoError,'already_complete'):self.bootstrap()
        self.setup_broker();self.io.fail='publish'
        with self.assertRaisesRegex(SecretIoError,'publication_timeout'):self.send('credentials')
        self.assertEqual(self.io.events[-2][:2],('pending','credentials'));self.assertIsNone(self.b.published)
        with self.assertRaisesRegex(SecretIoError,'already_complete'):self.send('credentials')
    def test_duplicate_json_keys_refused_without_io(self):
        self.setup_broker()
        with self.assertRaisesRegex(SecretIoError,'duplicate_key'):self.b.frame(b'{"format":"actual-rds-io-v2","sequence":1,"sequence":2,"operation":"credentials"}')
        self.assertEqual(self.io.events,[])
if __name__=='__main__':unittest.main()
