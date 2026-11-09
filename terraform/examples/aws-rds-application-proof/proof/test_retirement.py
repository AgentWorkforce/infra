import unittest
import subprocess
from unittest.mock import patch
import retirement as r

class RetirementTests(unittest.TestCase):
    def test_external_network_is_not_checked_or_deleted(self):
        with patch.object(r,'request') as request:
            self.assertEqual(r.network_absence({'owned_network':None}),{})
            request.assert_not_called()
        with self.assertRaises(RuntimeError):r.network_absence({})
    def test_owned_network_specific_absence_and_complete_associations(self):
        contract={'private_subnet_ids':['subnet-aaa','subnet-bbb'],'owned_network':{'subnet_ids':['subnet-aaa','subnet-bbb'],'route_table_id':'rtb-aaa','route_association_ids':['rtbassoc-aaa','rtbassoc-bbb']}}
        for response,want in [(({'RouteTables':[]},None),True),(({},None),False),(({'RouteTables':[],'NextToken':'more'},None),False),((None,'AccessDenied'),False)]:
            with patch.object(r,'absent',return_value=True) as absent,patch.object(r,'request',return_value=response):
                checks=r.network_absence(contract)
                self.assertEqual(all(checks.values()),want)
                self.assertEqual(absent.call_args_list[0].args[-1],'InvalidSubnetID.NotFound')
                self.assertEqual(absent.call_args_list[2].args[-1],'InvalidRouteTableID.NotFound')
        contract['owned_network']['route_association_ids']=['rtbassoc-aaa']
        with self.assertRaises(RuntimeError):r.network_absence(contract)
    def test_nested_credential_error_is_not_target_absence(self):
        result=subprocess.CompletedProcess([],1,'','An error occurred (NoSuchEntity) when calling the AssumeRole operation')
        with patch.object(r.subprocess,'run',return_value=result),patch.object(r,'environment',return_value={}):
            with self.assertRaises(RuntimeError):r.request({'region':'us-west-2'},'iam','get-role','--role-name','synthetic')
    def test_specific_missing_only(self):
        for error,want in [('NoSuchBucket',True),('AccessDenied',False),('RequestTimeout',False)]:
            with patch.object(r,'request',return_value=(None,error)):
                self.assertEqual(r.absent({},'s3api','list-object-versions',[],'NoSuchBucket'),want)
        for value in [{},{'IsTruncated':False}]:
            with patch.object(r,'request',return_value=(value,None)):
                self.assertFalse(r.absent({},'s3api','list-object-versions',[],'NoSuchBucket'))

class RuntimeSecretInventory(unittest.TestCase):
    def test_complete_empty_and_partial_success_counts_are_valid(self):
        c={'runtime_secret':{'arn':'synthetic-owned-arn'}}
        for versions in [[],['0'*32],['0'*32,'1'*32]]:
            ledger={'runtime_secret_inventory':{'arn':'synthetic-owned-arn','version_ids':versions,'complete':True}}
            self.assertEqual(r.runtime_inventory(ledger,c),versions)
    def test_missing_truncated_foreign_or_duplicate_inventory_refuses_before_io(self):
        c={'runtime_secret':{'arn':'synthetic-owned-arn'}}
        good={'arn':'synthetic-owned-arn','version_ids':[],'complete':True}
        for changed in [None,{**good,'complete':False},{**good,'NextToken':'more'},{**good,'arn':'foreign-arn'},{**good,'version_ids':['0'*32,'0'*32]},{**good,'version_ids':['bad']}]:
            ledger={'contract':c}
            if changed is not None:ledger['runtime_secret_inventory']=changed
            with self.subTest(inventory=changed),patch.object(r,'request') as native,self.assertRaises(RuntimeError):r.check(ledger)
            native.assert_not_called()
