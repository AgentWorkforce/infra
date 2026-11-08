"""F1 causal refusals: the shared-database application identities come from the
postgres-layout contract, the RDS master is never the application migrator or
runtime, and execution stays refused until a reviewed activation artifact exists."""
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch
from secret_io import SecretIoError
spec=importlib.util.spec_from_file_location('rds_host_f1',Path(__file__).with_name('verify-host.py'));h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)

def cfg(**over):
    c={'provisioning_executor':'proof_admin','forbidden_roles':['proof_admin'],
       'application':{'database':'relaycontrol','schema':'sessions','migration_role':'hoop','runtime_role':'sessions_pipeline_runtime','host':'db.example.invalid','port':5432},
       'application_activation':None}
    c.update(over);return c

def app(**over):
    a=dict(cfg()['application']);a.update(over);return a

class ApplicationIdentity(unittest.TestCase):
    def refused(self,c,code):
        with self.assertRaises(SecretIoError) as raised:h.application_identity(c)
        self.assertEqual(raised.exception.code,code)

    def test_layout_identities_refuse_without_reviewed_activation(self):
        self.refused(cfg(),'application_activation_artifact_missing')

    def test_even_a_supplied_activation_is_refused_until_the_guest_is_ported(self):
        activation={'sessions_commit':'a'*40,'artifact_sha256':'b'*64,'generation':'c'*64,'contract':'reviewed'}
        self.refused(cfg(application_activation=activation),'application_activation_not_implemented')

    def test_master_as_application_migrator_or_runtime_is_refused(self):
        self.refused(cfg(application=app(migration_role='proof_admin')),'application_binding_mismatch')
        # Even if the expected binding were changed to the master, the forbidden-role check refuses.
        with patch.dict(h.EXPECTED_APPLICATION,{'migration_role':'proof_admin'}):
            self.refused(cfg(application=app(migration_role='proof_admin')),'application_identity_is_master_or_forbidden')
        with patch.dict(h.EXPECTED_APPLICATION,{'runtime_role':'proof_admin'}):
            self.refused(cfg(application=app(runtime_role='proof_admin')),'application_identity_is_master_or_forbidden')

    def test_wrong_expected_login_or_namespace_is_refused(self):
        for change in [{'migration_role':'proof_runtime'},{'runtime_role':'proof_runtime'},{'runtime_role':'hoop'},
                       {'schema':'public'},{'schema':'relayhistory'},{'database':'applicationproof'}]:
            with self.subTest(change=change):self.refused(cfg(application=app(**change)),'application_binding_mismatch')

    def test_owner_and_runtime_must_differ(self):
        with patch.dict(h.EXPECTED_APPLICATION,{'runtime_role':'hoop'}):
            self.refused(cfg(application=app(runtime_role='hoop')),'application_owner_runtime_shared')

    def test_master_must_be_a_listed_forbidden_role(self):
        self.refused(cfg(forbidden_roles=[]),'provisioning_executor_not_forbidden')
        self.refused(cfg(forbidden_roles=['someone_else']),'provisioning_executor_not_forbidden')
        self.refused(cfg(provisioning_executor=''),'provisioning_executor_not_forbidden')

    def test_missing_binding_is_refused(self):
        self.refused(cfg(application=None),'application_binding_missing')

    def test_main_refuses_before_aws_or_followup_file_reads(self):
        # Invoke the actual entry point; calling the helper alone cannot prove
        # its position before credential/CLI work in main().
        activation={'sessions_commit':'a'*40,'artifact_sha256':'b'*64,'generation':'c'*64,'contract':'reviewed'}
        for supplied,code in [(None,'application_activation_artifact_missing'),
                              (activation,'application_activation_not_implemented')]:
            with self.subTest(supplied=supplied is not None):
                c=cfg(application_activation=supplied)
                c.update(account_id='111111111111',source_sha='a'*40,deadline='2099-01-01T00:00:00.000Z')
                reads=[]
                def read_input(path,*args,**kwargs):
                    reads.append(path.name)
                    if str(path)=='/proc/swaps':return 'Filename\tType\tSize\tUsed\tPriority\n'
                    if path.name=='inputs.json':return json.dumps(c)
                    raise AssertionError('unexpected read after refused application gate')
                with patch.object(h.platform,'system',return_value='Linux'), \
                     patch.object(h.platform,'machine',return_value='aarch64'), \
                     patch.object(h.Path,'read_text',new=read_input), \
                     patch.object(h,'cli',side_effect=AssertionError('AWS CLI must not start')) as child, \
                     patch.object(h,'run',side_effect=AssertionError('child process must not start')) as process:
                    with self.assertRaises(SecretIoError) as raised:h.main()
                self.assertEqual(raised.exception.code,code)
                self.assertEqual(reads,['swaps','inputs.json'])
                child.assert_not_called()
                process.assert_not_called()

class GuestRuntimeLogin(unittest.TestCase):
    def test_runtime_readiness_binds_session_user_not_only_current_user(self):
        # SET ROLE / role= substitution changes current_user but not session_user.
        text=Path(__file__).with_name('guest-adapter.mjs').read_text()
        self.assertIn('session_user AS login',text)
        self.assertIn('row.login===cfg.scope.runtimeRole&&row.role===cfg.scope.runtimeRole',text)

if __name__=='__main__':unittest.main()
