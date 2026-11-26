# RDS database setup by hand (without rds-setup.sh)

`scripts/selfhost/rds-setup.sh` creates the Agent Relay databases and logins
on Amazon RDS for PostgreSQL. This page is the same procedure as explicit
commands, for operators who do not run the script. The fresh-install activation
is deliberately one-shot and refuses an existing role graph. On later steps,
use the passwords you generated the first time (step 1.3), or every connection
string already deployed stops working. Pick one procedure per instance; to
switch from `rds-setup.sh`, take its passwords from
`~/.agent-relay-install/passwords/<role>` on the machine that ran it.

There are three phases:

1. **Before the Helm install:** CA bundle, passwords, three databases, their
   logins, and the HoopDb bootstrap.
2. **After the HoopDb migration Job succeeds:** activate three HoopDb logins.
3. **Existing installs only:** create one temporary administrator Job Secret
   before an upgrade or guide Job, then delete it.

## What you need

- One RDS for PostgreSQL instance, 16 or later (17 or 18 recommended). One instance holds all three
  databases. It can hold only one HoopDb: the role
  `session_directory_search_worker` is server-wide.
- An admin login on that instance with `rds_superuser` and `CREATEROLE` (the
  RDS master user, or a dedicated login granted `rds_superuser`). This page
  calls it the admin login. A fresh install uses it only for setup; the plain
  `hoopdb_owner` login owns the database and migrations afterwards.
- A machine that can reach the instance on port 5432 (VPN, bastion, or a pod
  in the cluster) with `psql` 16 or later, `openssl` and `curl`.
- `password_encryption` left at its default, `scram-sha-256`. PostgreSQL 18
  deprecates MD5 passwords and logs a warning for each one it sets.
- The services image your release pins, by digest: the `services-image` line
  under `x-pins` in your `values.yaml`, for example
  `ghcr.io/agentworkforce/sessions-pipeline@sha256:...`. The HoopDb SQL files
  ship inside it.
- `kubectl` access to the install namespace (`agent-relay`) for the CA
  ConfigMap.

## Phase 1: before the Helm install

### 1.1 Connection settings

The commands are for **bash** (run `bash` first if your shell is zsh, the macOS
default). Run every `psql` command below in that shell with these set. They verify the
server certificate, exactly as the services do.

```bash
export AWS_REGION=us-east-1                                   # your RDS region
export PGHOST=<instance>.<id>.<region>.rds.amazonaws.com       # the RDS endpoint, not an alias or IP
export PGPORT=5432
export PGUSER=<admin login>
export PGPASSWORD='<admin password>'
export PGSSLMODE=verify-full
export PGSSLROOTCERT="$PWD/rds-ca.pem"
export HOOPDB_DATABASE=<your HoopDb database name>
```

### 1.2 RDS CA bundle and the `rds-ca` ConfigMap

```bash
curl -fsS -o rds-ca.pem "https://truststore.pki.rds.amazonaws.com/$AWS_REGION/$AWS_REGION-bundle.pem"
grep -c 'BEGIN CERTIFICATE' rds-ca.pem                      # must be more than 0
kubectl create namespace agent-relay --dry-run=client -o yaml | kubectl apply -f -
kubectl -n agent-relay create configmap rds-ca --from-file=ca.crt=rds-ca.pem \
  --dry-run=client -o yaml | kubectl apply -f -
sha256sum rds-ca.pem | cut -d' ' -f1                        # macOS: shasum -a 256
```

The printed hash is the value for `__RDS_CA_SHA256__` in `values.yaml`.

### 1.3 Passwords

Generate one password per login, **once**. Use 48 hex characters: they need
no URL encoding. Store them where your connection strings will live (for
example AWS SSM SecureString parameters); never commit them. On any later run
of this page, export the stored passwords instead of generating new ones.