class ComputeInventory(unittest.TestCase):
    def test_released_compute_needs_the_ledger_marker(self):
        row={'instance_id':'i-0123456789abcdef0','root_volume_ids':['vol-0123456789abcdef0'],'eni_id':'eni-0123456789abcdef0'}
        good={'compute_inventory':{'complete':True,'instance_ids':[row['instance_id']]},'compute_history':[row],'compute_released':True}
        self.assertEqual(r.compute_inventory(good,{'compute':None}),[row])
        with self.assertRaises(RuntimeError):r.compute_inventory({**good,'compute_released':False},{'compute':None})
    def full_ledger(self,**contract):
        c={'account_id':'1','region':'r','lease':{'session_id':'s'},'database':{'identifier':'db','secret_arn':'arn:m','subnet_group':'g','parameter_group':'p'},'runtime_secret':{'arn':'arn:rt'},'bucket':'b','security_group_ids':['sg-1'],'verifier_identity':{'launch_template_id':'lt','role_arn':'a/role','profile_arn':'a/profile'},'owned_network':None,'compute':None,'restored':None,'snapshot':None,'orphan_candidates':{'snapshot':'x-marker','restored_identifier':'x-restored'}}
        c.update(contract)
        return {'contract':c,'runtime_secret_inventory':{'arn':'arn:rt','version_ids':[],'complete':True},'compute_history':[],'compute_inventory':{'complete':True,'instance_ids':[]},'database_resource_ids':['db-A'],'database_network_interface_ids':['eni-db'],'managed_secret_arns':['arn:m']}
    NOT_FOUND={'describe-db-instances':'DBInstanceNotFound','describe-db-snapshots':'DBSnapshotNotFound','describe-db-instance-automated-backups':'DBInstanceAutomatedBackupNotFound','describe-secret':'ResourceNotFoundException','list-secret-version-ids':'ResourceNotFoundException','describe-network-interfaces':'InvalidNetworkInterfaceID.NotFound','describe-security-groups':'InvalidGroup.NotFound','describe-launch-templates':'InvalidLaunchTemplateId.NotFound','get-role':'NoSuchEntity','get-instance-profile':'NoSuchEntity','list-object-versions':'NoSuchBucket','list-multipart-uploads':'NoSuchBucket','describe-db-subnet-groups':'DBSubnetGroupNotFoundFault','describe-db-parameter-groups':'DBParameterGroupNotFound'}
    def fake_request(self,found=()):
        def request(contract,service,operation,*args):
            if operation=='get-caller-identity':return {'Account':'1','Arn':'arn:aws:sts::1:assumed-role/agent-session/agent-s'},None
            if (operation,args[1] if len(args)>1 else None) in found:return {},None
            return None,self.NOT_FOUND[operation]
        return request
    def test_absence_passes_when_everything_is_gone(self):
        with patch.object(r,'request',self.fake_request()):self.assertTrue(r.check(self.full_ledger())['ok'])
    def test_unaccounted_marker_snapshot_or_clone_fails_absence(self):
        for found,key in [(('describe-db-snapshots','x-marker'),'snapshot:x-marker'),(('describe-db-instances','x-restored'),'database:x-restored')]:
            with self.subTest(key=key),patch.object(r,'request',self.fake_request({found})):
                result=r.check(self.full_ledger())
                self.assertFalse(result['ok']);self.assertFalse(result['checks'][key])
    def test_missing_orphan_candidates_refuses(self):
        ledger=self.full_ledger();del ledger['contract']['orphan_candidates']
        with patch.object(r,'request',self.fake_request()),self.assertRaises(RuntimeError):r.check(ledger)
    def test_captured_provision_before_seed_has_valid_empty_history(self):
        self.assertEqual(r.compute_inventory({'compute_inventory':{'complete':True,'instance_ids':[]},'compute_history':[]},{'compute':None}),[])
    def test_exact_complete_history_and_missing_foreign_truncated_refusal(self):
        row={'instance_id':'i-00000000000000000','root_volume_ids':['vol-00000000000000000'],'eni_id':'eni-00000000000000000'}
        good={'compute_inventory':{'complete':True,'instance_ids':[row['instance_id']]},'compute_history':[row]};c={'compute':row}
        self.assertEqual(r.compute_inventory(good,c),[row])
        for inv in [None,{'complete':False,'instance_ids':[row['instance_id']]},{'complete':True,'instance_ids':[]},{'complete':True,'instance_ids':['i-11111111111111111']},{'complete':True,'instance_ids':[row['instance_id'],row['instance_id']]}]:
            with self.subTest(inventory=inv),self.assertRaises(RuntimeError):r.compute_inventory({**good,'compute_inventory':inv},c)
        with self.assertRaises(RuntimeError):r.compute_inventory(good,{'compute':None})
if __name__=='__main__':unittest.main()
