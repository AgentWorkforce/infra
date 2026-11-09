"""Deterministic public source archive. Validates every byte before packing."""
import gzip
import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile

def build(root,output):
    root=Path(root);output=Path(output)
    if output.exists():raise RuntimeError('archive_output_exists')
    manifest=json.loads((root/'archive-manifest.json').read_text());expected=manifest['files']
    allowed={'format','composition_commit','composition_tree','bun_lock_sha256','packages','files'}
    if manifest.get('format')=='actual-rds-application-archive-v1':allowed|={'helm_commit','helm_tree','helm_sources','provider_lock_sha256','runtime_images','guest_manifest_sha256','ca_sha256','test_only','toolchain'}
    if set(manifest)!=allowed or manifest['format'] not in ['actual-rds-source-archive-v1','actual-rds-application-archive-v1']:raise RuntimeError('archive_manifest_invalid')
    files={}
    for path in root.rglob('*'):
        if path.is_symlink():raise RuntimeError('archive_symlink_refused')
        if path.is_dir():continue
        if not path.is_file():raise RuntimeError('archive_special_file_refused')
        name=path.relative_to(root).as_posix();data=path.read_bytes()
        if len(data)>2*1024*1024:raise RuntimeError('archive_member_bound')
        files[name]=data
    if set(files)!=set(expected)|{'archive-manifest.json'} or len(files)>1000 or sum(map(len,files.values()))>8*1024*1024:raise RuntimeError('archive_inventory_bound')
    for name,h in expected.items():
        if name.startswith('/') or '..' in name.split('/') or hashlib.sha256(files[name]).hexdigest()!=h:raise RuntimeError('archive_bytes_changed')
    buf=io.BytesIO()
    with tarfile.open(fileobj=buf,mode='w',format=tarfile.USTAR_FORMAT) as tar:
        for name,data in sorted(files.items()):
            info=tarfile.TarInfo(name);info.size=len(data);info.mode=0o600;info.mtime=0;tar.addfile(info,io.BytesIO(data))
    with output.open('wb') as target:
        with gzip.GzipFile(filename='',fileobj=target,mode='wb',mtime=0) as zipped:zipped.write(buf.getvalue())
    return {'archive_sha256':hashlib.sha256(output.read_bytes()).hexdigest(),'archive_bytes':output.stat().st_size,'files':len(files)}
if __name__=='__main__':print(json.dumps(build(sys.argv[1],sys.argv[2])))
