# prod

Read-only access for one named agent to one EKS cluster (`agent-relay-prod`,
us-west-2) in the prod account. The role is vended by the broker
(`../../allowlist.json`, capability `prod-cluster-read`, whose `requesters`
names the agent). Nothing here can write, in AWS or in Kubernetes.

| Resource | What |
| --- | --- |
| `aws_iam_role.read` (`agent-broker-prod-read`) | Assumable only by the broker role (exact ARN), with the same request-tag and source-identity conditions as the other broker target roles. 1 h max session. |
| `aws_iam_role_policy.read` | One Allow: `eks:DescribeCluster` on the one cluster ARN. That is what `aws eks update-kubeconfig` needs. `aws eks get-token` needs no IAM permission. |
| `aws_eks_access_entry.read` | The role as a STANDARD access entry, with no Kubernetes groups. |
| `aws_eks_access_policy_association.view` | `AmazonEKSViewPolicy` at cluster scope: read most namespaced and cluster resources, not Secrets, no writes, no exec or port-forward. |

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
   role's ARN before this step.
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
(`tests/prod.tftest.hcl` checks the name and the allowlist pairing). The plan
is four resources to add and nothing to change or destroy.

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

- The role's identity policy only allows `eks:DescribeCluster`. A request in
  this account for anything else is not automatic, and even if the approver
  says yes it is issued and then gets AccessDenied. Widen this root first.
- The `requesters` limit is on automatic issue. The approver can still
  approve another agent's request for this role; it gets the same read-only
  access and nothing more.
- `requesters` matches the verified Relay agent name of a member of the
  workspace named in `workspaceAuto`. It is not pinned to a Relay agent id.
- `AmazonEKSViewPolicy` is an AWS-managed Kubernetes policy; its contents are
  AWS's and are not pinned here.
