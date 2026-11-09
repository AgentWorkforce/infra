#!/usr/bin/env bash
#
# Standard-mode (not Auto Mode) EKS substrate for the durable-actors-on-AWS
# proof, built inside a Pippen sandbox. Variant of eks-proof-sandbox.sh.
# Run every subcommand under the lease's agent-session role:
#
#   pippen sandbox exec actors-proof -- scripts/selfhost/eks-actors-sandbox.sh up
#   pippen sandbox exec actors-proof -- scripts/selfhost/eks-actors-sandbox.sh status
#   pippen sandbox exec actors-proof -- scripts/selfhost/eks-actors-sandbox.sh assoc <ns> <sa> <cp|deployer|files>
#   pippen sandbox exec actors-proof -- scripts/selfhost/eks-actors-sandbox.sh down
#
# Pippen conventions: pippen:sandbox=true on every taggable resource, IAM
# roles under /pippen/workload/ with pippen-agent-session-boundary, names
# starting pippen-sbx-.
#
# Why standard mode: the actor hosts get a dedicated, tainted managed node
# group (label durable-actors/role=actor-host, taint
# durable-actors/actor-host=true:NoSchedule). Auto Mode's built-in pools take
# no custom taints, and a custom NodeClass rejects node roles under
# /pippen/workload/ (see eks-proof-sandbox.sh). A managed node group is also
# the path to the optional gVisor hardening (custom launch template).
#
# What it creates (us-west-2 by default):
#   - a VPC with two public subnets and an internet gateway (no NAT);
#   - the cluster role and the node role;
#   - an EKS cluster (API auth, public endpoint limited to the operator /32)
#     with managed add-ons vpc-cni (network policy enforcement on),
#     kube-proxy, coredns and eks-pod-identity-agent;
#   - a launch template with IMDSv2 required and hop limit 1, so pods cannot
#     reach the node's instance metadata;
#   - managed node groups `general` (2 nodes) and `actors` (1 tainted node);
#   - one S3 bucket for durable-actors state and artifacts plus the file stores;
#   - Pod Identity roles: control plane (S3 + AssumeRole on the actor-storage
#     role), actor-storage (assumed per actor with a session policy), deployer
#     (artifact uploads), files (relaycast/relayfile file stores).
#
# Pod Identity associations are made by `assoc` once the chart's
# ServiceAccount names are known.

set -euo pipefail

