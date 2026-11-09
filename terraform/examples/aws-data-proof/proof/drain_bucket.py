"""Parent-operated retirement only: delete exactly the reviewed version/MPU ledger.
Never execute as a source test or against the baseline workspace bucket.
"""
import importlib.util,json,pathlib,sys
spec=importlib.util.spec_from_file_location('host',pathlib.Path(__file__).with_name('verify-host.py'))
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)

def upload_entries(cfg):
    rows=[];seen=[];cursor=[]
    for _ in range(100):
        page=h.cli(cfg,'s3api','list-multipart-uploads','--bucket',cfg['bucket'],'--no-paginate',*cursor)
        h.require(isinstance(page.get('IsTruncated'),bool))
        rows.extend(page.get('Uploads',[]))
        if not page['IsTruncated']:return {(x['Key'],x['UploadId']) for x in rows}
        marker=(page.get('NextKeyMarker'),page.get('NextUploadIdMarker'))
        h.require(all(isinstance(x,str) and x for x in marker) and marker not in seen)
        seen.append(marker);cursor=['--key-marker',marker[0],'--upload-id-marker',marker[1]]
    raise RuntimeError('Multipart pagination bound exceeded')

def drain(ledger):
    c=ledger['contract'];cfg={'account_id':c['account_id'],'region':c['region'],'bucket':c['bucket'],'prefix':''}
    h.require(c['bucket']==f"pippen-sbx-{c['run_id']}-{c['account_id']}-{c['region']}" and c['prefix']==f"fixture/{c['lease']['session_id']}/" and c['sentinel']['key']=='unrelated/sentinel')
    caller=h.cli(cfg,'sts','get-caller-identity')
    h.require(caller['Account']==c['account_id'] and caller['Arn']==f"arn:aws:sts::{c['account_id']}:assumed-role/agent-session/agent-{c['lease']['session_id']}")
    allowed={c['payload_key'],'receipts/seed.json','receipts/restore.json',c['sentinel']['key'],c['prefix']+'marker',c['prefix']+'multipart'}
    versions={(x['Key'],x['VersionId']) for x in ledger['object_versions']}
    uploads={(x['Key'],x['UploadId']) for x in ledger['multipart_uploads']}
    h.require(all(k in allowed and isinstance(v,str) and v for k,v in versions|uploads))
    # Native complete listing must match the reviewed exact upload-ID ledger.
    found=upload_entries(cfg)
    h.require(found==uploads)
    current={(x['Key'],x['VersionId']) for x in h.version_entries(cfg)}
    h.require(current==versions) # Unknown key/version: refuse every mutation.
    for key,upload in sorted(uploads):
        h.cli(cfg,'s3api','abort-multipart-upload','--bucket',cfg['bucket'],'--key',key,'--upload-id',upload)
        h.cli(cfg,'s3api','list-parts','--bucket',cfg['bucket'],'--key',key,'--upload-id',upload,refusal='NoSuchUpload')
    h.clean_versions(cfg,versions)
    h.require(upload_entries(cfg)==set())
    return {'ok':True,'versions_deleted':len(versions),'uploads_aborted':len(uploads),'unrelated_keys_deleted':0}

if __name__=='__main__':print(json.dumps(drain(json.load(open(sys.argv[1])))))
