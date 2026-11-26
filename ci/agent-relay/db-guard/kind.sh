#!/usr/bin/env bash
# End-to-end test of databaseGuard (charts/agent-relay/templates/db-guard.yaml)
# on kind, against an RDS-shaped PostgreSQL with TLS:
#   - the only SUPERUSER is rdsadmin; the master login "postgres" has
#     CREATEROLE and CREATEDB and is a member of a NOLOGIN rds_superuser
#     (as scripts/selfhost/tests/rds-setup-postgres-test.sh models it);
#   - the server certificate is signed by a test CA served as the rds-ca
#     ConfigMap, and every login connects with verify-full, as on RDS.
# Render-time guard cases use real helm install/upgrade (lookup needs a live
# cluster); --dry-run=server shows what the real install would refuse without
# leaving a release behind. Hook cases run the real pre-install Job.
#
#   ci/agent-relay/db-guard/kind.sh            # creates kind cluster ar-dbguard
#   KEEP_CLUSTER=1 ci/agent-relay/db-guard/kind.sh
#
# Needs docker, kind, kubectl, helm, openssl, yq. The relaycast-self-host image
# is pulled by the kind node from ghcr.io.
set -euo pipefail
cd "$(dirname "$0")/../../.."
CLUSTER="${CLUSTER:-ar-dbguard}"
NS=agent-relay
PG="ar-dbguard-pg-$$"
PG_IMAGE="${PG_IMAGE:-pgvector/pgvector@sha256:38681dc6eaf55308e2a4c6de392d131652dcfac70e1263e35cd9b5ea3fe39782}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ar-dbguard.XXXXXX")"
CTX="kind-$CLUSTER"
k() { kubectl --context "$CTX" -n "$NS" "$@"; }
pass=0
ok() { pass=$((pass + 1)); printf 'ok %d - %s\n' "$pass" "$*"; }
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
cleanup() {
  docker rm -fv "$PG" >/dev/null 2>&1 || true
  [[ "${KEEP_CLUSTER:-0}" == 1 ]] || kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --wait 120s >/dev/null
# A kept cluster (KEEP_CLUSTER=1) may hold an earlier run's release.
helm --kube-context "$CTX" uninstall agent-relay -n "$NS" --wait >/dev/null 2>&1 || true
kubectl --context "$CTX" delete namespace "$NS" --ignore-not-found --wait=true >/dev/null
kubectl --context "$CTX" create namespace "$NS" --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null

# --- RDS-shaped PostgreSQL on the kind Docker network, TLS with a test CA ---
docker run -d --name "$PG" --network kind -e POSTGRES_USER=rdsadmin -e POSTGRES_PASSWORD="$(openssl rand -hex 12)" \
  "$PG_IMAGE" -c password_encryption=scram-sha-256 >/dev/null
for i in $(seq 1 60); do
  docker exec "$PG" pg_isready -h 127.0.0.1 -U rdsadmin -d postgres >/dev/null 2>&1 && break
  [[ "$i" != 60 ]] || fail "postgres did not start"; sleep 1
done
HOST="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' "$PG")"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=ar-dbguard test CA" \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
  -keyout "$WORK/ca.key" -out "$WORK/ca.crt" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=$HOST" -keyout "$WORK/server.key" -out "$WORK/server.csr" 2>/dev/null
printf 'subjectAltName=IP:%s\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' "$HOST" >"$WORK/ext"
openssl x509 -req -in "$WORK/server.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" -CAcreateserial -days 2 \
  -extfile "$WORK/ext" -out "$WORK/server.crt" 2>/dev/null
docker cp "$WORK/server.crt" "$PG:/var/lib/postgresql/server.crt"
docker cp "$WORK/server.key" "$PG:/var/lib/postgresql/server.key"
docker exec -u root "$PG" sh -c 'chown postgres /var/lib/postgresql/server.* && chmod 600 /var/lib/postgresql/server.key'
su() { docker exec -i "$PG" psql -X -q -v ON_ERROR_STOP=1 -U rdsadmin -At "$@"; }
su -d postgres >/dev/null <<'SQL'
ALTER SYSTEM SET ssl = on;
ALTER SYSTEM SET ssl_cert_file = '/var/lib/postgresql/server.crt';
ALTER SYSTEM SET ssl_key_file = '/var/lib/postgresql/server.key';
SELECT pg_reload_conf();
SQL

mkdir -p "$WORK/pw"
for r in postgres custom_admin control_owner control_api_runtime relaycast_owner relaycast_runtime hoopdb_owner \
         sessions_pipeline_runtime bulls96_read_api bulls96_session_ingest search_consumer_runtime; do
  openssl rand -hex 16 | tr -d '\n' >"$WORK/pw/$r"
done
pw() { cat "$WORK/pw/$1"; }
# The RDS model, then the dedicated logins scripts/selfhost/rds-setup.sh pre creates.
su -d postgres >/dev/null <<SQL
CREATE ROLE rds_superuser NOLOGIN;
GRANT pg_monitor, pg_signal_backend, pg_read_all_settings, pg_read_all_stats TO rds_superuser WITH ADMIN OPTION;
CREATE ROLE postgres LOGIN CREATEROLE CREATEDB PASSWORD '$(pw postgres)';
GRANT rds_superuser TO postgres WITH ADMIN OPTION;
GRANT ALL ON DATABASE postgres TO rds_superuser;
-- A second administrator whose name the render-time check does not know.
CREATE ROLE custom_admin LOGIN CREATEROLE PASSWORD '$(pw custom_admin)';
GRANT rds_superuser TO custom_admin;
CREATE DATABASE relaycontrol; CREATE DATABASE relaycast; CREATE DATABASE hoopdb;
CREATE ROLE control_owner LOGIN PASSWORD '$(pw control_owner)';
CREATE ROLE control_api_runtime LOGIN PASSWORD '$(pw control_api_runtime)';
ALTER DATABASE relaycontrol OWNER TO control_owner;
GRANT CONNECT ON DATABASE relaycontrol TO control_api_runtime;
CREATE ROLE relaycast_owner LOGIN PASSWORD '$(pw relaycast_owner)';
CREATE ROLE relaycast_runtime LOGIN PASSWORD '$(pw relaycast_runtime)';
CREATE ROLE hoopdb_owner LOGIN NOINHERIT PASSWORD '$(pw hoopdb_owner)';
ALTER DATABASE hoopdb OWNER TO hoopdb_owner;
SQL
for r in sessions_pipeline_runtime bulls96_read_api bulls96_session_ingest search_consumer_runtime; do
  su -d postgres -c "CREATE ROLE $r LOGIN NOINHERIT PASSWORD '$(pw $r)'" >/dev/null
done
su -d relaycast >/dev/null <<'SQL'
ALTER SCHEMA public OWNER TO relaycast_owner;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO relaycast_runtime;
REVOKE ALL ON DATABASE relaycast FROM PUBLIC;
GRANT TEMP ON DATABASE relaycast TO relaycast_owner;
GRANT CONNECT ON DATABASE relaycast TO relaycast_owner, relaycast_runtime;
SQL
ok "RDS-shaped PostgreSQL with TLS at $HOST and the dedicated service logins"

k create configmap rds-ca --from-file=ca.crt="$WORK/ca.crt" --dry-run=client -o yaml | k apply -f - >/dev/null
url() { printf 'postgresql://%s:%s@%s:5432/%s?sslmode=verify-full' "$1" "${3:-$(pw "$1")}" "$HOST" "$2"; }
json() { printf '{"%s":"%s"}' "$1" "$2"; }
# write_secrets <role for every URL, or empty for the dedicated logins>
write_secrets() {
  local m="${1:-}"
  r() { [[ -n "$m" ]] && printf '%s' "$m" || printf '%s' "$1"; }
  k create secret generic agent-relay-secrets \
    --from-literal=database-url="$(url "$(r control_api_runtime)" relaycontrol)" \
    --from-literal=database-migrations-url="$(url "$(r control_owner)" relaycontrol)" \
    --from-literal=HOOPDB_URL="$(url "$(r sessions_pipeline_runtime)" hoopdb)" \
    --from-literal=HOOPDB_MIGRATION_URL="$(url "$(r hoopdb_owner)" hoopdb)" \
    --from-literal=database-owner-url="$(url "$(r relaycast_owner)" relaycast)" \
    --from-literal=database-runtime-url="$(url "$(r relaycast_runtime)" relaycast)" \
    --from-literal=selfhost-bootstrap-token=x --from-literal=selfhost-setup-key=x \
    --from-literal=selfhost-encryption-key=x --from-literal=relaycast-internal-secret=x \
    --from-literal=relaycast-workspace-bootstrap-secret=x --from-literal=relaycontrol-introspect-secret=x \
    --from-literal=session-read-api-secret=x --from-literal=SUMMARY_MASTER_KEYS=k1:x \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  k create secret generic agent-relay-read-api --from-literal=RELAYHISTORY_READ_API_SECRET="$(json supabase_url "$(url "$(r bulls96_read_api)" hoopdb)")" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  k create secret generic agent-relay-ingest-edge-runtime --from-literal=database-url="$(url "$(r bulls96_session_ingest)" hoopdb)" \
    --from-literal=introspect-secret=x --dry-run=client -o yaml | k apply -f - >/dev/null
  k create secret generic search-indexer-runtime --from-literal=RELAYHISTORY_PIPELINE_CONSUMER_SECRET="$(json hoopdb_url "$(url "$(r search_consumer_runtime)" hoopdb)")" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  k create secret generic search-indexer-owner --from-literal=RELAYHISTORY_PIPELINE_CONSUMER_SECRET="$(json hoopdb_url "$(url "$(r hoopdb_owner)" hoopdb)")" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
}
set_key() { # secret key value
  k patch secret "$1" --type merge -p "$(jq -n --arg k "$2" --arg v "$3" '{stringData: {($k): $v}}')" >/dev/null
}

CHART=charts/agent-relay
VALUES=(-f "$CHART/values-eks.yaml" -f "$CHART/values-eks-native.yaml" -f examples/aws/values.yaml)
helm_run() { helm --kube-context "$CTX" "$@" agent-relay "$CHART" -n "$NS" "${VALUES[@]}" --timeout 4m; }
expect_refused() { # name grep-pattern... ; runs helm install --dry-run=server
  local name="$1"; shift
  if helm_run install --dry-run=server >"$WORK/out" 2>&1; then cat "$WORK/out" >&2; fail "$name: helm accepted it"; fi
  for p in "$@"; do grep -qF -- "$p" "$WORK/out" || { cat "$WORK/out" >&2; fail "$name: output lacks: $p"; }; done
  ! grep -Eq 'postgres(ql)?://[^ ]*:[0-9a-f]{32}@' "$WORK/out" || fail "$name: a password reached the output"
  ok "$name"
}

# 1. Every URL logs in as the RDS master (the Automation Anywhere rehearsal).
write_secrets postgres
expect_refused "render guard refuses the master login in every URL" \
  'AR_DB_LOGIN: the database credentials' \
  'agent-relay-secrets: database-url logs in as "postgres" (a database master/administrator login). Each service needs its own login.' \
  'search-indexer-owner: RELAYHISTORY_PIPELINE_CONSUMER_SECRET logs in as "postgres"' \
  'Run scripts/selfhost/configure-rds.sh'
[[ "$(grep -c 'logs in as "postgres"' "$WORK/out")" == 10 ]] || fail "expected all 10 URLs reported"
sed -n '/AR_DB_LOGIN/,$p' "$WORK/out" >"$WORK/master-message.txt"
helm --kube-context "$CTX" status agent-relay -n "$NS" >/dev/null 2>&1 && fail "a release exists after a refused install"
ok "the refused install left no release"

# 1b. The same refusal for an operator bound only to the documented
# namespace-scoped Role (docs/selfhost-secret-access.md): the live-render probe
# and every lookup are namespaced.
awk '/^```yaml$/{f=1;next} f&&/^---$/{exit} f' docs/selfhost-secret-access.md >"$WORK/operator-role.yaml"
k apply -f "$WORK/operator-role.yaml" >/dev/null
k create serviceaccount ar-operator --dry-run=client -o yaml | k apply -f - >/dev/null
k create rolebinding ar-operator --role=agent-relay-operator --serviceaccount="$NS:ar-operator" --dry-run=client -o yaml | k apply -f - >/dev/null
kubectl config view --raw --minify --context "$CTX" -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d >"$WORK/kube-ca.crt"
OPERATOR=(--kube-apiserver "$(kubectl config view --raw --minify --context "$CTX" -o jsonpath='{.clusters[0].cluster.server}')"
  --kube-ca-file "$WORK/kube-ca.crt" --kube-token "$(k create token ar-operator --duration 1h)")
if helm "${OPERATOR[@]}" install agent-relay "$CHART" -n "$NS" "${VALUES[@]}" --dry-run=server >"$WORK/out" 2>&1; then
  fail "operator Role: helm accepted the master login"
fi
grep -qF 'agent-relay-secrets: database-url logs in as "postgres"' "$WORK/out" || { cat "$WORK/out" >&2; fail "operator Role: the guard did not run (forbidden lookup?)"; }
! grep -qi forbidden "$WORK/out" || { cat "$WORK/out" >&2; fail "operator Role: a lookup was forbidden"; }
ok "render guard works for the documented namespace-scoped operator Role"

# 2. No-op without a cluster: helm template and client dry-run accept the same Secrets.
helm template agent-relay "$CHART" -n "$NS" "${VALUES[@]}" >/dev/null || fail "helm template failed"
helm_run install --dry-run >/dev/null 2>&1 || helm_run install --dry-run=client >/dev/null || fail "client dry-run failed"
ok "helm template and --dry-run (client) are a no-op"

# 3. Opt-out.
helm --kube-context "$CTX" install agent-relay "$CHART" -n "$NS" "${VALUES[@]}" --set databaseGuard.enabled=false \
  --dry-run=server >/dev/null || fail "databaseGuard.enabled=false still refused"
ok "databaseGuard.enabled=false renders"

# 4. Shared login: the relay-control runtime uses its owner's login.
write_secrets
set_key agent-relay-secrets database-url "$(url control_owner relaycontrol)"
expect_refused "render guard refuses an owner and runtime sharing a login" \
  'agent-relay-secrets: database-url and agent-relay-secrets: database-migrations-url both log in as "control_owner"; the relay-control runtime and the relay-control migrations owner need different logins.'

# 5. Shape: 04 holds a bare URL.
write_secrets
set_key search-indexer-runtime RELAYHISTORY_PIPELINE_CONSUMER_SECRET "$(url search_consumer_runtime hoopdb)"
expect_refused "render guard refuses a bare URL in search-indexer-runtime" \
  'search-indexer-runtime: RELAYHISTORY_PIPELINE_CONSUMER_SECRET holds a bare URL; it must be JSON {"hoopdb_url":"postgresql://..."}.'

# 6. A required Secret is missing.
write_secrets
k delete secret search-indexer-owner >/dev/null
expect_refused "render guard refuses a missing Secret" \
  'search-indexer-owner: Secret "search-indexer-owner" does not exist in namespace "agent-relay"'

# 6b. A URL with a login but no host.
write_secrets
set_key agent-relay-ingest-edge-runtime database-url "postgresql://bulls96_session_ingest:$(pw bulls96_session_ingest)@/hoopdb"
expect_refused "render guard refuses a URL without a host" \
  'agent-relay-ingest-edge-runtime: database-url names no database host in its URL.'

# 6c. One Secret key read as both the search runtime and the HoopDb owner.
write_secrets
helm_run install --dry-run=server --set sessions-pipeline.searchIndexer.bootstrap.existingSecret=search-indexer-runtime >"$WORK/out" 2>&1 \
  && fail "shared search runtime/owner key accepted"
grep -qF 'both log in as "search_consumer_runtime"; the search indexer runtime and the HoopDb owner need different logins.' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "shared key across roles not reported"; }
ok "render guard refuses one Secret key used for two roles"

