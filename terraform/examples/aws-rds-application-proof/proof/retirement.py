"""Read-only exact-owned absence checks. Parent runs only after reviewed cleanup.
This does not delete resources, discover credentials, or turn Denied into absent.
"""
import json,re,subprocess,sys
from parent_api import environment

OPERATIONS={
 'get-caller-identity':'GetCallerIdentity','describe-db-instances':'DescribeDBInstances',
 'describe-db-snapshots':'DescribeDBSnapshots','describe-db-instance-automated-backups':'DescribeDBInstanceAutomatedBackups',
 'describe-secret':'DescribeSecret','list-secret-version-ids':'ListSecretVersionIds','describe-instances':'DescribeInstances','describe-volumes':'DescribeVolumes',
 'describe-network-interfaces':'DescribeNetworkInterfaces','describe-security-groups':'DescribeSecurityGroups',
 'describe-launch-templates':'DescribeLaunchTemplates','get-role':'GetRole','get-instance-profile':'GetInstanceProfile',
 'list-object-versions':'ListObjectVersions','list-multipart-uploads':'ListMultipartUploads',
 'describe-db-subnet-groups':'DescribeDBSubnetGroups','describe-db-parameter-groups':'DescribeDBParameterGroups',
 'describe-subnets':'DescribeSubnets','describe-route-tables':'DescribeRouteTables'
}

def request(contract,service,operation,*args):
    result=subprocess.run(['aws','--region',contract['region'],'--no-cli-pager',service,operation,*args,'--output','json'],capture_output=True,text=True,timeout=90,env=environment())
    if result.returncode:
        match=re.search(r'An error occurred \(([^)]+)\) when calling the ([A-Za-z0-9]+) operation',result.stderr)
        if not match or match[2]!=OPERATIONS[operation]:raise RuntimeError('Unclassified native API error')
        return None,match[1]
    return (json.loads(result.stdout) if result.stdout.strip() else {}),None

def absent(contract,service,operation,args,code):
    value,error=request(contract,service,operation,*args)
    if error:return error==code
    return False

def network_absence(contract):
    if 'owned_network' not in contract:raise RuntimeError('Missing owned/external network capture')
    network=contract['owned_network']
    if network is None:return {} # Existing external subnets/routes are never deletion targets.
    subnets=network['subnet_ids'];associations=network['route_association_ids'];table=network['route_table_id']
    if len(set(subnets))!=2 or set(subnets)!=set(contract['private_subnet_ids']) or len(set(associations))!=2 or not all(re.fullmatch(r'subnet-[0-9a-f]+',x) for x in subnets) or not all(re.fullmatch(r'rtbassoc-[0-9a-f]+',x) for x in associations) or not re.fullmatch(r'rtb-[0-9a-f]+',table):raise RuntimeError('Incomplete owned network capture')
    checks={}
    for subnet in subnets:
        checks['subnet:'+subnet]=absent(contract,'ec2','describe-subnets',['--subnet-ids',subnet],'InvalidSubnetID.NotFound')
    checks['route_table:'+table]=absent(contract,'ec2','describe-route-tables',['--route-table-ids',table],'InvalidRouteTableID.NotFound')
    for association in associations:
        value,error=request(contract,'ec2','describe-route-tables','--filters',f'Name=association.route-table-association-id,Values={association}')
        checks['route_association:'+association]=error is None and isinstance(value.get('RouteTables'),list) and value['RouteTables']==[] and not value.get('NextToken')
    return checks

def runtime_inventory(ledger,contract):
    inventory=ledger.get('runtime_secret_inventory')
    if not isinstance(inventory,dict) or set(inventory)!={'arn','version_ids','complete'} or inventory['arn']!=contract['runtime_secret']['arn'] or inventory['complete'] is not True:
        raise RuntimeError('Missing/truncated/foreign runtime secret inventory')
    versions=inventory['version_ids']
    if not isinstance(versions,list) or len(versions)>1000 or not all(isinstance(x,str) and re.fullmatch(r'[A-Za-z0-9-]{32,64}',x) for x in versions) or len(set(versions))!=len(versions):
        raise RuntimeError('Invalid complete runtime secret version inventory')
    return versions # Empty is valid: failed/before-publication lifecycle.

