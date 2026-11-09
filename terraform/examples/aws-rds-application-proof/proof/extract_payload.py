"""Pure bounded archive verification; executed before any unpacked code."""
import gzip
import hashlib
import io
import json
from pathlib import Path
import tarfile

def verify(blob,c):
    def require(value):
        if not value:raise RuntimeError('payload_validation_failed')
    require(len(blob)<=4*1024*1024 and hashlib.sha256(blob).hexdigest()==c['payload_sha256'])
    with gzip.GzipFile(fileobj=io.BytesIO(blob),mode='rb') as zipped:
        unpacked=zipped.read(16*1024*1024+1);require(len(unpacked)<=16*1024*1024)
    files={};total=0
    with tarfile.open(fileobj=io.BytesIO(unpacked),mode='r:') as tar:
        for member in tar:
            name=member.name
            require(len(files)<1000 and member.isfile() and not member.issym() and not member.islnk() and not name.startswith('/') and not any(part in ['', '..','.'] for part in name.split('/')) and '\\' not in name and not any(ord(x)<32 for x in name) and name not in files and 0<=member.size<=2*1024*1024)
            total+=member.size;require(total<=8*1024*1024)
            require(name.split('/')[-1] not in ['rds-profile-proof.ts','.env'] and name!='.aws/credentials' and not name.endswith('/.aws/credentials'))
            files[name]=tar.extractfile(member).read()
    require('archive-manifest.json' in files)
    manifest=json.loads(files['archive-manifest.json'])
    require(manifest.get('format')=='actual-rds-application-archive-v1' and manifest.get('test_only') is False and manifest.get('helm_commit')==c['source_sha'] and manifest.get('provider_lock_sha256')==c['provider_lock_sha256'] and manifest.get('guest_manifest_sha256')==c['guest_sources']['manifest_sha256'] and manifest.get('ca_sha256')==c['ca_sha256'])
    expected=manifest.get('files');require(isinstance(expected,dict) and set(files)==set(expected)|{'archive-manifest.json'})
    require(all(isinstance(value,str) and hashlib.sha256(files[name]).hexdigest()==value for name,value in expected.items()))
    required={'guest-adapter.mjs','guest_protocol.py','secret_io.py','verify-host.py','s3_probe.py','runtime-hook.mjs','register.mjs','guest-sources.json','assets/rds-ca.pem','assets/wrong-ca.pem','source/src/hoopdb/rds-activation.ts','source/bun.lock'}
    require(required<=set(files) and manifest['bun_lock_sha256']==expected['source/bun.lock'])
    require(expected['assets/rds-ca.pem']==c['ca_sha256'] and files['assets/rds-ca.pem']!=files['assets/wrong-ca.pem'] and all(b'PRIVATE KEY' not in files[name] for name in ['assets/rds-ca.pem','assets/wrong-ca.pem']))
    sources=json.loads(files['guest-sources.json'])
    require(sources.get('compositionCommit')==c['guest_sources']['composition_commit'] and sources.get('generation')==c['guest_sources']['generation'] and sources.get('artifactSha256')==c['application_activation']['artifact_sha256'] and sources.get('contract')=='rds-activation/v1')
    return files

def extract(blob,c,destination):
    destination=Path(destination)
    if destination.exists():raise RuntimeError('payload_destination_exists')
    files=verify(blob,c);destination.mkdir(mode=0o700)
    for name,body in files.items():
        target=destination/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(body);target.chmod(0o600)
    return len(files)
