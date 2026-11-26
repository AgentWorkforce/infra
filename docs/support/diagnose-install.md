# Diagnose a managed-PostgreSQL installation

Run `scripts/support/diagnose-install.py` on an operator machine that can reach
Kubernetes and the database. It checks the **PostgreSQL Relaycast** install
contract used by the AWS/RDS and GCP/Cloud SQL guides. SQLite and durable-actors
Relaycasts are outside this diagnostic's scope. Custom database names work.
Python 3.10+, kubectl and psql are required; a database CA bundle must be available
on the operator machine. No Helm, Python packages or DBA password is needed
beyond the credentials already configured for the installation. On EKS, the
`aws` CLI with credentials for the cluster's account adds the
[Pod Identity checks](#eks-pod-identity); without it they report `UNKNOWN`.

The diagnostic performs reads only. It does not repair roles, activate logins,
run migrations, restart workloads, delete failed Jobs, change Secrets or apply
infrastructure. Run it before changing the failed state.

## Quick start: no flags

Put the script in the folder that holds your `rds-ca.pem`, your filled-in
values file (any `*values*.yaml`) and your Secret YAMLs (in that folder or
`./secrets`), then run:

```bash
python3 diagnose-install.py
```

It prints what it detected, then the checks, then **Likely problems (fix top
to bottom)**, and writes `install-diagnostic-<time>.json` in the same folder.
Detection order:

- **Kube context:** the current context. If the cluster is unreachable (for
  example on the database VPN), cluster checks are UNKNOWN and the run continues.
- **Credentials:** the deployed Secrets when the cluster is reachable; otherwise
  `~/.agent-relay-install/secret-files`; otherwise Secret YAMLs here or in `./secrets`.
- **Database CA:** `rds-ca.pem`, `database-ca.pem`, `global-bundle.pem` or
  `*-bundle.pem` here, then `~/.agent-relay-install/rds-ca.pem`.
- **Database names:** taken from the URLs; pass `--*-database` only to assert them.

If something is not found, the run ends with **Missing files - how to fix**:
which file, where it looked, and the command to fix it (for a missing CA, the
chart's bundle for your region, taken from the RDS hostname, and its download
URL).

The values file is linted for mistakes seen in real installs: example
placeholders left in (with line numbers), an OpenSearch endpoint without
`https://`, an RDS CA `caSha256` that is the example value or does not
match your local `rds-ca.pem`, and a `global.rdsCa.bundle` that is not an AWS
region or `global` (with it set, hand-set CA hashes are not needed). The
cluster checks also report a ConfigMap that a release pod mounts but that does
not exist (the pod stays in ContainerCreating; `rds-ca` is the usual one) and a
chart-managed `rds-ca` whose content no longer matches the hash the services
pin. Pass `--values FILE` to pick a file, or
`--values` with no file to skip the lint. Every flag below still works and
overrides detection.

## One run with both networks available

Use the kube context and database names from the private installation handoff:

```bash
python3 scripts/support/diagnose-install.py \
  --context "$KUBE_CONTEXT" \
  --namespace agent-relay --release agent-relay \
  --control-database "$DB_CONTROL" \
  --cast-database "$DB_CAST" \
  --hoop-database "$DB_HOOP" \
  --ca-file "$PWD/database-ca.pem" \
  --output ./install-diagnostic.json
```

`--context` defaults to the current kube context; the run prints which one it used.
Database name arguments are optional but recommended: without them, the script
checks that URLs agree within each service group and differ across groups, but
cannot tell that all URLs in a group consistently name the wrong database.
`--ca-file` overrides container-only paths such as `/etc/postgres-ca/ca.crt` in
the configured URLs for the diagnostic process only. TLS hostname verification
remains enabled. Use the actual database hostname, not its IP address or an
unverified alias.

The script reads exactly five named Kubernetes Secrets using `get`, keeps their
values in memory, validates all ten database credential slots, and connects as
the configured logins. It does not need `list` on Secrets. Your identity also
needs `list` on Jobs, Pods, Deployments and PersistentVolumeClaims in the namespace.
Workload reads use `app.kubernetes.io/instance=RELEASE`; custom labels can leave
sections unknown. Names and creation times identify failed resources in the
report, including old Jobs that may predate corrected credentials. A previous
container failure is historical evidence and is reported as `UNKNOWN`; readiness
is evaluated separately.

## EKS Pod Identity

With a cluster scope (`--scope cluster` or `all`), the diagnostic finds every
ServiceAccount the release's Deployments, StatefulSets, Jobs and CronJobs run
as whose pods read S3 (`LOCKER_BUCKET` with no static `LOCKER_ACCESS_KEY_ID`)
or sign OpenSearch requests (`SEARCH_INDEX_OPENSEARCH_AUTH=sigv4`), plus an
S3 re-arm sweeper in Pod Identity mode (`INGEST_REARM_CREDENTIALS=podIdentity`).
It then lists the namespace's associations, read-only:

```bash
aws eks list-pod-identity-associations --cluster-name <cluster> --region <region> --namespace agent-relay
```

The cluster and region come from the kube context that `aws eks
update-kubeconfig` writes (the cluster ARN, or its `--cluster-name`/`--region`
exec arguments). The AWS calls use the `AWS_PROFILE` that context authenticates
with, even if your shell sets another, so they look at the same account as the
workloads; `--aws-profile` overrides it. A context that isn't EKS (GKE, AKS,
kind) skips the section; `--eks-cluster` and `--aws-region` force it, and
`--no-aws` skips it.

