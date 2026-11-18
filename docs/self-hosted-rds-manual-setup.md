# RDS database setup by hand (without rds-setup.sh)

`scripts/selfhost/rds-setup.sh` creates the Agent Relay databases and logins
on Amazon RDS for PostgreSQL. This page is the same procedure as explicit
commands, for operators who do not run the script. Every SQL statement below
is what the script runs, in the same order. The SQL reuses databases and roles
that already exist, but it sets every login's password: on a repeat run, use
the passwords you generated the first time (step 1.3), or every connection
string already deployed stops working. Pick one procedure per instance; to
switch from `rds-setup.sh`, take its passwords from
`~/.agent-relay-install/passwords/<role>` on the machine that ran it.

There are three phases:

1. **Before the Helm install:** CA bundle, passwords, three databases, their
   logins, and the HoopDb bootstrap.
2. **After the HoopDb migration Job succeeds:** activate three HoopDb logins.
3. **When RDS rotates the admin password:** update two connection strings.

## What you need

- One RDS for PostgreSQL instance (16 or later). One instance holds all three
  databases. It can hold only one HoopDb: the role
  `session_directory_search_worker` is server-wide.
- An admin login on that instance with `rds_superuser` and `CREATEROLE` (the
  RDS master user, or a dedicated login granted `rds_superuser`). This page
  calls it the admin login. It owns the HoopDb migrations.
- A machine that can reach the instance on port 5432 (VPN, bastion, or a pod
  in the cluster) with `psql` 16 or later, `openssl` and `curl`.
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
for r in control_owner control_api_runtime relaycast_owner relaycast_runtime \
         sessions_pipeline_runtime bulls96_read_api bulls96_session_ingest search_consumer_runtime; do
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
psql -X -A -t -d postgres -c "select (select count(*) from pg_database where datname='hoopdb') as hoopdb,
  (select count(*) from pg_roles where rolname='session_directory_search_worker') as search_role"
```

`0|1` means another install's HoopDb is on this instance: stop and use a
separate instance. `0|0` (fresh) or `1|1` (a re-run) are fine.

### 1.6 Create the three databases

```bash
for db in relaycontrol hoopdb relaycast; do
  printf '%s\n' "SELECT 'CREATE DATABASE $db' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='$db') \\gexec" \
    | psql -X -q -v ON_ERROR_STOP=1 -d postgres
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

### 1.9 hoopdb: extensions, roles and the runtime login

Run these in order, as the admin login, from the SQL directory of 1.4. Each
must finish without an error before the next.

```bash
export PGDATABASE=hoopdb
P="psql -X -q -v ON_ERROR_STOP=1"

$P -c 'CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public; CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public; CREATE EXTENSION IF NOT EXISTS btree_gin WITH SCHEMA public;'
$P -f rds_owner_function_default_revoke.sql
$P -c 'ALTER DEFAULT PRIVILEGES FOR ROLE rds_superuser REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC'
$P -f rds_migration_roles.sql
$P -v migration_owner="$PGUSER" -v runtime_role=sessions_pipeline_runtime -v runtime_login=true -f hoopdb_runtime_role_rds.sql
printf '%s\n' "ALTER ROLE sessions_pipeline_runtime PASSWORD :'p1';" | $P -v p1="$PW_sessions_pipeline_runtime"
$P -f session_directory_search_worker.sql
$P -f session_token_verifier.sql
$P -f session_ingest_roles.sql
$P -f session_read_api_roles.sql
$P -f session_consumer_roles.sql
$P -v post=false -f rds-session-erase-search.sql
unset PGDATABASE
```

Check:

```bash
psql -X -A -t -d hoopdb -c "select 'hoopdb owner: '||pg_get_userbyid(datdba) from pg_database where datname='hoopdb'"
psql -X -A -t -d hoopdb -c "select 'extensions: '||string_agg(extname,',' order by extname) from pg_extension"
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
| | `HOOPDB_URL` | `postgresql://sessions_pipeline_runtime:<pw>@<endpoint>:5432/hoopdb?sslmode=verify-full` |
| | `HOOPDB_MIGRATION_URL` | `postgresql://<admin login>:<admin pw>@<endpoint>:5432/hoopdb?sslmode=verify-full` |
| `agent-relay-ingest-edge-runtime` | `database-url` | `postgresql://bulls96_session_ingest:<pw>@<endpoint>:5432/hoopdb?sslmode=verify-full` |
| `agent-relay-read-api` | `RELAYHISTORY_READ_API_SECRET` | `{"supabase_url":"postgresql://bulls96_read_api:<pw>@<endpoint>:5432/hoopdb?sslmode=verify-full"}` |
| `search-indexer-runtime` | `RELAYHISTORY_PIPELINE_CONSUMER_SECRET` | `{"hoopdb_url":"postgresql://search_consumer_runtime:<pw>@<endpoint>:5432/hoopdb?sslmode=verify-full"}` |
| `search-indexer-owner` | `RELAYHISTORY_PIPELINE_CONSUMER_SECRET` | `{"hoopdb_url":"<the HOOPDB_MIGRATION_URL value>"}` |

