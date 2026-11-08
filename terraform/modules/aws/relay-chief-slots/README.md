# aws/relay-chief-slots

Dedicated EC2 hosts ("slots") for [Relay Chief](https://github.com/AgentWorkforce/relay-chief), one chief per host. Each slot is an arm64 instance with a separate encrypted data volume for its ledger, reached only through SSM.

**Status: not qualified.** This module has passed static checks and mock-provider tests only. It has never been applied, and no host has booted from its bootstrap. The runtime's own [readiness document](https://github.com/AgentWorkforce/relay-chief/blob/main/docs/readiness.md) lists what must exist before customer use. Applying this module needs the approvals that document requires for IAM, secrets and deployment.

**Do not enable a timer on a customer binding until the execution bridge exists.** The reference service copied into this module always runs with `--dispatch`, so an enabled timer sends real Relay assignments every 30 seconds. That stays true until this module ships a unit that runs without it, whatever the runtime itself gains.

## What it creates

- One instance per id in `slot_ids`: no public IP, IMDSv2 required with a hop limit of 1, encrypted root volume, tagged with the opaque `relay:chief-slot` id.
- One shared security group with no inbound rules and outbound HTTPS only. The empty `ingress` makes the module authoritative: a rule added out of band is removed by the next apply.
- One encrypted gp3 data volume per slot at `/var/lib/relay-chief`, with `prevent_destroy`. It outlives its host, and the bootstrap never formats a volume that has any signature on it.
- One IAM role and instance profile per slot, with `AmazonSSMManagedInstanceCore` plus read of that slot's secret only: `secretsmanager:GetSecretValue` on `<secret_name_prefix>/<slot id>-??????`, and `kms:Decrypt` through Secrets Manager with the encryption context limited to that same secret.

The `slots` output maps slot ids to instances, volumes, roles and secret names. It is for operators and must never reach customers or a customer-facing system. Slot ids must stay opaque: never put a customer or chief name in one.

The module creates no secret, secret value or KMS key.

## Prerequisites

- **AMI** (arm64): `ami_id` or `ami_ssm_parameter`, with systemd, the SSM agent, AWS CLI v2, python3 with sqlite3, and util-linux. Bootstrap stops on a missing tool. No default image is offered.
- **Node.js**: `node_runtime` is the URL and SHA-256 of a Node.js 24+ linux-arm64 tarball.
- **Runtime build**: `relay_chief_artifact` is the URL and SHA-256 of a self-contained tarball with `dist/`, `node_modules/` and `package.json` at its root. Until one exists, leave it null: binding is refused because there is nothing to run. User data is ignored after creation, so setting this later shows no diff; each existing slot then needs `-replace` to install the build.
- **Network**: the subnet needs outbound HTTPS to AWS APIs (NAT or VPC endpoints), the download hosts, Relay, classification (`api.typesafe.ai`) and the control plane.
- **KMS key policy**: must let the applying principal attach encrypted volumes, and must delegate to IAM or name the slot roles. Secrets must be encrypted with this key.
- **Secret**: before binding, create `<secret_name_prefix>/<slot id>` as a JSON object:

  | Key | Required |
  | --- | --- |
  | `RELAY_AGENT_TOKEN` | Yes |
  | `TYPESAFE_API_KEY` | Yes |
  | `CHIEF_CONTROL_PLANE_URL` | Yes |
  | `CHIEF_CONTROL_PLANE_TOKEN` | Yes |
  | `RELAY_BASE_URL` | No. The runtime defaults to the hosted Relay |

  Any other key is refused, so a secret cannot inject variables such as `NODE_OPTIONS` into the service.

```hcl
module "relay_chief_slots" {
  source      = "github.com/AgentWorkforce/infra//terraform/modules/aws/relay-chief-slots?ref=<tag>"
  slot_ids    = ["slot-0a1b2c3d", "slot-4e5f6a7b"]
  vpc_id      = "<vpc id>"
  subnet_id   = "<private subnet id>"
  kms_key_arn = "<key arn>"
  ami_id      = "<arm64 ami id>"
  node_runtime = {
    url    = "<node 24+ linux-arm64 tarball url>"
    sha256 = "<sha256>"
  }
}
```

## Host layout

Bootstrap installs Node.js at `/usr/bin/node`, the `relay-chief` system user, `/opt/relay-chief`, the reference units and the scripts, then leaves `relay-chief.timer` disabled.

`files/relay-chief.service` and `files/relay-chief.timer` are unmodified copies of the units in relay-chief `deploy/` at commit `865f13949da25eadfdae4160a8a4ef6e293d6376`. Slot behavior is added with a drop-in, `relay-chief.service.d/10-slot.conf`, which requires the credentials unit and the mounted data volume. If the volume is missing, the cycle does not start, rather than creating an empty ledger on the root disk.

`/run/relay-chief/credentials.env` is on tmpfs, so `relay-chief-credentials.service` is enabled to re-fetch it at every boot, before the service starts. It writes the file with mode 0600 and fails closed: it removes the old file first and leaves none on any error. Until a slot's secret exists the unit shows as failed, which is expected.

### Rotating a secret

Never restart the credentials unit while a cycle may be running. The service `Requires=` it, so the restart stops an active cycle, and a cycle killed during a send leaves that task `uncertain`. Stop the timer and wait for the cycle first, as the bind script does:

```sh
systemctl stop relay-chief.timer
# Repeat until this prints inactive or failed; a cycle can take up to two minutes.
systemctl show -p ActiveState --value relay-chief.service
systemctl restart relay-chief-credentials.service
systemctl start relay-chief.timer
```

## Binding a slot

Run `relay-chief-bind-slot` as root through SSM. The configuration holds identifiers only, so it can be passed inline; never pass credentials on a command line.

```sh
printf %s '<base64 chief config>' | base64 -d \
  | relay-chief-bind-slot --slot-id slot-0a1b2c3d --config -
```

The script validates the configuration with the runtime's own schema, records the binding on the data volume, writes `/etc/relay-chief/config.json`, fetches credentials, and leaves the timer off. To enable the timer, pass both `--enable-timer` and `--dispatch-opt-in`; either alone is refused. Read the warning at the top of this page first.

A slot is single-use. Binding is refused if the host is not that slot, or if the data volume has a ledger or binding record for a different chief. A refusal changes nothing, so a running chief is not disturbed. Rebinding the same chief is allowed. Reusing a slot for another chief requires deliberately wiping its volume.

| Exit code | Meaning |
| --- | --- |
| 0 | Bound |
| 1 | Failure, such as the volume not mounted, no runtime build, or credentials unavailable |
| 2 | Malformed slot id or configuration |
| 3 | Slot already bound, or not this host's slot |
| 4 | Dispatch opt-in missing |

## Replacing a host

Replacement is always deliberate: `ami` and user data are ignored after creation, so use `terraform apply -replace='module.<name>.aws_instance.slot["<slot id>"]'`. The new host reattaches the same volume but has no `/etc/relay-chief/config.json` and a disabled timer. It stays stopped until an operator re-runs the bind command with the same configuration. Back up the data volumes before customer use; this module does not set up backups.

`prevent_destroy` means removing an id from `slot_ids` fails until the volume is deliberately handled.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.6 |
| aws | >= 6.0, < 7.0 |

### Providers

| Name | Version |
| ---- | ------- |
| aws | >= 6.0, < 7.0 |

### Resources

| Name | Type |
| ---- | ---- |
| [aws_ebs_volume.data](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ebs_volume) | resource |
| [aws_iam_instance_profile.slot](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_role.slot](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.slot_secret](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.ssm](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_instance.slot](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance) | resource |
| [aws_security_group.slots](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_volume_attachment.data](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/volume_attachment) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_ssm_parameter.ami](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |
| [aws_subnet.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| kms\_key\_arn | Customer managed KMS key that encrypts the EBS volumes and the slot secrets. Its key policy must allow the operator to attach encrypted volumes and must delegate to IAM (or name the slot roles). | `string` | n/a | yes |
| node\_runtime | Node.js 24+ linux-arm64 tarball and its SHA-256. Installed at /usr/bin/node. Bootstrap fails if the checksum, architecture or major version is wrong. | ```object({ url = string sha256 = string })``` | n/a | yes |
| slot\_ids | Opaque slot identifiers, one host per id: slot- plus 8 to 32 lowercase letters or digits. Never embed a customer or chief name; the id appears in tags and ARNs. | `set(string)` | n/a | yes |
| subnet\_id | Private subnet for every slot host. It must have outbound HTTPS (NAT or VPC endpoints); hosts get no public IP. | `string` | n/a | yes |
| vpc\_id | VPC of the slot security group. | `string` | n/a | yes |
| ami\_id | arm64 AMI id. Set exactly one of ami\_id and ami\_ssm\_parameter. The AMI must provide systemd, the SSM agent, AWS CLI v2, python3 with sqlite3 and util-linux. | `string` | `null` | no |
| ami\_ssm\_parameter | SSM parameter name holding an arm64 AMI id, instead of ami\_id. No default: choose the image deliberately. | `string` | `null` | no |
| data\_volume\_size\_gb | Data volume size. It holds the chief ledger at /var/lib/relay-chief. | `number` | `20` | no |
| egress\_cidr\_blocks | Destinations allowed for outbound HTTPS. The only other traffic is to VPC-provided DNS and time services, which security groups do not filter. | `list(string)` | ```[ "0.0.0.0/0" ]``` | no |
| iam\_path | Path of the slot IAM roles and instance profiles. | `string` | `"/"` | no |
| instance\_type | arm64 instance type, one of those the relay-chief provisioning contract admits. | `string` | `"t4g.small"` | no |
| name\_prefix | Prefix of IAM and security group names. | `string` | `"relay-chief"` | no |
| permissions\_boundary\_arn | Optional permissions boundary for the slot roles. | `string` | `null` | no |
| relay\_chief\_artifact | Self-contained relay-chief release tarball (dist/, node\_modules/, package.json at the root) and its SHA-256, extracted to /opt/relay-chief. null leaves /opt/relay-chief empty, and binding a slot is refused until a build is installed. User data is ignored after creation, so setting this later shows no diff: each existing slot needs -replace. | ```object({ url = string sha256 = string })``` | `null` | no |
| root\_volume\_size\_gb | Root volume size. | `number` | `20` | no |
| secret\_name\_prefix | Secrets Manager path of the slot secrets. Each slot reads only <prefix>/<slot id>. This module never creates the secrets or their values. | `string` | `"relay-chief/slots"` | no |
| tags | Tags applied to every resource. A relay:chief-slot key here is ignored; the module sets it per slot. | `map(string)` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| security\_group\_id | Security group shared by the slot hosts. |
| slots | Slot id to infrastructure mapping for operators, keyed by slot id. Internal: never expose it to customers or customer-facing systems. |
<!-- END_TF_DOCS -->
