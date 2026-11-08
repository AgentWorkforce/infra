"""Owned ARM host entry only. Import/source tests NEVER invoke cloud or SQL.

No secret-bearing subprocess enters a disk logger, argv, environment, receipt,
cloud-init output or exception text. Same-host trusted code is not an IAM sandbox.
"""
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import tempfile
import time
import uuid
from secret_io import run,SecretIoError
from guest_protocol import Broker,BOOTSTRAPS,require
import s3_probe

NODE='node@sha256:48abc13a19400ca3985071e287bd405a1d99306770eb81d61202fb6b65cf0b57'
PG='postgres@sha256:748a18a54d3842d43bc156f0840d78029b8d349e0feca98c12b9c4ce3404a6b3'
ENV={k:os.environ[k] for k in ['PATH','HOME'] if k in os.environ}
ENV.update(AWS_CONFIG_FILE='/dev/null',AWS_SHARED_CREDENTIALS_FILE='/dev/null',AWS_PAGER='',AWS_EC2_METADATA_DISABLED='false')
OPERATIONS={'get-caller-identity':'GetCallerIdentity','get-secret-value':'GetSecretValue','put-secret-value':'PutSecretValue','describe-db-instances':'DescribeDBInstances','list-tags-for-resource':'ListTagsForResource','get-object':'GetObject','put-object':'PutObject','delete-object':'DeleteObject','list-object-versions':'ListObjectVersions','list-objects-v2':'ListObjectsV2','create-multipart-upload':'CreateMultipartUpload','upload-part':'UploadPart','abort-multipart-upload':'AbortMultipartUpload','list-parts':'ListParts'}

def check_deadline(c):
    deadline=dt.datetime.fromisoformat(c['deadline'].replace('Z','+00:00')).timestamp()
    require(time.time()<deadline,'host_deadline_expired')

def cli(c,service,operation,*args,refusal=None,private_input=b''):
    check_deadline(c)
    owner=['--expected-bucket-owner',c['account_id']] if service=='s3api' else []
    result=run(['aws','--region',c['region'],'--no-cli-pager',service,operation,*args,*owner,'--output','json'],input_bytes=private_input,env=ENV,timeout=90)
    if refusal:
        match=re.search(rb'An error occurred \(([^)]+)\) when calling the ([A-Za-z0-9]+) operation',result.stderr)
        require(result.returncode!=0 and match and match[1].decode()==refusal and match[2].decode()==OPERATIONS[operation],'target_refusal_not_proved');return {}
    require(result.returncode==0,'host_aws_failed')
    try:return json.loads(result.stdout) if result.stdout.strip() else {}
    except Exception:raise SecretIoError('host_aws_json') from None

# Narrow compatibility for the inherited S3 drainer, never legacy DB emulation.
def version_entries(c):
    s3_probe.cli=cli;return s3_probe.version_entries(c)

def atomic(path,value):
    tmp=path.with_name(path.name+'.tmp')
    with tmp.open('w') as f:os.chmod(tmp,0o600);json.dump(value,f);f.write('\n');f.flush();os.fsync(f.fileno())
    os.replace(tmp,path)

def secret(c,arn,version=None):
    args=['--secret-id',arn]+(['--version-id',version] if version else [])
    value=cli(c,'secretsmanager','get-secret-value',*args)
    require(value.get('ARN')==arn and isinstance(value.get('VersionId'),str) and re.fullmatch(r'[A-Za-z0-9-]{32,64}',value['VersionId']) and (version is None or value['VersionId']==version),'secret_reference_mismatch')
    try:body=json.loads(value['SecretString'])
    except Exception:raise SecretIoError('secret_json_refused') from None
    require(isinstance(body,dict),'secret_body_refused');return body,value['VersionId']

def database(c,identifier):
    rows=cli(c,'rds','describe-db-instances','--db-instance-identifier',identifier).get('DBInstances')
    require(isinstance(rows,list) and len(rows)==1,'database_metadata_incomplete');d=rows[0]
    arn=f"arn:aws:rds:{c['region']}:{c['account_id']}:db:{identifier}"
    require(d.get('DBInstanceIdentifier')==identifier and d.get('DBInstanceArn')==arn and d.get('DBInstanceStatus')=='available' and d.get('Engine')=='postgres' and d.get('EngineVersion')==c['postgres_version'] and d.get('AutoMinorVersionUpgrade') is False and d.get('PubliclyAccessible') is False and d.get('StorageEncrypted') is True and d.get('DeletionProtection') is True and d.get('DBSubnetGroup',{}).get('VpcId')==c['vpc_id'] and re.fullmatch(r'db-[A-Z0-9]+',d.get('DbiResourceId','')),'native_database_refused')
    tags=cli(c,'rds','list-tags-for-resource','--resource-name',arn).get('TagList')
    require(isinstance(tags,list) and {v['Key']:v['Value'] for v in tags}==c['expected_tags'],'database_ownership_refused')
    return d