```bash
for r in control_owner control_api_runtime relaycast_owner relaycast_runtime hoopdb_owner \
         sessions_pipeline_runtime bulls96_read_api bulls96_session_ingest search_consumer_runtime \
         buffered_search_feed_runtime bulls96_acquisition_installer bulls96_analysis_admit \
         bulls96_digest_narrative bulls96_legacy_export_privacy bulls96_privacy_eraser \
         bulls96_project_events; do
  printf '%s=%s\n' "$r" "$(openssl rand -hex 24)"
done
```

Export them in your shell as `PW_<role>` for the commands below, e.g.
`export PW_control_owner=...`.

### 1.4 The HoopDb SQL files from the services image

The files are in `/app/supabase/bootstrap` in the image. Copy them out with
any OCI tool, for example:

```bash
IMAGE=ghcr.io/agentworkforce/sessions-pipeline@sha256:<digest from values.yaml>
mkdir -p hoopdb-sql
# With crane:
crane export --platform linux/amd64 "$IMAGE" - | tar -x -C hoopdb-sql app/supabase/bootstrap
# Or with Docker:
#   mkdir -p hoopdb-sql/app/supabase && docker create --name sql "$IMAGE" && docker cp sql:/app/supabase/bootstrap hoopdb-sql/app/supabase/ && docker rm sql
cd hoopdb-sql/app/supabase/bootstrap
ls rds_migration_roles.sql hoopdb_runtime_role_rds.sql session_ingest_roles.sql   # must all exist
```

Run the HoopDb commands below from this directory (one file includes another
by relative path). Also copy `scripts/selfhost/rds-session-erase-search.sql`
from this repository at your release tag into the same directory.

### 1.5 Refuse an instance that already has another HoopDb

```bash
psql -X -A -t -d postgres -v db="$HOOPDB_DATABASE" <<'SQL'
select (select count(*) from pg_database where datname=:'db') as hoopdb,
  (select count(*) from pg_roles where rolname='session_directory_search_worker') as search_role;
SQL
psql -X -A -t -d postgres <<'SQL' | grep -qx t || {
select current_setting('server_version_num')::int >= 160000;
SQL
  echo 'PostgreSQL 16 or later is required; no database or role was changed' >&2
  exit 1
}
```

`0|1` means another install's HoopDb is on this instance: stop and use a
separate instance. `0|0` (fresh) or `1|1` (a re-run) are fine.

### 1.6 Create the three databases

```bash
for db in relaycontrol "$HOOPDB_DATABASE" relaycast; do
  psql -X -q -v ON_ERROR_STOP=1 -d postgres -v db="$db" <<'SQL'
SELECT format('CREATE DATABASE %I', :'db')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname=:'db') \gexec
SQL
done
```

### 1.7 relaycontrol: owner and runtime logins

```bash
psql -X -q -v ON_ERROR_STOP=1 -d relaycontrol -v p1="$PW_control_owner" -v p2="$PW_control_api_runtime" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', r) FROM unnest(ARRAY['control_owner','control_api_runtime']) r WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=r) \gexec
ALTER ROLE control_owner PASSWORD :'p1';
ALTER ROLE control_api_runtime PASSWORD :'p2';
GRANT control_owner TO CURRENT_USER WITH SET TRUE;
ALTER DATABASE relaycontrol OWNER TO control_owner;
GRANT CONNECT ON DATABASE relaycontrol TO control_api_runtime;
SQL
```

### 1.8 relaycast: owner and runtime logins

```bash
psql -X -q -v ON_ERROR_STOP=1 -d relaycast -v p1="$PW_relaycast_owner" -v p2="$PW_relaycast_runtime" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', r) FROM unnest(ARRAY['relaycast_owner','relaycast_runtime']) r WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=r) \gexec
ALTER ROLE relaycast_owner PASSWORD :'p1';
ALTER ROLE relaycast_runtime PASSWORD :'p2';
GRANT relaycast_owner TO CURRENT_USER WITH SET TRUE;
ALTER SCHEMA public OWNER TO relaycast_owner;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO relaycast_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE relaycast_owner IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO relaycast_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE relaycast_owner IN SCHEMA public GRANT SELECT, USAGE, UPDATE ON SEQUENCES TO relaycast_runtime;
REVOKE TEMP, CREATE ON DATABASE relaycast FROM PUBLIC;
GRANT TEMP ON DATABASE relaycast TO relaycast_owner;
GRANT CONNECT ON DATABASE relaycast TO relaycast_owner, relaycast_runtime;
SQL
```

