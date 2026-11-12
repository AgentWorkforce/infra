#!/usr/bin/env bash
#
# Sandbox substrate for the Relaycast Postgres-vs-durable-actors benchmark
# (docs/benchmarks/relaycast-postgres-vs-actors.md). Adapted from
# scripts/selfhost/eks-actors-sandbox.sh without the Pippen conventions: it runs
# in the infra-environments sandbox account under an operator SSO session.
#
#   AWS_PROFILE=m5lxqm2osk-dev BENCH_API_CIDR=<your egress>/32 \
#     bench/relaycast/infra/cluster.sh up|status|assoc <ns> <sa> <cp|deployer|files>|scale <group> <n>|down|audit
#
# Every taggable resource carries purpose=relaycast-actors-bench (TAG). `down`
# deletes only resources carrying that tag, and `audit` lists every tagged
# resource left in the region through the Resource Groups Tagging API plus the
# untaggable-by-API leftovers (IAM roles, ENIs), so teardown can be shown to be
# complete.
#
# What `up` creates (us-west-2 by default):
#   - VPC 10.91.0.0/16 (outside agent-relay-dev's 10.80.0.0/16), three public
#     subnets, internet gateway, no NAT;
#   - cluster and node roles, and Pod Identity roles cp/storage/deployer/files;
#   - one S3 bucket for durable-actors state, artifacts and both file stores;
#   - EKS standard-mode cluster with vpc-cni (network policy), kube-proxy,
#     coredns, eks-pod-identity-agent, metrics-server;
#   - node groups (same instance type for app and actors, so the arms compare):
#       app      BENCH_APP_NODES x BENCH_APP_TYPE        (label bench/role=app)
#       actors   BENCH_ACTOR_NODES x BENCH_APP_TYPE, one zone, tainted
#                durable-actors/actor-host=true:NoSchedule (actors arm only;
#                scaled to 0 while the Postgres arm runs)
#       loadgen  BENCH_LOADGEN_NODES x BENCH_LOADGEN_TYPE, tainted
#                bench/loadgen=true:NoSchedule, so k6 never shares a node with
#                the system under test;
#   - RDS PostgreSQL 17 db.r7g.large Multi-AZ (AA sizing), private (no public
#     access), security group open to the VPC CIDR only, master password
#     managed by RDS in Secrets Manager (never printed or passed in argv).

set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
NAME="${BENCH_NAME:-relaycast-actors-bench}"
TAG_KEY=purpose
TAG_VAL=relaycast-actors-bench
K8S_VERSION="${BENCH_K8S_VERSION:-1.34}"
API_CIDR="${BENCH_API_CIDR:-}"
VPC_CIDR=10.91.0.0/16
APP_TYPE="${BENCH_APP_TYPE:-m7i.2xlarge}"
APP_NODES="${BENCH_APP_NODES:-3}"
ACTOR_NODES="${BENCH_ACTOR_NODES:-0}"
LOADGEN_TYPE="${BENCH_LOADGEN_TYPE:-c7i.4xlarge}"
LOADGEN_NODES="${BENCH_LOADGEN_NODES:-2}"
ACTOR_ZONE="${BENCH_ACTOR_ZONE:-${REGION}a}"
DB_CLASS="${BENCH_DB_CLASS:-db.r7g.large}"
DB_ENGINE_VERSION="${BENCH_DB_ENGINE_VERSION:-17}"
# One RDS instance per arm (rds-setup.sh: one HoopDb per instance): <NAME>-pg, <NAME>-actors.
DB_ID="${NAME}-${BENCH_DB_ARM:-pg}"
DB_SUBNET_GROUP="${NAME}-db"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
EXPECTED_ACCOUNT="${BENCH_ACCOUNT:-805532413586}"
[[ "$ACCOUNT" == "$EXPECTED_ACCOUNT" ]] || { echo "refusing: account $ACCOUNT is not the sandbox $EXPECTED_ACCOUNT" >&2; exit 2; }