def require_distinct_restore(source,target):
    require(source['DbiResourceId']!=target['DbiResourceId'] and source['DBInstanceArn']!=target['DBInstanceArn'] and source['Endpoint']['Address']!=target['Endpoint']['Address'],'restored_target_identity_not_distinct')

class HostIo:
    def __init__(self,c,root,owner_password,source_db,target,scope):
        self.c=c;self.root=root;self.owner_password=owner_password;self.source_db=source_db;self.target=target;self.scope=scope;self.marker=str(uuid.uuid4());self.names={'node':'rds-prep-node-'+self.marker[:12],'psql':'rds-prep-psql-'+self.marker[:12]};self.runtime_secret_arn=c['runtime_secret_arn'];self.events=[];self.containers={};self.pending_versions=[];self.versions={}
    def deadline(self):
        check_deadline(self.c);require(time.time()<dt.datetime.fromisoformat(self.scope['deadline'].replace('Z','+00:00')).timestamp(),'guest_deadline_expired')
    def docker(self,*args,private_input=b'',on_frame=None,timeout=60,max_input=131072):
        result=run(['docker',*args],input_bytes=private_input,env=ENV,timeout=timeout,max_input=max_input,on_frame=on_frame)
        require(result.returncode==0,'owned_docker_failed');return result
    def pending(self,step,identifier):
        self.deadline()
        value={'format':'actual-rds-pending-v1','source_sha':self.c['source_sha'],'marker':self.c['marker'],'phase':self.c['phase'],'step':step,'operation_id':identifier,'runtime_secret_arn':self.runtime_secret_arn,'instance_arn':self.target['DBInstanceArn']}
        path=self.root/'pending.json';atomic(path,value)
        r=cli(self.c,'s3api','put-object','--bucket',self.c['bucket'],'--key',self.c['pending_receipt_key'],'--body',str(path))
        require(isinstance(r.get('VersionId'),str) and r['VersionId'] not in ['','null'],'pending_version_missing')
        self.pending_versions.append(r['VersionId']);self.events.append({'step':step,'operation_id':identifier,'pending_version_id':r['VersionId']})
    def restored_auth(self):
        self.events.append({'step':'restored_seed_auth_before_mutation','runtime_secret_version_id':self.c['runtime_secret_version_id']})
    def psql(self,args,passwords):
        self.deadline();require(all(isinstance(p,str) and p and not re.search(r'[\r\n\0]',p) for p in passwords),'password_stdin_shape')
        self.docker('exec','-i','-e','PGSSLMODE=verify-full','-e','PGSSLROOTCERT=/guest/assets/rds-ca.pem','-e','PGPASSFILE=/dev/null','-e','PGCONNECT_TIMEOUT=5','-e','PGOPTIONS=-c statement_timeout=10000',self.names['psql'],'psql','-X','-W','-v','ON_ERROR_STOP=1','-h',self.c['host'],'-p','5432','-U',self.c['owner'],'-d',self.c['database'],*args,private_input=('\n'.join(passwords)+'\n').encode())
    def bootstrap(self,file):
        path=self.root/file['path'] if self.root.name=='source' else self.root/'source'/file['path']
        require(path.is_file() and not path.is_symlink() and hashlib.sha256(path.read_bytes()).hexdigest()==file['sha256'],'bootstrap_bytes_changed')
        args=[]
        for key,value in sorted(file['variables'].items()):args+=['-v',key+'='+value]
        self.psql(args+['-f','/guest/source/'+file['path']],[self.owner_password])
    def rotate(self,password):self.psql(['-c','\\password "'+self.c['runtime_role']+'"'],[self.owner_password,password,password])
    def runtime_value(self,password):
        return {'format':'actual-rds-runtime-v1','source_sha':self.c['source_sha'],'lease':self.c['expected_tags']['pippen:session'],'guest_source_sha':self.c['guest_sources']['composition_commit'],'manifest_sha256':self.c['guest_sources']['manifest_sha256'],'generation':self.c['guest_sources']['generation'],'seed_instance_arn':self.source_db['DBInstanceArn'],'seed_resource_id':self.source_db['DbiResourceId'],'database':self.c['database'],'runtime_role':self.c['runtime_role'],'password':password}
    def publish(self,password,identifier,receipt):
        data=json.dumps(self.runtime_value(password),separators=(',',':')).encode()
        stages=['AWSCURRENT','proof-seed' if self.c['phase']=='seed' else 'proof-restored']
        r=cli(self.c,'secretsmanager','put-secret-value','--secret-id',self.runtime_secret_arn,'--client-request-token',identifier,'--version-stages',*stages,'--secret-string','file:///dev/stdin',private_input=data)
        require(r.get('ARN')==self.runtime_secret_arn and r.get('VersionId')==identifier,'published_secret_reference_mismatch')
        stored,version=secret(self.c,self.runtime_secret_arn,identifier)
        require(stored==self.runtime_value(password),'published_secret_bytes_mismatch')
        return {'password':stored['password'],'arn':self.runtime_secret_arn,'versionId':version}
    def start(self):
        for kind,image in [('node',NODE),('psql',PG)]:
            name=self.names[kind]
            require(not self.docker('ps','-a','--filter','name=^/'+name+'$','--format','{{.ID}}').stdout.strip(),'owned_container_collision')
            meta=json.loads(self.docker('image','inspect',image).stdout)[0]
            require(meta['Architecture']=='arm64' and meta['Os']=='linux','runtime_image_architecture')
            declared=set(meta.get('Config',{}).get('Volumes') or {})
            require(declared==({'/var/lib/postgresql/data'} if kind=='psql' else set()),'runtime_image_volume_set')
            args=['create','--name',name,'--label','proof.rds-prep='+self.marker,'--platform','linux/arm64','--network','bridge','--read-only','--cap-drop','ALL','--security-opt','no-new-privileges','--memory','512m','--cpus','1','--pids-limit','128','--log-driver','none','--ulimit','core=0','--tmpfs','/guest:rw,nosuid,size=32m','--tmpfs','/tmp:rw,nosuid,size=16m','--entrypoint','sleep']
            for path in sorted(declared):args+=['--tmpfs',path+':rw,nosuid,size=16m']
            identifier=self.docker(*args,image,'infinity').stdout.decode().strip();self.containers[kind]={'name':name,'id':identifier,'image':image}
            mounts=json.loads(self.docker('inspect','--format','{{json .Mounts}}',name).stdout);require(all(m['Type']!='volume' for m in mounts),'implicit_runtime_volume')
            self.docker('start',name)
            self.versions[kind]=self.docker('exec',name,'node' if kind=='node' else 'psql','--version').stdout.decode().strip()
            require(self.versions[kind].startswith('v24.') if kind=='node' else ' 17.' in self.versions[kind],'installed_runtime_version')
            payload=(self.root.parent/'payload.tar.gz').read_bytes();require(hashlib.sha256(payload).hexdigest()==self.c['payload_sha256'],'runtime_archive_changed')
            self.docker('exec','-i',name,'tar','-xzf','-','-C','/guest',private_input=payload,max_input=4*1024*1024)
    def close(self):
        checks={}
        for kind in ['node','psql']:
            name=self.names[kind]
            if self.docker('ps','-a','--filter','name=^/'+name+'$','--format','{{.ID}}').stdout.strip():
                label=self.docker('inspect','--format','{{index .Config.Labels "proof.rds-prep"}}',name).stdout.decode().strip()
                require(label==self.marker,'foreign_runtime_cleanup_refused');self.docker('rm','--force','--volumes',name)
            checks[name]=not self.docker('ps','-a','--filter','name=^/'+name+'$','--format','{{.ID}}').stdout.strip()
        require(all(checks.values()),'runtime_containers_not_absent');return checks