# 6d. relay-control migrations off: its owner URL is not this release's to hold.
write_secrets
k patch secret agent-relay-secrets --type json -p '[{"op":"remove","path":"/data/database-migrations-url"}]' >/dev/null
helm_run install --dry-run=server --set relay-control.migrations.enabled=false >/dev/null \
  || fail "relay-control.migrations.enabled=false still required the migrations URL"
ok "relay-control migrations off: the migrations URL is not required"

# 7. Legacy administrator-owned HoopDb: the owner may be the master.
write_secrets
set_key agent-relay-secrets HOOPDB_MIGRATION_URL "$(url postgres hoopdb)"
set_key search-indexer-owner RELAYHISTORY_PIPELINE_CONSUMER_SECRET "$(json hoopdb_url "$(url postgres hoopdb)")"
helm_run install --dry-run=server --set sessions-pipeline.worker.migrations.rdsLayout=master-owner >/dev/null \
  || fail "legacy master-owner layout refused"
ok "legacy master-owner layout may use the master for the HoopDb owner"

# 8. Hook: an administrator the render check cannot name; the live privilege check catches it.
write_secrets
set_key agent-relay-secrets database-url "$(url custom_admin relaycontrol)"
if helm_run install >"$WORK/out" 2>&1; then fail "hook let custom_admin through"; fi
grep -q 'pre-install' "$WORK/out" || { cat "$WORK/out" >&2; fail "helm error does not name the pre-install hook"; }
k logs job/agent-relay-db-guard >"$WORK/hook.log" 2>&1 || true
grep -qF 'agent-relay-secrets: database-url logs in as "custom_admin", which has CREATEROLE' "$WORK/hook.log" \
  || { cat "$WORK/out" "$WORK/hook.log" >&2; fail "hook log lacks the custom_admin reason"; }