BUCKET="${NAME}-${ACCOUNT}"
ROLE_PATH="/${NAME}/"
ROLE_ARN_PREFIX="arn:aws:iam::${ACCOUNT}:role${ROLE_PATH}"
CLUSTER_ROLE="${NAME}-cluster"
NODE_ROLE="${NAME}-node"
CP_ROLE="${NAME}-cp"
STORAGE_ROLE="${NAME}-storage"
DEPLOYER_ROLE="${NAME}-deployer"
FILES_ROLE="${NAME}-files"
SESSIONS_ROLE="${NAME}-sessions"
EBS_ROLE="${NAME}-ebs-csi"
ROLES=("$EBS_ROLE" "$SESSIONS_ROLE" "$FILES_ROLE" "$DEPLOYER_ROLE" "$STORAGE_ROLE" "$CP_ROLE" "$NODE_ROLE" "$CLUSTER_ROLE")
LAUNCH_TEMPLATE="${NAME}-nodes"
TAG_SPEC_TAGS="{Key=${TAG_KEY},Value=${TAG_VAL}},{Key=Name,Value=${NAME}}"

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
aws_() { aws --region "$REGION" "$@"; }
none_empty() { sed 's/^None$//'; }

vpc_id() {
  aws_ ec2 describe-vpcs --filters "Name=tag:Name,Values=${NAME}" "Name=tag:${TAG_KEY},Values=${TAG_VAL}" \
    --query 'Vpcs[0].VpcId' --output text | none_empty
}

trust_service() {
  printf '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"%s"},"Action":%s}]}' "$1" "$2"
}

role_owned() {
  local v
  v="$(aws_ iam list-role-tags --role-name "$1" --query "Tags[?Key=='${TAG_KEY}'].Value | [0]" --output text | none_empty)"
  [[ "$v" == "$TAG_VAL" ]]
}

ensure_role() {
  local role="$1" trust="$2"; shift 2
  if ! aws_ iam get-role --role-name "$role" >/dev/null 2>&1; then
    log "create role ${ROLE_PATH}${role}"
    # A trust policy naming a role created seconds earlier is refused
    # (MalformedPolicyDocument) until IAM propagates it: retry.
    local try err
    for try in $(seq 1 12); do
      if err="$(aws_ iam create-role --role-name "$role" --path "$ROLE_PATH" \
          --tags "Key=${TAG_KEY},Value=${TAG_VAL}" --assume-role-policy-document "$trust" 2>&1 >/dev/null)"; then break; fi
      grep -q MalformedPolicyDocument <<<"$err" && ((try < 12)) || { echo "$err" >&2; exit 1; }
      sleep 5
    done
  else
    role_owned "$role" || { echo "role $role exists without ${TAG_KEY}=${TAG_VAL}: refusing to change it" >&2; exit 1; }
    aws_ iam update-assume-role-policy --role-name "$role" --policy-document "$trust"
  fi
  local p
  for p in "$@"; do aws_ iam attach-role-policy --role-name "$role" --policy-arn "arn:aws:iam::aws:policy/${p}"; done
}

put_policy() { aws_ iam put-role-policy --role-name "$1" --policy-name "$2" --policy-document "$3"; }

ensure_roles() {
  ensure_role "$CLUSTER_ROLE" "$(trust_service eks.amazonaws.com '"sts:AssumeRole"')" AmazonEKSClusterPolicy
  ensure_role "$NODE_ROLE" "$(trust_service ec2.amazonaws.com '"sts:AssumeRole"')" \
    AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy AmazonEC2ContainerRegistryPullOnly
  local pods='["sts:AssumeRole","sts:TagSession"]'
  ensure_role "$CP_ROLE" "$(trust_service pods.eks.amazonaws.com "$pods")"
  ensure_role "$STORAGE_ROLE" \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"${ROLE_ARN_PREFIX}${CP_ROLE}\"},\"Action\":[\"sts:AssumeRole\",\"sts:TagSession\"]}]}"
  ensure_role "$DEPLOYER_ROLE" "$(trust_service pods.eks.amazonaws.com "$pods")"
  ensure_role "$FILES_ROLE" "$(trust_service pods.eks.amazonaws.com "$pods")"
  ensure_role "$SESSIONS_ROLE" "$(trust_service pods.eks.amazonaws.com "$pods")"
  ensure_role "$EBS_ROLE" "$(trust_service pods.eks.amazonaws.com "$pods")" service-role/AmazonEBSCSIDriverPolicy
  local b="arn:aws:s3:::${BUCKET}"
  put_policy "$CP_ROLE" durable-actors \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:ListBucket\",\"s3:GetBucketLocation\"],\"Resource\":\"${b}\"},{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\"],\"Resource\":\"${b}/durable-actors/*\"},{\"Effect\":\"Allow\",\"Action\":[\"sts:AssumeRole\",\"sts:TagSession\"],\"Resource\":\"${ROLE_ARN_PREFIX}${STORAGE_ROLE}\"}]}"
  put_policy "$STORAGE_ROLE" actor-state \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"s3:ListBucket\",\"Resource\":\"${b}\"},{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\"],\"Resource\":\"${b}/durable-actors/v3/*\"}]}"
  put_policy "$DEPLOYER_ROLE" artifacts \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\"],\"Resource\":\"${b}/durable-actors/v3/artifacts/*\"}]}"
  put_policy "$FILES_ROLE" file-stores \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:ListBucket\",\"s3:GetBucketLocation\"],\"Resource\":\"${b}\"},{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\",\"s3:AbortMultipartUpload\",\"s3:ListMultipartUploadParts\"],\"Resource\":[\"${b}/relaycast/*\",\"${b}/relayfile/*\"]}]}"
  # Sessions pipeline locker (worker, ingest edge, read API, search indexer).
  put_policy "$SESSIONS_ROLE" locker \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:ListBucket\",\"s3:GetBucketLocation\"],\"Resource\":\"${b}\"},{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\"],\"Resource\":\"${b}/96bulls/*\"}]}"
}

