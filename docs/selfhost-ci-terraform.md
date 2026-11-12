# Terraform state from CI (plan, then apply the exact saved plan)

Run `terraform/examples/aws-environments` (the data stack: RDS, OpenSearch, S3, history uploads, Pod Identity
roles) from GitHub Actions instead of a workstation. It wraps the same saved-plan runner
(`terraform/scripts/aws-environment.py`), so every refusal it makes locally (input seals, bucket owner,
search history admission, one apply attempt per receipt) still applies.

| Piece | Where |
|---|---|
| OIDC plan and apply roles | [`terraform/modules/aws/ci-terraform`](../terraform/modules/aws/ci-terraform) |
| Plan and apply steps | [`scripts/selfhost/ci-terraform.sh`](../scripts/selfhost/ci-terraform.sh) |
| Workflow | in the repository that holds the environment (see [Caller workflow](#caller-workflow)) |

## Why no runner in the VPC

[CI deploy](selfhost-ci-deploy.md) runs in CodeBuild inside the VPC because Helm must reach a private EKS API.
This stack makes AWS API calls only (no Kubernetes, PostgreSQL or OpenSearch provider), so a GitHub-hosted
job with an OIDC role is enough. What the CodeBuild layer added there, keeping artifacts in the account, is
covered here by keeping the saved plan in the state bucket (never in a GitHub artifact), written once.

## Flow

**Plan** (`ci-terraform.sh plan`, plan role, read-only):

1. Read the tfvars from an SSM SecureString parameter (latest version), check its account and region.
2. Run the runner's `plan`: it takes and releases the state lock (`<key>.tflock`, the only write a plan
   makes), refreshes with Describe/Get/List calls and saves the plan with its receipt.
3. Upload the runner's private run directory (saved plan, receipt, derived variables; not provider binaries)
   as `s3://<state bucket>/<plan_store_prefix>/<run>-<attempt>/run.tgz` with `manifest.json`: plan SHA-256,
   infra commit, backend digest, tfvars parameter version and digest. Both are written with
   `If-None-Match`, SSE-KMS with the state key. The role may only write that way, so neither can be replaced
   after review.
4. Job summary: the plan run id, plan SHA-256, tfvars version and every resource address with its action,
   with no attribute values. The JSON plan (which carries sensitive values in clear) is only piped through
   `jq`. `plan.txt` is Terraform's text rendering, the same text the job log shows: sensitive values are
   redacted, but ordinary configuration (subnet and security group IDs, ServiceAccount names, policy
   documents) is in it, because that is what the approver reviews. It is visible to whoever can read the
   repository's Actions runs.

**Apply** (`ci-terraform.sh apply`, apply role, a separate manually dispatched run):

1. Inputs: the plan run id and the plan SHA-256 from the plan summary.
2. Refuse unless the manifest's digest is that SHA-256, it has changes, and its infra commit, backend and
   tfvars parameter equal today's `ci.json`. Download `run.tgz` and check its digest; read the tfvars **at
   the planned version** and check their digest.
3. Claim the plan: write `apply-attempt.json` with `If-None-Match`. A plan gets one attempt, ever, even if it
   fails; a failure needs reconciliation and a new plan.
4. Restore the run directory at the same paths and run the runner's `apply --approve-plan <sha256>`.
   Terraform refuses a saved plan whose state changed since it was made ("Saved plan is stale"), so a plan
   applies only to the state it was reviewed against.
5. Record `apply-result.json` with the exit code.

Paths must match between the two runs (the runner binds them): use the same runner image and
`$RUNNER_TEMP/ci-terraform` as the work directory, as the caller workflow below does.

## Inputs

`ci.json` in the environment repository (non-secret, committed):

```json
{
  "account_id": "111111111111",
  "aws_region": "us-west-2",
  "tools_ref": "<40-hex AgentWorkforce/infra commit: runner, stack and this script>",
  "approval_environment": "env-prod",
  "plan_role_arn": "arn:aws:iam::111111111111:role/env-prod-data-github-plan",
  "apply_role_arn": "arn:aws:iam::111111111111:role/env-prod-data-github-apply",
  "tfvars_parameter": "/env-prod/ci-terraform/data-tfvars",
  "backend": { "bucket": "...", "key": "agent-relay/111111111111/us-west-2/prod/data.tfstate", "region": "us-west-2",
               "expected_bucket_owner": "111111111111", "encrypt": true, "use_lockfile": true, "kms_key_id": "..." },
  "plan_store": { "bucket": "<the state bucket>", "prefix": "ci-plans/111111111111/us-west-2/prod/data", "kms_key_arn": "..." }
}
```

**tfvars** live in the SSM SecureString `tfvars_parameter`, not in git. They are not secret (account,
subnet, security group and cluster identifiers, ServiceAccount names) but the environment's owners keep them
out of the repository. SSM, rather than Secrets Manager or a repository secret, because every write is a new
**version**: the plan records the version it read and the apply reads exactly that version, so a later edit
cannot change what an approved plan applies. It is KMS-encrypted, readable only by the two roles (both are
denied every other parameter) and every read is in CloudTrail. Neither role can write it. Its owner sets it
with:

```sh
aws ssm put-parameter --name /env-prod/ci-terraform/data-tfvars --type SecureString \
  --key-id <state KMS key ARN> --value file://prod.data.tfvars.json --overwrite
```

Secrets (database passwords, the history witness key) are never tfvars: the stack has RDS manage its master
password and the witness key stays in Secrets Manager. The roles are denied `secretsmanager:GetSecretValue`.

## Roles

See the [module README](../terraform/modules/aws/ci-terraform/README.md). In short, trust is `aud` and `sub`
plus the GitHub claims STS evaluates: `repository_id`, `ref`, `job_workflow_ref` (the caller workflow at
`main`) and, for apply, `environment`. plan trusts `main`. apply trusts a GitHub environment that only this
workflow uses and that deploys only from `main`. The first plan dispatch proves the trust; if STS refuses the
extra claims, set `pin_github_claims = false` (aud and sub only). plan can read the state, take the lock and save its plan, and
is explicitly denied writing the state. apply can write the state and resources named
`<name_prefix>-<environment>-*`.

## Caller workflow

The workflow lives in the environment repository, next to its settings. It checks out this repository at
`tools_ref` and calls the script:

```yaml
on:
  workflow_dispatch:
    inputs:
      mode: { type: choice, options: [plan, apply], default: plan }
      plan_run_id: { type: string, default: "" }
      plan_sha256: { type: string, default: "" }
jobs:
  plan:
    if: inputs.mode == 'plan' && github.ref == 'refs/heads/main'
    permissions: { contents: read, id-token: write }
    steps:
      - checkout (site), checkout AgentWorkforce/infra at ci.json tools_ref (path tools, sparse terraform scripts)
      - hashicorp/setup-terraform (pinned, terraform_wrapper: false)
      - aws-actions/configure-aws-credentials with plan_role_arn
      - run: tools/scripts/selfhost/ci-terraform.sh plan site/<env>/ci.json tools "$RUNNER_TEMP/ci-terraform" "$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
  apply:
    if: inputs.mode == 'apply' && github.ref == 'refs/heads/main'
    environment: <approval_environment>
    concurrency: { group: <state>, cancel-in-progress: false }
    steps: [same, apply_role_arn, ci-terraform.sh apply ... "$PLAN_RUN_ID" "$PLAN_SHA256"]
```

AgentWorkforce/enterprise-onboarding `.github/workflows/agentrelay-data.yml` is a complete example.

Without environment protection rules (GitHub Free on a private repository), nothing in GitHub stops an
apply dispatch once someone can dispatch. There, apply is a separate manual dispatch that runs only on the
owner's explicit approval of a named plan SHA-256; it never follows a plan automatically.

## First run

1. Apply the module (the roles) for the account. That is an IAM change outside this CI and needs its own
   reviewed apply. Create the apply GitHub environment with deployment branches limited to `main`.
   The first plan dispatch is also the proof that STS accepts the pinned claims.
2. Put the tfvars parameter.
3. Dispatch `plan`. Review the summary: the resource list, the plan SHA-256 and the tfvars version.
4. Dispatch `apply` with that plan run id and SHA-256 after explicit approval.
