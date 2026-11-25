# prod

Read-only access for one named agent to one EKS cluster (`agent-relay-prod`,
us-west-2) in the prod account. The role is vended by the broker
(`../../allowlist.json`, capability `prod-cluster-read`, whose `requesters`
names the agent). Nothing in that role can write, in AWS or in Kubernetes.

It also holds a second role, `agent-broker-prod-edge-dns`, for the
`agentrelay-edge-dns` Terraform root's prod state and reads (see
[The edge-dns role](#the-edge-dns-role)).

| Resource | What |
| --- | --- |
| `aws_iam_role.read` (`agent-broker-prod-read`) | Assumable only by the broker role (exact ARN), with the same request-tag and source-identity conditions as the other broker target roles. 1 h max session. |
| `aws_iam_role_policy.read` | One Allow: `eks:DescribeCluster` on the one cluster ARN. That is what `aws eks update-kubeconfig` needs. `aws eks get-token` needs no IAM permission. |
| `aws_eks_access_entry.read` | The role as a STANDARD access entry, with no Kubernetes groups. |
| `aws_eks_access_policy_association.view` | `AmazonEKSViewPolicy` at cluster scope: read most namespaced and cluster resources, not Secrets, no writes, no exec or port-forward. |
| `aws_iam_role.edge_dns` (`agent-broker-prod-edge-dns`) | The `agentrelay-edge-dns` Terraform root's prod role (allowlist `roles.edgeDns`). Same trust as the read role, 1 h max session, no EKS access entry. Issued only on the owner's approval, for requests that name `"profile": "edge-dns"`. |
| `aws_iam_role_policy.edge_dns` | Exactly: `s3:GetObject`/`s3:PutObject` on the edge-dns state and its `.tflock`; `s3:DeleteObject` on the `.tflock` only; `s3:ListBucket` on the state bucket with `s3:prefix` = `env:/` only; `kms:Decrypt`/`kms:GenerateDataKey` on the state key via `s3.us-west-2.amazonaws.com`; `elasticloadbalancing:DescribeLoadBalancers`/`DescribeTags`/`DescribeLoadBalancerAttributes` on `*` (no resource-level permissions); `acm:DescribeCertificate`/`acm:ListTagsForCertificate` on the one certificate. No EKS, IAM, Route 53 (DNS is Cloudflare) or other S3. |

## The edge-dns role

For plans and applies of enterprise-onboarding's
`environments/agentrelay-edge-dns` in prod (`prod.backend.hcl`). The broker
uses it instead of `roles.elevated` only when the request names
`"profile": "edge-dns"` and is entirely inside the profile
(`broker/src/policy.ts` `EDGE_DNS_PROFILE`): this account, regions exactly
`us-west-2`, scope `account`, only the actions and resources above. Anything
else that names the profile is refused, never sent to the elevated role.
It is always approval; workspace auto-issue never applies to it. Request
JSON: `../../AGENTS.md` (Prod edge-dns).

What the S3 backend lists, checked in `hashicorp/terraform`
`internal/backend/remote-state/s3/backend_state.go` (v1.7.0 to v1.16.7):
the only `ListObjectsV2` is `Workspaces()`, with `Prefix` =
`<workspace_key_prefix>/`, i.e. `env:/` (the root sets no
`workspace_key_prefix`). It runs on every `StateMgr`, so on init, plan and
apply. It never lists with the state key. The state is read with
`HeadObject` and `GetObject` (`s3:GetObject`), written with `PutObject`, and
the lockfile (`use_lockfile = true`) is `<key>.tflock`: `PutObject`
(`If-None-Match`), `GetObject`, and `DeleteObject` on unlock. Terraform
>= 1.8 treats `AccessDenied` on the `env:/` listing as "default workspace
only"; 1.7 (which the root allows) does not, hence the one prefix.

`data.aws_lb` reads the load balancer's attributes as well as finding it by
tags (`terraform-provider-aws` `internal/service/elbv2/load_balancer_data_source.go`
calls `DescribeLoadBalancerAttributes`), so the role allows that third
Describe action too.

Prerequisites owned elsewhere:

- **The state key's key policy** (`717fa644-…`, made by the EO state
  bootstrap, not here). The role's IAM grant works only if the key policy
  lets IAM policies grant access (the default key policy's
  `"Principal": {"AWS": "arn:aws:iam::<account>:root"}, "Action": "kms:*"`
  statement). The staging bootstrap (`bootstrap-state.sh`) creates its key
  with the default policy; if the prod key's policy differs, it needs a
  statement for `agent-broker-prod-edge-dns` (`kms:Decrypt`,
  `kms:GenerateDataKey`). Not changed here.