ensure_vpc() {
  local vpc igw rtb az i sn
  vpc="$(vpc_id)"
  if [[ -z "$vpc" ]]; then
    log "create VPC ${NAME} ${VPC_CIDR}"
    vpc="$(aws_ ec2 create-vpc --cidr-block "$VPC_CIDR" \
      --tag-specifications "ResourceType=vpc,Tags=[${TAG_SPEC_TAGS}]" --query Vpc.VpcId --output text)"
    aws_ ec2 modify-vpc-attribute --vpc-id "$vpc" --enable-dns-hostnames
    igw="$(aws_ ec2 create-internet-gateway --tag-specifications "ResourceType=internet-gateway,Tags=[${TAG_SPEC_TAGS}]" \
      --query InternetGateway.InternetGatewayId --output text)"
    aws_ ec2 attach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc"
    rtb="$(aws_ ec2 create-route-table --vpc-id "$vpc" --tag-specifications "ResourceType=route-table,Tags=[${TAG_SPEC_TAGS}]" \
      --query RouteTable.RouteTableId --output text)"
    aws_ ec2 create-route --route-table-id "$rtb" --destination-cidr-block 0.0.0.0/0 --gateway-id "$igw" >/dev/null
    i=0
    for az in "${REGION}a" "${REGION}b" "${REGION}c"; do
      sn="$(aws_ ec2 create-subnet --vpc-id "$vpc" --availability-zone "$az" --cidr-block "10.91.${i}.0/20" \
        --tag-specifications "ResourceType=subnet,Tags=[${TAG_SPEC_TAGS},{Key=kubernetes.io/role/elb,Value=1}]" \
        --query Subnet.SubnetId --output text)"
      aws_ ec2 modify-subnet-attribute --subnet-id "$sn" --map-public-ip-on-launch
      aws_ ec2 associate-route-table --route-table-id "$rtb" --subnet-id "$sn" >/dev/null
      i=$((i + 16))
    done
  fi
  echo "$vpc"
}

ensure_bucket() {
  if ! aws_ s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    log "create bucket $BUCKET"
    aws_ s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
  fi
  aws_ s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws_ s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws_ s3api put-bucket-tagging --bucket "$BUCKET" --tagging "TagSet=[{Key=${TAG_KEY},Value=${TAG_VAL}}]"
}

ensure_db() {
  local vpc="$1" subnets="$2" sg
  if ! aws_ rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    aws_ rds create-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" \
      --db-subnet-group-description "$NAME" --subnet-ids $subnets --tags "Key=${TAG_KEY},Value=${TAG_VAL}" >/dev/null
  fi
  sg="$(aws_ ec2 describe-security-groups --filters "Name=vpc-id,Values=${vpc}" "Name=group-name,Values=${NAME}-db" \
    --query 'SecurityGroups[0].GroupId' --output text | none_empty)"
  if [[ -z "$sg" ]]; then
    sg="$(aws_ ec2 create-security-group --vpc-id "$vpc" --group-name "${NAME}-db" --description "${NAME} RDS from VPC" \
      --tag-specifications "ResourceType=security-group,Tags=[${TAG_SPEC_TAGS}]" --query GroupId --output text)"
    aws_ ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp --port 5432 --cidr "$VPC_CIDR" >/dev/null
  fi
  if ! aws_ rds describe-db-instances --db-instance-identifier "$DB_ID" >/dev/null 2>&1; then
    log "create RDS $DB_ID ($DB_CLASS, PostgreSQL $DB_ENGINE_VERSION, Multi-AZ)"
    aws_ rds create-db-instance --db-instance-identifier "$DB_ID" --engine postgres \
      --engine-version "$DB_ENGINE_VERSION" --db-instance-class "$DB_CLASS" --multi-az \
      --allocated-storage 200 --storage-type gp3 --storage-encrypted \
      --master-username bench_admin --manage-master-user-password \
      --db-subnet-group-name "$DB_SUBNET_GROUP" --vpc-security-group-ids "$sg" --no-publicly-accessible \
      --backup-retention-period 1 --no-deletion-protection --enable-performance-insights \
      --monitoring-interval 0 --tags "Key=${TAG_KEY},Value=${TAG_VAL}" >/dev/null
  fi
}

