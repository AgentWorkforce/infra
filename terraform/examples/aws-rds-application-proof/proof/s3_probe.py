"""Scoped S3 module operations only; no application/bootstrap emulation."""
from secret_io import SecretIoError

def require(v):
    if not v:raise SecretIoError('s3_proof_refused')

def cli(*args,**kwargs):
    raise SecretIoError('s3_transport_not_bound')

def version_entries(cfg):
    """Every page; missing/denied/malformed responses are never empty proof."""
    entries=[];markers=[];cursor=[]
    for _ in range(100):
        page=cli(cfg,'s3api','list-object-versions','--bucket',cfg['bucket'],'--prefix',cfg['prefix'],'--no-paginate',*cursor)
        require(isinstance(page.get('IsTruncated'),bool))
        for kind in ['Versions','DeleteMarkers']:
            for row in page.get(kind,[]):
                require(isinstance(row.get('Key'),str) and row['Key'].startswith(cfg['prefix']) and isinstance(row.get('VersionId'),str))
                entries.append({'Key':row['Key'],'VersionId':row['VersionId']})
        if not page['IsTruncated']:return entries
        marker=(page.get('NextKeyMarker'),page.get('NextVersionIdMarker'))
        require(all(isinstance(x,str) and x for x in marker) and marker not in markers)
        markers.append(marker);cursor=['--key-marker',marker[0],'--version-id-marker',marker[1]]
    raise RuntimeError('Version pagination bound exceeded')

def clean_versions(cfg,ledger):
    # Never delete an arbitrary prefix listing or an unrelated object/version.
    current=version_entries(cfg)
    require(all((x['Key'],x['VersionId']) in ledger for x in current))
    for key,version in sorted(ledger):
        require(key.startswith(cfg['prefix']))
        cli(cfg,'s3api','delete-object','--bucket',cfg['bucket'],'--key',key,'--version-id',version)
    require(version_entries(cfg)==[])

def prove_s3(cfg,folder):
    bucket=cfg['bucket'];key=cfg['prefix']+'marker';ledger=set();upload=None;cleanup=False
    require(version_entries(cfg)==[]) # Refuse adoption of old or unknown versions.
    try:
        for value in [b'synthetic-first',b'synthetic-second']:
            (folder/'object').write_bytes(value)
            put=cli(cfg,'s3api','put-object','--bucket',bucket,'--key',key,'--body',str(folder/'object'))
            require(put.get('ServerSideEncryption')=='aws:kms' and put.get('VersionId') not in [None,'null'])
            ledger.add((key,put['VersionId']))
            cli(cfg,'s3api','get-object','--bucket',bucket,'--key',key,'--version-id',put['VersionId'],str(folder/'download'))
            require((folder/'download').read_bytes()==value)
        listing=cli(cfg,'s3api','list-objects-v2','--bucket',bucket,'--prefix',cfg['prefix'],'--no-paginate')
        require(listing.get('IsTruncated') is False and [x['Key'] for x in listing.get('Contents',[])]==[key])
        deleted=cli(cfg,'s3api','delete-object','--bucket',bucket,'--key',key)
        require(deleted.get('DeleteMarker') is True and deleted.get('VersionId'))
        ledger.add((key,deleted['VersionId']))
        require(len(version_entries(cfg))==3)
        # Explicit proof of version recovery after deleting the current object.
        # Select a data version, never the newly-created delete marker.
        old=next(v for k,v in ledger if v!=deleted['VersionId'])
        cli(cfg,'s3api','get-object','--bucket',bucket,'--key',key,'--version-id',old,str(folder/'download'))
        require((folder/'download').read_bytes() in [b'synthetic-first',b'synthetic-second'])
        for operation,arguments in [
            ('get-object',['--key','unrelated/sentinel',str(folder/'denied')]),
            ('put-object',['--key','unrelated/refused','--body',str(folder/'object')]),
            ('delete-object',['--key','unrelated/sentinel']),
            ('list-objects-v2',[])]:
            cli(cfg,'s3api',operation,'--bucket',bucket,*arguments,refusal='AccessDenied')
        multi=cfg['prefix']+'multipart'
        created=cli(cfg,'s3api','create-multipart-upload','--bucket',bucket,'--key',multi)
        upload=created['UploadId'];require(isinstance(upload,str) and upload)
        cli(cfg,'s3api','upload-part','--bucket',bucket,'--key',multi,'--upload-id',upload,'--part-number','1','--body',str(folder/'object'))
        cli(cfg,'s3api','abort-multipart-upload','--bucket',bucket,'--key',multi,'--upload-id',upload)
        cli(cfg,'s3api','list-parts','--bucket',bucket,'--key',multi,'--upload-id',upload,refusal='NoSuchUpload')
        upload=None
    finally:
        if upload:cli(cfg,'s3api','abort-multipart-upload','--bucket',bucket,'--key',cfg['prefix']+'multipart','--upload-id',upload)
        clean_versions(cfg,ledger);cleanup=True
    return {'ok':True,'versions_and_delete_marker':3,'multipart_aborted':True,'scoped_refusals':4,'owned_prefix_empty':cleanup,'unrelated_mutations_denied':True}

