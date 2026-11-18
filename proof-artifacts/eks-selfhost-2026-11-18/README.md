# EKS self-hosted install proof, 2026-11-18

Transport branch, not meant to merge as is: the files here are the exact inputs applied during an end-to-end proof of
a self-hosted install on an existing EKS cluster, for reuse in `examples/aws` and the docs. Account ids, the RDS
endpoint id, the certificate id, the bucket suffix and the operator role name are replaced with example values.
Nothing here is a secret; every secret lived only in SSM Parameter Store (SecureString).

## Constraints the proof kept

- Existing EKS cluster (Kubernetes 1.37, 2 x m6i.large), Pod Identity, AWS Load Balancer Controller 3.6.3.
- Shared RDS PostgreSQL 17.11 that also holds an unrelated database; admin is the RDS master user with an
  RDS-managed password.
- Custom database names: `poc_relaycontrol`, `poc_hoopdb`, `poc_relaycast` (no default-named database exists).
- Bring-your-own S3 bucket, OpenSearch 2.19 domain (fine-grained access control, IAM master), IAM roles.
- No shell scripts from this repo: database setup by hand per `docs/self-hosted-rds-manual-setup.md`, run from a
  psql pod in the cluster.
- No plaintext secret files: 19 SSM SecureString parameters at `/agent-relay/proof/<SecretName>/<key>`, synced into
  5 Secrets by External Secrets Operator 2.15.0.
- Release `agent-relay-2026.11.16` (chart 0.7.54), then upgrade to the chart on main (0.7.57). Helm 3.22.1.

## Result

| Check | Variant A (0.7.54, hand-written ExternalSecrets) | Variant B (0.7.57, chart `externalSecrets`) |
| --- | --- | --- |
| 1. 9 Deployments Ready, migration Jobs Complete, phase 2 logins | pass (3 Jobs first attempt: 61 s, 38 s, 37 s; install to all rolled out 2 min 5 s) | pass (no migration Job re-ran; bootstrap Job re-ran, 6 s) |
| 2. 5 ExternalSecrets SecretSynced, key counts 14/1/2/1/1 | pass | pass, same Secret UIDs and data |
| 3. Sign-in with setup key, upload lands in dashboard, history search finds it | pass | pass (dashboard after 301 s, 3 search matches) |
| 4. Unrelated database untouched | pass | pass |
| 5. Rotate one runtime password, then the RDS master password | pass (see findings) | n/a |
| Images unchanged | | pass (13 container image digests identical) |
| Availability during the upgrade and handover | | 198 of 198 probes at 2 s intervals as expected (200/200/200/401) |

## Findings

1. **Helm 3 does not update an adopted ExternalSecret.** See `secrets-eso/HANDOVER.md`. Following "label, upgrade,
   delete the old store" would leave all 5 ExternalSecrets pointing at a deleted SecretStore: the Secrets stay, but
   refresh and rotation stop without any error from Helm.
2. **Runtime password rotation needs a pod restart, and the pod does not show it.** After `ALTER ROLE` + SSM
   overwrite + ESO sync, the old read-api pod stayed Ready with 0 restarts while every read returned 503. A rollout
   restart fixed it (new pod Ready in 3 s).
3. **RDS master rotation breaks no running pod.** The master URL is used only by the hoopdb migrate Job
   (`HOOPDB_MIGRATION_URL`) and the search-indexer bootstrap Job (`search-indexer-owner`). An unchanged
   `helm upgrade` re-runs neither, so "rotate before the next upgrade" cannot be verified by upgrading; test the new
   URL with psql. RDS-managed master passwords rotate every 7 days by default, so the stored URL goes stale.
4. **ESO refresh.** Any annotation change on an ExternalSecret triggers a sync within about 1 s; otherwise it waits
   for `refreshInterval` (1 h here).
5. **A browser session cannot mint an upload credential** (403), so a script-only first-upload check needs the
   bootstrap-token device flow. Upload to dashboard/search visibility took 1 to 5 minutes (indexer tick).
6. **Public desktop and CLI builds cannot target a self-hosted site** (the site is fixed at build time), so a
   real-client upload was not possible in this run.

## Docs gaps (for one pass over the install docs)

Database setup (`docs/self-hosted-rds-manual-setup.md`)
- The three default database names are hardcoded (about 20 places, phase 2, the URL table); custom names are never
  said to be allowed. They work.
- Assumes psql on the operator's machine; from a pod, pass `-d postgres` and mount the RDS CA.
- "Do not use the master user" conflicts with an install whose only admin is the master user.
- Phase 2 check prints `tls=true`, the doc says `tls=t`.
- Phase 3 does not say that running pods are unaffected, nor how to verify the new URL (see finding 3).
- No section on runtime-password rotation: order, the mandatory restart, the Ready-but-503 symptom.
- Erase-search SQL assumes `PGDATABASE=hoopdb` and names no password source for the SSM/ESO path.

Secrets
- Secret creation in the install guide is file-based; the ESO path is only in the chart README.
- No hand-written SecretStore/ExternalSecret example for chart versions before 0.7.57 (`secrets-eso/0*.yaml`).
- The handover to the chart's `externalSecrets` block is undocumented (`secrets-eso/HANDOVER.md`).
- Operator-side copies of DB passwords (used for setup) go stale after rotation.

Cluster and AWS
- No by-hand Ingress in any doc (`ingress/ingress.applied.yaml`); install steps 7 and 14 point at scripts.
- The LB controller helm command has no `--version`.
- The storage-class verify step expects EBS CSI pods before the add-on is installed.
- `examples/aws` does not exist at the release tag.
- `aws opensearch create-domain` rejects an access policy file that ends with a newline.
- `_plugins/_security/whoami` returns 401 on AWS; use `_plugins/_security/authinfo` to confirm the master identity.
- The docs name five ServiceAccounts; the chart renders no `agent-relay-alleyoop` ServiceAccount.
- Helm 3 is required by the documented commands; a default Helm 4 behaves differently (server-side apply).
- The image digest in `--set` style values must be quoted.
- relay-control logs `relation "organizations" does not exist` while its migrate Job runs (harmless, undocumented).

After install
- No script-only first-upload check (finding 5); the final check in the guide is server-side only.
- Desktop and headless-server pages do not say that self-hosted needs a site-specific build, or how to get one.
- `login.advertisesSync`: the session-read-api doc says false, the native-routing doc says true for caller-token
  sync; which one a desktop sign-in needs is unclear.

## Files

| Path | What |
| --- | --- |
| `secrets-eso/00-secretstore.yaml`, `01..05-externalsecret-*.yaml` | Variant A: exactly as applied with kubectl |
| `secrets-eso/values-externalsecrets.chart-0.7.57.yaml` | Variant B: values overlay for the chart's `externalSecrets` block |
| `secrets-eso/HANDOVER.md` | A to B handover paths, what Helm 3 and Helm 4 do, measured results |
| `ingress/ingress.applied.yaml` | Hand-written ALB Ingress (4 hosts, ACM certificate) |
| `db-setup/psql-pod.applied.yaml`, `dbsetup-externalsecret.yaml`, `snapshot.sql` | In-cluster psql pod, its setup Secret from SSM, the unrelated-database snapshot query |
| `iam/` | ESO policy, Pod Identity trust, upstream LB controller policy (v3.6.3), sessions/search policies and trusts, Pod Identity associations |
| `opensearch/` | `create-domain` call, access policy, the SigV4 role and role-mapping calls with their output |
| `cluster/` | Storage class, namespaces, and the LB controller / ESO install commands |

Cost of the stack while it runs: about 13 USD per day.