ensure_cluster() {
  local subnets="$1" sn_csv
  if ! aws_ eks describe-cluster --name "$NAME" >/dev/null 2>&1; then
    log "create EKS cluster $NAME ($K8S_VERSION)"
    sn_csv="$(tr ' \t' ',,' <<<"$subnets" | sed 's/,*$//')"
    aws_ eks create-cluster --name "$NAME" --kubernetes-version "$K8S_VERSION" \
      --role-arn "${ROLE_ARN_PREFIX}${CLUSTER_ROLE}" \
      --resources-vpc-config "subnetIds=${sn_csv},endpointPublicAccess=true,endpointPrivateAccess=true,publicAccessCidrs=${API_CIDR}" \
      --access-config authenticationMode=API,bootstrapClusterCreatorAdminPermissions=true \
      --no-bootstrap-self-managed-addons --tags "${TAG_KEY}=${TAG_VAL}" >/dev/null
  fi
  log "waiting for cluster ACTIVE"
  aws_ eks wait cluster-active --name "$NAME"
}

ensure_addon() {
  local addon="$1"; shift
  if ! aws_ eks describe-addon --cluster-name "$NAME" --addon-name "$addon" >/dev/null 2>&1; then
    log "create add-on $addon"
    aws_ eks create-addon --cluster-name "$NAME" --addon-name "$addon" \
      --resolve-conflicts OVERWRITE --tags "${TAG_KEY}=${TAG_VAL}" "$@" >/dev/null
  fi
}

ensure_launch_template() {
  if [[ -z "$(aws_ ec2 describe-launch-templates --filters "Name=launch-template-name,Values=${LAUNCH_TEMPLATE}" \
      --query 'LaunchTemplates[0].LaunchTemplateId' --output text 2>/dev/null | none_empty)" ]]; then
    log "create launch template $LAUNCH_TEMPLATE (IMDSv2, hop limit 1)"
    aws_ ec2 create-launch-template --launch-template-name "$LAUNCH_TEMPLATE" \
      --tag-specifications "ResourceType=launch-template,Tags=[${TAG_SPEC_TAGS}]" \
      --launch-template-data "{\"MetadataOptions\":{\"HttpTokens\":\"required\",\"HttpPutResponseHopLimit\":1,\"HttpEndpoint\":\"enabled\"},\"TagSpecifications\":[{\"ResourceType\":\"instance\",\"Tags\":[{\"Key\":\"${TAG_KEY}\",\"Value\":\"${TAG_VAL}\"},{\"Key\":\"Name\",\"Value\":\"${NAME}\"}]},{\"ResourceType\":\"volume\",\"Tags\":[{\"Key\":\"${TAG_KEY}\",\"Value\":\"${TAG_VAL}\"}]},{\"ResourceType\":\"network-interface\",\"Tags\":[{\"Key\":\"${TAG_KEY}\",\"Value\":\"${TAG_VAL}\"}]}]}" >/dev/null
  fi
}

ensure_nodegroup() {
  local group="$1" type="$2" size="$3" subnets="$4"; shift 4
  if ! aws_ eks describe-nodegroup --cluster-name "$NAME" --nodegroup-name "$group" >/dev/null 2>&1; then
    log "create node group $group ($size x $type)"
    # shellcheck disable=SC2086
    aws_ eks create-nodegroup --cluster-name "$NAME" --nodegroup-name "$group" \
      --node-role "${ROLE_ARN_PREFIX}${NODE_ROLE}" --subnets $subnets \
      --ami-type AL2023_x86_64_STANDARD --capacity-type ON_DEMAND --instance-types "$type" \
      --scaling-config "minSize=0,maxSize=$((size > 6 ? size : 6)),desiredSize=${size}" \
      --launch-template "name=${LAUNCH_TEMPLATE},version=\$Latest" \
      --tags "${TAG_KEY}=${TAG_VAL}" "$@" >/dev/null
  fi
}