- **The state bucket's policy**, if it has one, must not deny this role.
- The certificate id is the one the root manages today
  (`certificates.public`). If the root requests another certificate, this
  role can't read it until `edge_dns_certificate_id` and the broker profile
  are updated together (both tests check they agree). Requesting or deleting
  certificates (`acm:RequestCertificate`, `acm:DeleteCertificate`,
  `acm:AddTagsToCertificate`) is not granted.

## Who applies it

`layered-infra-ops`, with its own role in the prod account, plan first, and
only on the owner's approval of that plan. Never CI, never from a branch,
never the broker role and never another agent. The owner can also apply it by
hand with their own credentials.

## Who gets it

Only the agent named in the capability's `requesters` is issued this role
without approval, and only for `eks:DescribeCluster` on this cluster. Any
other workspace agent's request for the same thing is not matched against
the capability: it goes to the approver like every other request in this
account. No delegated approver has a capability here.

## What the access does not cover

`AmazonEKSViewPolicy` maps to the Kubernetes `view` role. It cannot:

- read Secrets. Helm keeps release records in Secrets, so `helm list`,
  `helm get values`, `helm get manifest` and `helm history` do not work.
  Read the rendered objects with `kubectl get` instead;
- create, change or delete anything;
- `kubectl exec`, `attach`, `cp` or `port-forward`;
- read Roles or RoleBindings.

It can read workloads, pods and their logs, Services, Ingresses, ConfigMaps,
Jobs and events in every namespace.

## Precondition

The cluster's authentication mode must be `API` or `API_AND_CONFIG_MAP`.
The root reads the cluster and refuses to plan otherwise (a postcondition on
`data.aws_eks_cluster.this`). The prod cluster is already in `API` mode, so
this root does not need the mode changed.

## Order

1. Merge the change that adds the account to `allowlist.json`. The broker
   host still runs the old `agent/broker.ref`, so nothing is issued yet.
2. On the owner's approval, `layered-infra-ops` applies this root (below).
   The role and its access entry then exist.
3. `layered-infra-ops` applies `../sandbox` from `main`, plan first: the
   broker role's `vend-agent-sessions` policy must list the new role in its
   `sts:AssumeRole` targets (an in-place update). That root has to carry the
   role's ARN before this step. It reads both prod roles (`roles.elevated`
   and `roles.edgeDns`) from `allowlist.json`, so adding the edge-dns role
   there is what adds it to the broker's targets.
4. Move `agent/broker.ref` to the merge commit in a second PR, so the host
   picks up the allowlist.

Steps 2 and 3 can run in either order. Moving `broker.ref` before both are
done is safe but useless: requests would be issued and then fail at
`AssumeRole`.

## Apply

```bash
cd agent/broker/terraform/prod
cp backend.hcl.example backend.hcl                # state bucket and profile
cp terraform.tfvars.example terraform.tfvars      # prod account id, broker role ARN
terraform init -backend-config=backend.hcl
terraform plan -out=prod.tfplan
terraform apply prod.tfplan
```

`broker_role_arn` is the `../sandbox` output `broker_role_arn`. `role_arn`
from this root must equal `allowlist.json` accounts.`<prod account>`.roles.elevated
(`tests/prod.tftest.hcl` checks the name and the allowlist pairing), and
`edge_dns_role_arn` must equal its `roles.edgeDns`. On a fresh account the
plan is six resources to add; where the read role already exists, adding the
edge-dns role is two to add (`aws_iam_role.edge_dns`,
`aws_iam_role_policy.edge_dns`) and nothing to change or destroy.

## Remove

`terraform destroy` in this root removes the access entry, its policy
association and the role. Sessions already issued lose their Kubernetes
access at once, whatever their expiry says.

## Tests

Plan-only, mocked providers, no credentials:

```bash
terraform init -backend=false -input=false && terraform validate && terraform test
```

## Limits

- The read role's identity policy only allows `eks:DescribeCluster`. A
  request in this account for anything else (without the edge-dns profile)
  is not automatic, and even if the approver says yes it is issued and then
  gets AccessDenied. Widen this root first, or add a profile and role like
  edge-dns.
- The broker's session policy for an edge-dns request groups the S3 actions
  on all the named S3 resources (as for every account-wide approval); the
  role's own policy is what keeps `s3:DeleteObject` off the state and
  `s3:ListBucket` to `env:/`.
- The `requesters` limit is on automatic issue. The approver can still
  approve another agent's request for this role; it gets the same read-only
  access and nothing more.
- `requesters` matches the verified Relay agent name of a member of the
  workspace named in `workspaceAuto`. It is not pinned to a Relay agent id.
- `AmazonEKSViewPolicy` is an AWS-managed Kubernetes policy; its contents are
  AWS's and are not pinned here.