: "${PIPPEN_SANDBOX_ACCOUNT_ID:?run under pippen sandbox exec}"
ACCOUNT="$PIPPEN_SANDBOX_ACCOUNT_ID"
REGION="${AWS_REGION:-us-west-2}"
NAME="${EKS_ACTORS_NAME:-pippen-sbx-actors-proof}"
K8S_VERSION="${EKS_ACTORS_K8S_VERSION:-1.34}"
API_CIDR="${EKS_ACTORS_API_CIDR:-}"
INSTANCE_TYPE="${EKS_ACTORS_INSTANCE_TYPE:-t3.large}"
GENERAL_NODES="${EKS_ACTORS_GENERAL_NODES:-2}"
ACTOR_NODES="${EKS_ACTORS_ACTOR_NODES:-1}"
# The actor node group lives in ONE zone, the zone durable-actors places actors in
# (chart value durable-actors.placement.zone must equal it), so a replacement node
# can never land where actors cannot be scheduled.
ACTOR_ZONE="${EKS_ACTORS_ACTOR_ZONE:-${REGION}a}"
BUCKET="${NAME}-${ACCOUNT}"
BOUNDARY="arn:aws:iam::${ACCOUNT}:policy/pippen-agent-session-boundary"
ROLE_PATH="/pippen/workload/"
ROLE_ARN_PREFIX="arn:aws:iam::${ACCOUNT}:role${ROLE_PATH}"
CLUSTER_ROLE="${NAME}-cluster"
NODE_ROLE="${NAME}-node"
# Workload roles are per proof, so two proofs in one account never share or delete
# each other's roles. EKS_ACTORS_ROLE_PREFIX exists only to reach roles made by an
# older copy of this script (prefix pippen-sbx-actors).
ROLE_PREFIX="${EKS_ACTORS_ROLE_PREFIX:-$NAME}"
CP_ROLE="${ROLE_PREFIX}-cp"
STORAGE_ROLE="${ROLE_PREFIX}-storage"
DEPLOYER_ROLE="${ROLE_PREFIX}-deployer"
FILES_ROLE="${ROLE_PREFIX}-files"
for r in "$CLUSTER_ROLE" "$NODE_ROLE" "$CP_ROLE" "$STORAGE_ROLE" "$DEPLOYER_ROLE" "$FILES_ROLE"; do
  ((${#r} <= 64)) || { echo "IAM role name $r is longer than 64 characters: shorten EKS_ACTORS_NAME" >&2; exit 2; }
done
((${#BUCKET} <= 63)) || { echo "bucket name $BUCKET is longer than 63 characters: shorten EKS_ACTORS_NAME" >&2; exit 2; }
# Every role this script creates carries OWNER_TAG=<NAME>; existing roles are
# updated or deleted only with that tag. EKS_ACTORS_ADOPT_ROLES=1 adopts (tags)
# same-named roles made by an older copy of this script that did not tag them.
OWNER_TAG="agent-relay.dev/eks-actors-proof"
LAUNCH_TEMPLATE="${NAME}-nodes"
TAG_KEY="pippen:sandbox"
TAG_SPEC_TAGS="{Key=${TAG_KEY},Value=true},{Key=Name,Value=${NAME}}"

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
aws_() { aws --region "$REGION" "$@"; }
none_empty() { sed 's/^None$//'; }

vpc_id() {
  aws_ ec2 describe-vpcs --filters "Name=tag:Name,Values=${NAME}" "Name=tag:${TAG_KEY},Values=true" \
    --query 'Vpcs[0].VpcId' --output text | none_empty
}

trust_service() {
  printf '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"%s"},"Action":%s}]}' "$1" "$2"
}

# role_owned <role>: true when the role carries OWNER_TAG=$NAME (adopting an
# untagged one when EKS_ACTORS_ADOPT_ROLES=1).
role_owned() {
  local owner
  owner="$(aws_ iam list-role-tags --role-name "$1" --query "Tags[?Key=='${OWNER_TAG}'].Value | [0]" --output text | none_empty)"
  [[ "$owner" == "$NAME" ]] && return 0
  if [[ -z "$owner" && -n "${EKS_ACTORS_ADOPT_ROLES:-}" ]]; then
    aws_ iam tag-role --role-name "$1" --tags "Key=${OWNER_TAG},Value=${NAME}"
    log "adopted role $1"; return 0
  fi
  return 1
}

ensure_role() {
  local role="$1" trust="$2"; shift 2
  if ! aws_ iam get-role --role-name "$role" >/dev/null 2>&1; then
    log "create role ${ROLE_PATH}${role}"
    aws_ iam create-role --role-name "$role" --path "$ROLE_PATH" \
      --permissions-boundary "$BOUNDARY" --tags "Key=${TAG_KEY},Value=true" "Key=${OWNER_TAG},Value=${NAME}" \
      --assume-role-policy-document "$trust" >/dev/null
  else
    role_owned "$role" || { echo "role $role exists but is not tagged ${OWNER_TAG}=${NAME}: refusing to change it" >&2; exit 1; }
    aws_ iam update-assume-role-policy --role-name "$role" --policy-document "$trust"
  fi
  local p
  for p in "$@"; do
    aws_ iam attach-role-policy --role-name "$role" --policy-arn "arn:aws:iam::aws:policy/${p}"
  done
}

put_policy() {
  aws_ iam put-role-policy --role-name "$1" --policy-name "$2" --policy-document "$3"
}

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

  local b="arn:aws:s3:::${BUCKET}"
  put_policy "$CP_ROLE" durable-actors \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:ListBucket\",\"s3:GetBucketLocation\"],\"Resource\":\"${b}\"},{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\"],\"Resource\":\"${b}/durable-actors/*\"},{\"Effect\":\"Allow\",\"Action\":[\"sts:AssumeRole\",\"sts:TagSession\"],\"Resource\":\"${ROLE_ARN_PREFIX}${STORAGE_ROLE}\"}]}"
  put_policy "$STORAGE_ROLE" actor-state \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"s3:ListBucket\",\"Resource\":\"${b}\"},{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\"],\"Resource\":\"${b}/durable-actors/v3/*\"}]}"
  put_policy "$DEPLOYER_ROLE" artifacts \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\"],\"Resource\":\"${b}/durable-actors/v3/artifacts/*\"}]}"
  put_policy "$FILES_ROLE" file-stores \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:ListBucket\",\"s3:GetBucketLocation\"],\"Resource\":\"${b}\"},{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\",\"s3:AbortMultipartUpload\",\"s3:ListMultipartUploadParts\"],\"Resource\":[\"${b}/relaycast/*\",\"${b}/relayfile/*\"]}]}"
}

ensure_vpc() {
  local vpc igw rtb az i sn
  vpc="$(vpc_id)"
  if [[ -z "$vpc" ]]; then
    log "create VPC ${NAME}"
    vpc="$(aws_ ec2 create-vpc --cidr-block 10.43.0.0/16 \
      --tag-specifications "ResourceType=vpc,Tags=[${TAG_SPEC_TAGS}]" --query Vpc.VpcId --output text)"
    aws_ ec2 modify-vpc-attribute --vpc-id "$vpc" --enable-dns-hostnames
    igw="$(aws_ ec2 create-internet-gateway \
      --tag-specifications "ResourceType=internet-gateway,Tags=[${TAG_SPEC_TAGS}]" \
      --query InternetGateway.InternetGatewayId --output text)"
    aws_ ec2 attach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc"
    rtb="$(aws_ ec2 create-route-table --vpc-id "$vpc" \
      --tag-specifications "ResourceType=route-table,Tags=[${TAG_SPEC_TAGS}]" \
      --query RouteTable.RouteTableId --output text)"
    aws_ ec2 create-route --route-table-id "$rtb" --destination-cidr-block 0.0.0.0/0 --gateway-id "$igw" >/dev/null
    i=0
    for az in "${REGION}a" "${REGION}b"; do
      sn="$(aws_ ec2 create-subnet --vpc-id "$vpc" --availability-zone "$az" --cidr-block "10.43.${i}.0/20" \
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
    if [[ "$REGION" == us-east-1 ]]; then
      aws_ s3api create-bucket --bucket "$BUCKET" >/dev/null  # us-east-1 rejects an explicit LocationConstraint
    else
      aws_ s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
    fi
  fi
  aws_ s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws_ s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws_ s3api put-bucket-tagging --bucket "$BUCKET" --tagging "TagSet=[{Key=${TAG_KEY},Value=true}]"
}

ensure_cluster() {
  local subnets="$1" sn_csv
  if ! aws_ eks describe-cluster --name "$NAME" >/dev/null 2>&1; then
    log "create EKS cluster $NAME ($K8S_VERSION, standard mode)"
    sn_csv="$(tr ' \t' ',,' <<<"$subnets" | sed 's/,*$//')"
    aws_ eks create-cluster --name "$NAME" --kubernetes-version "$K8S_VERSION" \
      --role-arn "${ROLE_ARN_PREFIX}${CLUSTER_ROLE}" \
      --resources-vpc-config "subnetIds=${sn_csv},endpointPublicAccess=true,endpointPrivateAccess=true,publicAccessCidrs=${API_CIDR}" \
      --access-config authenticationMode=API,bootstrapClusterCreatorAdminPermissions=true \
      --no-bootstrap-self-managed-addons \
      --tags "${TAG_KEY}=true" >/dev/null
  fi
  log "waiting for cluster ACTIVE"
  aws_ eks wait cluster-active --name "$NAME"
}

ensure_addon() {
  local addon="$1"; shift
  if ! aws_ eks describe-addon --cluster-name "$NAME" --addon-name "$addon" >/dev/null 2>&1; then
    log "create add-on $addon"
    aws_ eks create-addon --cluster-name "$NAME" --addon-name "$addon" \
      --resolve-conflicts OVERWRITE --tags "${TAG_KEY}=true" "$@" >/dev/null
  elif (($#)); then
    # An existing add-on gets the requested configuration too (e.g. vpc-cni
    # enableNetworkPolicy), so a reused cluster cannot run without it.
    log "update add-on $addon configuration"
    aws_ eks update-addon --cluster-name "$NAME" --addon-name "$addon" --resolve-conflicts OVERWRITE "$@" >/dev/null
    aws_ eks wait addon-active --cluster-name "$NAME" --addon-name "$addon"
  fi
}

ensure_launch_template() {
  if [[ -z "$(aws_ ec2 describe-launch-templates --filters "Name=launch-template-name,Values=${LAUNCH_TEMPLATE}" \
      --query 'LaunchTemplates[0].LaunchTemplateId' --output text 2>/dev/null | none_empty)" ]]; then
    log "create launch template $LAUNCH_TEMPLATE (IMDSv2, hop limit 1)"
    aws_ ec2 create-launch-template --launch-template-name "$LAUNCH_TEMPLATE" \
      --tag-specifications "ResourceType=launch-template,Tags=[${TAG_SPEC_TAGS}]" \
      --launch-template-data "{\"MetadataOptions\":{\"HttpTokens\":\"required\",\"HttpPutResponseHopLimit\":1,\"HttpEndpoint\":\"enabled\"},\"TagSpecifications\":[{\"ResourceType\":\"instance\",\"Tags\":[{\"Key\":\"${TAG_KEY}\",\"Value\":\"true\"},{\"Key\":\"Name\",\"Value\":\"${NAME}\"}]},{\"ResourceType\":\"volume\",\"Tags\":[{\"Key\":\"${TAG_KEY}\",\"Value\":\"true\"}]},{\"ResourceType\":\"network-interface\",\"Tags\":[{\"Key\":\"${TAG_KEY}\",\"Value\":\"true\"}]}]}" >/dev/null
  fi
}

ensure_nodegroup() {
  local group="$1" size="$2" subnets="$3"; shift 3
  if ! aws_ eks describe-nodegroup --cluster-name "$NAME" --nodegroup-name "$group" >/dev/null 2>&1; then
    log "create node group $group ($size x $INSTANCE_TYPE)"
    # shellcheck disable=SC2086
    aws_ eks create-nodegroup --cluster-name "$NAME" --nodegroup-name "$group" \
      --node-role "${ROLE_ARN_PREFIX}${NODE_ROLE}" --subnets $subnets \
      --ami-type AL2023_x86_64_STANDARD --capacity-type ON_DEMAND --instance-types "$INSTANCE_TYPE" \
      --scaling-config "minSize=${size},maxSize=${size},desiredSize=${size}" \
      --launch-template "name=${LAUNCH_TEMPLATE},version=\$Latest" \
      --tags "${TAG_KEY}=true" "$@" >/dev/null
  fi
}

kubeconfig() {
  if [[ -z "${KUBECONFIG_FILE:-}" ]]; then KUBECONFIG_FILE="$(mktemp)"; KUBECONFIG_TEMP=1; fi
  aws_ eks update-kubeconfig --name "$NAME" --alias actors-proof --kubeconfig "$KUBECONFIG_FILE" >/dev/null
  export KUBECONFIG="$KUBECONFIG_FILE"
}

# Removes the kubeconfig only when this script created it (never a caller's file).
drop_kubeconfig() {
  [[ -n "${KUBECONFIG_TEMP:-}" && -z "${KEEP_KUBECONFIG:-}" ]] && rm -f "$KUBECONFIG_FILE"
  return 0
}

cmd_up() {
  [[ -n "$API_CIDR" ]] || { echo "EKS_ACTORS_API_CIDR=<operator egress>/32 is required" >&2; exit 2; }
  local vpc subnets actor_subnet
  vpc="$(ensure_vpc)"
  subnets="$(aws_ ec2 describe-subnets --filters "Name=vpc-id,Values=${vpc}" --query 'Subnets[].SubnetId' --output text)"
  actor_subnet="$(aws_ ec2 describe-subnets --filters "Name=vpc-id,Values=${vpc}" "Name=availability-zone,Values=${ACTOR_ZONE}" \
    --query 'Subnets[0].SubnetId' --output text | none_empty)"
  # A VPC left by a failed earlier run can lack its subnets; ensure_vpc only
  # creates them with the VPC, so stop here (run `down`, then `up`).
  if [[ $(wc -w <<<"$subnets") -lt 2 || -z "$actor_subnet" ]]; then
    echo "VPC $vpc lacks its two subnets (or one in $ACTOR_ZONE): partial earlier run; run down, then up" >&2; exit 1
  fi
  log "vpc $vpc subnets $subnets (actors: $actor_subnet in $ACTOR_ZONE)"
  ensure_roles
  ensure_bucket
  ensure_cluster "$subnets"
  ensure_addon vpc-cni --configuration-values '{"enableNetworkPolicy":"true"}'
  ensure_addon kube-proxy
  ensure_addon eks-pod-identity-agent
  ensure_launch_template
  ensure_nodegroup general "$GENERAL_NODES" "$subnets" --labels durable-actors/role=general
  ensure_nodegroup actors "$ACTOR_NODES" "$actor_subnet" --labels durable-actors/role=actor-host \
    --taints "key=durable-actors/actor-host,value=true,effect=NO_SCHEDULE"
  ensure_addon coredns
  log "waiting for node groups ACTIVE"
  aws_ eks wait nodegroup-active --cluster-name "$NAME" --nodegroup-name general
  aws_ eks wait nodegroup-active --cluster-name "$NAME" --nodegroup-name actors
  kubeconfig
  kubectl get nodes -L durable-actors/role,topology.kubernetes.io/zone
  drop_kubeconfig
  cmd_status
}

# assoc <namespace> <serviceaccount> <cp|deployer|files>
cmd_assoc() {
  local ns="${1:?namespace}" sa="${2:?serviceaccount}" kind="${3:?cp|deployer|files}" role
  case "$kind" in
    cp) role="$CP_ROLE" ;;
    deployer) role="$DEPLOYER_ROLE" ;;
    files) role="$FILES_ROLE" ;;
    *) echo "role kind must be cp, deployer or files" >&2; exit 2 ;;
  esac
  local want="${ROLE_ARN_PREFIX}${role}" id have
  id="$(aws_ eks list-pod-identity-associations --cluster-name "$NAME" --namespace "$ns" \
    --service-account "$sa" --query 'associations[0].associationId' --output text | none_empty)"
  if [[ -n "$id" ]]; then
    have="$(aws_ eks describe-pod-identity-association --cluster-name "$NAME" --association-id "$id" \
      --query association.roleArn --output text)"
    if [[ "$have" == "$want" ]]; then log "pod identity ${ns}/${sa} already -> ${role}"; return; fi
    log "pod identity ${ns}/${sa} was ${have}; repointing to ${role}"
    aws_ eks update-pod-identity-association --cluster-name "$NAME" --association-id "$id" --role-arn "$want" >/dev/null
    return
  fi
  aws_ eks create-pod-identity-association --cluster-name "$NAME" --namespace "$ns" \
    --service-account "$sa" --role-arn "$want" --tags "${TAG_KEY}=true" >/dev/null
  log "pod identity ${ns}/${sa} -> ${role}"
}

cmd_status() {
  aws_ eks describe-cluster --name "$NAME" \
    --query 'cluster.{name:name,status:status,version:version,endpoint:endpoint}' --output json 2>/dev/null || echo '{"cluster":"absent"}'
  aws_ eks list-nodegroups --cluster-name "$NAME" --query nodegroups --output text 2>/dev/null || true
  printf 'vpc=%s bucket=%s\n' "$(vpc_id)" "$(aws_ s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 && echo "$BUCKET" || echo absent)"
}

# cluster_exists: 0 when the cluster exists, 1 when EKS confirms it does not;
# any other lookup error stops the script, so `down` never deletes storage
# while a cluster it could not see may still be running actors.
cluster_exists() {
  local err
  if err="$(aws_ eks describe-cluster --name "$NAME" 2>&1 >/dev/null)"; then return 0; fi
  if grep -q ResourceNotFoundException <<<"$err"; then return 1; fi
  echo "describe-cluster $NAME failed: $err" >&2
  exit 1
}

cmd_down() {
  local vpc assoc group id
  if cluster_exists; then
    kubeconfig
    kubectl delete ingress --all -A --wait=true --timeout=10m || true
    kubectl delete svc -A --field-selector spec.type=LoadBalancer --wait=true --timeout=10m || true
    kubectl delete pvc --all -A --wait=true --timeout=10m || true
    drop_kubeconfig
    for assoc in $(aws_ eks list-pod-identity-associations --cluster-name "$NAME" --query 'associations[].associationId' --output text); do
      aws_ eks delete-pod-identity-association --cluster-name "$NAME" --association-id "$assoc" >/dev/null
    done
    for group in $(aws_ eks list-nodegroups --cluster-name "$NAME" --query nodegroups --output text); do
      log "delete node group $group"
      aws_ eks delete-nodegroup --cluster-name "$NAME" --nodegroup-name "$group" >/dev/null
    done
    for group in $(aws_ eks list-nodegroups --cluster-name "$NAME" --query nodegroups --output text); do
      aws_ eks wait nodegroup-deleted --cluster-name "$NAME" --nodegroup-name "$group"
    done
    for id in $(aws_ eks list-addons --cluster-name "$NAME" --query addons --output text); do
      aws_ eks delete-addon --cluster-name "$NAME" --addon-name "$id" >/dev/null || true
    done
    log "delete cluster $NAME"
    local try
    for try in $(seq 1 20); do
      aws_ eks delete-cluster --name "$NAME" >/dev/null 2>&1 && break
      ((try == 20)) && aws_ eks delete-cluster --name "$NAME" >/dev/null
      sleep 30
    done
    aws_ eks wait cluster-deleted --name "$NAME"
  fi
  for id in $(aws_ ec2 describe-launch-templates --filters "Name=launch-template-name,Values=${LAUNCH_TEMPLATE}" \
      --query 'LaunchTemplates[].LaunchTemplateId' --output text 2>/dev/null); do
    log "delete launch template $id"; aws_ ec2 delete-launch-template --launch-template-id "$id" >/dev/null
  done
  if aws_ s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    log "empty and delete bucket $BUCKET"
    aws_ s3 rm "s3://${BUCKET}" --recursive --only-show-errors
    aws_ s3api delete-bucket --bucket "$BUCKET"
  fi
  vpc="$(vpc_id)"
  if [[ -n "$vpc" ]]; then
    local lb
    for lb in $(aws_ elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='${vpc}'].LoadBalancerArn" --output text); do
      log "delete leftover load balancer $lb"; aws_ elbv2 delete-load-balancer --load-balancer-arn "$lb"
    done
    for _ in $(seq 1 30); do
      [[ -z "$(aws_ ec2 describe-network-interfaces --filters "Name=vpc-id,Values=${vpc}" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)" ]] && break
      sleep 20
    done
    for id in $(aws_ ec2 describe-security-groups --filters "Name=vpc-id,Values=${vpc}" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
      aws_ ec2 delete-security-group --group-id "$id" || true
    done
    for id in $(aws_ ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=${vpc}" --query 'InternetGateways[].InternetGatewayId' --output text); do
      aws_ ec2 detach-internet-gateway --internet-gateway-id "$id" --vpc-id "$vpc"
      aws_ ec2 delete-internet-gateway --internet-gateway-id "$id"
    done
    for id in $(aws_ ec2 describe-subnets --filters "Name=vpc-id,Values=${vpc}" --query 'Subnets[].SubnetId' --output text); do
      aws_ ec2 delete-subnet --subnet-id "$id"
    done
    for id in $(aws_ ec2 describe-route-tables --filters "Name=vpc-id,Values=${vpc}" --query 'RouteTables[?!(Associations[?Main])].RouteTableId' --output text); do
      aws_ ec2 delete-route-table --route-table-id "$id"
    done
    log "delete VPC $vpc"
    aws_ ec2 delete-vpc --vpc-id "$vpc"
  fi
  local role p
  for role in "$FILES_ROLE" "$DEPLOYER_ROLE" "$STORAGE_ROLE" "$CP_ROLE" "$NODE_ROLE" "$CLUSTER_ROLE"; do
    aws_ iam get-role --role-name "$role" >/dev/null 2>&1 || continue
    if ! role_owned "$role"; then log "keep role $role: not tagged ${OWNER_TAG}=${NAME}"; continue; fi
    for p in $(aws_ iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text); do
      aws_ iam delete-role-policy --role-name "$role" --policy-name "$p"
    done
    for p in $(aws_ iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text); do
      aws_ iam detach-role-policy --role-name "$role" --policy-arn "$p"
    done
    log "delete role $role"
    aws_ iam delete-role --role-name "$role"
  done
  cmd_status
}

case "${1:-}" in
  up) cmd_up ;;
  down) cmd_down ;;
  status) cmd_status ;;
  assoc) shift; cmd_assoc "$@" ;;
  *) echo "usage: $0 up|status|assoc <ns> <sa> <cp|deployer|files>|down" >&2; exit 2 ;;
esac
