#!/usr/bin/env bash
#
# Minimal EKS Auto Mode substrate for the agent-relay EKS proof, built inside
# a Pippen sandbox (AgentWorkforce/pippen-tools). Run every subcommand under
# the lease's agent-session role:
#
#   pippen sandbox exec aws-proof -- scripts/selfhost/eks-proof-sandbox.sh up
#   pippen sandbox exec aws-proof -- scripts/selfhost/eks-proof-sandbox.sh status
#   pippen sandbox exec aws-proof -- scripts/selfhost/eks-proof-sandbox.sh down
#
# It follows the Pippen conventions so the permissions boundary allows every
# call and `pippen sandbox down` can sweep whatever is left:
#   - every taggable resource carries pippen:sandbox=true;
#   - every IAM role lives under /pippen/workload/ with the
#     pippen-agent-session-boundary permissions boundary;
#   - every name starts pippen-sbx-.
#
# What it creates (us-west-2 by default):
#   - a VPC with two public subnets and an internet gateway (no NAT gateway:
#     nodes get public IPs, which keeps the proof cheap and the sweep simple);
#   - the EKS cluster role and the Auto Mode node role;
#   - an EKS Auto Mode cluster (API auth, public endpoint limited to the
#     operator's /32, the built-in general-purpose and system node pools; the
#     default StorageClass (tagged EBS gp3) and the ALB IngressClass (tagged
#     ALBs) are applied by `up` once the cluster is ACTIVE).
#     A custom NodeClass (for tagged instances and a CPU cap) does not work
#     with a node role under an IAM path such as /pippen/workload/: Auto Mode
#     reports "Role ... is unauthorized to join nodes to the cluster" even with
#     the EC2 access entry and AmazonEKSAutoNodePolicy in place, while the
#     built-in pools accept the same role. Auto Mode instances are terminated
#     with the cluster;
#   - one S3 bucket and one Pod Identity role for the Sessions Pipeline
#     worker and Alleyoop;
#   - Pod Identity associations for the chart's ServiceAccounts.
#
# This is a proof substrate, not a production reference: production should
# use private subnets with NAT, a private or narrowly scoped API endpoint, and
# a managed Postgres (RDS/Aurora). See docs/self-hosted-eks.md.

set -euo pipefail

: "${PIPPEN_SANDBOX_ACCOUNT_ID:?run under pippen sandbox exec}"
ACCOUNT="$PIPPEN_SANDBOX_ACCOUNT_ID"
REGION="${AWS_REGION:-us-west-2}"
NAME="${EKS_PROOF_NAME:-pippen-sbx-eks-proof}"
K8S_VERSION="${EKS_PROOF_K8S_VERSION:-1.34}"
NAMESPACE="${EKS_PROOF_NAMESPACE:-agent-relay}"
RELEASE="${EKS_PROOF_RELEASE:-agent-relay}"
# Operator egress /32 for the public API endpoint (required for up).
API_CIDR="${EKS_PROOF_API_CIDR:-}"
BUCKET="${NAME}-${ACCOUNT}"
BOUNDARY="arn:aws:iam::${ACCOUNT}:policy/pippen-agent-session-boundary"
ROLE_PATH="/pippen/workload/"
CLUSTER_ROLE="${NAME}-cluster"
NODE_ROLE="${NAME}-node"
STORAGE_ROLE="${NAME}-storage"
TAG_KEY="pippen:sandbox"
TAG_SPEC_TAGS="{Key=${TAG_KEY},Value=true},{Key=Name,Value=${NAME}}"
# ServiceAccounts that get the storage role through Pod Identity.
# (Relaycast runs SQLite on EBS in this profile and needs no bucket access.)
POD_IDENTITY_SAS=(
  "${RELEASE}-worker"
  "${RELEASE}-session-ingest-api"
)

# cluster_exists: 0 present, 1 absent (ResourceNotFoundException); any other
# describe-cluster error stops the script instead of reading as "absent".
cluster_exists() {
  local err
  if err="$(aws_ eks describe-cluster --name "$NAME" 2>&1 >/dev/null)"; then return 0; fi
  [[ "$err" == *ResourceNotFoundException* ]] && return 1
  echo "describe-cluster $NAME failed: $err" >&2; exit 1
}

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
aws_() { aws --region "$REGION" "$@"; }

vpc_id() {
  aws_ ec2 describe-vpcs --filters "Name=tag:Name,Values=${NAME}" "Name=tag:${TAG_KEY},Values=true" \
    --query 'Vpcs[0].VpcId' --output text | sed 's/^None$//'
}

ensure_role() {
  local role="$1" service="$2"; shift 2
  if ! aws_ iam get-role --role-name "$role" >/dev/null 2>&1; then
    log "create role ${ROLE_PATH}${role}"
    aws_ iam create-role --role-name "$role" --path "$ROLE_PATH" \
      --permissions-boundary "$BOUNDARY" \
      --tags "Key=${TAG_KEY},Value=true" \
      --assume-role-policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"${service}\"},\"Action\":[\"sts:AssumeRole\",\"sts:TagSession\"]}]}" >/dev/null
  fi
  local p
  for p in "$@"; do
    aws_ iam attach-role-policy --role-name "$role" --policy-arn "arn:aws:iam::aws:policy/${p}"
  done
}

