# AWS environments

The application target is **one RDS instance with a separate PostgreSQL database
per service**. Control uses `relaycontrol` by default; HoopDb uses `hoopdb`,
Relaycast uses `relaycast`, and the optional Relayfile add-on uses `relayfile`.
Each has independent migration/runtime roles and its own canonical schema.
`application_database_name` names only the initial Control database; it stays
unchanged on existing instances. Changing it forces replacement of an existing RDS instance; review the plan and explicit data migration/restore first. `postgres_service_bindings` publishes complete
non-secret database/schema/role targets on the same endpoint. These outputs do
not create SQL databases, prove application compatibility or enable add-ons.
See the [storage contract](../../../docs/shared-postgres-storage-contract.md).
Legacy RelayAuth/standalone History databases and SQLite receipts are not target
acceptance; existing data is retained until a separately reviewed cutover.

An environment-aware data stack for self-hosted Agent Relay. It composes RDS
PostgreSQL 17 (or explicitly selected Aurora PostgreSQL), S3, private OpenSearch,
and optionally the sessions-pipeline Lambda/SQS/EventBridge runtime. This is
source preparation for a complete installation: mock tests do **not** prove a
live deployment or application compatibility.

The foundation supplies the private network, EKS, Pod Identity agent, security
groups, administrative runner access, NAT/endpoints, state bucket and KMS grants.
The account-wide OpenSearch service-linked role
(`AWSServiceRoleForAmazonOpenSearchService`) is created by neither foundation
nor this state; a brand-new account fails the domain create without it. Create
it once per account with the foundation's
[account prerequisites](../aws-foundation/README.md#account-prerequisites)
before the first plan. Foundation and application lifecycle
remain separate from this data state. Foundation automation is tracked in
[infra#59](https://github.com/AgentWorkforce/infra/issues/59).

## Environments and state

Choose any lowercase `environment` slug (up to 16 characters), independently of
its development/staging/production sizing class. The combined
`name_prefix-environment` must fit in 21 characters. Resources, namespace,
verification markers and tags are environment-scoped. Use a unique prefix or
environment name for every installation in the same account/region.

| Class | RDS | Backups | OpenSearch |
|---|---|---|---|
| development | t4g.micro, 20 GiB, single AZ | 7 days | one t3.small node, 20 GiB |
| staging | t4g.medium, 100 GiB, Multi-AZ | 14 days | one node per supplied AZ, m7g.large, 100 GiB |
| production | r7g.large, 100 GiB, Multi-AZ | 35 days | three r7g.large data nodes, dedicated masters, Multi-AZ standby, 200 GiB |

Production refuses database deletion protection being disabled and requires
three distinct search subnets in three AZs. The foundation must verify their
actual AZs; distinct IDs alone cannot establish AZ placement. Aurora requires
an explicit region-supported engine version and compatible instance class;
RDS live proof does not qualify Aurora.

Copy a matching pair from `profiles/` into an approved private directory and
replace every placeholder. Keep the JSON files uncommitted, with mode 0600.
The runner requires encrypted S3 state with native locking and an exact expected
bucket owner. Keys must end in:

```text
/<account_id>/<region>/<environment>/data.tfstate
```

Foundation and application state use different keys. CLI workspaces are not
used: the runner refuses both an environment-selected workspace and a cached
non-default workspace. Credentials belong to the approved runner, never backend
JSON, Terraform variables, values files or command output. State and saved plans
contain operational metadata and must remain private even without passwords.

### Application namespace

**Install the application charts into the namespace this state outputs.** Every
workload Pod Identity association (sessions storage and the search
indexer/reader) is bound to `namespace`. With the default `namespace = null`
it is `agent-relay-<environment>`, e.g. `agent-relay-dev`, **not**
`agent-relay`. Pods installed into any other namespace start normally but get
no AWS credentials, so S3 and OpenSearch calls fail at runtime. Pass the
foundation's `data_environment_inputs.namespace` through unchanged, then take
the Helm `--namespace` from this state. After the runner's `output` command:

```sh
jq -r .namespace terraform/.runs/<account>/<region>/<environment>/verification.json
```

The `environment` output carries the same value, and `service_accounts` lists
the exact ServiceAccount names in that namespace.
Changing `namespace` on an existing environment replaces its Pod Identity
associations; plan it as a reviewed migration together with the Helm release.

## Review and apply

From the repository root, under the intended customer's AWS identity:

```sh
python3 terraform/scripts/aws-environment.py plan \
  --variables /approved/private/dev.tfvars.json \
  --backend /approved/private/dev.backend.json
python3 terraform/scripts/aws-environment.py show \
  --variables /approved/private/dev.tfvars.json \
  --backend /approved/private/dev.backend.json
```

Review the saved plan and its account, region, environment, resource inventory,
cost, retention and networking. After approval of that exact plan, run `apply`
with the same arguments and `--approve-plan <saved-plan-SHA-256>`. Receipt v3
binds original variables/backend paths and bytes, Terraform source/dependency
locks, this wrapper, selected tool family and its run-owned CLI configuration.
For local Lambda ZIPs, it also binds the original artifact path/hash and private
content-addressed bytes actually named by the plan's derived variables. Original
input variables and ZIPs are never rewritten. The active `plan-receipt.json`
selects `plans/<random-v4-hex>/data.tfplan` and `variables.json`; local artifacts
live under `artifacts/sha256-<hex>/package.zip`, inside the private run directory.
Review the derived variables and staged artifact lineage with the saved plan.
Legacy receipts are refused: create and review a new v3 plan after upgrading.

Receipt v3 also records `search_mode_history`. The mandatory pure search classifier runs on native saved-plan prior state and changes before receipt creation and again before apply. It cross-checks exact prior/before IDs, holds mixed/deposed/unknown or destructive wrong-mode history, and permits old/unmarked state only as `legacy-or-missing-marker unchanged-domain` enrollment: all search AWS actions are no-op and only the matching fixed mode marker is added. A first apply whose domain create failed after the marker was recorded is admitted on retry as `fresh-retry`: the domain is created in the stored marker's mode, the marker is unchanged, and every recorded search object is a no-op (see the [search module](../../modules/aws/search/README.md)). This qualification does not prove a marker was never lost. Unmarked legacy destroy requires reviewed unchanged-mode enrollment first. No skip flag or client mode/digest establishes history. Receipts v1/v2 and frozen source/input bindings are never silently repinned; prepare/review a new plan. Standalone module invocations remain subject to the module's documented manual-upgrade limits.

The wrapper rechecks original/staged inputs, source, backend, CLI configuration
and receipt around init/plan and immediately before apply. Changed bindings
require a new plan; a refused operation or failed replacement plan preserves the
previous unconsumed approval. Every actual apply attempt atomically moves the
active receipt to that attempt's `apply-attempt-receipt.json` **before** invoking
Terraform, including when apply fails partially. Do not retry it automatically;
retain evidence and independently reconcile exact state/native resources before
reviewing a recovery plan. Receipt renames are atomic for cooperating live
processes, not power-loss durable: directory metadata is not fsynced. After a
host/filesystem crash, independently reconcile backend/state and attempt
evidence before trusting or retrying any recovered approval. This wrapper does
not own automatic rollback or
retirement of a customer's existing installation.

All inherited `TF_*` settings are discarded; the child uses only controlled
input/data-directory/CLI-config settings, with a run-owned configuration that
disables checkpoints. `TF_BIN` selects only the approved `terraform`/`tofu`
family before environment sanitization. These are drift checks, not isolation
from concurrent hostile same-UID or privileged mutation. Use an approved
PATH/toolchain and exclude concurrent privileged mutation. The wrapper does not
attest executable/provider bytes or remote backend state; Terraform's own
saved-plan/state locking checks remain necessary. Provider credentials refresh
through the runner's normal SDK chain; the provider fences the allowed account.

Use `output` with the same arguments to export **only** non-secret verification
references to `terraform/.runs/<account>/<region>/<environment>/verification.json`.
`TF_BIN=tofu` selects OpenTofu; use one reviewed tool/version and dependency lock
for the lifecycle. The committed lock is for Terraform. OpenTofu rewrites
implicit provider registry addresses and uses different package checksums;
initialize and review that tool's converted lock in a separate checkout before
using the runner. A Terraform lock cannot simply be used read-only with
OpenTofu. Normal runner operations require a reviewed, tool-compatible lock and
never upgrade providers implicitly. The runner exposes no destroy command.

### Pippen sandbox execution

Pippen allocates/leases/sweeps AWS accounts; these Terraform files create the
product infrastructure. Reuse the assigned account and certificate identity.
Follow the Pippen owner's current runbook for `sandbox up` and `status`, then set
the returned account/session and agent in `pippen`, and use a prefix such as
`pippen-sbx-ar`. Every product invocation runs under refreshing credentials:

```sh
pippen sandbox exec aws-proof -- \
  python3 terraform/scripts/aws-environment.py plan \
  --variables /approved/private/dev.tfvars.json \
  --backend /approved/private/dev.backend.json
```

Use the same wrapper for show/apply/output. The runner verifies Pippen's exported
account/agent/session and exact STS caller, and refuses a Pippen execution whose
configuration omits the lease instead of silently using customer defaults. Any
`PIPPEN_SANDBOX_*` marker requires the complete exact declared/exported tuple;
a recognized `agent-session` STS caller cannot opt out by stripping markers.
These checks do not allocate an account or grant credentials. Roles use `/pippen/workload/`, the
Pippen boundary, reserved tags and bucket prefix. No fallback to an admin role
is provided. Before live use the Pippen owner must confirm the deployed boundary
and sweeper support RDS, OpenSearch, Lambda/SQS/EventBridge and the foundation
resources. Existing S3-only or mock proof does not establish that support.

The state bucket must outlive inner stack teardown. Preserve approved recovery
data, state and receipts outside any session prefix Pippen will sweep. Never
delete the baseline workspace bucket. End with the owner-run Pippen sweep and a
`clean: true` receipt; investigate quarantine rather than bypassing it. Pippen
currently supplies AWS sandboxes, not GCP project vending.

## Private Desktop feed (optional)

Off by default. Setting `desktop_feed` creates the AWS side of Relay Control's
private Desktop feed through [`modules/aws/desktop-feed`](../../modules/aws/desktop-feed):
one `ECC_NIST_EDWARDS25519`/`SIGN_VERIFY` KMS key and alias
`alias/<name_prefix>-<environment>-desktop-feed-<profile>` per profile ID, a
private `<name_prefix>-<environment>-<account_id>-<region>-desktop-feed` bucket,
and a `<name_prefix>-<environment>-desktop-feed` role (with the same path and
Pippen boundary as the other roles) whose Pod Identity association binds
Control's ServiceAccount, `<release_name>-relay-control` by default, in this
environment's namespace:

```json
"desktop_feed": { "profiles": ["<profile-id-from-the-private-handoff>"] }
```

`prefix` (default `desktop-feed`) and `service_account` are optional. Set
`service_account` to the name the reviewed values actually render: an overlay
with `relay-control.fullnameOverride` (for example `values-eks.yaml` sets
`relay-control`) or `serviceAccount.name` changes it. Check with
`helm template ... | yq 'select(.kind == "ServiceAccount") | .metadata.name'`. The
`desktop_feed` output's `control_env` maps one to one onto Control's settings
(`SELFHOST_DESKTOP_FEED_SIGNER=awskms`, `_STORAGE=s3`, `_KMS_REGION`,
`_KMS_KEY_ALIASES`, `_S3_BUCKET`, `_S3_REGION`, `_S3_PREFIX`); copy it into
`relay-control.extraEnv`. Adding a profile later adds a key; removing one
schedules its key for deletion and breaks the Desktop builds that embed it.
Pod Identity allows one role per ServiceAccount, so nothing else may associate
Control's ServiceAccount. Check the module's credential-source note before
relying on the role: the Control image must read Pod Identity credentials.

## Search access to the sessions bucket

The search indexer and session-read roles have no bucket access by default. To
grant them read-only access to this environment's sessions bucket, set:

```hcl
search_sessions_bucket_read = {
  bucket_arn  = "arn:aws:s3:::<name_prefix>-<environment>-<account_id>-<region>-sessions"
  # The environment's kms_key_arn; omit for AWS-managed encryption.
  kms_key_arn = "arn:aws:kms:<region>:<account_id>:key/<key-id>"
}
```

Any other bucket or key is refused at plan. This adds one inline policy to each
role and changes nothing else. External
roles (`existing_runtime_roles`) get it as `runtime_role_policy_json.sessions_read`
to attach themselves. After apply, map both roles in OpenSearch; see
[the search module](../../modules/aws/search/README.md#after-apply).

## Existing runtime identities

By default this root manages the search and Lambda execution roles as before.
For an approved bootstrap phase that owns these identities separately, set:

```hcl
existing_runtime_roles = {
  indexer_role_arn  = "arn:aws:iam::111111111111:role/bootstrap/example-indexer"
  reader_role_arn   = "arn:aws:iam::111111111111:role/bootstrap/example-reader"
  # Required exactly when pipeline_runtime = "lambda"; omit in worker mode.
  pipeline_role_arn = "arn:aws:iam::111111111111:role/bootstrap/example-pipeline"
}
```

Replace the placeholder account and role names. Both search identities are
required together; Lambda mode additionally requires the pipeline identity.
Empty, wildcard, foreign-account, duplicate, administrative and managed-storage
role aliases are refused. The search module's existing `workload_roles.create =
false` path creates neither its roles/inline policies nor Pod Identity
associations. The functions module similarly authors no execution-role IAM.
All supplied runtime principals are included in the private OpenSearch domain
policy alongside its distinct administrator. Fine-grained OpenSearch role
mappings are still required: a domain policy does not make the reader read-only.
`verification.search` exports the supplied effective ARNs; verification and
application service-account names retain their existing contract.

The product bootstrap owner must independently verify the exact role, trust,
policy, boundary and mandatory-guard hashes, and arrange the exact EKS Pod
Identity associations before application use. This state performs no IAM reads
or validation of those properties, and does not grant the caller `iam:PassRole`
or other permissions. `runtime_role_policy_json` exports proposed indexer,
reader and optional pipeline permissions for review, including the Lambda's
OpenSearch indexer grant. It never installs them for external roles; generated
resource references can remain unknown until creation. The separate bootstrap
must resolve the exact resource scope and dependency order before activation.

These are product-owned bootstrap prerequisites, not new product resources in
Pippen's baseline. This option does **not** make the complete data root IAM-free:
the sessions-bucket access role and its worker/alleyoop associations retain their
existing ownership. It also does not provide a closed Pippen capability profile,
change the accepted caller contract, install guard infrastructure or prove any
live deployment. Those remain separate reviewed work. Null retains current
managed-role defaults. For existing deployments, use a reviewed IAM state
ownership handoff before changing modes; otherwise Terraform proposes deleting
the old managed roles/policies/associations. Preserve external identities through
consumer retirement and remove them in their owning bootstrap phase afterwards.

## Lambda provider and PostgreSQL TLS bindings

The private managed-OpenSearch Lambda artifact needs explicit non-secret runtime
configuration in addition to its immutable ZIP/image reference. Set
`lambda_runtime_bindings` using the Lambda profile example. The index must start
with `<name_prefix>-<environment>-` and match the artifact's lowercase letter/digit/
underscore/hyphen grammar (maximum 201 characters, no dots). Choose a fresh reviewed index for a changed
search representation. `state_backend_id` is the shared writer/reader base ID
(maximum 114 identifier characters); the matching artifact appends
`.js-literal-v2` before using its 128-character PostgreSQL completeness key.
`complete_since` must be `epoch` or a nonnegative RFC3339 timestamp.

The root passes the managed domain endpoint and region, index, projection schema,
completeness settings, and strict PostgreSQL TLS configuration to the function.
The matching artifact must contain the reviewed public CA at
`assets/postgres-ca.pem`; `postgres_ca_sha256` must equal the digest of those exact
packaged bytes. The configured runtime path is `/var/task/assets/postgres-ca.pem`.
Terraform does not inspect a remote ZIP/image, fetch a CA, mount a file or prove
that the chosen artifact implements this contract. Lambda supplies its reserved
`AWS_REGION` variable; this root does not override it.

`lambda_shared_environment` exports the same non-secret configuration for the
matching reader deployment. Independently verify that reader's immutable
artifact, read-only database identity, JWT issuer/audience/JWKS/origin, and
schema/FGAC bootstrap. Keep passwords, database URLs and AWS credentials in the
existing reviewed secret/runtime identity path, outside these bindings.

Omitting bindings preserves inactive provisioning behavior, and worker mode
rejects Lambda-only bindings. Automatic Lambda activation now refuses missing
bindings. Supplying them is configuration only: the existing exact-artifact,
managed-RDS bootstrap, projection-state grants, OpenSearch schema/role mappings,
S3/SQS event-path, private networking and overlapping-worker retirement checks
must still pass before an operator sets `activate_lambda = true`. No runtime
invocation creates schema or grants, and this change performs no activation.

## Lambda bootstrap and the complete application

Worker mode is the default. Lambda mode requires `pipeline_runtime = "lambda"`,
private function security groups, and exactly one compatible immutable package:
a digest-pinned ECR Lambda image, a **versioned** S3 ZIP (not the mutable `null`
version), or a local ZIP with its base64 SHA-256. [`profiles/lambda.tfvars.json.example`](profiles/lambda.tfvars.json.example)
shows an additive fragment to merge into an environment file. The Lambda module
uses Node 24/arm64 for ZIPs; a Bun services image is not a Lambda handler package.

`activate_lambda` defaults to false. The per-service-database profile currently
**refuses true**, even with valid artifact/TLS settings, until per-service
runtime/bootstrap qualification is implemented and reviewed. This keeps the
queue event source mapping and both schedules disabled. The queue and bucket notification still exist and can
accumulate messages. Direct authorized invocation remains possible. Before a
reviewed implementation can lift the application activation hold:

1. Verify package provenance, handler/schema assets, TLS support and actual
   provider adapter dispatch in the deployed pipeline **and** read API.
2. Complete a managed-RDS-compatible HoopDb bootstrap, with distinct owner and
   runtime credentials, extension/ACL convergence and generation checks. The
   existing true-superuser CNPG bootstrap is not an RDS bootstrap. Lambda cannot
   reach a Kubernetes-only CNPG Service merely by sharing a VPC.
3. Populate the pipeline's empty secret out of band, using runtime credentials.
   Never use the RDS master account as an application credential.
4. Configure OpenSearch fine-grained permissions for distinct indexer, Lambda
   writer and reader roles. The temporary proof mappings below are not the
   application's permanent security configuration.
5. Disable overlapping reconcile/referee/cost-sweep worker stages, account for
   queued messages, and verify no second pipeline owner will run. Lambda is an
   alternative for those stages; the remaining application workers still run.

The `application_contract` output records the target full suite:
relaycontrol API, relay-webapp, sessions-pipeline with History capability, Relaycast
with PostgreSQL authoritative state, Control authentication, and
optional Relayfile. A separate durable-actors store is not a dependency of the
separate-service-database target. The output is not a deployable Helm overlay and labels
the Relaycast PostgreSQL backend as required but unqualified. Schema-qualified
migrations, per-service runtime identities and Secrets, database CONNECT/ACL isolation,
Redis where required, DNS/TLS, authentication and application wiring still belong
in the reviewed foundation/application installation. ServiceAccount outputs must match actual
chart component identities; creating Pod Identity associations alone grants no
running workload the intended binding.

## Live verification

Use an approved private Linux/macOS runner with refreshed AWS credentials, network access,
`boto3` and `psycopg[binary]`. The verifier reads Secrets Manager only in memory
for PostgreSQL and prints bounded receipts without URLs or secret values.
Choose one random run ID (`python3 -c 'import uuid; print(uuid.uuid4().hex)'`) and
use it for every phase:

```sh
python3 terraform/scripts/verify-aws-data.py configuration \
  --config /approved/private/verification.json --run-id <32-hex-run-id> \
  --confirm-account <account> --confirm-region us-west-2 \
  --confirm-environment dev --confirm-environment-class development \
  --confirm-name-prefix agent-relay \
  --confirm-search-url <separately-reviewed-private-HTTPS-search-url> --confirm-live
```

The account, region, environment, class, installation prefix and exact private
OpenSearch HTTPS URL must come from an independently reviewed installation/
backend record, not from the target JSON
being verified. Confirm the exact URL against a separately reviewed native
DescribeDomain record and expected domain ARN: domain names can repeat across
accounts, and the opaque endpoint suffix is not an account ownership proof.
Do not automatically derive `--confirm-search-url` from the untrusted target
JSON. All confirmations are required, including for cleanup. Replacing
`verification.json` with another installation's otherwise valid same-account,
same-environment output is refused before constructing an SDK session. There is
no permissive legacy schema fallback: regenerate `verification` after upgrading.
For Pippen, also supply the exact independently reviewed
`--confirm-pippen-agent <agent> --confirm-pippen-session <UUID>`; both must match
the exported tuple. Customer mode refuses an exported Pippen tuple. Native
Pippen ownership tags are checked in the RDS/Aurora and Lambda phases; S3
requests bind the expected bucket owner, and Search uses the confirmed URL and
configuration/bootstrap ARN-to-endpoint checks rather than native tag reads.

The closed output includes `name_prefix`, `environment_class`, nullable `pippen`,
`postgres.identifier`/`master_username`, and `pipeline.function_name`. Every phase
and the direct-import helpers require an immutable `ConfirmedInstallation` of
scalar values (including that exact independently confirmed HTTPS origin),
validate all derived resource names and unqualified ARN types,
and check the caller before a target operation. RDS uses
`<prefix>-<environment>-pg` (instance or Aurora cluster); Lambda uses
`<prefix>-<environment>-session-pipeline`; bucket/search names and writer
endpoints follow this root's exact conventions. Import callers must construct
that confirmation separately with `confirm_installation(...)`; omitting it is an
error. Before signing each direct `Search.call`, its path and exact confirmed
origin are checked first, then STS must report the confirmed account and a
well-formed same-account ARN. A recognized common `agent-session` caller must
match the selected Pippen lease and is refused in customer mode. Runtime-role
callers remain supported. Direct `Search` checks account/common lease; the
phase helpers additionally enforce their exact configured phase-role ARN.
Neither check inspects native IAM role content or establishes authorization.
Names and confirmations are safety checks, not IAM authorization.

Before `GetSecretValue`, the PostgreSQL phase checks singleton native RDS/Aurora
metadata, PostgreSQL17 engine/status, exact identifiers/ARNs, private/encrypted
settings, database/port/master username, backups/protection, writer endpoint and
active managed-secret linkage. Aurora also checks every unique member's exact
installation name/ARN, cluster membership, private settings and tags. Native
`Environment`, `EnvironmentClass`, `ManagedBy` and, when selected, all three exact
Pippen ownership tags must match before reading credentials. Missing, duplicate,
malformed, foreign or denied metadata refuses the operation. These tags come
from the existing DescribeDBInstances/DescribeDBClusters responses; no new IAM
grant or permission fallback is installed. The returned secret ARN and master
username are checked again before SQL; secret values remain only in memory.

Before `Invoke`, Lambda native name/unqualified ARN, execution-role ARN,
`Environment`/`EnvironmentClass`/`ManagedBy`/optional Pippen tags, arm64/private-VPC
state and reviewed code/image must match. Missing or denied tags refuse; a
`GetFunction` response with tag errors is not accepted. The external-role seam
remains: equality to the reviewed output role proves only the actual function's
binding. Independently verify that role's native ownership, trust, boundary,
inline/attached policy content and approved installation use; this helper does
not inspect IAM role content or make an authorization claim from its ARN. No
new permission grants are added to make a refused read succeed.

Run `postgres` with `--rds-ca /approved/rds-global-bundle.pem` to require real
PostgreSQL 17, private RDS metadata, encryption/backups/protection and
`sslmode=verify-full`, then a temporary-table round trip. Run `storage` under the
storage role for synthetic put/get/list/delete. Every configuration and storage
S3 request binds `ExpectedBucketOwner` to the separately confirmed account,
including cleanup; a name containing an account ID is not ownership proof.
Version history is retained.

Run `search-bootstrap` as the separate administrator, `search-write` as the
indexer, `search-read` as the reader, then `search-cleanup` as the administrator,
each with the same arguments and run ID. Each phase first requires the
independently confirmed exact search URL, so runtime roles need no new
DescribeDomain permission. Native bootstrap still
checks domain ARN and endpoint linkage. These phases create temporary scoped
FGAC roles/mappings and two synthetic indices, verify the marker, reject both
single and bulk reader writes, reject access to a known foreign index, and
check the rejected writes had no effects before cleanup. Signed requests never
follow redirects. Direct `Search.call` paths must have exactly one leading
slash, remain on the confirmed HTTPS origin, and contain no backslash, control
character or fragment; refusal precedes credential access or signing. Keep
cleanup failures visible and retain the run ID so the
exact synthetic resources can be retired later.

`lambda-smoke` checks the deployed arm64/private-VPC artifact and explicitly
invokes reconcile. ZIPs also need the reviewed `--lambda-code-sha256`. An invoke
HTTP 200 with `FunctionError` fails. This proves initialization/reconcile only;
the complete proof must additionally upload a synthetic session through the
real courier, follow S3 notification -> SQS -> Lambda -> RDS/OpenSearch -> read
API, and verify tenant/lease isolation, partial failures, DLQ/replay,
idempotence, all required application components, optional Relayfile on/off,
backup/restore, upgrade and clean retirement. Resource creation and a successful
smoke invocation are not full application proof.

Do not tear down an existing environment until ownership and a current
consistent recovery set are recorded. RDS deletion protection, final snapshots,
versioned non-empty S3 and the search module's `prevent_destroy` intentionally
block casual destruction. Any retirement needs a reviewed protection change,
exact destroy inventory and recovery proof; do not remove state to bypass them.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11 |
| aws | >= 6.0, < 7.0 |

### Providers

| Name | Version |
| ---- | ------- |
| aws | >= 6.0, < 7.0 |
| terraform | n/a |

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| chief\_execution\_node | ../../modules/aws/chief-execution-node | n/a |
| desktop\_feed | ../../modules/aws/desktop-feed | n/a |
| pipeline | ../../modules/aws/functions | n/a |
| postgres | ../../modules/aws/postgres | n/a |
| postgres\_layout | ../../modules/postgres-layout | n/a |
| search | ../../modules/aws/search | n/a |
| sessions\_bucket | ../../modules/aws/object-storage | n/a |

### Resources

| Name | Type |
| ---- | ---- |
| [terraform_data.environment_contract](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | Exact target AWS account. The provider refuses any other account. Use the allocated account from Pippen in sandbox mode. | `string` | n/a | yes |
| database\_security\_group\_ids | Database security groups allowing PostgreSQL only from the approved application/proof runner. | `list(string)` | n/a | yes |
| eks\_cluster\_name | Existing EKS cluster for Pod Identity; the foundation root owns the cluster. | `string` | n/a | yes |
| environment | Unique environment slug, e.g. dev, staging, production or team-a. It scopes resource names, tags, the namespace and the verification prefix. | `string` | n/a | yes |
| private\_subnet\_ids | Existing private database subnets in at least two AZs. The foundation stack owns VPC/subnets/routes. | `list(string)` | n/a | yes |
| region | AWS region for this environment. | `string` | n/a | yes |
| search\_master\_user\_arn | Existing environment-specific IAM administrator for OpenSearch role bootstrap. Never a runtime role. | `string` | n/a | yes |
| search\_security\_group\_ids | Search security groups allowing HTTPS only from approved application/proof runner identities. | `list(string)` | n/a | yes |
| search\_subnet\_ids | Existing private OpenSearch subnets, one per AZ. Production requires three. | `list(string)` | n/a | yes |
| activate\_lambda | Reserved activation input. This per-service-database profile currently refuses true until schema/bootstrap/runtime support is qualified by a reviewed implementation change; provision inactive infrastructure meanwhile. | `bool` | `false` | no |
| application\_database\_name | Initial Control database only, on the shared RDS instance. Other services use separate logical databases. Default preserves the existing identity. Changing this value on an existing RDS instance forces instance replacement; review the plan and an explicit data migration/restore before changing it. | `string` | `"relaycontrol"` | no |
| aurora\_engine\_version | Explicit region-supported Aurora PostgreSQL 17 minor version when Aurora is selected. | `string` | `null` | no |
| chief\_execution\_node | Optional dedicated Chief execution host (modules/aws/chief-execution-node). null creates nothing. Private installation values only; no credentials belong here. | ```object({ subnet_id = string relay_base_url = string instance_type = optional(string, "t3.medium") root_volume_size_gb = optional(number, 40) node_runtime = object({ url = string sha256 = string }) relay_node = object({ url = string sha256 = string }) harness = object({ npm_package = string version = string }) bridge = object({ repository = string commit = string }) repositories = list(string) })``` | `null` | no |
| database\_instance\_class | Override the environment tier's instance class. Aurora needs an Aurora-supported class. | `string` | `null` | no |
| deletion\_protection | Database API deletion protection. Production refuses false. Final snapshots and S3 versioning remain enabled. | `bool` | `true` | no |
| desktop\_feed | Optional private Desktop feed for Relay Control (modules/aws/desktop-feed): one Ed25519 KMS signing key and alias per profile ID, a private bucket, and a Pod Identity role for Control's ServiceAccount. null creates nothing. Profile IDs come from the private handoff. | ```object({ profiles = set(string) prefix = optional(string, "desktop-feed") service_account = optional(string) })``` | `null` | no |
| enable\_relayfile | Include Relayfile in the full-suite application contract; its actor identities/Secrets must be configured by the application layer. | `bool` | `false` | no |
| environment\_class | Sizing/protection tier; environment names remain independent of this classification. | `string` | `"development"` | no |
| existing\_runtime\_roles | Operator-owned runtime identities. Null manages search/pipeline roles here. Otherwise supply both search roles and, only in Lambda mode, the pipeline role. Trust, policies, guards and EKS associations must already be verified outside this state. | ```object({ indexer_role_arn = string reader_role_arn = string pipeline_role_arn = optional(string) })``` | `null` | no |
| function\_security\_group\_ids | Lambda security groups with private database/search access and egress to the required AWS services. | `list(string)` | `[]` | no |
| kms\_key\_arn | Existing customer-managed key; null uses AWS-managed encryption keys. | `string` | `null` | no |
| lambda\_package | Compatible pipeline artifact when pipeline\_runtime=lambda: exactly one immutable image, versioned S3 zip, or local zip with hash. No credential values. | ```object({ image_uri = optional(string) s3_bucket = optional(string) s3_key = optional(string) s3_object_version = optional(string) filename = optional(string) source_code_hash = optional(string) })``` | `null` | no |
| lambda\_runtime\_bindings | Non-secret configuration for an independently verified private OpenSearch/Lambda artifact with its pinned public PostgreSQL CA at assets/postgres-ca.pem. Writer and reader must share these bindings. This is not artifact, bootstrap, FGAC or caller-transition proof. | ```object({ search_index = string state_backend_id = string complete_since = string postgres_ca_sha256 = string projection_schema = optional(string, "search_index") })``` | `null` | no |
| name\_prefix | Product prefix. prefix-environment must be at most 21 characters. For Pippen use e.g. pippen-sbx-ar. | `string` | `"agent-relay"` | no |
| namespace | Environment namespace; null uses agent-relay-<environment>. | `string` | `null` | no |
| pipeline\_runtime | workers or lambda. Lambda requires its own compatible immutable handler artifact; application deployment must disable overlapping worker stages. | `string` | `"workers"` | no |
| pippen | Pippen lease identity from sandbox status/exec. null for customer accounts. No credentials belong here. | ```object({ agent = string session_id = string })``` | `null` | no |
| postgres\_engine\_mode | rds or aurora. Aurora requires an explicit full engine version and separate live validation. | `string` | `"rds"` | no |
| release\_name | Helm release name used in generated ServiceAccount names. | `string` | `"agent-relay"` | no |
| search\_engine\_version | Region-supported OpenSearch engine version. | `string` | `"OpenSearch_2.19"` | no |
| search\_instance\_type | Override the environment tier's OpenSearch data node type. | `string` | `null` | no |
| search\_sessions\_bucket\_read | Exact ARNs of this environment's sessions bucket and, for a customer-managed key, its kms\_key\_arn (null for AWS-managed encryption). Any other bucket or key is refused. Grants the search indexer and session-read roles read-only access. null changes nothing. | ```object({ bucket_arn = string kms_key_arn = optional(string) })``` | `null` | no |
| service\_database\_names | Existing or reviewed new database names for HoopDb, Relaycast and optional Relayfile on the same RDS instance. This metadata does not create or rename databases. Control uses application\_database\_name. | `map(string)` | ```{ "hoopdb": "hoopdb", "relaycast": "relaycast", "relayfile": "relayfile" }``` | no |
| tags | Additional resource tags. Environment identity and Pippen conventions cannot be overridden. | `map(string)` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| application\_contract | Required full-suite components and selected pipeline mode. This contract does not replace complete Helm values, actor roles, bootstrap or runtime compatibility proof. |
| chief\_execution\_node | Chief execution host references, or null. Holds no secret value. |
| desktop\_feed | Relay Control private Desktop feed bindings, or null when desktop\_feed is unset. control\_env maps directly to relay-control.extraEnv; it holds no secret. |
| environment | Environment identity to compare with the separately configured backend before apply. |
| lambda\_shared\_environment | Non-secret writer/reader bindings, or null until explicitly configured. Independently qualify the matching reader artifact, read-only DB identity, JWT settings, schema/FGAC bootstrap and worker retirement before activation. |
| pipeline | Lambda runtime bindings, or null in worker mode. Populate the secret out of band and verify actual handler compatibility before activation. |
| postgres\_service\_bindings | Separate service databases and independent migration/runtime roles on the same RDS endpoint. Contains no credentials; reviewed database bootstrap, CONNECT/ACL isolation and runtime proof remain required. Optional-service bindings do not enable workloads. |
| postgres\_topology | Single-instance, separate-service-database target; application\_sql\_ready=false until actual service integration and managed-RDS validation are completed. |
| runtime\_role\_policy\_json | Proposed search and Lambda runtime permissions for operator review. External mode does not attach them or validate existing IAM configuration. Values may be unknown until service resources exist. |
| service\_accounts | Distinct environment-scoped workload bindings; the application chart must use these identities. |
| verification | Non-secret input for the private-runner data-path verifier. Contains secret references, never secret values. |
<!-- END_TF_DOCS -->