kubeconfig() {
  KUBECONFIG_FILE="${BENCH_KUBECONFIG:-${HOME}/.agent-tmp/${NAME}.kubeconfig}"
  aws_ eks update-kubeconfig --name "$NAME" --alias "$NAME" --kubeconfig "$KUBECONFIG_FILE" >/dev/null
  export KUBECONFIG="$KUBECONFIG_FILE"
}

cmd_up() {
  [[ -n "$API_CIDR" ]] || { echo "BENCH_API_CIDR=<operator egress>/32 is required" >&2; exit 2; }
  local vpc subnets actor_subnet
  vpc="$(ensure_vpc)"
  subnets="$(aws_ ec2 describe-subnets --filters "Name=vpc-id,Values=${vpc}" --query 'Subnets[].SubnetId' --output text)"
  actor_subnet="$(aws_ ec2 describe-subnets --filters "Name=vpc-id,Values=${vpc}" "Name=availability-zone,Values=${ACTOR_ZONE}" \
    --query 'Subnets[0].SubnetId' --output text | none_empty)"
  [[ $(wc -w <<<"$subnets") -ge 2 && -n "$actor_subnet" ]] || { echo "VPC $vpc lacks subnets: run down, then up" >&2; exit 1; }
  ensure_roles
  ensure_bucket
  ensure_db "$vpc" "$subnets"
  ensure_cluster "$subnets"
  ensure_addon vpc-cni --configuration-values '{"enableNetworkPolicy":"true"}'
  ensure_addon kube-proxy
  ensure_addon eks-pod-identity-agent
  ensure_launch_template
  ensure_nodegroup app "$APP_TYPE" "$APP_NODES" "$subnets" --labels bench/role=app,durable-actors/role=general
  ensure_nodegroup actors "$APP_TYPE" "$ACTOR_NODES" "$actor_subnet" --labels durable-actors/role=actor-host,bench/role=actors \
    --taints "key=durable-actors/actor-host,value=true,effect=NO_SCHEDULE"
  ensure_nodegroup loadgen "$LOADGEN_TYPE" "$LOADGEN_NODES" "$subnets" --labels bench/role=loadgen \
    --taints "key=bench/loadgen,value=true,effect=NO_SCHEDULE"
  ensure_addon coredns
  ensure_addon metrics-server
  # EBS CSI (Relaycast's PVC on the Postgres backend). Volumes carry the bench
  # tag so `down` can find ones left by the chart's keep policy.
  ensure_addon aws-ebs-csi-driver \
    --pod-identity-associations "serviceAccount=ebs-csi-controller-sa,roleArn=${ROLE_ARN_PREFIX}${EBS_ROLE}" \
    --configuration-values "{\"controller\":{\"extraVolumeTags\":{\"${TAG_KEY}\":\"${TAG_VAL}\"}}}"
  log "waiting for node groups and RDS"
  for g in app actors loadgen; do aws_ eks wait nodegroup-active --cluster-name "$NAME" --nodegroup-name "$g"; done
  aws_ rds wait db-instance-available --db-instance-identifier "$DB_ID"
  kubeconfig
  kubectl apply -f - >/dev/null <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations: {storageclass.kubernetes.io/is-default-class: "true"}
provisioner: ebs.csi.aws.com
parameters: {type: gp3, encrypted: "true"}
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
  kubectl get nodes -L bench/role,topology.kubernetes.io/zone,node.kubernetes.io/instance-type
  cmd_status
}

cmd_scale() {
  local group="${1:?group}" n="${2:?count}"
  log "scale node group $group to $n"
  aws_ eks update-nodegroup-config --cluster-name "$NAME" --nodegroup-name "$group" \
    --scaling-config "minSize=0,maxSize=$((n > 6 ? n : 6)),desiredSize=${n}" >/dev/null
}

cmd_assoc() {
  local ns="${1:?namespace}" sa="${2:?serviceaccount}" kind="${3:?cp|deployer|files}" role
  case "$kind" in cp) role="$CP_ROLE" ;; deployer) role="$DEPLOYER_ROLE" ;; files) role="$FILES_ROLE" ;; sessions) role="$SESSIONS_ROLE" ;;
    *) echo "role kind must be cp, deployer, files or sessions" >&2; exit 2 ;; esac
  local want="${ROLE_ARN_PREFIX}${role}" id
  id="$(aws_ eks list-pod-identity-associations --cluster-name "$NAME" --namespace "$ns" \
    --service-account "$sa" --query 'associations[0].associationId' --output text | none_empty)"
  if [[ -n "$id" ]]; then
    aws_ eks update-pod-identity-association --cluster-name "$NAME" --association-id "$id" --role-arn "$want" >/dev/null
  else
    aws_ eks create-pod-identity-association --cluster-name "$NAME" --namespace "$ns" \
      --service-account "$sa" --role-arn "$want" --tags "${TAG_KEY}=${TAG_VAL}" >/dev/null
  fi
  log "pod identity ${ns}/${sa} -> ${role}"
}

