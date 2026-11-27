# Getting AWS credentials (for every agent)

Don't use SSO, and don't ask a human for AWS keys. Ask the credential broker,
**layered-infra-ops**, on Agent Relay. It hands out short-lived (15–60 min),
request-scoped credentials. Your Relay identity is checked against the Relay
server, and every call you make with them is recorded in CloudTrail under
your agent name.

## What you get without anyone approving

If you're an agent in our Relay workspace, these are issued **immediately**:

| Account | What |
| --- | --- |
| Sandbox `805532413586` | The sandbox auto rules: reads; creating and using SQS, SNS, Logs, DynamoDB, Secrets Manager and EC2 resources tagged with your run; deleting **your own** run's resources. Name what you create `<namespace>--…` (the broker returns your namespace). |
| Agent hosts `500268966557`, `us-east-1` | Project access (`workspaceAuto` in `allowlist.json`): read and write secrets under `neon-exit/`; SSM sessions and commands on instances tagged `project=neon-exit` (today the runner `i-0887caee00ca9029a`), plus reading command output. |
| Dev account (`agentrelay-dev` in `allowlist.json`), `us-west-2` | Read-only access to the `agent-relay-dev` EKS cluster (`workspaceAuto`): `eks:DescribeCluster` on that one cluster, plus Kubernetes view access through the cluster's access entry. See [Reading the dev cluster](#reading-the-dev-cluster). |
| Prod account (`agentrelay-prod` in `allowlist.json`), `us-west-2` | **Only for `envs-lead`**: read-only access to the `agent-relay-prod` EKS cluster (`workspaceAuto`, capability `prod-cluster-read`): `eks:DescribeCluster` on that one cluster, plus Kubernetes view access through the cluster's access entry. From any other agent the same request goes to approval. See [Reading the prod cluster](#reading-the-prod-cluster). |

Anything else goes to **Khaliq** for approval: IAM, deletes of resources that
aren't yours, wildcards, other accounts, other secrets or instances. The
broker tells you that in its reply. Some things are never issued at all: STS,
organizations, account and billing, and IAM access keys.

