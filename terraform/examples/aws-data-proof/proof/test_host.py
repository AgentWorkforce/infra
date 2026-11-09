import importlib.util,pathlib,subprocess,unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('host',pathlib.Path(__file__).with_name('verify-host.py'))
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
CFG={'account_id':'111111111111','region':'us-west-2','bucket':'synthetic','prefix':'fixture/owned/'}

class HostTests(unittest.TestCase):
    def test_version_pages_are_complete(self):
        pages=[{'IsTruncated':True,'Versions':[{'Key':'fixture/owned/key','VersionId':'one'}],'NextKeyMarker':'fixture/owned/key','NextVersionIdMarker':'one'}, {'IsTruncated':False,'DeleteMarkers':[{'Key':'fixture/owned/key','VersionId':'two'}]}]
        with patch.object(h,'cli',side_effect=pages) as call:
            self.assertEqual(len(h.version_entries(CFG)),2)
            self.assertIn('--version-id-marker',call.call_args.args)
    def test_missing_shape_and_repeated_page_are_not_absence(self):
        for page in [{}, {'IsTruncated':True,'NextKeyMarker':'key','NextVersionIdMarker':'v'}]:
            with patch.object(h,'cli',return_value=page):
                with self.assertRaises(RuntimeError):h.version_entries(CFG)
    def test_foreign_prefix_is_refused(self):
        with patch.object(h,'cli',return_value={'IsTruncated':False,'Versions':[{'Key':'unrelated/sentinel','VersionId':'one'}]}):
            with self.assertRaises(RuntimeError):h.version_entries(CFG)
    def test_unknown_version_prevents_all_deletes(self):
        with patch.object(h,'version_entries',return_value=[{'Key':'fixture/owned/key','VersionId':'foreign'}]),patch.object(h,'cli') as call:
            with self.assertRaises(RuntimeError):h.clean_versions(CFG,{('fixture/owned/key','known')})
            call.assert_not_called()
    def test_cleanup_uses_exact_version_ledger(self):
        ledger={('fixture/owned/key','one')}
        with patch.object(h,'version_entries',side_effect=[[{'Key':'fixture/owned/key','VersionId':'one'}],[]]),patch.object(h,'cli') as call:
            h.clean_versions(CFG,ledger)
            self.assertEqual(call.call_args.args[-2:],('--version-id','one'))
    def test_auth_failure_is_not_empty_or_printed_secret(self):
        result=subprocess.CompletedProcess([],1,'synthetic-secret-value','AccessDenied synthetic-secret-value')
        with patch.object(h.subprocess,'run',return_value=result):
            with self.assertRaises(RuntimeError) as error:h.cli(CFG,'secretsmanager','get-secret-value')
            self.assertNotIn('synthetic-secret-value',str(error.exception))
    def test_specific_refusal_does_not_accept_other_error(self):
        result=subprocess.CompletedProcess([],1,'','(AccessDenied)')
        with patch.object(h.subprocess,'run',return_value=result):
            with self.assertRaises(RuntimeError):h.cli(CFG,'s3api','list-parts',refusal='NoSuchUpload')

if __name__=='__main__':unittest.main()