### 1.9 HoopDb: extensions and the membership-free owner graph

Fetch `scripts/selfhost/rds-hoopdb-activate.sql` from the same infra release as
this guide. It is the reviewed, database-name-agnostic activation used for the
by-hand path. It uses `current_database()` for the ownership handoff. The
disposable creator and all target roles are created and the creator is dropped
in one transaction. This reaches the same graph technique as upstream's
activation, but does not claim its fixed-name `rds-activation/v1` contract;
the released migrator's `separate-database` preflight is the acceptance check.

Run these in order as the admin login. Set `PGDATABASE` to the actual target
database; do not assume it is named `hoopdb`.

```bash
export PGDATABASE="$HOOPDB_DATABASE"
P="psql -X -q -v ON_ERROR_STOP=1"

$P -c 'CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public; CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public; CREATE EXTENSION IF NOT EXISTS btree_gin WITH SCHEMA public;'
$P -f rds_owner_function_default_revoke.sql
$P -c 'ALTER DEFAULT PRIVILEGES FOR ROLE rds_superuser REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC'
$P -v DBNAME="$PGDATABASE" \
  -v owner_password="$PW_hoopdb_owner" \
  -v runtime_password="$PW_sessions_pipeline_runtime" \
  -v search_password="$PW_search_consumer_runtime" \
  -v read_password="$PW_bulls96_read_api" \
  -v ingest_password="$PW_bulls96_session_ingest" \
  -v buffered_password="$PW_buffered_search_feed_runtime" \
  -v acquisition_password="$PW_bulls96_acquisition_installer" \
  -v analysis_password="$PW_bulls96_analysis_admit" \
  -v digest_password="$PW_bulls96_digest_narrative" \
  -v legacy_password="$PW_bulls96_legacy_export_privacy" \
  -v privacy_password="$PW_bulls96_privacy_eraser" \
  -v project_password="$PW_bulls96_project_events" \
  -f rds-hoopdb-activate.sql
unset PGDATABASE
```

Check:

```bash
psql -X -A -t -d "$HOOPDB_DATABASE" -c "select current_database(), pg_get_userbyid(datdba) from pg_database where datname=current_database()"
psql -X -A -t -d "$HOOPDB_DATABASE" -c "select rolsuper,rolcreaterole,rolcreatedb from pg_roles where rolname='hoopdb_owner'"
psql -X -A -t -d "$HOOPDB_DATABASE" -c "select string_agg(extname,',' order by extname) from pg_extension"
protected_edges="$(psql -X -A -t -d "$HOOPDB_DATABASE" <<'SQL'
with protected(name) as (values
  ('anon'),('authenticated'),('service_role'),('session_directory_search_worker'),
  ('session_token_verifier'),('bulls96_session_ingest_seeder'),
  ('bulls96_canonical_feature_producer'),('bulls96_babysitter_retention'),
  ('bulls96_session_erase_search'),('hoopdb_owner'),('sessions_pipeline_runtime'),
  ('search_consumer_runtime'),('bulls96_read_api'),('bulls96_session_ingest'),
  ('buffered_search_feed_runtime'),('bulls96_acquisition_installer'),
  ('bulls96_analysis_admit'),('bulls96_digest_narrative'),
  ('bulls96_legacy_export_privacy'),('bulls96_privacy_eraser'),
  ('bulls96_project_events'))
select count(*) from pg_auth_members m
join pg_roles granted on granted.oid=m.roleid
join pg_roles member on member.oid=m.member
where granted.rolname in (select name from protected)
   or member.rolname in (select name from protected);
SQL
)"
printf 'protected role membership edges: %s\n' "$protected_edges"
test "$protected_edges" = 0
```

