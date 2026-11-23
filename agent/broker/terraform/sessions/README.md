# sessions

Read-only access to one Lambda function, the session pipeline's indexing
Lambda, and its one log group, in the sessions account (us-east-1). The role
is vended by the broker (`../../allowlist.json`, account label
`sessions-prod`), on the approver's approval of each request. Nothing here
can write, invoke the function or download its code.

| Resource | What |
| --- | --- |
| `aws_iam_role.read` (`agent-broker-sessions-read`) | Assumable only by the broker role (exact ARN), with the same request-tag and source-identity conditions as the other broker target roles. 1 h max session. |
| `aws_iam_role_policy.read` | Two Allows. Lambda: `GetFunctionConfiguration`, `ListVersionsByFunction` and `ListAliases` on the one function (and its versions and aliases). CloudWatch Logs: `DescribeLogStreams`, `GetLogEvents` and `FilterLogEvents` on the function's one log group (and its streams). |

The function and the log group are read, never created or changed.

## Who applies it

The owner, by hand, with their own credentials in the sessions account, plan
first. Never CI, never from a branch, never the broker role and never an
agent: the infra agent's roles have no access to that account. If the owner's
profile is in another account, set `assume_role_arn` to a role in the
sessions account that it can assume.

## Who gets it

Nobody without approval. The account's tier is `prod` and no `workspaceAuto`
capability and no delegated approver names it, so every request is
`pending-approval` and waits for the approver's `approve <id> <digest>`. The
approval prompt shows the session policy, which the broker narrows to the
actions and resources the request names.

A no-approval path would need new grant kinds in `src/policy.ts` (there is
none for Lambda functions or log groups); that is a separate change.

## What the access does not cover

- `lambda:GetFunction`: it returns a download link for the function's code.
- Invoking, updating or deleting the function, or changing its configuration.
- `lambda:ListEventSourceMappings`: it has no resource-level permission, so
  it can't be limited to this function.
- CloudWatch Logs Insights (`StartQuery`, `GetQueryResults`, `StopQuery`):
  two of the three take no resource, so they can't be limited to this log
  group. Use `filter-log-events` with a filter pattern instead.
- Any other log group, and listing log groups.
- The transcript bucket, the queue, Secrets Manager and every other service
  in the account.
- The sessions database. That is not in AWS; the broker can't issue access
  to it.

## Precondition

The function and its log group must exist in the account and region. The
plan stops otherwise (a postcondition on `data.aws_lambda_functions.all`, and
`data.aws_cloudwatch_log_group.this`), so a typo can't produce a role that
reads nothing. The root lists function names only; it never reads the
function itself, so no environment variable value enters this root's state.

## Order

1. Merge the change that adds the account to `allowlist.json`. The broker
   host still runs the old `agent/broker.ref`, so nothing is issued yet.
2. The owner applies this root (below). The role then exists.
3. `../sandbox` is applied from `main`, plan first, on the owner's approval:
   the broker role's `vend-agent-sessions` policy must list the new role in
   its `sts:AssumeRole` targets (an in-place update). That root reads the
   role's ARN from the allowlist.
4. Move `agent/broker.ref` to the merge commit in a second PR, so the host
   picks up the allowlist.

Steps 2 and 3 can run in either order. Moving `broker.ref` before both are
done is safe but useless: an approved request would be issued and then fail
at `AssumeRole`.

## Apply

```bash
cd agent/broker/terraform/sessions
cp backend.hcl.example backend.hcl                # state bucket
cp terraform.tfvars.example terraform.tfvars      # sessions account id, broker role ARN
terraform init -backend-config=backend.hcl
terraform plan -out=sessions.tfplan
terraform apply sessions.tfplan
```

`sessions_account_id` is the allowlist account with the label
`sessions-prod`. `broker_role_arn` is the `../sandbox` output
`broker_role_arn`. `role_arn` from this root must equal `allowlist.json`
accounts.`<sessions account>`.roles.elevated (`tests/sessions.tftest.hcl`
checks the name and the allowlist pairing). The plan is two resources to add
and nothing to change or destroy.

## Remove

`terraform destroy` in this root removes the role and its policy. Sessions
already issued stop working at once, whatever their expiry says. Then take
the account out of `allowlist.json` and re-apply `../sandbox`.

## Tests

Plan-only, mocked providers, no credentials:

```bash
terraform init -backend=false -input=false && terraform validate && terraform test
```

## Limits

- `GetFunctionConfiguration` returns the function's environment variable
  values. In the pipeline's source these are flags and settings, a bucket
  name, a queue URL and the ARN of a secret, not secret values. Anything put in the
  function's environment later becomes readable with this role, so keep
  secret values out of it.
- The log group holds whatever the function logs. Reading it is reading
  that.
- The role's identity policy only allows the six actions above. A request in
  this account for anything else can still be approved, but it is issued and
  then gets AccessDenied. Widen this root first.
- A request must name its resources (`scope: "account"` with `resources`),
  or the broker asks for the function and log group ARNs to be listed. The
  two ARNs are this root's `function_arn` and `log_group_arn` outputs; log
  reads also need the log group ARN followed by `:*` (its streams).