# db <arm>: create (and wait for) the arm's RDS instance in the bench VPC.
cmd_db() {
  DB_ID="${NAME}-${1:?pg|actors}"
  local vpc subnets
  vpc="$(vpc_id)"; [[ -n "$vpc" ]] || { echo "no bench VPC: run up first" >&2; exit 1; }
  subnets="$(aws_ ec2 describe-subnets --filters "Name=vpc-id,Values=${vpc}" --query 'Subnets[].SubnetId' --output text)"
  ensure_db "$vpc" "$subnets"
  aws_ rds wait db-instance-available --db-instance-identifier "$DB_ID"
  log "RDS $DB_ID available"
}

# db-nossl <arm>: the durable-actors control plane cannot verify the RDS CA
# (the chart mounts no CA bundle and its TLS client refuses the RDS chain), so
# the actors arm's instance gets a parameter group with rds.force_ssl=0 and the
# control plane connects with sslmode=disable inside the VPC. Every other
# component keeps verify-full TLS. Static parameter: the instance reboots.
cmd_db_nossl() {
  local id="${NAME}-${1:?pg|actors}" pg="${NAME}-${1}-pg17"
  if ! aws_ rds describe-db-parameter-groups --db-parameter-group-name "$pg" >/dev/null 2>&1; then
    aws_ rds create-db-parameter-group --db-parameter-group-name "$pg" --db-parameter-group-family postgres17 \
      --description "${NAME}: rds.force_ssl=0 for the durable-actors control plane" --tags "Key=${TAG_KEY},Value=${TAG_VAL}" >/dev/null
  fi
  aws_ rds modify-db-parameter-group --db-parameter-group-name "$pg" \
    --parameters "ParameterName=rds.force_ssl,ParameterValue=0,ApplyMethod=pending-reboot" >/dev/null
  aws_ rds modify-db-instance --db-instance-identifier "$id" --db-parameter-group-name "$pg" --apply-immediately >/dev/null
  aws_ rds wait db-instance-available --db-instance-identifier "$id"
  aws_ rds reboot-db-instance --db-instance-identifier "$id" >/dev/null
  sleep 30
  aws_ rds wait db-instance-available --db-instance-identifier "$id"
  log "RDS $id: parameter group $pg (rds.force_ssl=0) applied"
}

# db-down <arm>: delete the arm's RDS instance (no final snapshot: benchmark data only).
cmd_db_down() {
  local id="${NAME}-${1:?pg|actors}"
  if aws_ rds describe-db-instances --db-instance-identifier "$id" >/dev/null 2>&1; then
    log "delete RDS $id"
    aws_ rds delete-db-instance --db-instance-identifier "$id" --skip-final-snapshot --delete-automated-backups >/dev/null 2>&1 || true
    aws_ rds wait db-instance-deleted --db-instance-identifier "$id"; deleted "rds-instance $id"
  fi
  if aws_ rds describe-db-parameter-groups --db-parameter-group-name "${NAME}-${1}-pg17" >/dev/null 2>&1; then
    aws_ rds delete-db-parameter-group --db-parameter-group-name "${NAME}-${1}-pg17"; deleted "rds-parameter-group ${NAME}-${1}-pg17"
  fi
}

cmd_status() {
  aws_ eks describe-cluster --name "$NAME" --query 'cluster.{name:name,status:status,version:version}' --output json 2>/dev/null || echo '{"cluster":"absent"}'
  aws_ eks list-nodegroups --cluster-name "$NAME" --query nodegroups --output text 2>/dev/null || true
  aws_ rds describe-db-instances --db-instance-identifier "$DB_ID" \
    --query 'DBInstances[0].{db:DBInstanceIdentifier,status:DBInstanceStatus,class:DBInstanceClass,multiAz:MultiAZ,endpoint:Endpoint.Address}' \
    --output json 2>/dev/null || echo '{"db":"absent"}'
  printf 'vpc=%s bucket=%s\n' "$(vpc_id)" "$(aws_ s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 && echo "$BUCKET" || echo absent)"
}

