# AWS credential broker (layered-infra-ops)

Status: draft for Khaliq's review. Nothing here is applied or deployed: no
role exists yet, `agent/lead-prompt.md` doesn't mention the broker, and these
files aren't in the host's `laneFiles`.

## Why

Agents on linuyc reach AWS through interactive SSO, which needs a human at a
browser and gives each agent the human's whole SSO role. The broker replaces
that with credentials that last 15 to 60 minutes, are scoped to one request
and name the agent that asked:

- **One long-lived identity.** Only the broker (layered-infra-ops) holds
  a standing role, `agent-cred-broker`. Agents hold nothing between requests.
- **Scoped to the request.** Every session gets an inline session policy
  built from the request. STS intersects it with the target role's own
  policy, so the session can do no more than either allows.
- **Traceable.** RoleSessionName and SourceIdentity are both the agent's
  name. Session tags carry `broker-request-id`, `agent-run` (the run tag) and
  `agent`. Every CloudTrail event names the agent and the request, and the
  broker's audit log maps the request to the Relay message it came from.

## Flow

```
agent ──Relay DM──▶ layered-infra-ops (broker)
   {account, purpose, actions, durationMinutes, runTag, scope?, resources?, regions?, delivery}
                      │ requester = the Relay envelope's sender (never the body)
                      ▼
                policy engine (broker/src/policy.ts, allowlist.json)
          deny ◀──────┼──────▶ auto (sandbox, own run tag)
                      │                    │
                      ▼                    ▼
        pending: DM khaliq-gant      host role ─▶ agent-cred-broker ─▶ target role
        "approve <id> <digest>"      (AssumeRole, session policy, tags, SourceIdentity)
                      │                    │
     Khaliq (human) ──┘                    ▼
                               out-of-band delivery (file 0600 | 1Password item)
                                           │
agent ◀──Relay reply: request id, pointer, expiry, access key id (no secret)
```

## Tiers

