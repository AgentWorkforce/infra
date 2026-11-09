"""Parent-operated retirement only: delete exactly the reviewed version/MPU ledger.
Never execute as a source test or against the baseline workspace bucket.
"""
import json,sys
import parent_api as h

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
    allowed={c['payload_key'],'receipts/seed.json','receipts/restore.json','receipts/seed.pending.json','receipts/restore.pending.json',c['sentinel']['key'],c['prefix']+'marker',c['prefix']+'multipart'}
    versions={(x['Key'],x['VersionId']) for x in ledger['object_versions']}
    uploads={(x['Key'],x['UploadId']) for x in ledger['multipart_uploads']}
    h.require(all(k in allowed and isinstance(v,str) and v for k,v in versions|uploads))
    sentinel=(c['sentinel']['key'],c['sentinel'].get('version_id'))
    h.require(isinstance(sentinel[1],str) and sentinel[1] not in ['', 'null'] and sentinel in versions)
    h.require(len(versions)==len(ledger['object_versions']) and len(uploads)==len(ledger['multipart_uploads']))
    # Native complete listing must match the reviewed exact upload-ID ledger.
    found=upload_entries(cfg)
    h.require(found==uploads)
    current={(x['Key'],x['VersionId']) for x in h.version_entries(cfg)}
    h.require(current==versions) # Unknown key/version: refuse every mutation.
    for key,upload in sorted(uploads):
        h.cli(cfg,'s3api','abort-multipart-upload','--bucket',cfg['bucket'],'--key',key,'--upload-id',upload)
        h.cli(cfg,'s3api','list-parts','--bucket',cfg['bucket'],'--key',key,'--upload-id',upload,refusal='NoSuchUpload')
    for key,version in sorted(versions-{sentinel}):h.cli(cfg,'s3api','delete-object','--bucket',cfg['bucket'],'--key',key,'--version-id',version)
    h.require({(x['Key'],x['VersionId']) for x in h.version_entries(cfg)}=={sentinel})
    h.require(upload_entries(cfg)==set())
    return {'ok':True,'versions_deleted':len(versions)-1,'sentinel_retained_for_terraform':True,'uploads_aborted':len(uploads),'unrelated_keys_deleted':0}

if __name__=='__main__':print(json.dumps(drain(json.load(open(sys.argv[1])))))
