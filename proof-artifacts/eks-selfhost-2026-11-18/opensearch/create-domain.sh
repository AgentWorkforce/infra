# as run; sources facts.env for ACCT, OS_DOMAIN, PRIVATE_SUBNETS, DATA_SG_ID, TAG_*
SUBNET1=${PRIVATE_SUBNETS%%,*}
aws opensearch create-domain --domain-name $OS_DOMAIN --engine-version OpenSearch_2.19 \
  --cluster-config InstanceType=m7g.medium.search,InstanceCount=1,DedicatedMasterEnabled=false,ZoneAwarenessEnabled=false \
  --ebs-options EBSEnabled=true,VolumeType=gp3,VolumeSize=20 \
  --vpc-options SubnetIds=$SUBNET1,SecurityGroupIds=$DATA_SG_ID \
  --encryption-at-rest-options Enabled=true --node-to-node-encryption-options Enabled=true \
  --domain-endpoint-options EnforceHTTPS=true,TLSSecurityPolicy=Policy-Min-TLS-1-2-2019-07 \
  --advanced-security-options "Enabled=true,InternalUserDatabaseEnabled=false,MasterUserOptions={MasterUserARN=arn:aws:iam::$ACCT:role/EXAMPLE-operator-admin-role}" \
  --access-policies file://$A/domain-access-policy.json  # newline-stripped copy of os-access.json \
  --tag-list Key=owner,Value=$TAG_OWNER Key=purpose,Value=$TAG_PURPOSE --query DomainStatus.ARN --output text