The extensions line must include `btree_gin`, `pg_trgm` and `vector`.

### 1.10 The connection strings

Build one URL per login. Every URL ends in `?sslmode=verify-full`, uses the
RDS endpoint from 1.1, and port 5432. If the admin password has characters
other than letters and digits, percent-encode it (`@` is `%40`, `:` is `%3A`,
`/` is `%2F`, `#` is `%23`, `?` is `%3F`).

| Secret | Key | URL |
|---|---|---|
| `agent-relay-secrets` | `database-url` | `postgresql://control_api_runtime:<pw>@<endpoint>:5432/relaycontrol?sslmode=verify-full` |
| | `database-migrations-url` | `postgresql://control_owner:<pw>@<endpoint>:5432/relaycontrol?sslmode=verify-full` |
| | `database-runtime-url` | `postgres://relaycast_runtime:<pw>@<endpoint>:5432/relaycast?sslmode=verify-full` |
| | `database-owner-url` | `postgres://relaycast_owner:<pw>@<endpoint>:5432/relaycast?sslmode=verify-full` |
| | `HOOPDB_URL` | `postgresql://sessions_pipeline_runtime:<pw>@<endpoint>:5432/<HoopDb database>?sslmode=verify-full` |
| | `HOOPDB_MIGRATION_URL` | `postgresql://hoopdb_owner:<pw>@<endpoint>:5432/<HoopDb database>?sslmode=verify-full` |
| `agent-relay-ingest-edge-runtime` | `database-url` | `postgresql://bulls96_session_ingest:<pw>@<endpoint>:5432/<HoopDb database>?sslmode=verify-full` |
| `agent-relay-read-api` | `RELAYHISTORY_READ_API_SECRET` | `{"supabase_url":"postgresql://bulls96_read_api:<pw>@<endpoint>:5432/<HoopDb database>?sslmode=verify-full"}` |
| `search-indexer-runtime` | `RELAYHISTORY_PIPELINE_CONSUMER_SECRET` | `{"hoopdb_url":"postgresql://search_consumer_runtime:<pw>@<endpoint>:5432/<HoopDb database>?sslmode=verify-full"}` |
| `search-indexer-owner` | `RELAYHISTORY_PIPELINE_CONSUMER_SECRET` | `{"hoopdb_url":"<the HOOPDB_MIGRATION_URL value>"}` |

The last three are JSON. The names `RELAYHISTORY` and `supabase_url` are
historical; all three are HoopDb logins on your RDS instance.

The `bulls96_read_api`, `bulls96_session_ingest` and `search_consumer_runtime`
logins are created in phase 1 with no creator edges. Phase 2 grants their
object privileges after migrations create the objects.

