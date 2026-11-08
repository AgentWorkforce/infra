# AWS foundation (source preparation)

Creates an environment VPC with two or three AZs, one **public NAT gateway per AZ**, private subnets, a private EKS API by default, encrypted managed general/actor capacity, explicit operator access entries, VPC flow and EKS control-plane logs, Pod Identity agent, VPC CNI, CoreDNS, kube-proxy and EBS CSI prerequisites. Existing account, organization/billing, parent DNS, remote state and durable KMS key remain external. This is not a full application installer and has not been applied or live validated.

Use the thin [aws-foundation example](../../../examples/aws-foundation). The root sets `allowed_account_ids`; this module additionally refuses a caller/account or provider/region mismatch. A caller using the module directly must configure the same provider account allow-list. Kubernetes version, compatible add-on versions and AL2023 AMI release are mandatory, execution-plan inputs: mocks contain synthetic versions and prove no regional availability.

## Capacity, cost and log retention

This foundation creates metered resources even before an application is installed:
an EKS control plane, one public NAT gateway and Elastic IP per selected AZ, the
EKS Auth interface endpoint, encrypted node disks, and general and actor managed
node groups. The defaults start two general and one actor `m6i.large` instances;
both groups require nonzero capacity. VPC flow logs capture `ALL` traffic, and
flow/control-plane log groups retain events for 365 days. Review the exact
region, capacity, traffic and retention inputs before budgeting a real run;
source/mock checks are not a cost estimate.

The module does not set an EKS upgrade support policy. Review the pinned
provider/AWS support behavior and the selected version's support window before
applying; no standard-support-only cost policy is enforced here. The owned log
groups also have no `skip_destroy` override: their retention period does not
preserve them when foundation state is destroyed. Export any required audit and
recovery evidence to its separately owned destination before retirement.

## Access, identity and encryption

The private API needs an operator network route (VPN, approved connected runner or equivalent); access entries grant only the explicitly listed same-account operator roles cluster administration. Public API opt-in requires operator IPv4 CIDRs `/8` or narrower and rejects world access. Setting a CIDR creates no connectivity or DNS integration. Operator SG references must be valid for this VPC/approved connected topology.

Only AWS resources are managed. No Kubernetes/Helm provider, token, kubeconfig, password or credential value is produced. Later application state uses exec authentication, e.g. `aws eks get-token`, and applies the exported encrypted `gp3` StorageClass manifest. Its `WaitForFirstConsumer` binding respects AZ placement and `Retain` preserves data; snapshot controller/CRDs, snapshot policy and recovery receipts remain application/operator work.

