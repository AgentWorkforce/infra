# GCP foundation root (held, source only)

Thin root for [`modules/gcp/foundation`](../../modules/gcp/foundation). Read that
module's state/credential, networking, actor, managed-upgrade and retirement
limitations before preparing an operator plan. No live proof or application
installer is implied. Existing proof stacks remain untouched. GCP project vending
is not implemented in Pippen.

Use this root for **foundation state only**. The approved existing project ID and
immutable number, environment, zones, version/channel, private operator path,
network ranges, API/service-agent setup, durable backend and recovery storage are
external inputs. Organization/billing/parent DNS and state storage are not managed.
Do not apply the example unchanged: project number and GKE version are deliberately
invalid placeholders. CIDRs/dates are illustrative and need independent review.

Copy the `.tfvars.example` to an ignored local configuration and replace all
placeholders without adding secret values. Keep the private API, previews and
managed Redis disabled until individually reviewed. The default has **no NAT**;
full-suite image pulls and actor public HTTPS egress need a reviewed NAT opt-in or
another designed path. Default lack of egress is a safe source profile, not a claim
that the application can run unchanged.

Configure an approved remote backend separately (for example an existing external
GCS backend, with distinct foundation/data/application prefixes) before any live
plan. Do not let this stack own that backend or its KMS/recovery dependencies. Use
ambient approved ADC or Workload Identity; no provider/OIDC tokens in variables,
outputs, backends, saved configuration or state. Only Google provider resources
are used here; Kubernetes/Helm authentication belongs in later application state.
Use gke-gcloud-auth-plugin exec there, never google_client_config access_token.

For source-only checks (no backend and no credentials):

```sh
terraform init -backend=false -input=false
terraform validate
terraform test
```

Do not run plan/apply against real GCP from this example without a concrete
reviewed execution packet and operator approval under the repository GCP setup
skill. The mock tests use `apply` only against mocked Google resources; the module
composition fixture uses the real local random provider with administrator
creation disabled, generating no password or secret value. Supply an exact
available GKE version and channel after independent verification; channel/node
auto-upgrades remain managed and the requested version is not a permanent pin.

`foundation` exports `identity`, `network`, `gke`, `workload_identity`,
`actor_host_profile` and `pipeline`. Pass a reviewed non-secret manifest to a
separate data root composing postgres/object-storage/search/functions, then to a
separate application root for relaycontrol, relay-webapp, sessions-pipeline,
relayhistory, Relaycast/Terse and optional Relayfile/auth dependencies. SQL roles,
extensions, secret delivery, migration ledgers, buckets, actors artifacts, ingress,
certificates, DNS and exact versioned images are later contracts. Object-storage
can bind exact KSA namespace/name identities through the exported workload pool.
The functions module owns separate GCS push Pub/Sub topics; the optional foundation
queue is for native pod pipeline `PUBSUB_TOPIC`/`PUBSUB_SUBSCRIPTION` only.

Managed Redis is opt-in and **stores generated AUTH in foundation state on every
provider refresh**. Its password is never exported, but that does not make state
secret-free. Enabling requires `redis.acknowledge_auth_in_state=true`, explicit
version and approved restricted state/history handling. When secrets in foundation
state are forbidden, keep it off and use externally managed TLS+AUTH Redis with
Secret Manager/External Secret delivery; do not import/data-source that instance.
No auth-disabled shortcut is provided.

Retirement is separate approval: verified recovery, quiesced application/data,
then foundation. Protection defaults require an applied reviewed change before
destroy; Pub/Sub queues must be drained/exported. PSA intentionally retains its
connection on destroy and may block network deletion until separately reconciled.
Do not sweep or disable APIs/delete the adopted project. State/recovery and
sensitive history outlive the stack. Follow the full module retirement contract.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, < 2.0 |
| google | >= 7.46.2, < 8.0 |

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| foundation | ../../modules/gcp/foundation | n/a |

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
| foundation | Reviewed non-secret handoff contract for separate data and application states. |
<!-- END_TF_DOCS -->
