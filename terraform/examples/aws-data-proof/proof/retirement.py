"""Read-only exact-owned absence checks. Parent runs only after reviewed cleanup.
This does not delete resources, discover credentials, or turn Denied into absent.
"""
import json,re,subprocess,sys

OPERATIONS={
 'get-caller-identity':'GetCallerIdentity','describe-db-instances':'DescribeDBInstances',
 'describe-db-snapshots':'DescribeDBSnapshots','describe-db-instance-automated-backups':'DescribeDBInstanceAutomatedBackups',
 'describe-secret':'DescribeSecret','describe-instances':'DescribeInstances','describe-volumes':'DescribeVolumes',
 'describe-network-interfaces':'DescribeNetworkInterfaces','describe-security-groups':'DescribeSecurityGroups',
 'describe-launch-templates':'DescribeLaunchTemplates','get-role':'GetRole','get-instance-profile':'GetInstanceProfile',
 'list-object-versions':'ListObjectVersions','list-multipart-uploads':'ListMultipartUploads',
 'describe-db-subnet-groups':'DescribeDBSubnetGroups','describe-db-parameter-groups':'DescribeDBParameterGroups',
 'describe-subnets':'DescribeSubnets','describe-route-tables':'DescribeRouteTables'
}

def request(contract,service,operation,*args):
    result=subprocess.run(['aws','--region',contract['region'],'--no-cli-pager',service,operation,*args,'--output','json'],capture_output=True,text=True,timeout=90)
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

def check(ledger):
    c=ledger['contract'];checks={};ids=ledger['database_resource_ids']
    if len(set(ids))!=(2 if c.get('restored') else 1) or not all(re.fullmatch(r'db-[A-Z0-9]+',x) for x in ids):raise RuntimeError('Incomplete DB resource-ID capture')
    if ledger['managed_secret_arns']!=[c['database']['secret_arn']] or not ledger['database_network_interface_ids'] or len(ledger['compute_history'])!=(2 if c.get('restored') else 1) or not all(x['root_volume_ids'] for x in ledger['compute_history']):raise RuntimeError('Incomplete secret/storage/network capture')
    if len({x['instance_id'] for x in ledger['compute_history']})!=len(ledger['compute_history']) or ledger['compute_history'][-1]!=c['compute']:raise RuntimeError('Incomplete compute lifetime capture')
    caller,error=request(c,'sts','get-caller-identity')
    expected=f"arn:aws:sts::{c['account_id']}:assumed-role/agent-session/agent-{c['lease']['session_id']}"
    if error or caller.get('Account')!=c['account_id'] or caller.get('Arn')!=expected:raise RuntimeError('Wrong expected lease/caller')
    for identifier in [c['database']['identifier']]+([c['restored']['identifier']] if c.get('restored') else []):
        checks['database:'+identifier]=absent(c,'rds','describe-db-instances',['--db-instance-identifier',identifier],'DBInstanceNotFound')
    if c.get('snapshot'):
        checks['snapshot']=absent(c,'rds','describe-db-snapshots',['--db-snapshot-identifier',c['snapshot']],'DBSnapshotNotFound')
    for resource_id in ids:
        value,error=request(c,'rds','describe-db-instance-automated-backups','--dbi-resource-id',resource_id)
        checks['automated_backups:'+resource_id]=error=='DBInstanceAutomatedBackupNotFound' or (error is None and isinstance(value.get('DBInstanceAutomatedBackups'),list) and value['DBInstanceAutomatedBackups']==[])
    for secret in ledger['managed_secret_arns']:
        checks['secret:'+secret]=absent(c,'secretsmanager','describe-secret',['--secret-id',secret],'ResourceNotFoundException')
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