kubeconfig() {
  KUBECONFIG_FILE="$(mktemp)"
  aws_ eks update-kubeconfig --name "$NAME" --kubeconfig "$KUBECONFIG_FILE" >/dev/null
  export KUBECONFIG="$KUBECONFIG_FILE"
}

cluster_addons_yaml() {
  cat <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.eks.amazonaws.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
parameters:
  type: gp3
  encrypted: "true"
  tagSpecification_1: "${TAG_KEY}=true"
---
apiVersion: eks.amazonaws.com/v1
kind: IngressClassParams
metadata:
  name: alb
spec:
  # No custom tags: Auto Mode's AmazonEKSLoadBalancingPolicy allows only its
  # own tag keys on created ELB resources (aws:TagKeys allowlist), so a
  # pippen:sandbox tag here makes CreateRule fail with AccessDenied. The ALBs
  # are deleted with their Ingresses; `down` removes any left in the VPC.
  scheme: internet-facing
---
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: alb
spec:
  controller: eks.amazonaws.com/alb
  parameters:
    apiGroup: eks.amazonaws.com
    kind: IngressClassParams
    name: alb
EOF
}

cmd_up() {
  [[ "$API_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]] ||
    { echo "EKS_PROOF_API_CIDR=<operator egress IPv4>/32 is required (a single /32, not a range)" >&2; exit 2; }
  local vpc subnets="" igw rtb az i
  vpc="$(vpc_id)"
  if [[ -z "$vpc" ]]; then
    log "create VPC ${NAME}"
    vpc="$(aws_ ec2 create-vpc --cidr-block 10.42.0.0/16 \
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
      local sn
      sn="$(aws_ ec2 create-subnet --vpc-id "$vpc" --availability-zone "$az" --cidr-block "10.42.${i}.0/20" \
        --tag-specifications "ResourceType=subnet,Tags=[${TAG_SPEC_TAGS},{Key=kubernetes.io/role/elb,Value=1}]" \
        --query Subnet.SubnetId --output text)"
      aws_ ec2 modify-subnet-attribute --subnet-id "$sn" --map-public-ip-on-launch
      aws_ ec2 associate-route-table --route-table-id "$rtb" --subnet-id "$sn" >/dev/null
      i=$((i + 16))
    done
  fi
  subnets="$(aws_ ec2 describe-subnets --filters "Name=vpc-id,Values=${vpc}" --query 'Subnets[].SubnetId' --output text)"
  # A VPC left by a failed earlier up may lack its gateway, route or subnets;
  # refuse it rather than hand EKS a partial network.
  local nsub igws
  nsub="$(wc -w <<<"$subnets" | tr -d ' ')"
  igws="$(aws_ ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=${vpc}" --query 'length(InternetGateways)' --output text)"
  if ((nsub < 2)) || [[ "$igws" != 1 ]]; then
    echo "VPC $vpc is incomplete (subnets=$nsub internet_gateways=$igws): run down, then up" >&2; exit 1
  fi
  log "vpc $vpc subnets $subnets"

  ensure_role "$CLUSTER_ROLE" eks.amazonaws.com \
    AmazonEKSClusterPolicy AmazonEKSComputePolicy AmazonEKSBlockStoragePolicy \
    AmazonEKSLoadBalancingPolicy AmazonEKSNetworkingPolicy
  ensure_role "$NODE_ROLE" ec2.amazonaws.com \
    AmazonEKSWorkerNodeMinimalPolicy AmazonEC2ContainerRegistryPullOnly
  ensure_role "$STORAGE_ROLE" pods.eks.amazonaws.com
  aws_ iam put-role-policy --role-name "$STORAGE_ROLE" --policy-name s3-proof-bucket \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:ListBucket\",\"s3:GetBucketLocation\"],\"Resource\":\"arn:aws:s3:::${BUCKET}\"},{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\",\"s3:AbortMultipartUpload\",\"s3:ListMultipartUploadParts\"],\"Resource\":\"arn:aws:s3:::${BUCKET}/*\"}]}"

  if ! aws_ s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    log "create bucket $BUCKET"
    if [[ "$REGION" == us-east-1 ]]; then
      aws_ s3api create-bucket --bucket "$BUCKET" >/dev/null
    else
      aws_ s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
    fi
    aws_ s3api put-public-access-block --bucket "$BUCKET" \
      --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  fi
  aws_ s3api put-bucket-tagging --bucket "$BUCKET" --tagging "TagSet=[{Key=${TAG_KEY},Value=true}]"

  if ! cluster_exists; then
    log "create EKS Auto Mode cluster $NAME ($K8S_VERSION)"
    local sn_csv; sn_csv="$(tr ' \t' ',,' <<<"$subnets" | sed 's/,*$//')"
    aws_ eks create-cluster --name "$NAME" --kubernetes-version "$K8S_VERSION" \
      --role-arn "arn:aws:iam::${ACCOUNT}:role${ROLE_PATH}${CLUSTER_ROLE}" \
      --resources-vpc-config "subnetIds=${sn_csv},endpointPublicAccess=true,endpointPrivateAccess=true,publicAccessCidrs=${API_CIDR}" \
      --access-config authenticationMode=API,bootstrapClusterCreatorAdminPermissions=true \
      --no-bootstrap-self-managed-addons \
      --compute-config "enabled=true,nodeRoleArn=arn:aws:iam::${ACCOUNT}:role${ROLE_PATH}${NODE_ROLE},nodePools=general-purpose,system" \
      --kubernetes-network-config '{"elasticLoadBalancing":{"enabled":true}}' \
      --storage-config '{"blockStorage":{"enabled":true}}' \
      --tags "${TAG_KEY}=true" >/dev/null
  fi
  log "waiting for cluster ACTIVE"
  aws_ eks wait cluster-active --name "$NAME"
  # An existing cluster keeps its endpoint CIDRs: reconcile them to API_CIDR
  # (the operator's egress may have changed since it was created).
  local cidrs
  cidrs="$(aws_ eks describe-cluster --name "$NAME" --query 'join(`,`, cluster.resourcesVpcConfig.publicAccessCidrs)' --output text)"
  if [[ "$cidrs" != "$API_CIDR" ]]; then
    log "public endpoint CIDRs $cidrs -> $API_CIDR"
    local upd
    upd="$(aws_ eks update-cluster-config --name "$NAME" \
      --resources-vpc-config "endpointPublicAccess=true,endpointPrivateAccess=true,publicAccessCidrs=${API_CIDR}" \
      --query update.id --output text)"
    local st=""
    for _ in $(seq 1 60); do
      st="$(aws_ eks describe-update --name "$NAME" --update-id "$upd" --query update.status --output text)"
      [[ "$st" == InProgress ]] || break
      sleep 15
    done
    [[ "$st" == Successful ]] || { echo "endpoint update $upd: $st" >&2; exit 1; }
    log "endpoint update $upd done"
  fi

  local sa
  for sa in "${POD_IDENTITY_SAS[@]}"; do
    if [[ -z "$(aws_ eks list-pod-identity-associations --cluster-name "$NAME" --namespace "$NAMESPACE" \
        --service-account "$sa" --query 'associations[0].associationId' --output text | sed 's/^None$//')" ]]; then
      aws_ eks create-pod-identity-association --cluster-name "$NAME" --namespace "$NAMESPACE" \
        --service-account "$sa" --role-arn "arn:aws:iam::${ACCOUNT}:role${ROLE_PATH}${STORAGE_ROLE}" \
        --tags "${TAG_KEY}=true" >/dev/null
      log "pod identity ${NAMESPACE}/${sa} -> ${STORAGE_ROLE}"
    fi
  done

  kubeconfig
  cluster_addons_yaml | kubectl apply -f -
  rm -f "$KUBECONFIG_FILE"
  cmd_status
}

cmd_status() {
  if cluster_exists; then
    aws_ eks describe-cluster --name "$NAME" \
      --query 'cluster.{name:name,status:status,version:version,endpoint:endpoint,autoMode:computeConfig.enabled}' --output json
  else
    echo '{"cluster":"absent"}'
  fi
  printf 'vpc=%s bucket=%s\n' "$(vpc_id)" "$(aws_ s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 && echo "$BUCKET" || echo absent)"
}

cmd_down() {
  local vpc assoc
  if cluster_exists; then
    # Load balancers and volumes made from Ingresses and PVCs go first, while
    # the controllers that own them still run.
    kubeconfig
    kubectl delete ingress --all -A --wait=true --timeout=10m || true
    kubectl delete pvc --all -A --wait=true --timeout=10m || true
    rm -f "$KUBECONFIG_FILE"
    for assoc in $(aws_ eks list-pod-identity-associations --cluster-name "$NAME" --query 'associations[].associationId' --output text); do
      aws_ eks delete-pod-identity-association --cluster-name "$NAME" --association-id "$assoc" >/dev/null
    done
    log "delete cluster $NAME"
    # Deleting the Pod Identity associations can leave a short-lived cluster
    # update in progress, which refuses DeleteCluster (ResourceInUseException).
    local try
    for try in $(seq 1 20); do
      aws_ eks delete-cluster --name "$NAME" >/dev/null 2>&1 && break
      ((try == 20)) && { aws_ eks delete-cluster --name "$NAME" >/dev/null; }
      sleep 30
    done
    aws_ eks wait cluster-deleted --name "$NAME"
  fi
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
    local id
    # Leftover ENIs (load balancers, Auto Mode) release asynchronously.
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
  for role in "$STORAGE_ROLE" "$NODE_ROLE" "$CLUSTER_ROLE"; do
    aws_ iam get-role --role-name "$role" >/dev/null 2>&1 || continue
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
  *) echo "usage: $0 up|status|down" >&2; exit 2 ;;
esac