def compute_inventory(ledger,contract):
    history=ledger.get('compute_history');inventory=ledger.get('compute_inventory')
    if not isinstance(history,list) or len(history)>2 or not isinstance(inventory,dict) or set(inventory)!={'complete','instance_ids'} or inventory['complete'] is not True:
        raise RuntimeError('Missing/truncated compute lifetime inventory')
    identifiers=inventory['instance_ids']
    if not isinstance(identifiers,list) or not all(isinstance(x,str) and re.fullmatch(r'i-[a-f0-9]{8,17}',x) for x in identifiers) or len(set(identifiers))!=len(identifiers):raise RuntimeError('Invalid compute native IDs')
    if not all(isinstance(x,dict) and set(x)=={'instance_id','root_volume_ids','eni_id'} and isinstance(x['instance_id'],str) and re.fullmatch(r'i-[a-f0-9]{8,17}',x['instance_id']) and x['root_volume_ids'] and isinstance(x['root_volume_ids'],list) and all(isinstance(v,str) and re.fullmatch(r'vol-[a-f0-9]{8,17}',v) for v in x['root_volume_ids']) and isinstance(x['eni_id'],str) and re.fullmatch(r'eni-[a-f0-9]{8,17}',x['eni_id']) for x in history):raise RuntimeError('Incomplete compute physical history')
    volumes=[v for x in history for v in x['root_volume_ids']];interfaces=[x['eni_id'] for x in history]
    if len(set(volumes))!=len(volumes) or len(set(interfaces))!=len(interfaces):raise RuntimeError('Duplicate compute physical IDs')
    historical=[x['instance_id'] for x in history]
    if len(set(historical))!=len(historical) or set(historical)!=set(identifiers) or (contract.get('compute') is None and history and ledger.get('compute_released') is not True) or (contract.get('compute') is not None and (not history or history[-1]!=contract.get('compute'))):raise RuntimeError('Compute inventory differs from captured lifetime/current output')
    return history

