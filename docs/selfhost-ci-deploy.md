# Deploying an environment from CI

Every change to an environment's Helm releases goes through GitHub Actions: a reviewed plan, an approved
apply, a snapshot first, health checks after, and a rollback in the same workflow. Nobody runs `helm upgrade`
from a laptop.

```
GitHub job ──OIDC──> role that can only start one CodeBuild project ──> CodeBuild in the cluster's VPC
  bundle (charts + env)  ─── S3 ───>                                     ci-deploy.sh plan|apply|rollback
  report (plan.md, diff) <── S3 ────                                     ──> private EKS API, RDS / Postgres
```

The EKS API stays private (or limited to operator addresses): GitHub runners never reach it.

## Pieces

| Piece | Where |
|---|---|
| AWS: OIDC roles, CodeBuild projects, bucket, EKS access | `terraform/modules/aws/ci-deploy` (one instance per environment) |
| Reusable workflow | `.github/workflows/selfhost-ci-deploy.yml`, pinned to a commit by the caller |
| Bundle, start, log, report | `scripts/selfhost/ci-deploy-run.sh` (GitHub side) |
| Plan, apply, rollback | `scripts/selfhost/ci-deploy.sh` and `ci_deploy_plan.py` (CodeBuild side) |
| Values and settings | the caller's repository: one directory per environment (below) |

## Environment directory (caller repository)

```
<env>/deploy.json      releases, snapshot, health checks
<env>/values/*.yaml    non-secret values; Secrets are referenced by name, never inlined
<env>/allow-drop.txt   reviewed exceptions to the drop guard (optional)
<env>/plan-rbac.yaml   the module's plan_rbac_manifest output (re-applied by every apply)
```

```json
{
  "environment": "dev",
  "releases": [
    {"name": "agent-relay", "namespace": "agent-relay-dev", "chart": "infra/charts/agent-relay",
     "values": ["infra/charts/agent-relay/values-eks.yaml", "env/values/agent-relay.yaml"], "timeout": "25m"}
  ],
  "snapshot": {"type": "rds", "instance": "agent-relay-dev-pg"},
  "health": ["https://dev.example.com/readyz"]
}
```

Paths are relative to the bundle: `infra/charts` is this repository's charts at the caller's `infra-ref` (what
the environment runs), `infra/scripts/selfhost` the deploy scripts at `tools-ref` (the workflow's own pin, so an
environment on an older chart still gets the current tooling), and `env/` is the environment directory. `snapshot` is one of:

- `{"type": "rds", "instance": "<id>"}`: `CreateDBSnapshot` named `<module name>-<run>`, waited on.
- `{"type": "pg_dump", "databases": [{"label": "control", "namespace": "<ns>", "secret": "<Secret>", "key": "<key>"}]}`:
  a custom-format `pg_dump` per database, streamed to `s3://<bucket>/snapshots/<run>/<label>.dump`. The URL is
  read from the Secret inside the job and never printed. Use a session-mode (not transaction-mode) pooler URL.
- `{"type": "none"}`.

## What each mode does

**plan** (read-only; from the protected branch only): builds chart dependencies, reads each live release
(`helm get values/manifest/hooks`), renders the upgrade with `helm upgrade --dry-run=client`, and compares.
The report (`plan.md` in the job summary, `diff.txt` and per-release JSON as an artifact) lists added,
changed and dropped values and resources. Secret data and secret-looking values appear only as digests.

The **drop guard** refuses a plan that removes a live user-supplied value or a live rendered resource
(including hooks), unless `allow-drop.txt` lists it:

```
value agent-relay relay-control.featureX        # the path and everything under it
resource agent-relay ConfigMap/agent-relay-dev/old-config
```

A first plan that is not empty means the committed values do not reproduce what is live: fix the values,
do not apply.

**apply** runs only when the plan has changes, in the caller's approval environment (its required reviewers
approve). It rebuilds the bundle and refuses if the digest differs from the plan's, re-runs the plan and
refuses if any release's revision moved since the reviewed plan, snapshots, applies `plan-rbac.yaml`, runs
`helm upgrade --install --wait` per changed release, fails on any Job that failed during the upgrade (helm
`--wait` does not), records the running images and chart versions, and checks every health URL for a 2xx.

**rollback**: `helm rollback <release> <revision> --wait`, then the health checks. Also gated by the approval
environment. The revision to return to is the "Live revision" column of the plan that preceded the apply.
A rollback does not undo database migrations: restore from the run's snapshot if one must be undone.

## Setting up an environment

1. Apply the module once per environment (an operator with admin rights; afterwards the module itself can
   be applied from CI). Inputs: the cluster, its security group and private subnets, the KMS key, the GitHub
   repository and the approval environment name.
2. `kubectl apply -f` the `plan_rbac_manifest` output, and commit it as `<env>/plan-rbac.yaml`.
3. In GitHub, create the approval environment: required reviewers, "prevent self-review", deployment
   branches limited to the default branch.
4. Commit the environment directory with values that reproduce what is live, and a caller workflow:

```yaml
jobs:
  deploy:
    uses: AgentWorkforce/infra/.github/workflows/selfhost-ci-deploy.yml@<commit>
    permissions: { contents: read, id-token: write }
    with:
      environment-dir: deploy/dev
      infra-ref: <commit of AgentWorkforce/infra whose charts deploy>
      tools-ref: <the commit in the uses: line above>
      mode: ${{ inputs.mode }}
      approval-environment: dev
      aws-region: us-west-2
      plan-role-arn: <plan_role_arn>
      apply-role-arn: <apply_role_arn>
      plan-project: <plan_project>
      apply-project: <apply_project>
      bucket: <bucket_name>
      log-group: <log_group>
      rollback-release: ${{ inputs.rollback_release }}
      rollback-revision: ${{ inputs.rollback_revision }}
```

5. Dispatch `plan`. The first plan must show no changes: that proves the committed values are what is live.