| Tier | When | Result |
| --- | --- | --- |
| Never | `sts:*`, `organizations:*`, `account:*`, billing, `iam:CreateAccessKey` / login profiles, `*`, or any wildcard that overlaps them; an account not on the allowlist; a bad shape (duration outside 15 to 60 min, run tag, region) | Refused, audited, STS never called |
| Auto | Sandbox account `805532413586`, every action literal and on an `autoRules` entry, scope `run-tag`, the run tag unclaimed or claimed by this agent | Issued on `agent-broker-sandbox-scoped` |
| Approval | A prod account, `iam:*` / identity / audit actions, wildcards, `scope: account` with any non-read action (changes outside the run's tag), off-list actions, another agent's run tag | Parked. Khaliq is DMed the full request and a digest |

Auto rules (allowlist `autoRules`) have three scopes:

- `any`: reads (Describe/List/GetMetricData), plus the inputs RunInstances needs (image, subnet, security group, key pair);
- `request-tag`: creates must carry `agent-run=<runTag>` (`aws:RequestTag`);
- `resource-tag`: use, stop and delete only on resources tagged `agent-run=<runTag>` (`aws:ResourceTag`).

So a delete is automatic only on the run's own resources. Every session
policy also denies creating anything with another run's tag, adding or
removing the `agent-run` tag on an existing resource, and EC2 tagging except
at create time.

A run tag is claimed by the first agent that receives credentials for it
(`run-tags.json`). A different agent asking for that tag needs approval.

### Approval

- Only principals in `humanApprovers` (`khaliq-gant`) whose Relay envelope
  says `kind: human` count. An agent's approval never counts, even under the
  same name. A requester can't approve its own request.
- The approval names the request id and at least 12 hex characters of a
  digest over the request, the requester, the role, the session policy and the
  duration. Khaliq approves exactly what he was shown.
- An approval is single use and expires after `approvalWindowMinutes` (30).
  When it arrives, the broker decides the request again against the current
  allowlist. If the policy changed, the approval is void.
- Approval-tier sessions use the account's `roles.elevated`. None exists yet,
  so approval-tier requests are refused up front rather than parked, and
  Khaliq isn't asked about something the broker can't issue.

## Delivery: never in a Relay message

- `file`: a `credential_process` JSON file, mode 0600, under
  `~/.aws-broker/creds/<agent>/<request-id>.json` on the broker's node, for
  its own workers. Use it with `credential_process = cat <path>`.
- `1password`: an API Credential item in a vault the requester can read. The
  item template goes to `op item create` on stdin, never on argv. This is the
  cross-node path, for linuyc agents.

`sweep` removes deliveries whose credentials have expired. The Relay reply
holds only the pointer, the expiry, the access key id (not a secret; it's how
CloudTrail is searched) and the digest.

## Audit log

`<state>/audit.jsonl` holds one JSON line per event: requested, denied,
pending-approval, approval-rejected, approved, refused, issued,
delivery-removed, error. It records the requester and approver envelopes,
the Relay message id, the account, role, session name, actions, digest,
access key id and expiry. Lines are hash-chained (`prev`, `hash`) and
checked with `cli.ts verify-audit`. The writer refuses any line that contains
the issued secret or token, or looks like an STS secret.

## AWS side (Terraform, `broker/terraform`)

- `modules/broker-role`: `agent-cred-broker` in the host's account. Its trust
  is the account root with `ArnEquals aws:PrincipalArn = <infra-ops host role>`,
  and nothing else. Its only permissions are `sts:AssumeRole`,
  `sts:TagSession` and `sts:SetSourceIdentity` on the exact target role
  ARNs. Sessions last at most 1 h.
- `modules/scoped-role`: `agent-broker-sandbox-scoped` in 805532413586. It
  trusts only the broker role, and only when the broker sets a `cb-*`
  request id, the run and agent tags (and no other tag keys) and a source
  identity. Its ceiling is PowerUserAccess plus denies: IAM, STS,
  organizations, account, SSO, identity store, CloudTrail, Config,
  GuardDuty, Security Hub, RAM and KMS key deletion or policy; any session
  without the run tag; creating with another run's tag; moving the run tag;
  EC2 tags after create; stop or delete outside
  `${aws:PrincipalTag/agent-run}`; regions outside the allowed list. These
  denies hold even if the policy engine has a bug.
- `sandbox/`: the root that wires the two together across both accounts. It
  has no backend and is applied by a human only.

Credential chain: host instance role → `agent-cred-broker` → scoped role. Role
chaining caps each hop at 1 h, which matches the 60-minute maximum.

## Running it (after review)

```bash
# the broker host, as the agent user, once the roles exist:
# ~/.aws/config: [profile aws-cred-broker] role_arn=<broker role>, credential_source=Ec2InstanceMetadata
node broker/src/cli.ts request --from-name <sender> --from-address <sender address> --from-kind agent --message-id <id> < request.json
node broker/src/cli.ts approve --request-id cb-… --digest <hex> --from-name khaliq-gant --from-address <addr> --from-kind human
node broker/src/cli.ts sweep          # on a timer
node broker/src/cli.ts verify-audit
```

## Phase 2 (design only): signing proxy

For high-risk calls (prod, IAM), hand out no credentials at all. The broker
runs a SigV4 signing proxy on its host. An approved request becomes a
proxy grant, an opaque handle bound to the request id, a method/host/path
allowlist and an expiry. The agent sends the unsigned API call to the proxy
with the handle. The proxy checks the grant, signs with a session it holds
(the same AssumeRole, tags and SourceIdentity), forwards the call and logs
the request and the response status. The secret never leaves the broker
host, a grant can be revoked mid-session, and the audit log has every call,
not just the issue. Cost: one proxy per broker, and AWS CLI/SDK clients
configured with `--endpoint-url` or an HTTPS proxy plus a CA. Worth it for
the approval tier only.

## Open questions for Khaliq

1. **Requester identity.** The broker trusts the Relay envelope's sender.
   Today the lead (an LLM) passes `--from-*` from the message header, so a
   prompt-injected lead could pass a wrong name. Should the broker run as a
   deterministic Relay listener, or check the message id against the relay
   API, before this goes live?
2. **The broker account and host role ARN.** Which account does
   layered-infra-ops run in? The host boundary in layered-agents allows
   `sts:AssumeRole` only on the admin role today. It needs a statement for
   `agent-cred-broker`, which is an IAM change in layered-agents.
   Alternative: trust the admin role and chain from it.
3. **Prod accounts and the elevated roles.** Which account ids, and should
   each get an `agent-broker-elevated` role (what ceiling)? Until then, the
   approval tier refuses.
4. **1Password.** A service account token for the broker host (a secret
   parameter, out of band) and a vault per requester or a shared agents vault.
   Confirm that `op item create -` with a stdin template works on the CLI
   version installed on the host.
5. **Auto allowlist.** Is the curated set (EC2 instances and volumes, SQS,
   SNS, Logs, DynamoDB, Secrets Manager) right? S3 is approval-only for now
   because bucket ABAC support for `aws:ResourceTag` is uneven.
6. **Audit shipping.** Is a local hash-chained file enough, or should it also
   go to CloudWatch Logs or S3 with Object Lock?
7. **Deploying the code.** It isn't in `laneFiles`. Should it ship by the
   kit's hot update (a laneFiles change), or should setup-lane.sh run it from
   the repo checkout?