def check(ledger):
    c=ledger['contract'];runtime_inventory(ledger,c);compute_inventory(ledger,c);checks={};ids=ledger['database_resource_ids']
    if len(set(ids))!=(2 if c.get('restored') else 1) or not all(re.fullmatch(r'db-[A-Z0-9]+',x) for x in ids):raise RuntimeError('Incomplete DB resource-ID capture')
    orphans=c.get('orphan_candidates')
    if not isinstance(orphans,dict) or set(orphans)!={'snapshot','restored_identifier'} or not all(isinstance(x,str) and x for x in orphans.values()):raise RuntimeError('Missing unaccounted resource candidates')
    if ledger['managed_secret_arns']!=[c['database']['secret_arn']] or not ledger['database_network_interface_ids']:raise RuntimeError('Incomplete secret/storage/network capture')
    caller,error=request(c,'sts','get-caller-identity')
    expected=f"arn:aws:sts::{c['account_id']}:assumed-role/agent-session/agent-{c['lease']['session_id']}"
    if error or caller.get('Account')!=c['account_id'] or caller.get('Arn')!=expected:raise RuntimeError('Wrong expected lease/caller')
    # The candidate names are checked even when state never recorded them: an apply lost
    # between AWS and state must not read as absent.
    for identifier in sorted({c['database']['identifier'],orphans['restored_identifier']}|({c['restored']['identifier']} if c.get('restored') else set())):
        checks['database:'+identifier]=absent(c,'rds','describe-db-instances',['--db-instance-identifier',identifier],'DBInstanceNotFound')
    for snapshot in sorted({orphans['snapshot']}|({c['snapshot']} if c.get('snapshot') else set())):
        checks['snapshot:'+snapshot]=absent(c,'rds','describe-db-snapshots',['--db-snapshot-identifier',snapshot],'DBSnapshotNotFound')
    for resource_id in ids:
        value,error=request(c,'rds','describe-db-instance-automated-backups','--dbi-resource-id',resource_id)
        checks['automated_backups:'+resource_id]=error=='DBInstanceAutomatedBackupNotFound' or (error is None and isinstance(value.get('DBInstanceAutomatedBackups'),list) and value['DBInstanceAutomatedBackups']==[])
    for secret in ledger['managed_secret_arns']:
        checks['secret:'+secret]=absent(c,'secretsmanager','describe-secret',['--secret-id',secret],'ResourceNotFoundException')
    runtime=c['runtime_secret']['arn']
    checks['runtime_secret']=absent(c,'secretsmanager','describe-secret',['--secret-id',runtime],'ResourceNotFoundException')
    checks['runtime_secret_all_versions']=absent(c,'secretsmanager','list-secret-version-ids',['--secret-id',runtime,'--include-deprecated'],'ResourceNotFoundException')
    for compute in ledger['compute_history']:
        value,error=request(c,'ec2','describe-instances','--instance-ids',compute['instance_id'])
        rows=[i for r in (value or {}).get('Reservations',[]) for i in r.get('Instances',[])]
        checks['instance:'+compute['instance_id']]=error=='InvalidInstanceID.NotFound' or (error is None and len(rows)==1 and rows[0].get('State',{}).get('Name')=='terminated')
        for volume in compute['root_volume_ids']:
            checks['volume:'+volume]=absent(c,'ec2','describe-volumes',['--volume-ids',volume],'InvalidVolume.NotFound')
    enis=set(ledger['database_network_interface_ids'])|{x['eni_id'] for x in ledger['compute_history']}
    for eni in enis:
        checks['eni:'+eni]=absent(c,'ec2','describe-network-interfaces',['--network-interface-ids',eni],'InvalidNetworkInterfaceID.NotFound')
    for group in c['security_group_ids']:
        checks['sg:'+group]=absent(c,'ec2','describe-security-groups',['--group-ids',group],'InvalidGroup.NotFound')
    identity=c['verifier_identity']
    checks['launch_template']=absent(c,'ec2','describe-launch-templates',['--launch-template-ids',identity['launch_template_id']],'InvalidLaunchTemplateId.NotFound')
    checks['role']=absent(c,'iam','get-role',['--role-name',identity['role_arn'].split('/')[-1]],'NoSuchEntity')
    checks['profile']=absent(c,'iam','get-instance-profile',['--instance-profile-name',identity['profile_arn'].split('/')[-1]],'NoSuchEntity')
    # S3 version/multipart drain and parent evidence capture happen BEFORE
    # bucket deletion. Require a specific service error after deletion.
    for operation in ['list-object-versions','list-multipart-uploads']:
        checks['bucket:'+operation]=absent(c,'s3api',operation,['--bucket',c['bucket'],'--expected-bucket-owner',c['account_id']],'NoSuchBucket')
    for operation,key,arg in [('describe-db-subnet-groups','DBSubnetGroups','--db-subnet-group-name'),('describe-db-parameter-groups','DBParameterGroups','--db-parameter-group-name')]:
        name=c['database']['subnet_group'] if key=='DBSubnetGroups' else c['database']['parameter_group']
        code='DBSubnetGroupNotFoundFault' if key=='DBSubnetGroups' else 'DBParameterGroupNotFound'
        checks[key]=absent(c,'rds',operation,[arg,name],code)
    checks.update(network_absence(c))
    return {'ok':all(checks.values()),'checks':checks,'scope':'exact captured owned IDs only; no account-wide or application proof'}

if __name__=='__main__':
    result=check(json.load(open(sys.argv[1])))
    print(json.dumps(result,indent=2));raise SystemExit(0 if result['ok'] else 1)