| ServiceAccount | Needs |
| --- | --- |
| `<release>-worker` | S3 read/write |
| `<release>-session-ingest-api` | S3 read/write |
| `<release>-search-indexer` | S3 read, OpenSearch write |
| `<release>-session-read` | S3 read, OpenSearch read |
| `<release>-alleyoop` (only profiles that render it) | S3 read/write |

Only the access a workload actually uses is checked: a read API on PostgreSQL
search needs no OpenSearch. A ServiceAccount with no association is a `FAIL`
whose next step is the exact command to create it. The role is the one the
reference Terraform shares with it (worker, alleyoop and session-ingest-api use
one sessions role), or a placeholder naming the access. With direct uploads on
(`HISTORY_UPLOAD_DIRECT`), the ingest edge is the upload consumer and never
shares a role:

```text
FAIL podidentity.agent-relay-worker [agent-relay-worker]: No Pod Identity association for ServiceAccount agent-relay-worker (used by agent-relay-worker-session-summary-worker, ...), which needs S3 read/write. Its pods get no AWS credentials.
  Next: aws eks create-pod-identity-association --cluster-name demo --region us-west-2 --namespace agent-relay --service-account agent-relay-worker --role-arn arn:aws:iam::123456789012:role/session-ingest-api  then restart its pods: kubectl -n agent-relay rollout restart deployment/agent-relay-worker-session-summary-worker ...
```

Without it, the session-summary worker logs `no Locker credentials: set
LOCKER_ACCESS_KEY_ID/LOCKER_SECRET_ACCESS_KEY, or run with EKS Pod Identity`.
Associations that no workload of the release uses are listed, for information
only.

For each association found, the diagnostic also asks IAM whether the role's
policies allow the access, with `aws iam simulate-principal-policy` (read only):
`s3:GetObject`/`s3:ListBucket` (plus `s3:PutObject`/`s3:DeleteObject` for
read/write) on the bucket in the workload's `LOCKER_BUCKET`, and the
`modules/aws/search` action sets on the domain in `SEARCH_INDEX_OPENSEARCH_URL`
(read: `es:ESHttpGet`/`Head`/`Post`; write: also `Put`/`Delete`/`Patch`). These
are checks such as `podidentity.agent-relay-search-indexer.os-w`. If your
identity may not call `iam:SimulatePrincipalPolicy` or
`eks:DescribePodIdentityAssociation`, they are `UNKNOWN`; `--no-iam-simulate`
skips them. The simulation covers the role's identity policies only: bucket
policies, KMS key policies and the OpenSearch domain access policy and
fine-grained role mapping (install step 7) are not evaluated.

