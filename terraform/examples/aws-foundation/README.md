# AWS foundation root

Source-only first layer. Read the [module scope, identity, KMS and lifecycle contract](../../modules/aws/foundation) before any execution plan. No cloud resource has been created by this example. Account, region, versions, operator roles/networks, key policy and subnet availability require separate review.

1. Copy `terraform.tfvars.example` to an ignored local input file and replace every placeholder. Use an existing AWS account and durable customer-managed KMS key. No credentials or secret values belong in inputs. Complete the [account prerequisites](#account-prerequisites) first: a brand-new account lacks service-linked roles that the key policy and data layer need.
2. Copy `backend.hcl.example` to an ignored/operator-owned backend file. The pre-existing versioned/encrypted state bucket must survive foundation/data/application retirement. Use separate account/region/environment/layer keys, native S3 locking (`use_lockfile=true`) and bucket access limited to the intended operator; backend credentials come from the environment. Backend `allowed_account_ids` independently fences the backend account. A separate backend account is valid when explicitly reviewed.
3. Validate without a backend or cloud credentials: `terraform init -backend=false`, `terraform validate`, `terraform test`. For the routing graph check, separately initialize `../../modules/aws/foundation` with `terraform init -backend=false`, then run `python3 tests/check_routing_graph.py` from that module directory. This verifies transitive routing/association ordering without initializing the S3 backend or making cloud calls. Tests use synthetic mock-only versions and IDs. For a later approved execution, initialize the reviewed S3 backend and credentials, then review a saved plan. Do not run a live plan/apply based on synthetic test defaults.
4. Hand the non-secret `data_environment_inputs` object to a separately initialized `aws-environments` state as explicit inputs. Its `namespace` is where every workload Pod Identity association is bound; with the default `namespace = null` it is `agent-relay-<environment>` (e.g. `agent-relay-dev`), **not** `agent-relay`. Install the application charts into exactly that namespace, or set foundation `namespace` explicitly before the first apply and pass the exported value to the data inputs unchanged; Pods in any other namespace silently get no AWS access. It intentionally omits the search admin role and Lambda package. Do not point data or application at the foundation state key. StorageClass and actor outputs are application manifests/values to apply later with exec authentication.

Example key layout: `<existing-account>/<region>/<environment>/foundation/terraform.tfstate`, then separate `data/terraform.tfstate` and `application/terraform.tfstate`. The backend does not read root variables: replace its placeholders independently. Customer/Pippen identities and resource names must be checked against both the state key and target account.

Foundation provides infrastructure prerequisites for the full suite, including Lambda networking and first-party Terse placement. It does not install Helm charts, a Lambda handler, secrets, DNS/certificates, auth services or application data. Existing proof resources are out of scope and remain running.

## Account prerequisites

Run these once per account, before creating the KMS key or applying foundation. They need `iam:CreateServiceLinkedRole` and are account-wide, so neither foundation nor data state creates or destroys them (in Pippen they are platform-owned baseline resources).

1. **Service-linked roles.** A brand-new account has neither of these until something creates them. The KMS key policy below names the Auto Scaling role, and KMS rejects a policy whose principal does not exist yet. The data layer's OpenSearch domain fails with "you must enable a service-linked role to give Amazon OpenSearch Service permissions to access your VPC" without the OpenSearch role. Check each one and create only a missing role; `create-service-linked-role` fails if the role already exists:

   ```sh
   aws iam get-role --role-name AWSServiceRoleForAutoScaling >/dev/null 2>&1 ||
     aws iam create-service-linked-role --aws-service-name autoscaling.amazonaws.com
   aws iam get-role --role-name AWSServiceRoleForAmazonOpenSearchService >/dev/null 2>&1 ||
     aws iam create-service-linked-role --aws-service-name opensearchservice.amazonaws.com
   ```

   EKS creates its own service-linked roles during apply when the deploying identity may call `iam:CreateServiceLinkedRole`.

2. **Durable KMS key.** Create a symmetric `ENCRYPT_DECRYPT` customer-managed key in the target account and region, outside foundation state, and set `kms_key_arn` to it. [`kms-key-policy.json.example`](kms-key-policy.json.example) is a reference key policy. Replace `<account-id>`, `<region>` and `<name>` (`name_prefix-environment`, e.g. `agent-relay-dev`; it must match the two log groups foundation creates) and review it with the customer's key administrators:

   | Statement | Why |
   | --- | --- |
   | Account root `kms:*` | Lets IAM policies grant use. The operator role (EKS secrets encryption) and the EBS CSI role's inline policy rely on it. |
   | `logs.<region>.amazonaws.com` `Encrypt*`/`Decrypt*`/`ReEncrypt*`/`GenerateDataKey*`/`Describe*`, `ArnEquals kms:EncryptionContext:aws:logs:arn` | Encrypts only the two foundation log groups, `/aws/vpc/<name>/flow` and `/aws/eks/<name>/cluster`. |
   | `AWSServiceRoleForAutoScaling` `Encrypt`/`Decrypt`/`ReEncrypt*`/`GenerateDataKey*`/`DescribeKey` | Managed node groups launch encrypted EBS root volumes through Auto Scaling. |
   | `AWSServiceRoleForAutoScaling` `kms:CreateGrant` with `Bool kms:GrantIsForAWSResource=true` | Auto Scaling grants EC2 use of the key for those volumes. Without it, nodes never launch. |

   ```sh
   # After replacing the placeholders in a private copy:
   aws kms create-key --key-spec SYMMETRIC_DEFAULT --key-usage ENCRYPT_DECRYPT \
     --description "<name> durable foundation key" \
     --policy file:///approved/private/kms-key-policy.json
   aws kms enable-key-rotation --key-id <key-id>
   ```

   For an existing key, compare its policy with the reference instead (`aws kms get-key-policy --key-id <key-id> --policy-name default`) and add only the missing statements.

## After apply

Foundation creates AWS resources only. Before installing the data layer's workloads or any application chart, complete both Kubernetes steps in order with an operator kubeconfig for the new cluster (`aws eks update-kubeconfig --name <cluster_name> --region <region>`):

1. **Install the AWS Load Balancer Controller** (requires `enable_load_balancer_controller = true`) with the values from `terraform output load_balancer_controller`. See [the command below](#aws-load-balancer-controller). Without it, no Ingress or `LoadBalancer` Service gets an AWS load balancer.
2. **Apply the encrypted StorageClass**:

   ```sh
   terraform output -json storage_class_manifest | kubectl apply -f -
   kubectl get storageclass
   ```

   It is named `<name>-gp3`; reference that name in the application values for persistent volumes.

## AWS Load Balancer Controller

Off by default. Setting `enable_load_balancer_controller = true` creates the controller's IAM policy, IAM role, policy attachment and Pod Identity association; no Kubernetes object is created. After apply, install the chart with the values from `terraform output load_balancer_controller`:

```sh
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks
LBC="$(terraform output -json load_balancer_controller)"
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version 3.6.2 \
  --namespace kube-system \
  --set clusterName="$(jq -r .cluster_name <<<"$LBC")" \
  --set region="$(jq -r .region <<<"$LBC")" \
  --set vpcId="$(jq -r .vpc_id <<<"$LBC")" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller
```

The chart creates the ServiceAccount and needs no IRSA annotation: Pod Identity binds it to the role by namespace and name.
Wait for `kubectl -n kube-system rollout status deployment/aws-load-balancer-controller` before applying anything that creates a load balancer.

### Adopting an existing installation

An account where the controller was installed by hand already has the `<cluster>-lbc` policy, the `<cluster>-lbc` role and the Pod Identity association. Do not delete or recreate them, because that interrupts a running controller. An apply without imports fails because the names are already taken. Set `enable_load_balancer_controller = true`, initialize the real backend, then import them before the first apply. `<cluster>` is `name_prefix-environment`.

Find the association ID:

```sh
aws eks list-pod-identity-associations \
  --cluster-name <cluster> \
  --namespace kube-system \
  --service-account aws-load-balancer-controller \
  --query 'associations[0].associationId' --output text
```

Import the three resources:

```sh
terraform import 'module.foundation.aws_iam_policy.lbc[0]' 'arn:aws:iam::<account-id>:policy/<cluster>-lbc'
terraform import 'module.foundation.aws_iam_role.this["lbc"]' '<cluster>-lbc'
terraform import 'module.foundation.aws_eks_pod_identity_association.lbc[0]' '<cluster>,<association-id>'
```

Import the policy attachment as well so the plan has nothing left to create. It is the role-to-policy link rather than a separately named AWS object:

```sh
terraform import 'module.foundation.aws_iam_role_policy_attachment.lbc[0]' '<cluster>-lbc/arn:aws:iam::<account-id>:policy/<cluster>-lbc'
```

Then review a saved plan. It must show no resource being replaced or destroyed; stop if one is. The policy's name, path and description, the role's name and path, and the association's cluster, namespace and ServiceAccount cannot change in place, so any difference there means replacement. The module sets no policy description, so a hand-built policy that has one would be replaced. Expect these in-place updates on a hand-built installation: the module's tags are added where missing, and the role trust gains the `aws:RequestTag/*` conditions that the module's other Pod Identity roles have. Leave the Helm release as it is; these imports do not touch it.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.10 |
| aws | >= 6.72, < 7.0 |

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| foundation | ../../modules/aws/foundation | n/a |

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
| enable\_load\_balancer\_controller | Create the AWS Load Balancer Controller IAM policy, role and Pod Identity association; the Helm release stays external. | `bool` | `false` | no |
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
| actor\_profile | First-party durable-actors placement/sandbox values. |
| cluster\_security\_group\_id | Service-created SG identifier for scoped retirement inventory. |
| data\_environment\_inputs | Non-secret subset of inputs for a separately initialized aws-environments state. |
| identity\_references | References for separately owned workload roles. |
| load\_balancer\_controller | Helm install references for the AWS Load Balancer Controller; null while disabled. |
| storage\_class\_manifest | Retained encrypted CSI class to apply in application state. |
<!-- END_TF_DOCS -->
