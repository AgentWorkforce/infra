import gzip
import hashlib
import io
import json
import tarfile
import unittest
import extract_payload as x

def sha(value):return hashlib.sha256(value).hexdigest()
def fixture():
    guest={'compositionCommit':'a'*40,'generation':'3'*64,'artifactSha256':'4'*64,'contract':'rds-activation/v1'}
    files={name:b'public-source' for name in ['guest-adapter.mjs','guest_protocol.py','secret_io.py','verify-host.py','s3_probe.py','runtime-hook.mjs','register.mjs','source/src/hoopdb/rds-activation.ts']}
    files.update({'guest-sources.json':json.dumps(guest).encode(),'assets/rds-ca.pem':b'public-ca','assets/wrong-ca.pem':b'public-wrong-ca','source/bun.lock':b'public-lock'})
    c={'source_sha':'0'*40,'provider_lock_sha256':'1'*64,'guest_sources':{**guest,'composition_commit':guest['compositionCommit'],'manifest_sha256':'2'*64},'application_activation':{'artifact_sha256':'4'*64},'ca_sha256':sha(files['assets/rds-ca.pem'])}
    manifest={'format':'actual-rds-application-archive-v1','test_only':False,'helm_commit':c['source_sha'],'provider_lock_sha256':c['provider_lock_sha256'],'guest_manifest_sha256':'2'*64,'ca_sha256':c['ca_sha256'],'bun_lock_sha256':sha(files['source/bun.lock']),'files':{n:sha(v) for n,v in files.items()}}
    files['archive-manifest.json']=json.dumps(manifest).encode();return files,c

def pack(files,extra=None):
    buf=io.BytesIO()
    with tarfile.open(fileobj=buf,mode='w') as tar:
        for name,value in files.items():
            member=tarfile.TarInfo(name);member.size=len(value);tar.addfile(member,io.BytesIO(value))
        if extra:tar.addfile(extra[0],io.BytesIO(extra[1]))
    return gzip.compress(buf.getvalue())

class Extraction(unittest.TestCase):
    def test_exact_hashed_regular_inventory(self):
        files,c=fixture();blob=pack(files);c['payload_sha256']=sha(blob);self.assertEqual(x.verify(blob,c),files)
    def test_digest_source_test_only_and_unlisted_changes_refused(self):
        for mutation in ['digest','source','test_only','unlisted','private_key','artifact']:
            files,c=fixture()
            if mutation=='artifact':c['application_activation']['artifact_sha256']='f'*64
            if mutation=='source':c['source_sha']='f'*40
            if mutation=='test_only':m=json.loads(files['archive-manifest.json']);m['test_only']=True;files['archive-manifest.json']=json.dumps(m).encode()
            if mutation=='unlisted':files['unexpected']=b'public-extra'
            if mutation=='private_key':files['assets/rds-ca.pem']=b'PRIVATE KEY'
            blob=pack(files);c['payload_sha256']=sha(blob) if mutation!='digest' else 'f'*64
            with self.subTest(mutation=mutation),self.assertRaises(RuntimeError):x.verify(blob,c)
    def test_duplicate_traversal_symlink_and_decompression_bound_refused(self):
        for name,kind in [('guest-adapter.mjs','file'),('../escape','file'),('link','symlink')]:
            files,c=fixture();member=tarfile.TarInfo(name);member.size=1
            if kind=='symlink':member.type=tarfile.SYMTYPE;member.linkname='outside';member.size=0
            blob=pack(files,(member,b'x'));c['payload_sha256']=sha(blob)
            with self.subTest(name=name),self.assertRaises(RuntimeError):x.verify(blob,c)
        files,c=fixture();blob=gzip.compress(b'\0'*(16*1024*1024+1));c['payload_sha256']=sha(blob)
        with self.assertRaises(RuntimeError):x.verify(blob,c)
if __name__=='__main__':unittest.main()