The AWS identity needs `eks:ListPodIdentityAssociations`,
`eks:DescribePodIdentityAssociation` and, for the simulation,
`iam:SimulatePrincipalPolicy`.

## Cluster and database VPNs cannot coexist

On the cluster VPN, collect the workload and credential-structure checks:

```bash
python3 scripts/support/diagnose-install.py \
  --context "$KUBE_CONTEXT" --scope cluster \
  --output ./install-diagnostic-cluster.json
```

On the database VPN, use the **existing private `secret-files` directory** from
`rds-setup.sh` / `cloud-sql-setup.sh` (or the same directory structure prepared
through your approved secret delivery workflow):

```bash
python3 scripts/support/diagnose-install.py \
  --scope database \
  --secret-dir "$HOME/.agent-relay-install/secret-files" \
  --control-database "$DB_CONTROL" \
  --cast-database "$DB_CAST" \
  --hoop-database "$DB_HOOP" \
  --ca-file "$PWD/database-ca.pem" \
  --output ./install-diagnostic-database.json
```

If you set up the database by hand and have no `secret-files` directory, point
the diagnostic at the Secret manifests you filled in from `examples/aws/secrets/`
instead (files or a directory; YAML with `stringData`/`data`, or
`kubectl get secret -o json` output):

```bash
python3 scripts/support/diagnose-install.py \
  --scope database \
  --secret-manifests ./secrets \
  --control-database "$DB_CONTROL" \
  --cast-database "$DB_CAST" \
  --hoop-database "$DB_HOOP" \
  --ca-file "$PWD/database-ca.pem" \
  --output ./install-diagnostic-database.json
```

Only `kind: Secret` documents are read; other documents are skipped. A warning
is printed for manifest files readable by other users. Like local files, a
manifest proves only that copy: if it differs from what was applied, rerun
against the cluster.

This mode needs no Kubernetes access. Each input is a file named
`SECRET_NAME/KEY_NAME` containing that key's value, with mode `0600` (or stricter).
Read-API and search files retain their JSON wrappers. No credential export is
created by this script. Keep the private input directory on the approved
operator machine. A stale local file can differ from the deployed Secret: only a
run against the deployed credential source proves those credentials work.

## What the report identifies

| Check | What a failure suggests |
| --- | --- |
| URL structure / JSON wrapper | Empty host or database, missing field, invalid JSON, unsupported URL option, or non-Postgres URL. Empty host is rejected before libpq can fall back to a local socket. |
| Credential login | Admin URL in a runtime slot, swapped owner/runtime URLs, or a wrong service login. |
| Credential targets | Owner and runtime URLs point to different databases, or the three services accidentally share a database. |
| Database login | Distinguishes authentication, missing database, TLS, DNS, network and permission error categories without printing raw error text. |
| Relaycast role existence | Missing phase 1 bootstrap roles. |
| Relaycast `schema_owner`, `owner_temp`, `owner_schema_create` | The migration owner lacks the prerequisites associated with identity exit 65. |
| Relaycast `owner_no_db_create` / owner membership | The migration login has database CREATE or can assume the database owner role. It must own the public schema without owning the database. |
| Relaycast runtime isolation | Runtime has CREATE, TEMP, owner membership, administrative attributes or broad predefined role membership. |
| Relaycast default grants | New tables need SELECT/INSERT/UPDATE/DELETE; new sequences need SELECT/USAGE/UPDATE. PUBLIC must not receive object or default grants. |
| Relaycast existing object grants / owners | Existing public-schema objects were created by a different login, or default grants were applied after objects already existed. Extension-owned objects are excluded. |
| HoopDb extensions / sessions schema | Phase 1 or migration is incomplete. |
| HoopDb owner layout | Reports whether the database and sessions schema are owned by the configured migration login. A mismatch is unknown and requires checking the release's owner/bootstrap contract. |
| Workloads / Jobs / exit codes | Failed migrations, init waits, image pull failures, missing container configuration, unready Deployments or unbound volumes. |
| Pod Identity (`podidentity.*`) | A ServiceAccount that reads S3 or OpenSearch has no EKS Pod Identity association, or its role's IAM policy lacks that access. |

