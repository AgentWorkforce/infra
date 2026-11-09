import unittest
from unittest.mock import patch
import drain_bucket as d

class DrainTests(unittest.TestCase):
    def test_unknown_key_or_upload_refuses_before_mutation(self):
        c={'account_id':'111111111111','region':'us-west-2','run_id':'example','bucket':'pippen-sbx-example-111111111111-us-west-2','lease':{'session_id':'synthetic'},'payload_key':'transport/owned','sentinel':{'key':'unrelated/sentinel'},'prefix':'fixture/synthetic/'}
        caller={'Account':c['account_id'],'Arn':'arn:aws:sts::111111111111:assumed-role/agent-session/agent-synthetic'}
        ledger={'contract':c,'object_versions':[],'multipart_uploads':[]}
        for page,versions in [({'IsTruncated':False,'Uploads':[{'Key':'foreign','UploadId':'x'}]},[]),({'IsTruncated':False},[{'Key':'foreign','VersionId':'x'}])]:
            with patch.object(d.h,'cli',side_effect=[caller,page]) as call,patch.object(d.h,'version_entries',return_value=versions):
                with self.assertRaises(RuntimeError):d.drain(ledger)
                self.assertTrue(all(x.args[2] in ['get-caller-identity','list-multipart-uploads'] for x in call.call_args_list))

if __name__=='__main__':unittest.main()