def read_seed(c,root):
    path=root.parent/'seed.json'
    meta=cli(c,'s3api','get-object','--bucket',c['bucket'],'--key','receipts/seed.json','--version-id',c['seed_receipt_version_id'],str(path))
    require(meta.get('VersionId')==c['seed_receipt_version_id'] and path.stat().st_size<=65536 and hashlib.sha256(path.read_bytes()).hexdigest()==c['seed_receipt_sha256'],'seed_receipt_version_or_hash')
    value=json.loads(path.read_text())
    require(value.get('ok') is True and value.get('phase')=='seed' and value.get('source_sha')==c['source_sha'] and value.get('marker')==c['marker'] and value.get('secret_version_id')==c['secret_version_id'] and value.get('runtime_secret_version_id')==c['runtime_secret_version_id'] and value.get('guest',{}).get('receipt',{}).get('evidenceSha256')==c['seed_evidence_sha256'],'seed_receipt_scope')
    return value

def main():
    require(platform.system()=='Linux' and platform.machine()=='aarch64','owned_linux_arm_host_required')
    require(len(Path('/proc/swaps').read_text().splitlines())<=1,'swap_must_be_disabled_before_credentials')
    root=Path(__file__).resolve().parent;c=json.loads((root.parent/'inputs.json').read_text());check_deadline(c)
    require(re.fullmatch(r'[0-9]{12}',c['account_id']) and re.fullmatch(r'[a-f0-9]{40}',c['source_sha']) and c['owner']=='proof_admin' and c['runtime_role']=='proof_runtime','closed_host_identity')
    require(c['phase'] in ['seed','restore'] and c['guest_sources']['composition_commit']=='292359f0c68b1e4615704fd51d303b7f6b4db445','closed_guest_source')
    sources=json.loads((root/'guest-sources.json').read_text());outer=json.loads((root/'archive-manifest.json').read_text())
    require(outer['format']=='actual-rds-application-archive-v1' and outer.get('test_only') is False and outer['helm_commit']==c['source_sha'] and outer['guest_manifest_sha256']==c['guest_sources']['manifest_sha256'] and sources['compositionCommit']==c['guest_sources']['composition_commit'] and sources['generation']==c['guest_sources']['generation'],'frozen_source_manifest')
    ca=(root/'assets/rds-ca.pem').read_text();wrong_ca=(root/'assets/wrong-ca.pem').read_text()
    require(hashlib.sha256(ca.encode()).hexdigest()==c['ca_sha256'] and 'PRIVATE KEY' not in ca and ca!=wrong_ca,'public_ca_binding')
    for name,expected in outer['files'].items():
        path=root/name
        require(path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(root) and hashlib.sha256(path.read_bytes()).hexdigest()==expected,'installed_payload_changed')
    arn_prefix=f"arn:aws:secretsmanager:{c['region']}:{c['account_id']}:secret:"
    require(c['secret_arn'].startswith(arn_prefix) and c['runtime_secret_arn'].startswith(arn_prefix) and c['secret_arn']!=c['runtime_secret_arn'],'secret_account_region_scope')
    role=c['verifier_role_arn'];require(re.fullmatch(f"arn:aws:iam::{c['account_id']}:role/pippen/workload/pippen-sbx-[a-z][a-z0-9]{{2,15}}-verifier",role),'host_role_path')
    who=cli(c,'sts','get-caller-identity')
    require(who.get('Account')==c['account_id'] and re.fullmatch(f"arn:aws:sts::{c['account_id']}:assumed-role/{role.rsplit('/',1)[1]}/i-(?:[a-f0-9]{{8}}|[a-f0-9]{{17}})",who.get('Arn','')),'fresh_owned_host_caller')
    source_db=database(c,c['source_instance_id']);target=source_db if c['phase']=='seed' else database(c,c['instance_id'])
    if c['phase']=='restore':require_distinct_restore(source_db,target)
    require(target['Endpoint']['Address']==c['host'] and target['EngineVersion']==c['postgres_version'] and source_db.get('MasterUserSecret',{}).get('SecretArn')==c['secret_arn'],'native_target_or_master_mapping')
    owner,master_version=secret(c,c['secret_arn'],c['secret_version_id'])
    require(owner.get('username')==c['owner'] and isinstance(owner.get('password'),str) and owner['password'] and not re.search(r'[\r\n\0]',owner['password']),'owner_credential_shape')
    prior=None
    if c['phase']=='restore':
        seed=read_seed(c,root)
        require(seed['source_database_resource_id']==source_db['DbiResourceId'],'restored_seed_native_identity')
        value,version=secret(c,c['runtime_secret_arn'],c['runtime_secret_version_id'])
        # The seeded endpoint is never a restore target or a connection override.
        expected={'format':'actual-rds-runtime-v1','source_sha':c['source_sha'],'lease':c['expected_tags']['pippen:session'],'guest_source_sha':c['guest_sources']['composition_commit'],'manifest_sha256':c['guest_sources']['manifest_sha256'],'generation':c['guest_sources']['generation'],'seed_instance_arn':source_db['DBInstanceArn'],'seed_resource_id':source_db['DbiResourceId'],'database':c['database'],'runtime_role':c['runtime_role']}
        require(set(value)==set(expected)|{'password'} and all(value[k]==v for k,v in expected.items()) and isinstance(value['password'],str) and len(value['password'])>=32,'restored_runtime_credential_provenance');prior=value['password']
    deadline=min(dt.datetime.now(dt.timezone.utc)+dt.timedelta(minutes=20),dt.datetime.fromisoformat(c['deadline'].replace('Z','+00:00')))
    scope={'accountId':c['account_id'],'region':c['region'],'instanceArn':target['DBInstanceArn'],'endpoint':c['host'],'database':c['database'],'owner':c['owner'],'runtimeRole':c['runtime_role'],'compositionCommit':c['guest_sources']['composition_commit'],'sourceManifestSha256':c['guest_sources']['manifest_sha256'],'generation':c['guest_sources']['generation'],'deadline':deadline.isoformat(timespec='milliseconds').replace('+00:00','Z'),'phase':'fresh' if c['phase']=='seed' else 'restored'}
    if c['phase']=='restore':scope['restoredEvidenceSha256']=c['seed_evidence_sha256']
    io=HostIo(c,root,owner['password'],source_db,target,scope);broker=Broker(scope,sources,io);cleanup={};unsettled=False
    try:
        io.start()
        initial={'format':'actual-rds-io-v1','sequence':0,'scope':scope,'sources':sources,'ownerPassword':owner['password'],'priorRuntimePassword':prior,'ca':ca,'wrongCa':wrong_ca}
        # Pending intent already exists before the first committed bootstrap; the
        # Broker adds per-write intents immediately before each SQL/SM mutation.
        io.pending('guest_started',str(uuid.uuid4()))
        io.docker('exec','-i',io.names['node'],'node','--import','/guest/runtime-hook.mjs','/guest/guest-adapter.mjs',private_input=(json.dumps(initial)+'\n').encode(),on_frame=broker.frame,timeout=1200)
        require(broker.result is not None and broker.result['ok'],'complete_guest_transport_missing')
    except SecretIoError as error:
        unsettled=error.code=='sensitive_process_unsettled'
        raise
    finally:
        if not unsettled:cleanup=io.close()
    # Existing S3 proof functions are rebound to this exact-account memory-only
    # AWS transport. They never invoke the legacy module DB/ACL helper.
    s3_probe.cli=cli
    with tempfile.TemporaryDirectory(prefix='owned-s3-synthetic-') as folder:s3=s3_probe.prove_s3(c,Path(folder))
    return {'ok':True,'application_sql_ready':False,'migration_identity':'synthetic_rds_master','scope':'actual original HoopDB RDS bootstrap/migration/runtime readiness + module S3; no shared-database/search/provider/Lambda/full-app/retirement proof','phase':c['phase'],'source_sha':c['source_sha'],'marker':c['marker'],'guest_sources':c['guest_sources'],'payload_sha256':c['payload_sha256'],'payload_version_id':c['payload_version_id'],'ca_sha256':c['ca_sha256'],'secret_version_id':master_version,'runtime_secret_arn':c['runtime_secret_arn'],'runtime_secret_version_id':broker.result['secretRef']['versionId'],'source_database_resource_id':source_db['DbiResourceId'],'database_resource_id':target['DbiResourceId'],'guest':broker.result,'s3':s3,'ordered_events':io.events,'pending_object_versions':io.pending_versions,'containers':io.containers,'runtime_versions':io.versions,'host_arch':platform.machine(),'python_version':platform.python_version(),'aws_cli_version':run(['aws','--version'],env=ENV,timeout=15).stdout.decode().strip(),'container_absence':cleanup,'infrastructureRetired':False,'requiresInstanceRetirement':True}

if __name__=='__main__':
    try:print(json.dumps(main()))
    except BaseException as error:
        code=error.code if isinstance(error,SecretIoError) else 'host_proof_failed'
        print(json.dumps({'ok':False,'code':code,'quarantined':True,'infrastructureRetired':False}))
        raise SystemExit(75 if code=='sensitive_process_unsettled' else 1)
