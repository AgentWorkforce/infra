# GCP self-host foundation (source only)

Creates prerequisites in an **existing approved project** for the portable-single
Agent Relay suite. It does not install the application or prove a live deployment.
The project, organization, billing, API enablement/service agents, parent DNS,
private operator connectivity, durable state backend and recovery storage remain
external. Pippen does not vend GCP projects. Do not create a simulated vending path.

The approved project number is read through Resource Manager and compared before
provisioning/update resources. All resources use explicit project IDs; cross-project image
reader grants use only `node_image_registry_projects`. Environment is independently
fenced and added to resource names and reserved labels. This fences the **target**;
it does not authenticate or approve the operator. Use approved ADC/Workload Identity
and review the caller separately. The module never reads an access token, creates a
service-account key, retrieves a Secret Manager payload, or changes APIs.

## Network and cluster

- Dedicated custom VPC; subnet with disjoint pod/service secondary ranges, flow
  logs, and Private Google Access; disjoint PSA allocation and connection for
  private Cloud SQL and optional Memorystore. An explicit logged IPv4 ingress
  deny-all rule at priority 65534 binds to this VPC. It adds no allow rule; GKE
  and connector generated rules use higher priorities (lower numbers) for their
  required traffic. Review those rules and their ownership before execution;
  custom approved allows must have a priority below 65534. The baseline preserves
  default-deny behavior and is a cluster provisioning/retirement dependency.
  It does not restrict egress or replace Dataplane V2 NetworkPolicy.
- Reviewed RFC1918 ranges are required and checked for mutual overlap. PSA must
  be /24 or larger; control plane and connector must be /28. Also check connected
  VPC/VPN/peered networks and sufficient Cloud SQL/Redis address capacity externally.
- Private regional Standard GKE, VPC-native, Workload Identity, Dataplane V2,
  shielded COS/containerd nodes, custom node identity, PD CSI, logging/monitoring,
  and intranode visibility. Dataplane V2 enforces NetworkPolicy without Calico.
- Private API by default. Explicit operator CIDRs are required and enforced on
  the private endpoint; prefixes broader than /8, including 0.0.0.0/0, are refused.
  `public_api_enabled=true` is a deliberate allowlisted public API opt-in. There
  is no DNS endpoint configured. The private endpoint requires a routed bastion,
  VPN or CI runner in the same region (global access is disabled); CIDRs alone
  grant neither routing nor IAM/RBAC. No human cluster-admin binding is created.
- NAT is **off by default** and must be reviewed explicitly. When enabled it
  covers only the node subnet (including pod ranges) and optional connector
  subnet, using ephemeral egress IPs; it is not a fixed-IP allowlist or domain
  filter. Private Google Access uses Google's service routing; the VPC retains
  the normal default route. This is not restricted.googleapis.com DNS or VPC-SC.
  Non-Google registry pulls and actor public HTTPS egress need NAT or another
  separately designed path; an NAT-disabled plan is not a working full suite.
