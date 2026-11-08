"""Offline config graph regression. Never plan/apply or call a cloud API."""
import json,re,subprocess,sys
from pathlib import Path
import os,tempfile

root=Path(__file__).resolve().parents[1]
base=root/'.terraform';base.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='offline-graph-',dir=base) as directory:
    temporary=Path(directory)
    env={k:v for k,v in os.environ.items() if not k.startswith(('AWS_','TF_'))}
    env.update(AWS_CONFIG_FILE='/dev/null',AWS_SHARED_CREDENTIALS_FILE='/dev/null',AWS_EC2_METADATA_DISABLED='true',TF_DATA_DIR=str(temporary/'data'))
    # Honor only the caller's non-secret provider cache, not local CLI/state
    # configuration. With no cache supplied, init uses its normal data folder.
    if os.environ.get('TF_PLUGIN_CACHE_DIR'):
        env['TF_PLUGIN_CACHE_DIR']=os.environ['TF_PLUGIN_CACHE_DIR']
    rc=temporary/'terraform.rc';rc.write_text('disable_checkpoint = true\n');env['TF_CLI_CONFIG_FILE']=str(rc)
    binary=sys.argv[1] if len(sys.argv)>1 else 'terraform'
    subprocess.run([binary,'init','-input=false','-no-color','-lockfile=readonly','-reconfigure','-backend-config=path='+str(temporary/'offline.tfstate')],cwd=root,env=env,capture_output=True,text=True,check=True,timeout=120)
    text=subprocess.check_output([binary,'graph','-type=plan'],text=True,cwd=root,env=env,timeout=60)

edges={}
for source,target in re.findall(r'"(\[root\] [^"]+)" -> "(\[root\] [^"]+)"',text):edges.setdefault(source,set()).add(target)
def reachable(source,target):
    pending=[f'[root] {source} (expand)'];seen=set();goal=f'[root] {target} (expand)'
    while pending:
        node=pending.pop()
        if node==goal:return True
        if node not in seen:seen.add(node);pending.extend(edges.get(node,[]))
    return False
pairs=[
 *[('aws_s3_object.sentinel',f'module.objects.{resource}.this') for resource in ['aws_s3_bucket_versioning','aws_s3_bucket_server_side_encryption_configuration','aws_s3_bucket_public_access_block','aws_s3_bucket_policy','aws_s3_bucket_ownership_controls','aws_s3_bucket_lifecycle_configuration']],
 *[(resource,association) for resource in ['module.postgres.aws_db_instance.this','module.postgres.aws_db_subnet_group.this','aws_db_instance.restored','aws_instance.verifier'] for association in ['aws_route_table_association.private_first','aws_route_table_association.private_second']],
 ('aws_instance.verifier','aws_secretsmanager_secret.runtime'),
 ('aws_iam_role_policy.verifier','aws_secretsmanager_secret.runtime'),
 ('aws_db_instance.restored','aws_db_snapshot.marker'),
 ('aws_db_instance.restored','module.postgres.aws_db_instance.this'),
 ('aws_db_instance.restored','module.postgres.aws_db_parameter_group.this'),
 ('aws_db_instance.restored','module.postgres.aws_db_subnet_group.this'),
 *[('aws_instance.verifier',x) for x in ['aws_db_instance.restored','module.postgres.aws_db_instance.this','aws_iam_role_policy.verifier','aws_iam_instance_profile.verifier','aws_vpc_security_group_ingress_rule.database','aws_vpc_security_group_egress_rule.database','aws_vpc_security_group_egress_rule.https','terraform_data.execution','terraform_data.guard','terraform_data.application_gate']]
]
missing=[(source,target) for source,target in pairs if not reachable(source,target)]
if missing:raise SystemExit(json.dumps({'missing_prerequisites':missing}))
print(json.dumps({'ok':True,'transitive_prerequisites':len(pairs),'retirement':'reverse dependency graph; native async absence still required'}))
