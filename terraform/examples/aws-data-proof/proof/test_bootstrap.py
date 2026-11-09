import hashlib,io,json,pathlib,subprocess,tarfile,tempfile,unittest
from unittest.mock import patch

TEMPLATE=pathlib.Path(__file__).resolve().parent.parent/'bootstrap.sh.tftpl'
BLOCK=TEMPLATE.read_text().split("<<'PY'\n")[2].split('\nPY\n')[0]

def archive(source='0'*40,extra=False):
    files={'db-proof.mjs':b'synthetic-db','verify-host.py':b'synthetic-host'}
    files['manifest.json']=json.dumps({'source_sha':source,'files':{n:hashlib.sha256(v).hexdigest() for n,v in files.items()}}).encode()
    if extra:files['../escape']=b'refused'
    out=io.BytesIO()
    with tarfile.open(fileobj=out,mode='w:gz') as t:
        for name,value in files.items():
            info=tarfile.TarInfo(name);info.size=len(value);t.addfile(info,io.BytesIO(value))
    return out.getvalue()

class BootstrapTests(unittest.TestCase):
    def extract(self,blob,digest=None,source='0'*40,fail=False):
        with tempfile.TemporaryDirectory() as tmp:
            root=pathlib.Path(tmp)
            cfg={'region':'us-west-2','bucket':'synthetic','account_id':'111111111111','payload_key':'transport/owned','payload_version_id':'synthetic-version','payload_sha256':digest or hashlib.sha256(blob).hexdigest(),'source_sha':source}
            (root/'inputs.json').write_text(json.dumps(cfg))
            def stub(args,**kwargs):
                self.assertIn('--expected-bucket-owner',args);self.assertIn('--version-id',args)
                self.assertEqual(args[args.index('--version-id')+1],'synthetic-version')
                pathlib.Path(args[-1]).write_bytes(blob)
                return subprocess.CompletedProcess(args,0)
            code=compile(BLOCK.replace('/opt/data-proof',tmp),'<synthetic extraction>','exec')
            with patch('subprocess.run',side_effect=stub):
                if fail:
                    with self.assertRaises((AssertionError,tarfile.TarError)):exec(code,{})
                    self.assertFalse((root/'payload').exists())
                else:
                    exec(code,{})
                    self.assertEqual((root/'payload/db-proof.mjs').read_bytes(),b'synthetic-db')
    def test_exact_payload(self):self.extract(archive())
    def test_changed_bytes_refused_before_extraction(self):
        body=archive();self.extract(body+b'tamper',digest=hashlib.sha256(body).hexdigest(),fail=True)
    def test_path_and_source_refused_before_extraction(self):
        self.extract(archive(extra=True),fail=True)
        self.extract(archive(),source='1'*40,fail=True)

if __name__=='__main__':unittest.main()