grep -qF 'AR_DB_LOGIN' "$WORK/hook.log" || fail "hook log lacks AR_DB_LOGIN"
[[ -z "$(k get deploy -o name 2>/dev/null)" ]] || fail "workloads were created after the hook failed"
cp "$WORK/out" "$WORK/hook-helm-error.txt"; cp "$WORK/hook.log" "$WORK/hook-custom-admin.log"
ok "pre-install hook refuses an administrator login and nothing is deployed"
helm --kube-context "$CTX" uninstall agent-relay -n "$NS" >/dev/null 2>&1 || true

# 9. Hook: a login whose password differs from the Secret.
write_secrets
set_key agent-relay-ingest-edge-runtime database-url "$(url bulls96_session_ingest hoopdb 00000000000000000000000000000000)"
if helm_run install >"$WORK/out" 2>&1; then fail "hook let a wrong password through"; fi
k logs job/agent-relay-db-guard >"$WORK/hook.log" 2>&1 || true
grep -qF 'login "bulls96_session_ingest" was refused (password authentication failed)' "$WORK/hook.log" \
  || { cat "$WORK/hook.log" >&2; fail "hook log lacks the password reason"; }
ok "pre-install hook reports a wrong password"
helm --kube-context "$CTX" uninstall agent-relay -n "$NS" >/dev/null 2>&1 || true