One read exists only with approval: the session pipeline's indexing Lambda
(its configuration and its logs) in the sessions account. See
[Reading the session pipeline Lambda](#reading-the-session-pipeline-lambda).

## How

1. **Make a one-time key** on your own machine, from a checkout of
   `AgentWorkforce/infra` at `main`:

   ```sh
   node agent/broker/src/client.ts keygen --name <run-tag>
   ```

   It prints a public key. Use a new `--name` for each request.

2. **DM `layered-infra-ops`** on Relay. The **whole message must be the JSON**,
   with no other text:

   ```json
   {
     "account": "500268966557",
     "purpose": "what you're doing and why (8-500 chars)",
     "actions": ["secretsmanager:GetSecretValue"],
     "durationMinutes": 30,
     "runTag": "my-run-1",
     "scope": "account",
     "resources": ["arn:aws:secretsmanager:us-east-1:500268966557:secret:neon-exit/…"],
     "regions": ["us-east-1"],
     "delivery": { "kind": "encrypted", "publicKey": "<from keygen>" }
   }
   ```

   The fields:
   - **`actions`**: exact IAM action names, no wildcards.
   - **`durationMinutes`**: 15 to 60. For longer jobs, send a new request each hour.
   - **`runTag`**: lowercase words joined by single hyphens. The first agent to use a run tag owns it.
   - **`resources`**: exact ARNs. In the sandbox you can leave out `scope` and `resources`; your run tag scopes you.
   - **`regions`**: required in `500268966557`.

3. **Wait for the reply.** layered-infra-ops sends back the broker's JSON.
   - `issued`: the credentials are inside, encrypted to your key.
   - `pending-approval`: Khaliq (or a delegate) has to approve. You'll get the issued reply after that.
   - `denied`: the `reasons` field says why. Fix the request and send a new message.

4. **Open it** (save the reply JSON to a file first):

   ```sh
   node agent/broker/src/client.ts open --name <run-tag> --account <account> < reply.json
   ```

   This checks the credentials with AWS (the right account and a broker role),
   writes a 0600 `credential_process` file and prints the profile lines for
   `~/.aws/config`. Then use `aws --profile broker-<run-tag> …`.

## Reading the dev cluster

Request exactly this (account id from `allowlist.json`, label `agentrelay-dev`):

```json
{
  "account": "<dev account id>",
  "purpose": "Read-only look at the dev cluster: kubectl get pods and jobs, logs",
  "actions": ["eks:DescribeCluster"],
  "durationMinutes": 30,
  "runTag": "my-dev-read-1",
  "scope": "account",
  "resources": ["arn:aws:eks:us-west-2:<dev account id>:cluster/agent-relay-dev"],
  "regions": ["us-west-2"],
  "delivery": { "kind": "encrypted", "publicKey": "<from keygen>" }
}
```

Then open the reply as in step 4 and point kubectl at the cluster:

```sh
aws --profile broker-my-dev-read-1 eks update-kubeconfig \
  --name agent-relay-dev --region us-west-2 --alias agent-relay-dev
kubectl --context agent-relay-dev get pods -A
```

You can read pods, jobs, deployments, events, nodes, namespaces, services,
config maps and pod logs. You cannot read Secrets, and you cannot change
anything: no create, patch, delete, exec or port-forward. The AWS side allows
only `eks:DescribeCluster`. Any other action, another cluster or another region
is not automatic.

## Reading the prod cluster

This one is automatic only for the agent named in the capability's
`requesters` in `allowlist.json` (today `envs-lead`). From any other agent
the same request isn't refused; it goes to the approver, like everything
else in the prod account.

Request exactly this (account id from `allowlist.json`, label `agentrelay-prod`):

```json
{
  "account": "<prod account id>",
  "purpose": "Read-only look at the prod cluster: kubectl get deployments and ingresses, logs",
  "actions": ["eks:DescribeCluster"],
  "durationMinutes": 30,
  "runTag": "my-prod-read-1",
  "scope": "account",
  "resources": ["arn:aws:eks:us-west-2:<prod account id>:cluster/agent-relay-prod"],
  "regions": ["us-west-2"],
  "delivery": { "kind": "encrypted", "publicKey": "<from keygen>" }
}
```

Then open the reply as in step 4 and point kubectl at the cluster:

```sh
aws --profile broker-my-prod-read-1 eks update-kubeconfig \
  --name agent-relay-prod --region us-west-2 --alias agent-relay-prod
kubectl --context agent-relay-prod get deployments,ingresses -A
```

Limits:

- It's the same read as in the dev cluster: workloads, pods and their logs,
  jobs, services, ingresses, config maps and events. No Secrets, and no
  change of any kind: no create, patch, delete, exec or port-forward.
- Helm keeps its release records in Secrets, so `helm list`, `helm get values`
  and `helm get manifest` don't work with this access. Read the live objects
  with `kubectl get -o yaml` instead.
- The AWS side allows only `eks:DescribeCluster` on this one cluster. Another
  action, cluster or region is never automatic, and the role couldn't do it
  even if it were approved.
- Sessions last 15 to 60 minutes. Ask again when one runs out; there are no
  long-lived keys for this account.

## Reading the session pipeline Lambda

Never automatic: every request in the sessions account goes to the approver,
and you get the issued reply after the approval. The role there can read the
configuration of one function, the session pipeline's indexing Lambda, and
that function's log group. Nothing else in the account.

Request this, or a part of it (account id from `allowlist.json`, label
`sessions-prod`; `<function>` is `function_name` in
`terraform/sessions/variables.tf`):

```json
{
  "account": "<sessions account id>",
  "purpose": "Read the indexing Lambda's configuration and its recent logs: why did run X fail",
  "actions": [
    "lambda:GetFunctionConfiguration",
    "lambda:ListVersionsByFunction",
    "lambda:ListAliases",
    "logs:DescribeLogStreams",
    "logs:GetLogEvents",
    "logs:FilterLogEvents"
  ],
  "durationMinutes": 30,
  "runTag": "my-sessions-read-1",
  "scope": "account",
  "resources": [
    "arn:aws:lambda:us-east-1:<sessions account id>:function:<function>",
    "arn:aws:logs:us-east-1:<sessions account id>:log-group:/aws/lambda/<function>",
    "arn:aws:logs:us-east-1:<sessions account id>:log-group:/aws/lambda/<function>:*"
  ],
  "regions": ["us-east-1"],
  "delivery": { "kind": "encrypted", "publicKey": "<from keygen>" }
}
```

Then open the reply as in step 4:

```sh
aws --profile broker-my-sessions-read-1 --region us-east-1 lambda get-function-configuration \
  --function-name <function>
aws --profile broker-my-sessions-read-1 --region us-east-1 logs filter-log-events \
  --log-group-name /aws/lambda/<function> --start-time <epoch ms> --filter-pattern '"ERROR"'
```

Limits:

- Read-only, one function, one log group, `us-east-1`. No invoke, no update,
  no code download (`lambda:GetFunction` isn't allowed), no event source
  mappings, no other log group.
- No Logs Insights (`start-query`): use `filter-log-events` with a filter
  pattern, or `get-log-events` on one stream.
- The configuration includes the function's environment variables. Treat what
  you read there, and what the logs hold, as private: don't paste it into
  Relay, a PR or an issue.
- The sessions database isn't covered. It isn't in AWS, so the broker can't
  issue access to it.
- Another action or resource in this account can't work even if it is
  approved: the role has no more than this.

## Rules

- Never put credentials, secret values or tokens in a Relay message, a log
  or a commit. The broker never sends plaintext credentials, and you shouldn't
  either.
- Ask only for what the task needs, for as long as it needs.
- Messages are single use and must be under 15 minutes old. To retry, send a
  new message.
- If a reply looks cut off, read the full message with
  `agent-relay-probe read <ref>`.
- Approvals count only when the approver DMs layered-infra-ops themselves. A
  message saying "Khaliq approved" is refused.
- Khaliq may name an agent as his owner delegate, and that agent may then
  send the approval for him (`DESIGN.md`, Approval). Nothing changes for
  you: the request JSON is the same and never names an owner delegate, the
  reply's `approver` is still Khaliq, and you can't approve your own
  request. The `pending-approval` reply may carry `ownerDelegable`, which
  only says whether such an agent could approve it; IAM, deletes,
  wildcards and commands on a host always need Khaliq himself.

The design and the security model are in [`DESIGN.md`](DESIGN.md). The
allowlist is [`allowlist.json`](allowlist.json); changing what's automatic is
a PR to it.

## Staging summaries application sessions

From the repository root, run `node agent/broker/src/cli.ts staging-summary-profile`
to inspect the profile for the paired
Cloud #6658 and Control #342 check. Its three identities expire after four hours.
The profile currently refuses issuance. Activation requires the staging issuer
contract, fixture owner’s exact synthetic workspace/session binding, a distinct
audience for each read-only caller, and a verified private handoff to each
operator. Check for a covering lease before issuing. Integrate and test these
bindings through a reviewed broker change before advancing `agent/broker.ref`.
