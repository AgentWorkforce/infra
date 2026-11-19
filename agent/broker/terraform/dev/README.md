# dev

Read-only access for workspace agents to one EKS cluster (`agent-relay-dev`,
us-west-2) in the dev account. The role is vended by the broker
(`../../allowlist.json`, capability `dev-cluster-read`). Nothing here can
write, in AWS or in Kubernetes.

| Resource | What |
| --- | --- |
| `aws_iam_role.read` (`agent-broker-dev-read`) | Assumable only by the broker role (exact ARN), with the same request-tag and source-identity conditions as the other broker target roles. 1 h max session. |
| `aws_iam_role_policy.read` | One Allow: `eks:DescribeCluster` on the one cluster ARN. That is what `aws eks update-kubeconfig` needs. `aws eks get-token` needs no IAM permission. |
| `aws_eks_access_entry.read` | The role as a STANDARD access entry, with no Kubernetes groups. |
| `aws_eks_access_policy_association.view` | `AmazonEKSViewPolicy` at cluster scope: read most namespaced and cluster resources, not Secrets, no writes, no exec or port-forward. |

## Who applies it

The owner of the dev account, by hand, with their own credentials. Never CI,
never an agent, never the broker host. `layered-infra-ops` does not apply this
root.

## Precondition

The cluster's authentication mode must be `API` or `API_AND_CONFIG_MAP`.
The root reads the cluster and refuses to plan otherwise (a postcondition on
`data.aws_eks_cluster.this`). To change it, as the owner and outside this
repo: `aws eks update-cluster-config --name agent-relay-dev --access-config authenticationMode=API_AND_CONFIG_MAP`.
That change is one-way: a cluster cannot go back to `CONFIG_MAP`.

## Order

1. The dev account's owner applies this root (below). The role then exists.
2. `layered-infra-ops` applies `../sandbox` from `main`-equivalent code: the
   broker role's `vend-agent-sessions` policy gains the new role in its
   `sts:AssumeRole` targets (an in-place update).
3. Merge the PR that adds the account to `allowlist.json`, then move
   `agent/broker.ref` so the host picks it up.

Merging the allowlist first is safe but useless: requests would be issued
and then fail at `AssumeRole` until steps 1 and 2 are done.

## Apply

```bash
cd agent/broker/terraform/dev
cp backend.hcl.example backend.hcl                # the owner's state bucket and profile
cp terraform.tfvars.example terraform.tfvars      # dev account id, broker role ARN
terraform init -backend-config=backend.hcl
terraform plan -out=dev.tfplan
terraform apply dev.tfplan
```

`broker_role_arn` is the `../sandbox` output `broker_role_arn`. `role_arn`
from this root must equal `allowlist.json` accounts.`<dev account>`.roles.elevated
(`tests/dev.tftest.hcl` checks the name and the allowlist pairing).

## Tests

Plan-only, mocked providers, no credentials:

```bash
terraform init -backend=false -input=false && terraform validate && terraform test
```

## Limits

- The role's identity policy only allows `eks:DescribeCluster`. A request in
  this account for anything else is not automatic, and even if the approver
  says yes it is issued and then gets AccessDenied. Widen this root first.
- `AmazonEKSViewPolicy` is an AWS-managed Kubernetes policy; its contents are
  AWS's and are not pinned here.