The remaining keys of `agent-relay-secrets` (`selfhost-bootstrap-token`,
`selfhost-encryption-key`, `selfhost-setup-key`, `relaycast-internal-secret`,
`relaycast-workspace-bootstrap-secret`, `relaycontrol-introspect-secret`,
`session-read-api-secret`, `SUMMARY_MASTER_KEYS`) and
`agent-relay-ingest-edge-runtime`'s `introspect-secret` are listed in the
install guide's Secrets step. To load all of them from AWS SSM instead of
creating Secrets by hand, see "Secrets from AWS SSM Parameter Store" in
[the agent-relay chart README](https://github.com/AgentWorkforce/infra/blob/main/charts/agent-relay/README.md).

### 1.11 Select the fresh dedicated-owner migration layout

Save this non-secret values overlay and pass it after the site values, before
the release image overlay. It is the by-hand equivalent of the
`hoopdb-layout-values.yaml` that `rds-setup.sh pre` writes for a fresh install:

```yaml
sessions-pipeline:
  worker:
    migrations:
      hoopdb:
        existingSecret: agent-relay-secrets
        key: HOOPDB_MIGRATION_URL
      rdsLayout: separate-database
  searchIndexer:
    bootstrap:
      existingSecret: search-indexer-owner
      key: RELAYHISTORY_PIPELINE_CONSUMER_SECRET
```

Then install with Helm as the install guide says. Do not rely on a chart default
or an older site-values copy to select the layout: the migration Job must render
exactly one `HOOPDB_RDS_LAYOUT=separate-database` entry for this fresh
`hoopdb_owner` database.

### 1.12 Troubleshoot a refused migration profile

If the migrate Job logs `"error_code":"rds_profile_unproven"`, compare the
database owner with the rendered `HOOPDB_RDS_LAYOUT` before retrying:

- A database owned by `hoopdb_owner` needs `separate-database`; apply the fresh
  overlay above. Omitting the value selects the legacy preflight and refuses the
  plain owner.
- An administrator-owned database must not use `separate-database`; classify it
  with `rds-setup.sh pre` and apply the `master-owner` overlay in Phase 3.

The refusal occurs before migrations change the database. Do not grant
`CREATEROLE` or a provider-admin membership to make either mismatched render
pass.

## Phase 2: after the HoopDb migration Job succeeds

Wait until the release's HoopDb migrate Job has succeeded:

```bash
kubectl -n agent-relay get jobs -l app.kubernetes.io/component=hoopdb-migrate
```

`COMPLETIONS` must be `1/1` for the current Job. Then, with the settings of
1.1 and from the SQL directory of 1.4:

```bash
export PGDATABASE="$HOOPDB_DATABASE"
export PGUSER=hoopdb_owner
export PGPASSWORD="$PW_hoopdb_owner"
P="psql -X -q -v ON_ERROR_STOP=1"

# Read API login
sed '/^ALTER ROLE bulls96_read_api /d' session_read_api_role.sql | $P
printf "%s\n" "SELECT format('GRANT CONNECT ON DATABASE %I TO bulls96_read_api', current_database()) \\gexec" | $P
$P -f session_read_api_role_verify.sql

# Ingest login
sed '/^ALTER ROLE bulls96_session_ingest /d' session_ingest_role.sql | $P
printf "%s\n" "SELECT format('GRANT CONNECT ON DATABASE %I TO bulls96_session_ingest', current_database()) \\gexec" | $P
$P -f session_ingest_role_verify.sql
$P -f session_ingest_verify.sql

# Search consumer login (phase 1 created it)
psql -X -A -t -c "select count(*) from pg_roles where rolname='search_consumer_runtime'"   # must print 1
unset PGDATABASE
```

Prove each login connects over TLS:

```bash
for r in bulls96_read_api bulls96_session_ingest search_consumer_runtime; do
  pw_var="PW_$r"
  PGUSER="$r" PGPASSWORD="${!pw_var}" psql -X -A -t -d "$HOOPDB_DATABASE" \
    -c "select 'login ok: '||session_user||' tls='||(select ssl from pg_stat_ssl where pid=pg_backend_pid())"
done
```

Each line must read `login ok: <role> tls=t`. Then restart the three services
so they reconnect:

```bash
kubectl -n agent-relay rollout restart deploy/agent-relay-read-api deploy/agent-relay-ingest-edge deploy/agent-relay-search-indexer
```

Then finish the search bootstrap as the install guide says.

## Phase 3: existing administrator-owned installs

> **Upgrade gate:** both shared RDS profiles now default to
> `rdsLayout: separate-database` for fresh dedicated-owner installs. An existing
> administrator-owned database must apply the `master-owner` overlay below on
> its very first upgrade with these profiles or the migrator will refuse its
> layout. Run the setup classifier before rendering Helm values.

Ownership transfer for existing installs is a separate follow-up under #480.
Do not transfer ownership as part of this temporary-Secret upgrade flow.

Immediately before an upgrade or a guide Job, create Secret
`hoopdb-admin-jobs` with keys `HOOPDB_MIGRATION_URL` and
`RELAYHISTORY_PIPELINE_CONSUMER_SECRET`, point only the migrate/bootstrap Job
values at that Secret, and delete it after those Jobs complete. Remove the same
two keys from `agent-relay-secrets` and `search-indexer-owner` only after Helm,
the affected Jobs, and Deployments succeed. If the temporary Secret is absent,
the upgrade must stop before Helm changes anything. The fully scripted
equivalent is `agent-relay-upgrade.sh --rds-setup`, which prepares the
temporary Secret, waits for Helm/Jobs/Deployments, removes the two old keys,
and deletes the temporary Secret. If running Helm by hand, use
`rds-setup.sh prepare-admin-jobs`, then run the explicit key-removal block
below after success, followed by `rds-setup.sh delete-admin-jobs`.

Restrict who can read this temporary administrator Secret as described in
[Secret access](selfhost-secret-access.md); its short lifetime does not make
its contents less privileged.

For the by-hand flow, enter the current administrator URL without echoing it,
stage it in a private temporary directory, and create the Secret from files so
the credential never appears in process arguments:

```bash
umask 077
ADMIN_JOB_DIR="$(mktemp -d)"
read -r -s -p "Current administrator URL for $HOOPDB_DATABASE: " HOOPDB_ADMIN_URL; echo
printf '%s' "$HOOPDB_ADMIN_URL" >"$ADMIN_JOB_DIR/HOOPDB_MIGRATION_URL"
jq -n --rawfile u "$ADMIN_JOB_DIR/HOOPDB_MIGRATION_URL" '{hoopdb_url:$u}' \
  >"$ADMIN_JOB_DIR/RELAYHISTORY_PIPELINE_CONSUMER_SECRET"
unset HOOPDB_ADMIN_URL
kubectl -n agent-relay delete secret hoopdb-admin-jobs --ignore-not-found
kubectl -n agent-relay create secret generic hoopdb-admin-jobs \
  --from-file="$ADMIN_JOB_DIR"
```

Save this non-secret values overlay and pass it after the site values, before
the release image overlay, to the upgrade or guide Job:

```yaml
sessions-pipeline:
  worker:
    migrations:
      hoopdb:
        existingSecret: hoopdb-admin-jobs
        key: HOOPDB_MIGRATION_URL
      rdsLayout: master-owner
  searchIndexer:
    bootstrap:
      existingSecret: hoopdb-admin-jobs
      key: RELAYHISTORY_PIPELINE_CONSUMER_SECRET
```

Guard the Helm command with `kubectl -n agent-relay get secret
hoopdb-admin-jobs >/dev/null || exit 1`; this is the fail-before-change check.
After Helm, all migration/bootstrap Jobs, and Deployments succeed, remove the
old long-lived keys, then delete the temporary credential and local staging
directory. A failed upgrade skips this block, retains the old keys for the
previous revision, and deletes only `hoopdb-admin-jobs`.

If either long-lived Secret is owned by an `ExternalSecret` or has the
`reconcile.external-secrets.io/managed` label, do not run a Kubernetes patch.
The loop below stops and names the key: remove that mapping from the
Helm release values used for later upgrades and from the live ExternalSecret,
delete its backing-store value, wait for reconciliation, then retry cleanup.
Keep `hoopdb-admin-jobs` until this succeeds. The loop checks the mapping even
when the generated Secret or key is already absent, so ESO cannot restore it.
If an ExternalSecret uses `dataFrom`, the loop deliberately treats that import
as potentially containing either administrator key because Kubernetes cannot
show which remote keys it may produce later. Replace that `dataFrom` entry with
equivalent explicit `data` mappings for the runtime keys you still need,
excluding the administrator key, wait for reconciliation, and rerun cleanup;
do not delete or replace unrelated runtime values. The guard also checks
explicit output keys in `spec.target.template.data`. Any `templateFrom` entry
is treated as unknown until it is removed or replaced with inspectable explicit
outputs.

```bash
for pair in agent-relay-secrets:HOOPDB_MIGRATION_URL \
            search-indexer-owner:RELAYHISTORY_PIPELINE_CONSUMER_SECRET; do
  secret="${pair%%:*}"; key="${pair#*:}"
  if ! kubectl -n agent-relay get secret "$secret" --ignore-not-found -o json \
      >"$ADMIN_JOB_DIR/$secret.json"; then
    echo "could not read $secret; leave hoopdb-admin-jobs in place and retry cleanup" >&2
    exit 1
  fi
  if [ -s "$ADMIN_JOB_DIR/$secret.json" ]; then
    key_present=$(jq -r --arg k "$key" 'if .data[$k] == null then "no" else "yes" end' \
      "$ADMIN_JOB_DIR/$secret.json") || exit 1
    externally_managed=$(jq -r '
        any(.metadata.ownerReferences[]?; .kind == "ExternalSecret") or
        ((.metadata.labels // {}) | has("reconcile.external-secrets.io/managed"))' \
        "$ADMIN_JOB_DIR/$secret.json") || exit 1
  else
    key_present=no; externally_managed=false
  fi
  if kubectl -n agent-relay get externalsecrets.external-secrets.io --ignore-not-found -o json \
      >"$ADMIN_JOB_DIR/externalsecrets.json" 2>"$ADMIN_JOB_DIR/externalsecrets.err"; then
    mapping_rc=0
    jq -e --arg target "$secret" --arg key "$key" '
        any(.items[]?; ((.spec.target.name // .metadata.name) == $target) and
          (any(.spec.data[]?; .secretKey == $key) or
           ((.spec.dataFrom // []) | length > 0) or
           ((.spec.target.template.data // {}) | has($key)) or
           ((.spec.target.template.templateFrom // []) | length > 0) or
           ((.spec.target.templateFrom // []) | length > 0)))' \
        "$ADMIN_JOB_DIR/externalsecrets.json" >/dev/null || mapping_rc=$?
    if [ "$mapping_rc" = 0 ]; then
      echo "External Secrets still maps $secret/$key: remove it from the Helm release values, ExternalSecret and backing store; leave hoopdb-admin-jobs in place" >&2
      exit 1
    elif [ "$mapping_rc" != 1 ]; then
      echo "could not parse ExternalSecret mappings; leave hoopdb-admin-jobs in place" >&2
      exit 1
    fi
  elif ! grep -Eqi "(doesn't have a resource type|could not find the requested resource|no matches for kind.*ExternalSecret)" \
      "$ADMIN_JOB_DIR/externalsecrets.err"; then
    echo "could not inspect ExternalSecret mappings; leave hoopdb-admin-jobs in place" >&2
    exit 1
  fi
  [ "$key_present" = no ] && continue
  if [ "$externally_managed" = true ]; then
    echo "$secret is managed by External Secrets: remove the $key mapping from its Helm release values and ExternalSecret and delete the backing-store value, wait for reconciliation, and retry; leave hoopdb-admin-jobs in place" >&2
    exit 1
  fi
  if ! kubectl -n agent-relay patch secret "$secret" --type=json \
    -p="[{\"op\":\"remove\",\"path\":\"/data/$key\"}]"; then
    echo "could not remove $key from $secret; leave hoopdb-admin-jobs and $ADMIN_JOB_DIR in place and retry cleanup" >&2
    exit 1
  fi
done
kubectl -n agent-relay delete secret hoopdb-admin-jobs
rm -r -- "$ADMIN_JOB_DIR"
```

Verify after deletion:

```bash
kubectl -n agent-relay get secret hoopdb-admin-jobs --ignore-not-found
kubectl -n agent-relay get secret agent-relay-secrets -o json | jq -e '.data.HOOPDB_MIGRATION_URL == null'
kubectl -n agent-relay get secret search-indexer-owner -o json | jq -e '.data.RELAYHISTORY_PIPELINE_CONSUMER_SECRET == null'
```

Rollback after a failed upgrade: delete only `hoopdb-admin-jobs`; the old keys
remain for the previous revision. After successful cleanup, a rollback to a
revision that references the old keys must restore those keys from the staged
files before `helm rollback` (re-enter the URL if the directory was removed).
First inspect the selected revision: `helm -n agent-relay get manifest
agent-relay --revision <revision>`. Stage the Secret names and keys that its
Jobs already reference; `helm rollback` cannot accept a values overlay.

For unmanaged Secrets, `agent-relay-secrets` must already exist because it
contains unrelated runtime keys. An absent `search-indexer-owner` may be
recreated from the staged file. Stop and use the ExternalSecret and backing
store instead if either target is ESO-managed or mapped by ESO:

```bash
kubectl -n agent-relay get secret agent-relay-secrets >/dev/null || {
  echo 'restore the complete agent-relay-secrets for the target revision first' >&2
  exit 1
}
if ! kubectl -n agent-relay get secret search-indexer-owner --ignore-not-found -o name \
    >"$ADMIN_JOB_DIR/search-secret-name"; then
  echo 'could not inspect search-indexer-owner; no rollback Secret was changed' >&2
  exit 1
fi
jq -n --rawfile u "$ADMIN_JOB_DIR/HOOPDB_MIGRATION_URL" \
  '{data:{HOOPDB_MIGRATION_URL:($u|@base64)}}' >"$ADMIN_JOB_DIR/migration-patch.json"
kubectl -n agent-relay patch secret agent-relay-secrets --type=merge \
  --patch-file="$ADMIN_JOB_DIR/migration-patch.json"
if [ -s "$ADMIN_JOB_DIR/search-secret-name" ]; then
  jq -n --rawfile u "$ADMIN_JOB_DIR/RELAYHISTORY_PIPELINE_CONSUMER_SECRET" \
    '{data:{RELAYHISTORY_PIPELINE_CONSUMER_SECRET:($u|@base64)}}' >"$ADMIN_JOB_DIR/search-patch.json"
  kubectl -n agent-relay patch secret search-indexer-owner --type=merge \
    --patch-file="$ADMIN_JOB_DIR/search-patch.json"
else
  kubectl -n agent-relay create secret generic search-indexer-owner \
    --from-file="RELAYHISTORY_PIPELINE_CONSUMER_SECRET=$ADMIN_JOB_DIR/RELAYHISTORY_PIPELINE_CONSUMER_SECRET"
fi
```

Recreate `hoopdb-admin-jobs` only if the selected revision already references
it. The values overlay above is only for Jobs rendered separately; it cannot
change a saved Helm revision. Keep the restored long-lived keys while that
rollback revision is active. Only after it has been replaced or removed,
remove the two keys with the cleanup loop above and delete
`hoopdb-admin-jobs` again; finishing its initial Jobs alone is not sufficient.
For ESO-managed Secrets, make the temporary restore and removal through the
target revision's ExternalSecrets and backing store; never patch the generated
Secrets.
Long-running pods do not use this Secret and are unaffected by its creation or
deletion. The database stays administrator-owned; verify without assuming its
name with `psql -X -A -t -d "$HOOPDB_DATABASE" -c 'select
current_database(),pg_get_userbyid(datdba) from pg_database where
datname=current_database()'`. The second column must be the expected provider
administrator role, not merely the login used for the check.

## Optional: the session-erase search login

Only for operator hard delete, which is off by default. After the search
bootstrap has completed, with the settings of 1.1 and a new password
`PW_bulls96_session_erase_search`:

```bash
sed 's/^GRANT CONNECT ON DATABASE hoopdb TO bulls96_session_erase_search;$/GRANT CONNECT ON DATABASE :"DBNAME" TO bulls96_session_erase_search;/' \
  rds-session-erase-search.sql \
  | PGDATABASE="$HOOPDB_DATABASE" psql -X -q -v ON_ERROR_STOP=1 \
      -v DBNAME="$HOOPDB_DATABASE" -v post=true -v p1="$PW_bulls96_session_erase_search"
```

Its URL (`postgresql://bulls96_session_erase_search:<pw>@<endpoint>:5432/<HoopDb database>?sslmode=verify-full`)
goes in Secret `session-erase-search-runtime`, key
`SESSION_ERASE_SEARCH_POSTGRES_URL`.
