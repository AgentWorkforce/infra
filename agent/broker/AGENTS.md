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

Anything else goes to **Khaliq** for approval: IAM, deletes of resources that
aren't yours, wildcards, other accounts, other secrets or instances. The
broker tells you that in its reply. Some things are never issued at all: STS,
organizations, account and billing, and IAM access keys.

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

The design and the security model are in [`DESIGN.md`](DESIGN.md). The
allowlist is [`allowlist.json`](allowlist.json); changing what's automatic is
a PR to it.
