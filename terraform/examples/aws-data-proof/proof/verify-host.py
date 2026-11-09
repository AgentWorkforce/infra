"""Owned EC2 guest only. Runtime AWS operations; NEVER run during source checks.
Secret values exist only in subprocess pipes/process memory, not files/argv/logs.
"""
import hashlib,json,os,pathlib,platform,subprocess,tempfile,urllib.request

NODE='node@sha256:48abc13a19400ca3985071e287bd405a1d99306770eb81d61202fb6b65cf0b57'

def require(condition):
    if not condition:raise RuntimeError('Proof invariant failed')

def cli(cfg,service,operation,*args,refusal=None):
    owner=['--expected-bucket-owner',cfg['account_id']] if service=='s3api' else []
    result=subprocess.run(['aws','--region',cfg['region'],'--no-cli-pager',service,operation,*args,*owner,'--output','json'],capture_output=True,text=True,timeout=90)
    if refusal:
        require(result.returncode!=0 and ('('+refusal+')') in result.stderr)
        return {}
    # Do not echo captured stdout/stderr: Secrets Manager output can be secret.
    require(result.returncode==0)
    return json.loads(result.stdout) if result.stdout.strip() else {}

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

def main():
    root=pathlib.Path(__file__).resolve().parent
    cfg=json.loads((root.parent/'inputs.json').read_text())
    require(platform.system()=='Linux' and platform.machine()=='aarch64')
    if cfg['phase']=='restore':
        with tempfile.TemporaryDirectory(prefix='owned-seed-receipt-') as tmp:
            path=pathlib.Path(tmp)/'seed.json'
            cli(cfg,'s3api','get-object','--bucket',cfg['bucket'],'--key','receipts/seed.json','--version-id',cfg['seed_receipt_version_id'],str(path))
            require(hashlib.sha256(path.read_bytes()).hexdigest()==cfg['seed_receipt_sha256'])
            seed=json.loads(path.read_text())
            require(seed['ok'] is True and seed['phase']=='seed' and seed['marker']==cfg['marker'] and seed['source_sha']==cfg['source_sha'] and seed['secret_version_id']==cfg['secret_version_id'])
    meta=cli(cfg,'rds','describe-db-instances','--db-instance-identifier',cfg['instance_id'])['DBInstances']
    require(len(meta)==1);db=meta[0]
    require(db['DBInstanceIdentifier']==cfg['instance_id'] and db['Engine']=='postgres' and db['EngineVersion'].startswith('17.') and not db['PubliclyAccessible'] and db['StorageEncrypted'] and db['DeletionProtection'] and db['Endpoint']['Address']==cfg['host'] and db['DBSubnetGroup']['VpcId']==cfg['vpc_id'])
    require(db['DBInstanceArn']==f"arn:aws:rds:{cfg['region']}:{cfg['account_id']}:db:{cfg['instance_id']}")
    tag_list=cli(cfg,'rds','list-tags-for-resource','--resource-name',db['DBInstanceArn'])['TagList']
    tags={x['Key']:x['Value'] for x in tag_list}
    require(all(tags.get(k)==v for k,v in cfg['expected_tags'].items()))
    args=['--secret-id',cfg['secret_arn']]
    if cfg['secret_version_id']:args+=['--version-id',cfg['secret_version_id']]
    secret=cli(cfg,'secretsmanager','get-secret-value',*args)
    require(secret['ARN']==cfg['secret_arn'] and (not cfg['secret_version_id'] or secret['VersionId']==cfg['secret_version_id']))
    credentials=json.loads(secret['SecretString'])
    require(credentials['username']=='proof_admin')
    ca=urllib.request.urlopen(f"https://truststore.pki.rds.amazonaws.com/{cfg['region']}/{cfg['region']}-bundle.pem",timeout=30).read()
    require(hashlib.sha256(ca).hexdigest()==cfg['ca_sha256'])
    name='data-proof-'+cfg['marker'][:12]
    existing=subprocess.run(['docker','ps','--all','--filter','name=^/'+name+'$','--format','{{.Names}}'],capture_output=True,text=True,timeout=15)
    require(existing.returncode==0 and existing.stdout.strip()=='')
    with tempfile.TemporaryDirectory(prefix='owned-data-proof-') as tmp:
        folder=pathlib.Path(tmp)
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(folder/'wrong.key'),'-out',str(folder/'wrong.crt'),'-days','1','-subj','/CN=synthetic-wrong-ca','-addext','basicConstraints=critical,CA:TRUE'],check=True,capture_output=True,timeout=30)
        child={**cfg,'username':credentials['username'],'password':credentials['password'],'ca':ca.decode(),'wrong_ca':(folder/'wrong.crt').read_text()}
        try:
            # AWS credentials remain on the host IMDS SDK chain. Only DB
            # credentials flow through stdin; no env/argv/file/credential mount.
            run=subprocess.run(['docker','run','--rm','--name',name,'--label','proof.marker='+cfg['marker'],'--platform','linux/arm64','--network','bridge','--read-only','--cap-drop','ALL','--security-opt','no-new-privileges','--memory','512m','--cpus','1','--pids-limit','128','--mount','type=bind,src='+str(root)+',dst=/proof,readonly','-i',NODE,'node','/proof/db-proof.mjs'],input=json.dumps(child),capture_output=True,text=True,timeout=300)
            require(run.returncode==0)
            proof=json.loads(run.stdout);require(proof['ok'] is True)
        finally:
            # Inspect ownership before removing only this exact container.
            left=subprocess.run(['docker','ps','--all','--filter','name=^/'+name+'$','--format','{{.Names}}'],capture_output=True,text=True,timeout=15)
            require(left.returncode==0)
            if left.stdout.strip():
                label=subprocess.check_output(['docker','inspect','--format','{{ index .Config.Labels "proof.marker" }}',name],text=True,timeout=15).strip()
                require(label==cfg['marker']);subprocess.run(['docker','rm','-f',name],check=True,capture_output=True,timeout=30)
                gone=subprocess.run(['docker','ps','--all','--filter','name=^/'+name+'$','--format','{{.Names}}'],capture_output=True,text=True,timeout=15)
                require(gone.returncode==0 and gone.stdout.strip()=='')
        s3=prove_s3(cfg,folder)
    receipt={'ok':True,'source_sha':cfg['source_sha'],'payload_sha256':cfg['payload_sha256'],'payload_version_id':cfg['payload_version_id'],'ca_sha256':cfg['ca_sha256'],'phase':cfg['phase'],'marker':cfg['marker'],'seed_receipt_sha256':cfg['seed_receipt_sha256'],'secret_version_id':secret['VersionId'],'database_resource_id':db['DbiResourceId'],'database':proof,'s3':s3,'host_arch':platform.machine(),'aws_cli':subprocess.check_output(['aws','--version'],text=True,timeout=15).strip(),'scope':'actual module RDS/S3 + synthetic ACL/restore marker; no application/provider/full-suite proof'}
    print(json.dumps(receipt))

if __name__=='__main__':
    try:main()
    except Exception:
        print(json.dumps({'ok':False,'code':'GUEST_PROOF_FAILED'}));raise SystemExit(1)