- Optional dedicated Serverless VPC Access connector feeds the existing functions
  module. Its deterministic `ar-<16 hex>` name hashes the complete installation
  prefix and environment (64-bit SHA-256 prefix), rather than truncating similar
  prefixes/environments into identical readable names. It has 20 effective
  characters under
  [Google's connector naming rule](https://docs.cloud.google.com/vpc/docs/configure-serverless-vpc-access),
  which counts hyphens twice and requires fewer than 21. Project/region scope
  comes from the connector's resource identity. ALL_TRAFFIC function egress
  additionally requires reviewed NAT. This
  source does not install private DNS, VPN, allow rules for customer workloads,
  external ingress, certificates, DNS, registries or image artifacts. GKE and
  Serverless VPC Access create their own platform firewall rules. Review those
  generated resources and the umbrella's health-check/NetworkPolicy allowances.

The pinned Checkov 3.3.30 whole-tree resource check cannot resolve the nested
optional `labels` merge at the example-to-module boundary. A resource-local
`CKV_GCP_21` exception records that false positive; runtime label behavior is
unchanged. Mock plans assert both reserved nonempty labels and preservation of
customer labels when conflicting reserved values are supplied. The explicit
network/firewall graph check remains enabled.

The node service account has only `roles/container.defaultNodeServiceAccount` in
this project and optional Artifact Registry reader in explicitly named projects.
Cloud-platform OAuth scope is bounded by that IAM and GKE metadata isolation;
workloads receive exact KSA Workload Identity grants from data/application state.
No workload bucket, SQL, secret, or project-wide Pub/Sub permissions go to nodes.

`gke_version`, `release_channel`, zones and maintenance window have no guessed
latest defaults. Supply a reviewed **available** region/channel version. The version
is initial/minimum only: GKE manages control-plane and node upgrades, emergency
maintenance can bypass a window, and a channel is not a permanent version pin.
This module does not call a versions API to guess one. Node pool minima/maxima are
**total** across selected zones; initial count is one per selected zone. Budget
for surge capacity, actual pod requests, quotas, and zonal PVC scheduling.

## GCP actor hosts

`actor_hosts.enabled` is opt-in; this does not enable the preview chart component.
The GCP profile in `docs/self-hosted-durable-actors.md` requires a dedicated **GKE
Sandbox (gVisor)** pool in the explicit `placement.zone`. The pool uses COS/containerd
and `sandbox_config.type=GVISOR`. GKE supplies label/taint
`sandbox.gke.io/runtime=gvisor:NoSchedule`; its `gvisor` RuntimeClass supplies the
toleration. The output names that runtime, selector, taint and zone. Keep the
control plane and ordinary services on ordinary nodes. Do not copy the EKS-only
`durable-actors/role=actor-host` selector or `durable-actors/actor-host` taint here.
The current GCP Helm profile relies on GKE-native admission and adds neither.

This is a capacity/placement prerequisite for the first-party Terse path, **not**
a claim that arbitrary untrusted tenants are supported. The suite remains
portable-single; extra nodes and Redis replicas do not make Relaycast, RelayAuth,
SQLite/PVC writers or the stateful pipeline HA. Versioned actor images, GCS code
and state buckets, exact KSA bindings, migration credentials, optional Relayfile
and auth dependencies belong to later data/application wiring and approval.

## Native pipeline Pub/Sub and Redis

`pipeline.enabled` adds a regional-storage-policy topic, pull subscription with
bounded retry/dead-letter forwarding, a retained dead-letter subscription, and
resource-scoped publisher/subscriber grants to exact `namespace/ksa` subjects.
The existing Pub/Sub service agent receives only dead-letter publisher and source
subscription subscriber grants. The service agent must already exist. This is
for native pod worker `PUBSUB_TOPIC`/`PUBSUB_SUBSCRIPTION`; it is **distinct** from
`modules/gcp/functions`, which owns its own GCS notification/push topics. No app
consumer is installed. Validate the selected application release's queue and
credential contracts before enabling it. Monitor/alert/drain the queue externally.
Retention defaults to seven days and is not an indefinite backup. Topics use
Google-managed encryption unless an existing approved `pipeline.kms_key_name` is
supplied; authorize the Pub/Sub service agent on CMEK separately first.

`redis.enabled` adds STANDARD_HA Memorystore with private PSA, TLS server
authentication, AUTH, explicit Redis version, >=5 GiB, and deletion protection.
The Redis service tier does not change the suite's portable-single guarantee.
The exported host/port/CA references support native pipeline Redis TLS wiring;
use `rediss`/server certificate verification and the selected runtime's AUTH
secret mechanism. Do not place a password/credential URL in Helm values/extraEnv,
plan output or shell argv. CA certificates are public; rotate clients ahead of
CA expiry. Never copy the render-only CI profile's disabled AUTH setting.

**State constraint:** the Google provider's `google_redis_instance` reads the
server-generated AUTH value and stores it in the computed sensitive `auth_string`
attribute during create **and refresh**. There is no write-only alternative in
this resource. Suppressing outputs, `ignore_changes`, `sensitive`, moving a secret
into Secret Manager, or importing the instance does **not** remove that value
from state/history. Therefore managed Redis is off by default and enabling it
requires `acknowledge_auth_in_state=true`. The default foundation has no generated
service credential. A Redis-enabled state/plan/backup must be treated as a secret:
encrypted restricted durable backend, tightly scoped readers, audited access,
protected plan artifacts, and approved history/retirement handling. Do not emit
state or use debug logs in shared channels.

If foundation state must contain **no service secret**, keep managed Redis disabled.
Provision and rotate TLS+AUTH Redis through the customer's separately reviewed
secret-capable workflow. Pass only host/port/public CA and an approved Secret
Manager reference to application configuration; deliver AUTH through the existing
Secret delivery system. Do not import it or read it with the Redis data source,
which can also fetch AUTH. IAM Redis Cluster is a different runtime/client contract;
this source does not claim compatibility. Never disable AUTH to satisfy a
secret-free-state requirement. This assignment performs no credential retrieval.

## Three states and output contract

Use separate durable backends/keys and permissions for foundation, data and
application. Backend/recovery storage must be external and outlive all three.

| Output | Consumer |
| --- | --- |
| `identity` | Approved project ID, immutable number, environment, region receipts/fences |
| `network.self_link`, `allocated_ip_range`, `private_services_connection` | `modules/gcp/postgres.network_self_link`, `.allocated_ip_range`; apply foundation first and wait for PSA |
| `network.functions_vpc_connector`, `network.functions_vpc_connector_name` | `modules/gcp/functions.vpc_connector`; never omit private SQL routing |
| `network.subnet_self_link`, range names/ranges | Reviewed private networking and NetworkPolicy profile |
| `gke.name`, `.location`, `.private_endpoint`, `.id` | Separate application/search root with exec authentication and private operator path |
| `gke.workload_pool`, `workload_identity` | `modules/gcp/object-storage.workload_identity` exact namespace/KSA entries and other per-resource IAM |
| `actor_host_profile` | Opt-in durable-actors `placement.zone`, GKE gvisor RuntimeClass/selector |
| `pipeline` | Pub/Sub IDs and optional Redis non-secret host/port/public CA references; password never output |

Use a reviewed explicit **non-secret output manifest** between states if the next
operator must not read the whole foundation state. `terraform_remote_state` grants
access to the complete state, including Redis AUTH when enabled. Data state owns
Cloud SQL/PostgreSQL 17, separate relaycontrol/relayhistory/hoopdb databases and
migration ledgers, GCS, optional search/function resources and least-privilege
workload bindings. Foundation does not bootstrap SQL roles, extensions or secrets.
Application state owns namespaces/KSAs, External Secrets integration, Kubernetes,
Helm and selected immutable images/artifacts. Use `gke-gcloud-auth-plugin` exec
with approved ambient credentials there; never output or persist provider/OIDC
tokens. The older `examples/gcp` is **not** a safe combined installer for this
contract: it co-locates state and reads a Google access token. Build/review a
separate application root before use rather than copying that provider setup.

Before applying anything, have the operator review exact resources, identity,
networking, state/recovery permissions and the plan, then approve the persistent
mutation under the GCP setup skill. No deploy/apply is authorized by these files.

## External prerequisites and retirement

The approved project needs billing/quotas and reviewed API/service-agent setup:
`cloudresourcemanager.googleapis.com`, `compute.googleapis.com`,
`container.googleapis.com`, `iam.googleapis.com`, `servicenetworking.googleapis.com`,
`logging.googleapis.com`, `monitoring.googleapis.com`; `vpcaccess.googleapis.com`
when using the connector; `pubsub.googleapis.com` and its service agent for the
native queue; `redis.googleapis.com` and its service agent for managed Redis.
Artifact Registry, SQL Admin, Secret Manager, Cloud Functions/Run/Build/Scheduler
and KMS APIs/agents are additional **data/application** prerequisites as selected.
This module has no `google_project_service`; destroying it cannot disable APIs.
No org/billing/project/DNS management, adopted resources or state imports occur.
Existing proof installations and their Alchemy/CLI/Helm ownership stay untouched.

Retirement needs a separate approved inventory and verified backup/restore set.
Terraform resource preconditions are not a destroy-time authorization gate: verify
the exact project number, backend/key, state resource IDs and receipt independently
before approving a destroy plan, including targeted operations.
Remove application writers/consumers and retain/export PVC, SQL, object and queue
data first; then retire data state; only then foundation. GKE, topics and
subscriptions are protected by default (`deletion_protection`, Pub/Sub `PREVENT`);
Redis has its own deletion protection. Disabling protection requires a reviewed
change applied while the resources remain in configuration, then a fresh destroy
plan. Retention/protection do not replace backups. GKE deletion may leave cloud
load balancers/disks that application controllers owned; reconcile those from the
receipt rather than sweeping a project. PSA uses `ABANDON` to prevent disconnecting
remaining managed data. That **retains** peering and can block VPC/range deletion:
after all data consumers are gone, separately approve removal/reconciliation of
that exact retained connection. Do not promise blind `destroy` completeness.
Never delete projects, detach billing, disable APIs, remove parent DNS or sweep
unowned resources. State, its history and recovery storage have a separate
retention/access lifecycle, including Redis AUTH if used.

## Offline validation

Terraform >=1.11 (<2), Google >=7.46.2 (<8); root lock pins the tested release.
`terraform init -backend=false`, `validate`, and `test` run with mock Google
providers and no cloud credentials. `apply` inside `.tftest.hcl` applies mocked Google resources
only. The composition fixture uses the real local random provider because the CI
Terraform version cannot mock ephemeral resource types; administrator creation
is explicitly disabled, so no password or secret value is generated. Tests cover private defaults, dependency/output composition, explicit
optional services, exact KSA IAM, security/retirement flags and negative
project/environment/access/range/version/actor/Redis acknowledgment cases. Mock
success does not prove GCP availability, policy, IAM propagation, quotas, routing,
DNS, application compatibility, live E2E or destroy/recreate/isolated restore.

Primary references: [VPC firewall priority](https://docs.cloud.google.com/firewall/docs/firewalls#priority),
[GKE provider](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/container_cluster),
[GKE channels](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/release-channels),
[GKE Sandbox](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/sandbox-pods),
[Redis TLS](https://docs.cloud.google.com/memorystore/docs/redis/about-in-transit-encryption),
[Redis networking](https://docs.cloud.google.com/memorystore/docs/redis/networking),
[provider AUTH state behavior](https://github.com/hashicorp/terraform-provider-google/blob/v7.46.2/google/services/redis/resource_redis_instance.go).

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, < 2.0 |
| google | >= 7.46.2, < 8.0 |

### Providers

| Name | Version |
| ---- | ------- |
| google | >= 7.46.2, < 8.0 |
| terraform | n/a |

### Resources

| Name | Type |
| ---- | ---- |
| [google_compute_firewall.deny_ingress](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_global_address.private_services](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_global_address) | resource |
| [google_compute_network.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_network) | resource |
| [google_compute_router.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_router) | resource |
| [google_compute_router_nat.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_router_nat) | resource |
| [google_compute_subnetwork.connector](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_subnetwork) | resource |
| [google_compute_subnetwork.nodes](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_subnetwork) | resource |
| [google_container_cluster.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/container_cluster) | resource |
| [google_container_node_pool.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/container_node_pool) | resource |
| [google_project_iam_member.nodes](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.registry](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_pubsub_subscription.dead_letter](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_subscription) | resource |
| [google_pubsub_subscription.pipeline](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_subscription) | resource |
| [google_pubsub_subscription_iam_member.dead_letter](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_subscription_iam_member) | resource |
| [google_pubsub_subscription_iam_member.subscriber](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_subscription_iam_member) | resource |
| [google_pubsub_topic.dead_letter](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic) | resource |
| [google_pubsub_topic.pipeline](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic) | resource |
| [google_pubsub_topic_iam_member.dead_letter](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic_iam_member) | resource |
| [google_pubsub_topic_iam_member.publisher](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/pubsub_topic_iam_member) | resource |
| [google_redis_instance.pipeline](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/redis_instance) | resource |
| [google_service_account.nodes](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_networking_connection.private_services](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_networking_connection) | resource |
| [google_vpc_access_connector.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/vpc_access_connector) | resource |
| [terraform_data.fence](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [google_project.existing](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/project) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| environment | Environment label and resource-name suffix. | `string` | n/a | yes |
| expected\_environment | Independent reviewed environment fence; must equal environment. | `string` | n/a | yes |
| expected\_project\_number | Approved immutable project number, checked against Resource Manager before mutations. | `string` | n/a | yes |
| gke\_version | Explicit reviewed initial/minimum GKE version (x.y.z-gke.build); managed channel upgrades can advance it. No latest lookup. | `string` | n/a | yes |
| maintenance\_window | Reviewed recurring GKE maintenance window (RFC3339 start/end, RFC5545 recurrence); GKE minimum availability requirements apply. | `object({ start_time = string, end_time = string, recurrence = string })` | n/a | yes |
| name | Installation prefix; environment is appended automatically. | `string` | n/a | yes |
| network\_ranges | Reviewed disjoint RFC1918 IPv4 ranges: nodes, pods, services, /28 control plane, PSA, /28 serverless connector. Must also avoid connected networks. | ```object({ nodes = string pods = string services = string control_plane = string private_services = string connector = string })``` | n/a | yes |
| node\_locations | Explicit node zones in region; regional control plane does not imply application HA. | `list(string)` | n/a | yes |
| operator\_cidrs | Explicit approved operator source IPv4 CIDRs (VPN/bastion/CI); required even for private API. No /0. These do not create a network path or grant Kubernetes RBAC. | `map(string)` | n/a | yes |
| project\_id | Approved existing project ID. No project, billing or organization resources are created. | `string` | n/a | yes |
| region | Explicit regional GKE and managed-service location. | `string` | n/a | yes |
| release\_channel | Explicit GKE managed upgrade channel. Control plane and nodes advance; a version is not a permanent pin. | `string` | n/a | yes |
| actor\_hosts | Opt-in GCP Terse/durable-actors GKE Sandbox pool, not the EKS actor-host profile. Zone must match chart placement.zone. No multi-tenant or HA guarantee. | `object({ enabled = optional(bool, false), zone = optional(string), machine_type = optional(string, "e2-standard-4"), total_min = optional(number, 1), total_max = optional(number, 3) })` | `{}` | no |
| create\_connector | Create dedicated Serverless VPC Access connector for modules/gcp/functions. | `bool` | `true` | no |
| deletion\_protection | GKE deletion protection. Disabling must be a separately approved retirement change applied before destroy; does not authorize deleting durable data. | `bool` | `true` | no |
| enable\_nat | Reviewed internet egress through Cloud NAT for private nodes/connector. False permits Google API access but not arbitrary internet pulls or actor HTTPS egress. | `bool` | `false` | no |
| labels | Additional non-secret labels; environment/managed-by are reserved. | `map(string)` | `{}` | no |
| node\_capacity | Ordinary node pool total min/max across the selected zones; initial count is per zone. Size for all selected application resources and PVC constraints. | `object({ machine_type = string, total_min = number, total_max = number })` | ```{ "machine_type": "e2-standard-4", "total_max": 6, "total_min": 3 }``` | no |
| node\_image\_registry\_projects | Approved existing projects granting nodes Artifact Registry reader; no wildcard project-wide data/secret roles. Registry projects are explicit external inputs. | `set(string)` | `[]` | no |
| pipeline | Optional native pod pipeline pull queue, distinct from functions module GCS event topic; IAM is limited to supplied KSAs. No subscription is auto-consumed by the chart. | `object({ enabled = optional(bool, false), publishers = optional(set(string), []), subscribers = optional(set(string), []), retention = optional(string, "604800s"), kms_key_name = optional(string) })` | `{}` | no |
| public\_api\_enabled | Explicit opt-in to operator-CIDR-scoped public GKE API; default is private endpoint only. | `bool` | `false` | no |
| redis | Optional managed TLS+AUTH Memorystore. Enabling requires explicit acknowledgment that the Google provider stores generated AUTH in state, including refresh. Prefer externally managed Redis when foundation state must contain no secrets. | `object({ enabled = optional(bool, false), acknowledge_auth_in_state = optional(bool, false), version = optional(string), memory_size_gb = optional(number, 5), deletion_protection = optional(bool, true) })` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| actor\_host\_profile | Opt-in GCP chart placement contract. GKE installs native sandbox.gke.io/runtime=gvisor node label/taint and RuntimeClass toleration; no EKS actor-host taint is added. This is not untrusted multi-tenant isolation or an application HA claim. |
| gke | Non-secret application/search state inputs. Use gke-gcloud-auth-plugin exec later; never store google\_client\_config access\_token in any state. Private endpoint requires approved routed operator access and IAM/RBAC. |
| identity | Verified project/environment contract; existing org, billing and parent DNS remain external. |
| network | Data-state inputs: postgres network\_self\_link/allocated\_ip\_range, and functions vpc\_connector. PSA completion is an explicit dependency. |
| pipeline | Native pipeline non-secret Pub/Sub and optional Redis references. Redis password is intentionally never output; provider state still contains generated AUTH when managed Redis is enabled. |
| workload\_identity | Namespace/KSA direct-principal contract for data IAM, without keys or workload-wide IAM grants. Use one subject per exact namespace/service account. |
<!-- END_TF_DOCS -->