# 10. Correct Secrets: the hook verifies every login over verify-full TLS and the install proceeds.
write_secrets
k delete job agent-relay-db-guard --ignore-not-found >/dev/null
helm_run install --set databaseGuard.statusTest.rbac.create=true >"$WORK/out" 2>&1 || { cat "$WORK/out" >&2; k logs job/agent-relay-db-guard >&2 || true; fail "install with correct Secrets failed"; }
k get job agent-relay-db-guard >/dev/null 2>&1 && fail "the succeeded hook Job was not deleted"
ok "install with the dedicated logins passes the render guard and the TLS privilege hook"

# 11b. helm test prints the status table. After a HoopDb migration but before
# rds-setup.sh post, the search runtime has no USAGE on sessions (the rehearsal's
# "permission denied for schema sessions" crash loop): only that row fails. The
# example caSha256 is not this test CA's, so the CA row must say so.
docker exec -i "$PG" psql -X -q -v ON_ERROR_STOP=1 -U rdsadmin -d hoopdb >/dev/null <<'SQL'
SET ROLE hoopdb_owner;
CREATE SCHEMA IF NOT EXISTS sessions;
GRANT USAGE ON SCHEMA sessions TO sessions_pipeline_runtime, bulls96_read_api, bulls96_session_ingest;
SQL
helm --kube-context "$CTX" test agent-relay -n "$NS" --logs --timeout 3m >"$WORK/status.txt" 2>&1 || true
grep -q '^  AREA  *CHECK  *STATUS  DETAIL' "$WORK/status.txt" || { cat "$WORK/status.txt" >&2; fail "helm test printed no status table"; }
[[ "$(grep -c '^POD LOGS' "$WORK/status.txt")" == 1 ]] || fail "helm test should run exactly one test Pod"
[[ "$(grep -cE '^  database  .* ok  ' "$WORK/status.txt")" == 9 ]] || { cat "$WORK/status.txt" >&2; fail "status table: expected 9 database rows ok"; }
grep -E '^  database  +search-indexer-runtime: ' "$WORK/status.txt" | grep -q 'FAIL  .*no USAGE on schema sessions.*rds-setup.sh post' \
  || { cat "$WORK/status.txt" >&2; fail "status table: search runtime without sessions USAGE not flagged"; }