cluster_exists() {
  local err
  if err="$(aws_ eks describe-cluster --name "$NAME" 2>&1 >/dev/null)"; then return 0; fi
  grep -q ResourceNotFoundException <<<"$err" && return 1
  echo "describe-cluster $NAME failed: $err" >&2; exit 1
}

# Every deletion is appended to DELETED_LOG (docs evidence).
DELETED_LOG="${BENCH_DELETED_LOG:-${HOME}/.agent-tmp/${NAME}-deleted.txt}"
deleted() { printf '%s\t%s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$DELETED_LOG" >&2; }

cmd_down() {
  local vpc assoc group id
  if cluster_exists; then
    kubeconfig
    kubectl delete ingress --all -A --wait=true --timeout=10m || true
    kubectl delete svc -A --field-selector spec.type=LoadBalancer --wait=true --timeout=10m || true
    kubectl delete pvc --all -A --wait=true --timeout=10m || true
    for assoc in $(aws_ eks list-pod-identity-associations --cluster-name "$NAME" --query 'associations[].associationId' --output text); do
      aws_ eks delete-pod-identity-association --cluster-name "$NAME" --association-id "$assoc" >/dev/null; deleted "pod-identity-association $assoc"
    done
    for group in $(aws_ eks list-nodegroups --cluster-name "$NAME" --query nodegroups --output text); do
      aws_ eks delete-nodegroup --cluster-name "$NAME" --nodegroup-name "$group" >/dev/null
    done
    for group in $(aws_ eks list-nodegroups --cluster-name "$NAME" --query nodegroups --output text); do
      aws_ eks wait nodegroup-deleted --cluster-name "$NAME" --nodegroup-name "$group"; deleted "eks-nodegroup $NAME/$group"
    done
    for id in $(aws_ eks list-addons --cluster-name "$NAME" --query addons --output text); do
      aws_ eks delete-addon --cluster-name "$NAME" --addon-name "$id" >/dev/null || true
    done
    local try
    for try in $(seq 1 20); do
      aws_ eks delete-cluster --name "$NAME" >/dev/null 2>&1 && break
      ((try == 20)) && aws_ eks delete-cluster --name "$NAME" >/dev/null
      sleep 30
    done
    aws_ eks wait cluster-deleted --name "$NAME"; deleted "eks-cluster $NAME"
  fi
  # Volumes kept by helm.sh/resource-policy: keep (relaycast-data) outlive the cluster.
  for id in $(aws_ ec2 describe-volumes --filters "Name=tag:${TAG_KEY},Values=${TAG_VAL}" "Name=status,Values=available" --query 'Volumes[].VolumeId' --output text); do
    aws_ ec2 delete-volume --volume-id "$id"; deleted "ebs-volume $id"
  done
  cmd_db_down pg
  cmd_db_down actors
  if aws_ rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null 2>&1; then
    aws_ rds delete-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP"; deleted "rds-subnet-group $DB_SUBNET_GROUP"
  fi
  for id in $(aws_ ec2 describe-launch-templates --filters "Name=launch-template-name,Values=${LAUNCH_TEMPLATE}" \
      --query 'LaunchTemplates[].LaunchTemplateId' --output text 2>/dev/null); do
    aws_ ec2 delete-launch-template --launch-template-id "$id" >/dev/null; deleted "launch-template $id"
  done
  if aws_ s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    aws_ s3 rm "s3://${BUCKET}" --recursive --only-show-errors
    aws_ s3api delete-bucket --bucket "$BUCKET"; deleted "s3-bucket $BUCKET"
  fi
  vpc="$(vpc_id)"
  if [[ -n "$vpc" ]]; then
    local lb
    for lb in $(aws_ elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='${vpc}'].LoadBalancerArn" --output text); do
      aws_ elbv2 delete-load-balancer --load-balancer-arn "$lb"; deleted "load-balancer $lb"
    done
    for _ in $(seq 1 30); do
      [[ -z "$(aws_ ec2 describe-network-interfaces --filters "Name=vpc-id,Values=${vpc}" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)" ]] && break
      sleep 20
    done
    for id in $(aws_ ec2 describe-security-groups --filters "Name=vpc-id,Values=${vpc}" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
      aws_ ec2 delete-security-group --group-id "$id" && deleted "security-group $id" || true
    done
    for id in $(aws_ ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=${vpc}" --query 'InternetGateways[].InternetGatewayId' --output text); do
      aws_ ec2 detach-internet-gateway --internet-gateway-id "$id" --vpc-id "$vpc"
      aws_ ec2 delete-internet-gateway --internet-gateway-id "$id"; deleted "internet-gateway $id"
    done
    for id in $(aws_ ec2 describe-subnets --filters "Name=vpc-id,Values=${vpc}" --query 'Subnets[].SubnetId' --output text); do
      aws_ ec2 delete-subnet --subnet-id "$id"; deleted "subnet $id"
    done
    for id in $(aws_ ec2 describe-route-tables --filters "Name=vpc-id,Values=${vpc}" --query 'RouteTables[?!(Associations[?Main])].RouteTableId' --output text); do
      aws_ ec2 delete-route-table --route-table-id "$id"; deleted "route-table $id"
    done
    aws_ ec2 delete-vpc --vpc-id "$vpc"; deleted "vpc $vpc"
  fi
  local role p
  for role in "${ROLES[@]}"; do
    aws_ iam get-role --role-name "$role" >/dev/null 2>&1 || continue
    role_owned "$role" || { log "keep role $role: not tagged ${TAG_KEY}=${TAG_VAL}"; continue; }
    for p in $(aws_ iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text); do
      aws_ iam delete-role-policy --role-name "$role" --policy-name "$p"
    done
    for p in $(aws_ iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text); do
      aws_ iam detach-role-policy --role-name "$role" --policy-arn "$p"
    done
    aws_ iam delete-role --role-name "$role"; deleted "iam-role $role"
  done
  # RDS-managed master secret is deleted with the instance; report any leftovers.
  cmd_audit
}

# audit: prints every resource still tagged purpose=relaycast-actors-bench plus
# checks the Tagging API cannot see. Exit 1 when anything is left.
cmd_audit() {
  local left=0 out
  out="$(aws_ resourcegroupstaggingapi get-resources --tag-filters "Key=${TAG_KEY},Values=${TAG_VAL}" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text)"
  # The Tagging API can list a deleted resource for a while; verify instances directly.
  [[ -n "$out" ]] && { echo "tagged (Tagging API):"; tr '\t' '\n' <<<"$out"; left=1; }
  out="$(aws_ ec2 describe-instances --filters "Name=tag:${TAG_KEY},Values=${TAG_VAL}" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text)"
  [[ -n "$out" ]] && { echo "instances: $out"; left=1; }
  out="$(aws_ ec2 describe-volumes --filters "Name=tag:${TAG_KEY},Values=${TAG_VAL}" --query 'Volumes[].VolumeId' --output text)"
  [[ -n "$out" ]] && { echo "volumes: $out"; left=1; }
  out="$(aws_ ec2 describe-network-interfaces --filters "Name=tag:${TAG_KEY},Values=${TAG_VAL}" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)"
  [[ -n "$out" ]] && { echo "enis: $out"; left=1; }
  out="$(aws_ iam list-roles --path-prefix "$ROLE_PATH" --query 'Roles[].RoleName' --output text)"
  [[ -n "$out" ]] && { echo "iam roles: $out"; left=1; }
  out="$(aws_ secretsmanager list-secrets --filters "Key=name,Values=${NAME}/" --query 'SecretList[].Name' --output text)"
  [[ -n "$out" ]] && { echo "secrets: $out"; left=1; }
  out="$(aws_ eks list-clusters --query "clusters[?@=='${NAME}']" --output text)"
  [[ -n "$out" ]] && { echo "eks: $out"; left=1; }
  out="$(aws_ rds describe-db-instances --query "DBInstances[?starts_with(DBInstanceIdentifier, '${NAME}-')].DBInstanceIdentifier" --output text)"
  [[ -n "$out" ]] && { echo "rds: $out"; left=1; }
  if ((left)); then echo "AUDIT: resources remain" >&2; return 1; fi
  echo "AUDIT: zero ${TAG_KEY}=${TAG_VAL} resources in ${ACCOUNT}/${REGION}"
}

case "${1:-}" in
  up) cmd_up ;;
  db) shift; cmd_db "$@" ;;
  db-down) shift; cmd_db_down "$@" ;;
  db-nossl) shift; cmd_db_nossl "$@" ;;
  down) cmd_down ;;
  status) cmd_status ;;
  audit) cmd_audit ;;
  scale) shift; cmd_scale "$@" ;;
  assoc) shift; cmd_assoc "$@" ;;
  *) echo "usage: $0 up|status|scale <group> <n>|assoc <ns> <sa> <cp|deployer|files>|down|audit" >&2; exit 2 ;;
esac