The last three are JSON. The names `RELAYHISTORY` and `supabase_url` are
historical; all three are HoopDb logins on your RDS instance.

The `bulls96_read_api`, `bulls96_session_ingest` and `search_consumer_runtime`
logins are created in phase 2. Their URLs can be stored now; they only work
after phase 2.

The remaining keys of `agent-relay-secrets` (`selfhost-bootstrap-token`,
`selfhost-encryption-key`, `selfhost-setup-key`, `relaycast-internal-secret`,
`relaycast-workspace-bootstrap-secret`, `relaycontrol-introspect-secret`,
`session-read-api-secret`, `SUMMARY_MASTER_KEYS`) and
`agent-relay-ingest-edge-runtime`'s `introspect-secret` are listed in the
install guide's Secrets step. To load all of them from AWS SSM instead of
creating Secrets by hand, see "Secrets from AWS SSM Parameter Store" in
[the agent-relay chart README](https://github.com/AgentWorkforce/infra/blob/main/charts/agent-relay/README.md).

Then install with Helm as the install guide says.

## Phase 2: after the HoopDb migration Job succeeds

Wait until the release's HoopDb migrate Job has succeeded:

```bash
kubectl -n agent-relay get jobs -l app.kubernetes.io/component=hoopdb-migrate
```

`COMPLETIONS` must be `1/1` for the current Job. Then, with the settings of
1.1 and from the SQL directory of 1.4:

```bash
export PGDATABASE=hoopdb
P="psql -X -q -v ON_ERROR_STOP=1"

# Read API login
$P -f session_read_api_role.sql
printf '%s\n' "ALTER ROLE bulls96_read_api PASSWORD :'p1';" | $P -v p1="$PW_bulls96_read_api"
$P -c 'GRANT CONNECT ON DATABASE hoopdb TO bulls96_read_api'
$P -f session_read_api_role_verify.sql

# Ingest login
$P -f session_ingest_role.sql
printf '%s\n' "ALTER ROLE bulls96_session_ingest PASSWORD :'p1';" | $P -v p1="$PW_bulls96_session_ingest"
$P -c 'GRANT CONNECT ON DATABASE hoopdb TO bulls96_session_ingest'
$P -f session_ingest_role_verify.sql
$P -f session_ingest_verify.sql

# Search consumer login (the migrations created the role)
psql -X -A -t -c "select count(*) from pg_roles where rolname='search_consumer_runtime'"   # must print 1
printf '%s\n' "ALTER ROLE search_consumer_runtime LOGIN NOINHERIT PASSWORD :'p1'; ALTER ROLE search_consumer_runtime SET statement_timeout = '60s';" \
  | $P -v p1="$PW_search_consumer_runtime"
unset PGDATABASE
```

Prove each login connects over TLS:

```bash
for r in bulls96_read_api bulls96_session_ingest search_consumer_runtime; do
  pw_var="PW_$r"
  PGUSER="$r" PGPASSWORD="${!pw_var}" psql -X -A -t -d hoopdb \
    -c "select 'login ok: '||session_user||' tls='||(select ssl from pg_stat_ssl where pid=pg_backend_pid())"
done
```

Each line must read `login ok: <role> tls=t`. Then restart the three services
so they reconnect:

```bash
kubectl -n agent-relay rollout restart deploy/agent-relay-read-api deploy/agent-relay-ingest-edge deploy/agent-relay-search-indexer
```

Then finish the search bootstrap as the install guide says.

## Phase 3: when RDS rotates the admin password

`HOOPDB_MIGRATION_URL` and `search-indexer-owner` carry the admin password.
After RDS rotates it (every 7 days by default for a managed master password),
update both values before the next `helm upgrade`. No database change is
needed. If the values come from SSM through External Secrets Operator, force a
sync and check the ExternalSecret's `status.refreshTime` is after the update
before upgrading.

## Optional: the session-erase search login

Only for operator hard delete, which is off by default. After the search
bootstrap has completed, with the settings of 1.1 and a new password
`PW_bulls96_session_erase_search`:

```bash
PGDATABASE=hoopdb psql -X -q -v ON_ERROR_STOP=1 -v post=true -v p1="$PW_bulls96_session_erase_search" -f rds-session-erase-search.sql
```

Its URL (`postgresql://bulls96_session_erase_search:<pw>@<endpoint>:5432/hoopdb?sslmode=verify-full`)
goes in Secret `session-erase-search-runtime`, key
`SESSION_ERASE_SEARCH_POSTGRES_URL`.
