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
        with patch.object(r.subprocess,'run',return_value=result):
            with self.assertRaises(RuntimeError):r.request({'region':'us-west-2'},'iam','get-role','--role-name','synthetic')
    def test_specific_missing_only(self):
        for error,want in [('NoSuchBucket',True),('AccessDenied',False),('RequestTimeout',False)]:
            with patch.object(r,'request',return_value=(None,error)):
                self.assertEqual(r.absent({},'s3api','list-object-versions',[],'NoSuchBucket'),want)
        for value in [{},{'IsTruncated':False}]:
            with patch.object(r,'request',return_value=(value,None)):
                self.assertFalse(r.absent({},'s3api','list-object-versions',[],'NoSuchBucket'))

if __name__=='__main__':unittest.main()
