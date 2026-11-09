import unittest
from unittest.mock import patch
from secret_io import SecretIoError
import drain_bucket as d

class DrainTests(unittest.TestCase):
    def test_unknown_key_or_upload_refuses_before_mutation(self):
        c={'account_id':'111111111111','region':'us-west-2','run_id':'example','bucket':'pippen-sbx-example-111111111111-us-west-2','lease':{'session_id':'synthetic'},'payload_key':'transport/owned','sentinel':{'key':'unrelated/sentinel','version_id':'synthetic-sentinel-version'},'prefix':'fixture/synthetic/'}
        caller={'Account':c['account_id'],'Arn':'arn:aws:sts::111111111111:assumed-role/agent-session/agent-synthetic'}
        ledger={'contract':c,'object_versions':[],'multipart_uploads':[]}
        for page,versions in [({'IsTruncated':False,'Uploads':[{'Key':'foreign','UploadId':'x'}]},[]),({'IsTruncated':False},[{'Key':'foreign','VersionId':'x'}])]:
            with patch.object(d.h,'cli',side_effect=[caller,page]) as call,patch.object(d.h,'version_entries',return_value=versions):
                with self.assertRaises(SecretIoError):d.drain(ledger)
                self.assertTrue(all(x.args[2] in ['get-caller-identity','list-multipart-uploads'] for x in call.call_args_list))

    def test_reviewed_pending_versions_deleted_but_pinned_sentinel_retained(self):
        c={'account_id':'111111111111','region':'us-west-2','run_id':'example','bucket':'pippen-sbx-example-111111111111-us-west-2','lease':{'session_id':'synthetic'},'payload_key':'transport/owned','sentinel':{'key':'unrelated/sentinel','version_id':'sentinel-version'},'prefix':'fixture/synthetic/'}
        rows=[{'Key':'unrelated/sentinel','VersionId':'sentinel-version'},{'Key':'receipts/seed.pending.json','VersionId':'pending-version'},{'Key':'transport/owned','VersionId':'payload-version'}]
        who={'Account':c['account_id'],'Arn':'arn:aws:sts::111111111111:assumed-role/agent-session/agent-synthetic'}
        def api(cfg,service,operation,*args,**kwargs):
            if operation=='get-caller-identity':return who
            if operation=='list-multipart-uploads':return {'IsTruncated':False,'Uploads':[]}
            if operation=='delete-object':
                self.assertNotIn('unrelated/sentinel',args);return {}
            raise AssertionError(operation)
        ledger={'contract':c,'object_versions':rows,'multipart_uploads':[]}
        with patch.object(d.h,'cli',side_effect=api) as api_call,patch.object(d.h,'version_entries',side_effect=[rows,[rows[0]]]):result=d.drain(ledger)
        self.assertTrue(result['sentinel_retained_for_terraform']);self.assertEqual(result['versions_deleted'],2)
if __name__=='__main__':unittest.main()