The report uses `PASS`, `FAIL` and `UNKNOWN` with a next step for failures and
unknowns. Exit status: **0** means all requested checks passed, **1** means at
least one finding failed, **2** means incomplete evidence or an invocation/output
error. A cluster-only run intentionally reports database checks as unknown.
Missing access or tools never become a healthy result. A database query can
fail because a required role is missing; subsequent checks for that connection
then remain unknown. This is not a complete application acceptance test, and
schema objects do not prove the current migration generation completed.

A search/read/ingest login may fail until the reviewed **post-migration phase 2**
activation has run. Do not work around it by replacing its URL with the admin
URL. A failed Job may remain after its credentials are corrected; preserve it
and follow the release's approved migration recovery procedure.

## Data handling and limits

The JSON report contains check IDs, statuses, fixed diagnostic text, resource
names/times, PostgreSQL version numbers and catalog counts, and on EKS the
cluster name, region, bucket name and associated IAM role ARNs. It never contains
passwords, URLs, application rows, pod logs, raw manifests or raw command errors.
It is created mode `0600` and never overwrites an existing file. Review it before
sharing through the support channel.

Credentials reach psql through its process environment, never argv or SQL.
As with other database clients, processes with sufficient access on that
operator machine can inspect their environment. The script removes inherited
libpq routing/options variables, disables psql startup files and prompts,
requires `sslmode=verify-full`, and sends fixed catalog SQL in bounded read-only
transactions. It does not inspect customer application data or infer migration
completion from a successful login.

The Secret/key names and fixed role names below follow the managed install
contract. If your deployment customizes these, adapt the input mapping before
running; an unavailable key will be reported explicitly.

| Slot | Secret / key | Login |
| --- | --- | --- |
| control-owner | agent-relay-secrets / database-migrations-url | control_owner |
| control-runtime | agent-relay-secrets / database-url | control_api_runtime |
| cast-owner | agent-relay-secrets / database-owner-url | relaycast_owner |
| cast-runtime | agent-relay-secrets / database-runtime-url | relaycast_runtime |
| hoop-owner | agent-relay-secrets / HOOPDB_MIGRATION_URL | configured migration owner |
| hoop-runtime | agent-relay-secrets / HOOPDB_URL | sessions_pipeline_runtime |
| read-runtime | agent-relay-read-api / RELAYHISTORY_READ_API_SECRET (`supabase_url` JSON field) | bulls96_read_api |
| ingest-runtime | agent-relay-ingest-edge-runtime / database-url | bulls96_session_ingest |
| search-runtime | search-indexer-runtime / RELAYHISTORY_PIPELINE_CONSUMER_SECRET (`hoopdb_url` JSON field) | search_consumer_runtime |
| search-owner | search-indexer-owner / RELAYHISTORY_PIPELINE_CONSUMER_SECRET (`hoopdb_url` JSON field) | configured migration owner |

The broader [support bundle collector](README.md) adds ingress, DNS/TLS/HTTP,
Helm metadata and resource-pressure evidence. It does not connect to PostgreSQL.

## Verification

```bash
python3 -m unittest discover -s scripts/support/tests -p 'test_*.py' -v
```

Tests cover malformed credentials, swapped logins, custom database names,
credential-free output/argv, partial collection, historical exit codes and private
report creation. If local PostgreSQL server binaries are installed, the tests
start a temporary isolated instance, prove healthy grants, break individual
grants/memberships/default ACLs, and verify the corresponding findings. With
OpenSSL installed they also exercise the real TLS client and prove that its
read-only transaction refuses a write. They never connect to a configured cloud
cluster or database. CI runs this suite alongside the existing support bundle
tests.