Supply an existing symmetric KMS key in this account/region, kept outside foundation state. Before apply its key policy must allow EKS, encrypted CloudWatch Logs (the two exact log-group ARNs), EBS CSI and the account's EC2 Auto Scaling service-linked role appropriate use/grants. EBS volumes need the Auto Scaling key grant before managed capacity can launch. The CSI role's inline key access is limited to this key and grants for AWS resources. VPC CNI and CSI permissions are separate Pod Identity roles, never attached to the shared node role. AWS managed infrastructure policies still include AWS-required wildcard resources; their effective permissions must be reviewed with the customer/Pippen boundary. See [EBS CSI IAM prerequisites](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html) and [Auto Scaling KMS grants](https://docs.aws.amazon.com/autoscaling/ec2/userguide/key-policy-requirements.html).

Private workloads have HTTPS internet egress through NAT for AWS APIs, image registries and Relaycast public origins. The explicit EKS Auth interface endpoint serves Pod Identity. This reviewed egress shape is not an air-gapped cluster. The module does not create S3, ECR, STS or CloudWatch interface endpoints.

## Data and application contract

Outputs feed `modules/aws/{postgres,object-storage,search,functions}` and the separate `examples/aws-environments` composition: account/region/environment, two or three private AZ subnets, database destination SGs (TCP 5432), one/two/three chosen OpenSearch AZ subnets and destination SGs (HTTPS), Lambda source SGs, EKS cluster name and namespace/identity references. The thin root exports these plus matching name/release/Pippen lease references as `data_environment_inputs`; search administrator, Lambda artifact, application secrets and workload-specific roles remain explicit data/application inputs.

Checkov's whole-tree attachment check cannot connect these security-group outputs to a separate data state. The shared group resource therefore has a local `CKV2_AWS_5` exception for the deliberately unattached database/search/function groups. The workload/operator/endpoint groups attach within foundation; all ingress/egress checks still run. Before applying data state, verify that RDS, OpenSearch and any selected Lambda bind the exact exported destination/source groups, then verify those bindings against the live services. A passing static scan does not establish those cross-state attachments.

Workload SGs are attached to nodes, not to individual Pods. Database/search ingress permits only the environment node/function source SGs. This does not enforce Pod-level tenant isolation or Kubernetes NetworkPolicy. Operators/proof runners needing data access must have a separately reviewed attachment/access change; API SG access alone grants none. EKS creates a cluster SG with self traffic and broad egress, attached explicitly alongside our workload group in launch templates. SG rules are additive, so node egress is broader than the workload group's HTTPS rules. We do not claim node egress confinement. See [AWS service-created SG behavior](https://docs.aws.amazon.com/eks/latest/userguide/sec-group-reqs.html).

`actor_profile` matches `charts/agent-relay/values-eks-actors.yaml` and `charts/durable-actors/ci/eks-values.yaml`: `durable-actors/role=actor-host`, taint `durable-actors/actor-host=true:NoSchedule`, `Exists` toleration, explicit `placement.zone`, and empty runtimeClassName. The dedicated AL2023 actor group runs first-party Terse actors on the standard runtime; it neither installs gVisor nor supports claims of untrusted multi-tenant sandboxing or application HA. General nodes host the controllers. Actor storage/deployer/application bucket roles and credentials remain in the data/application layer. In Pippen the chart's reviewed control-plane credential mode must be explicit because nested AssumeRole may be forbidden.

Target application acceptance remains relaycontrol, relay-dashboard, sessions-pipeline in Lambda mode on AWS, relayhistory, Relaycast with Terse, optional Relayfile and auth dependencies. Foundation outputs alone do not prove any application or restore path.

## Pippen and cleanup boundaries

`pippen` requires the expected nonempty agent/session lease and exact caller `arn:aws:sts::<account>:assumed-role/agent-session/agent-<session_id>`. Pippen allocation/status/credential delivery remains external; a mock cannot validate an active lease. Prefix must begin `pippen-sbx-`. All Terraform-owned taggable resources carry reserved `pippen:sandbox`, `pippen:agent`, `pippen:session` tags. Every created role uses `/pippen/workload/` and the existing `pippen-agent-session-boundary`; no platform boundary or permissions are widened here.

This source is **not executable under today's Pippen baseline** without reviewed platform support. [pippen-tools#50](https://github.com/AgentWorkforce/pippen-tools/issues/50) tracks missing `es`, Lambda, SQS, Events/CloudWatch permissions and OpenSearch service-linked-role baseline support; RDS cleanup draft #51 is not deployed. EKS/add-ons/Pod Identity/access entries, managed node groups, EC2 launch templates/NAT/EIPs/PrivateLink/flow logs, IAM policy attachment/pass-role, CloudWatch Logs/KMS and their reverse retirement paths require an explicit supported allow-list and sweeper review. Managed EKS/EC2/Auto Scaling service-linked roles, CMK grants and service-created SGs/ENIs may lack user sandbox tags or live outside `/pippen/workload/`. Account-wide service-linked-role baseline resources must remain platform-owned. Fail the execution gate when unsupported; do not bypass the platform policy.

Foundation state is separate from data and application, and its backend/key outlive all stacks. Never destroy or import the existing non-Terraform AWS proof. Preserve workspace/baseline/recovery resources. A future retirement must first quiesce Lambda/event sources, remove application Services/Ingress/load balancers while controllers still run, inventory and preserve PVC/EBS/snapshots, then retire reviewed data state before foundation state. Existing data modules deliberately protect durable search/buckets/backups; generic `terraform destroy` is not a complete teardown plan.

EKS API deletion protection defaults to true. A reviewed retirement must first explicitly disable it and verify that change before deletion.

The cluster depends on both public/private subnet route-table associations as well as the routes. This makes them transitive prerequisites of every node group and add-on, keeping associations attached until those consumers retire.

Destroy order in this graph removes storage/DNS add-ons before managed nodes, bootstrap add-ons before cluster, then network. The cluster explicitly depends on its IAM policy attachments so they survive until EKS has retired its managed infrastructure ([provider dependency guidance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster)). AWS controls the cluster SG and ENI lifecycle; dependent external ENIs/load balancers/PVs may block or outlive deletion. Record the exported cluster SG ID plus EKS cluster/node-group IDs and inventory their ENIs/Auto Scaling/EC2/EBS/PrivateLink/NAT/EIP/flow-log resources before and after retirement. Verify service-created groups/ENIs actually disappear; do not blindly delete untagged resources or report a clean teardown from Terraform exit status alone. See [EKS deletion prerequisites](https://docs.aws.amazon.com/eks/latest/userguide/delete-cluster.html).

## Offline routing dependency regression

After `terraform init -backend=false`, run `python3 tests/check_routing_graph.py` from this module. The checker reads `terraform graph -type=plan` without cloud credentials and requires paths from the cluster, bootstrap add-ons, managed node groups and storage/DNS add-ons to both route resources and both subnet association resources. It fails if any of those 16 paths is absent. The reverse dependency order preserves routes and their subnet attachments until EKS consumers retire; graph ordering alone proves neither network reachability nor clean live retirement. `--graph <saved-plan.dot>` can audit a previously captured graph.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.7 |
| aws | >= 6.72, < 7.0 |

### Providers

| Name | Version |
| ---- | ------- |
| aws | >= 6.72, < 7.0 |
| terraform | n/a |

### Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_log_group.cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.flow](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_default_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/default_security_group) | resource |
| [aws_eip.nat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eip) | resource |
| [aws_eks_access_entry.operator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_entry) | resource |
| [aws_eks_access_policy_association.operator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_policy_association) | resource |
| [aws_eks_addon.bootstrap](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_eks_addon.storage_dns](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_eks_cluster.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster) | resource |
| [aws_eks_node_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_node_group) | resource |
| [aws_eks_pod_identity_association.cni](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_eks_pod_identity_association.ebs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_flow_log.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/flow_log) | resource |
| [aws_iam_role.flow](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.ebs_kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.flow](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_internet_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/internet_gateway) | resource |
| [aws_launch_template.node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_template) | resource |
| [aws_nat_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/nat_gateway) | resource |
| [aws_route.internet](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route.nat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route_table.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table_association.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_route_table_association.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_subnet.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_subnet.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_vpc.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc) | resource |
| [aws_vpc_endpoint.eks_auth](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_security_group_egress_rule.database](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.dns](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.https](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.database](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.eks_auth](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.operator_cidr](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.operator_sg](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.search](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [terraform_data.guard](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | Exact existing target account; independently checked against the caller. | `string` | n/a | yes |
| actor\_availability\_zone | Single approved actor-host AZ, matching durable-actors placement.zone; no HA claim. | `string` | n/a | yes |
| addon\_versions | Explicit compatible versions for vpc-cni, kube-proxy, coredns, eks-pod-identity-agent and aws-ebs-csi-driver. | `map(string)` | n/a | yes |
| environment | Environment slug shared with the data root. | `string` | n/a | yes |
| kms\_key\_arn | Existing durable same-account/region symmetric KMS key for cluster secrets, logs and EBS; key policy/grants are external. | `string` | n/a | yes |
| kubernetes\_version | Required region-supported EKS minor version, verified by the execution plan. No latest default. | `string` | n/a | yes |
| node\_ami\_release\_version | Explicit compatible AL2023 x86\_64 EKS AMI release, pinned by execution packet. | `string` | n/a | yes |
| operator\_role\_arns | Existing same-account IAM operator roles granted EKS cluster-admin access explicitly; no implicit creator admin. | `set(string)` | n/a | yes |
| region | Explicit AWS commercial region. | `string` | n/a | yes |
| subnets | Two or three unique AZ names mapped to non-overlapping public/private CIDRs within the VPC. | `map(object({ public_cidr = string, private_cidr = string }))` | n/a | yes |
| actor\_capacity | Dedicated first-party actor managed-node sizing; single AZ. | `object({ min = number, desired = number, max = number })` | ```{ "desired": 1, "max": 2, "min": 1 }``` | no |
| actor\_instance\_type | Region-supported x86\_64 first-party actor-host node instance type. | `string` | `"m6i.large"` | no |
| capacity | General managed-node sizing; node count alone does not provide application HA. | `object({ min = number, desired = number, max = number })` | ```{ "desired": 2, "max": 4, "min": 2 }``` | no |
| deletion\_protection | EKS API deletion protection; disable only through a reviewed retirement change. | `bool` | `true` | no |
| instance\_type | Region-supported x86\_64 AL2023 general node instance type. | `string` | `"m6i.large"` | no |
| name\_prefix | Product prefix; combined name must fit the data-layer contract. | `string` | `"agent-relay"` | no |
| namespace | Application namespace reference only; null exports agent-relay-environment. | `string` | `null` | no |
| operator\_cidrs | Approved IPv4 operator networks; private reachability is still required by default. Public API requires /8 or narrower. | `list(string)` | `[]` | no |
| operator\_security\_group\_ids | Existing operator/proof-runner SGs in this VPC or connected networks; only API HTTPS ingress is granted. | `set(string)` | `[]` | no |
| pippen | Expected allocated lease agent/session from Pippen; exact STS session caller is enforced. No credentials. | `object({ agent = string, session_id = string })` | `null` | no |
| public\_api\_enabled | Opt in to public EKS API only with explicit bounded operator CIDRs. | `bool` | `false` | no |
| release\_name | Helm release reference used for ServiceAccount names; creates no Kubernetes objects. | `string` | `"agent-relay"` | no |
| search\_az\_count | Number of private AZs exported to OpenSearch: 1, 2 or 3. | `number` | `2` | no |
| tags | Additional tags; reserved environment/Pippen identity cannot be overridden. | `map(string)` | `{}` | no |
| vpc\_cidr | Non-overlapping IPv4 VPC range approved by the operator. | `string` | `"10.80.0.0/16"` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| account\_id | Existing fenced AWS account. |
| actor\_profile | Values under durable-actors matching values-eks-actors.yaml; first-party only. |
| cluster\_security\_group\_id | AWS service-created group; inventory and retirement require explicit verification. |
| database\_security\_group\_ids | Postgres destination groups, TCP 5432 from environment nodes/functions only. |
| eks\_cluster\_name | EKS cluster for later Pod Identity association. |
| environment | Environment identity. |
| function\_security\_group\_ids | Lambda source group with private PostgreSQL/DNS and HTTPS NAT egress. |
| identity\_references | References for data/application-owned workload roles; no tokens or credentials. |
| namespace | Application namespace reference; not created here. |
| private\_subnet\_ids | Private subnets in two or three sorted AZs. |
| region | AWS region. |
| search\_security\_group\_ids | OpenSearch destination groups, TCP 443 from environment nodes/functions only. |
| search\_subnet\_ids | One, two or three private AZ subnets selected for OpenSearch. |
| storage\_class\_manifest | Application applies this manifest via exec-auth; retained PVs require separate recovery/retirement approval. |
| vpc\_id | Environment VPC. |
| workload\_security\_group\_ids | Node-scoped workload groups; does not isolate individual Pods. |
<!-- END_TF_DOCS -->
