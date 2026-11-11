# Upgrading from your own GitHub Actions

Agent Relay publishes each release as a GitHub release `agent-relay-<version>`
in `AgentWorkforce/infra`: the packaged chart, `release-manifest.json`,
`release-images.values.yaml` and `SHA256SUMS`, with GitHub build attestations.
You pull releases into your install; Agent Relay never has access to your
account or cluster.

The reusable workflow `.github/workflows/selfhost-upgrade.yml` runs
`scripts/selfhost/agent-relay-upgrade.sh` from your own repository:

1. **plan** (no approval): selects the release (newest by default), verifies
   the attestations (bound to `AgentWorkforce/infra`'s
   `release-agent-relay.yml` workflow and the release tag) and checksums,
   renders the chart with your values, checks that every image is a release
   image in your ECR mirror, and writes the image changes and every rendered
   resource that differs from the deployed release to the run summary.
2. **apply** (by default only when the rendered release changes: a new chart,
   values or images): runs in your environment
   `agent-relay-upgrade`, so it waits for your required reviewers. It mirrors
   the images, snapshots RDS, runs `helm upgrade` and waits for this release's
   migrations and rollouts. A failure prints the rollback revision and snapshot.

The workflow and upgrader come from the release tag you select, so these
behaviours apply to releases cut after they were added.

## Set up (once)

1. **A repository** holding your values file(s), for example
   `deploy/agent-relay/values.yaml`.
2. **An environment** in it named `agent-relay-upgrade`, with required
   reviewers. Every upgrade waits for one of them.
3. **A self-hosted runner** that can reach the EKS API (a private cluster needs
   one inside the VPC), with `gh curl jq yq helm kubectl tar aws crane` and
   `sha256sum` (or `shasum`) installed. The workflow checks these first.
   Outbound access: `github.com`, `api.github.com`, `ghcr.io`, AWS APIs.
4. **Two IAM roles**, both trusted through GitHub OIDC
   (`token.actions.githubusercontent.com`, audience `sts.amazonaws.com`):
   - **Plan role (read-only)**, trusted for `repo:<org>/<repo>:ref:refs/heads/main`:
     `eks:DescribeCluster`, and an EKS access entry with read-only (view)
     access to the `agent-relay` namespace plus read of Helm release Secrets.
     The plan job never writes to ECR, RDS or the cluster.
   - **Apply role (write)**, trusted **only** for
     `repo:<org>/<repo>:environment:agent-relay-upgrade`, so it can be assumed
     only by a job your reviewers approved. It needs:
     - ECR: `ecr:GetAuthorizationToken`, and on `agent-relay/*` repositories
       `ecr:CreateRepository`, `ecr:DescribeRepositories`, `ecr:PutImage`,
       `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`,
       `ecr:CompleteLayerUpload`, `ecr:BatchCheckLayerAvailability`,
       `ecr:BatchGetImage`, `ecr:PutImageScanningConfiguration`,
       `ecr:PutImageTagMutability`
     - RDS: `rds:CreateDBSnapshot`, `rds:DescribeDBSnapshots` on the database
     - EKS: `eks:DescribeCluster`, and an EKS access entry allowing it to
       manage the `agent-relay` namespace (Helm release, Deployments, Jobs).
     - With `rds-setup: true` also `secretsmanager:GetSecretValue` on the RDS
       admin secret, and in the namespace: create/delete Jobs and Secrets
       (`rds-setup.sh` runs its SQL in short-lived Jobs) and patch the
       `agent-relay-secrets` and `search-indexer-owner` Secrets.

## First install and RDS-managed installs

Set `first-install: true` for one run to create the release: the plan refuses
it if the release already exists (and a normal run refuses a missing release).
Apply then snapshots RDS, runs `helm install --no-hooks` without `--wait`,
waits for the HoopDb migrate Job, then for every Job in the installed release
(bounded; a failed Job fails the run with its name and last logs) and the
Deployments. Remove the input after it
succeeds.

If `scripts/selfhost/rds-setup.sh` bootstrapped the databases, set
`rds-setup: true` (implied by `profile: eks-rds-native`) with `rds-host`,
`rds-admin-secret-arn` and `state-dir`. `state-dir` is the directory on the
self-hosted runner holding the files `rds-setup.sh pre` wrote, so the apply
job must run on that runner. A first install then runs `rds-setup.sh post`
after the migration and restarts the read API, ingest edge and search indexer;
every later upgrade runs `rds-setup.sh refresh-admin` and updates the two
admin-derived Secret keys before `helm upgrade`. If an external secret
controller owns those Secrets, leave `rds-setup` off and refresh them there.

## The workflow file

```yaml
# .github/workflows/agent-relay-upgrade.yml
name: Agent Relay upgrade
on:
  schedule: [{ cron: "0 9 * * 1-5" }]   # check each weekday
  workflow_dispatch:
    inputs:
      version: { description: "Release (empty = newest)", default: "" }
permissions: { contents: read, id-token: write, attestations: read }
jobs:
  upgrade:
    # Pin to the release tag (or commit) you have reviewed.
    uses: AgentWorkforce/infra/.github/workflows/selfhost-upgrade.yml@agent-relay-2026.11.0
    with:
      version: ${{ inputs.version || '' }}
      runs-on: '["self-hosted", "agent-relay"]'
      aws-region: us-east-1
      aws-plan-role-arn: arn:aws:iam::<account>:role/agent-relay-upgrade-plan
      aws-apply-role-arn: arn:aws:iam::<account>:role/agent-relay-upgrade-apply
      eks-cluster: <cluster-name>
      registry: <account>.dkr.ecr.us-east-1.amazonaws.com
      profile: eks-native
      values: deploy/agent-relay/values.yaml
      db-instance: <rds-instance-id>
      # first-install: true                 # one run, for a new install
      # rds-setup: true                     # databases managed by rds-setup.sh
      # rds-host: <terraform output -raw database_host>
      # rds-admin-secret-arn: <terraform output -raw database_admin_secret_arn>
      # state-dir: /srv/agent-relay-install # on the self-hosted runner
```

To be notified of new releases, watch `AgentWorkforce/infra` for releases, or
subscribe to `https://github.com/AgentWorkforce/infra/releases.atom`.

Without GitHub Actions, run the same command by hand or from any CI:

```sh
scripts/selfhost/agent-relay-upgrade.sh --version <v> \
  --registry <account>.dkr.ecr.<region>.amazonaws.com --profile eks-native \
  --values values.yaml                        # plan
# then add: --db-instance <rds-id> --apply
# new install: add --first-install; rds-setup.sh-managed databases: add --rds-setup
```
