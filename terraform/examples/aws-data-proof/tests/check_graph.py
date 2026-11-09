"""Offline config graph regression. Never plan/apply or call a cloud API."""
import json,re,subprocess,sys

text=subprocess.check_output([sys.argv[1] if len(sys.argv)>1 else 'terraform','graph','-type=plan'],text=True)
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
 ('aws_db_instance.restored','aws_db_snapshot.marker'),
 ('aws_db_instance.restored','module.postgres.aws_db_instance.this'),
 ('aws_db_instance.restored','module.postgres.aws_db_parameter_group.this'),
 ('aws_db_instance.restored','module.postgres.aws_db_subnet_group.this'),
 *[('aws_instance.verifier',x) for x in ['aws_db_instance.restored','module.postgres.aws_db_instance.this','aws_iam_role_policy.verifier','aws_iam_instance_profile.verifier','aws_vpc_security_group_ingress_rule.database','aws_vpc_security_group_egress_rule.database','aws_vpc_security_group_egress_rule.https','terraform_data.execution','terraform_data.guard']]
]
missing=[(source,target) for source,target in pairs if not reachable(source,target)]
if missing:raise SystemExit(json.dumps({'missing_prerequisites':missing}))
print(json.dumps({'ok':True,'transitive_prerequisites':len(pairs),'retirement':'reverse dependency graph; native async absence still required'}))