grep -qE '^  ca  .*configMap/rds-ca  .*FAIL  .*differs from the configured 9f2c4e1a' "$WORK/status.txt" || { cat "$WORK/status.txt" >&2; fail "status table: CA sha256 mismatch not reported"; }
for area in migrations workloads s3 search; do
  grep -qE "^  $area  " "$WORK/status.txt" || { cat "$WORK/status.txt" >&2; fail "status table lacks a $area row"; }
done
grep -qE '^  migrations  +relaycast-migrate ' "$WORK/status.txt" || { cat "$WORK/status.txt" >&2; fail "status table: no per-Job migrations row with rbac.create"; }
grep -q '^UNHEALTHY: ' "$WORK/status.txt" || fail "status table has no verdict"
! grep -Eq 'postgres(ql)?://' "$WORK/status.txt" || fail "a URL reached the status output"
[[ -z "$(helm template agent-relay "$CHART" -n "$NS" "${VALUES[@]}" | yq -N 'select(.kind == "Role" or .kind == "RoleBinding") | .metadata.name')" ]] \
  || fail "the default render creates RBAC objects"
ok "helm test prints the status table (9 logins ok, search runtime without sessions USAGE fails, CA mismatch, per-Job migrations; no RBAC by default)"

# 11. Upgrade reruns the hook and fails closed on a regression (the hook log stays readable).
set_key agent-relay-secrets database-runtime-url "$(url postgres relaycast)"
if helm_run upgrade --set databaseGuard.statusTest.rbac.create=true >"$WORK/out" 2>&1; then fail "upgrade accepted the master login"; fi
grep -qF 'agent-relay-secrets: database-runtime-url logs in as "postgres"' "$WORK/out" || { cat "$WORK/out" >&2; fail "upgrade did not refuse at render time"; }
ok "upgrade refuses a regression to the master login"

echo "# all $pass passed"
if [[ -n "${OUT_DIR:-}" ]]; then mkdir -p "$OUT_DIR"; cp "$WORK"/*.txt "$WORK"/*.log "$OUT_DIR/" 2>/dev/null || true; fi
