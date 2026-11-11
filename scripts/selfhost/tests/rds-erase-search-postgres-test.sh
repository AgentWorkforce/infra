#!/usr/bin/env bash
# Owned disposable PostgreSQL fixture; no published ports or cloud access.
set -euo pipefail
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SQL="${TEST_DIR}/../rds-session-erase-search.sql"
FIXTURE="erase-search-role-test-$$"
CONTAINER=""
cleanup() { if [[ -n "$CONTAINER" ]]; then docker rm -f "$CONTAINER" >/dev/null; fi; }
trap cleanup EXIT
CONTAINER="$(docker run -d --name "$FIXTURE" -e POSTGRES_HOST_AUTH_METHOD=trust postgres:17)"
for attempt in {1..30}; do
  if docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then break; fi
  [[ "$attempt" != 30 ]] || { echo "fixture did not become ready" >&2; exit 1; }
  sleep 1
done
admin() { docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U postgres -d hoopdb "$@"; }
owner() { docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U erase_fixture_owner -d hoopdb "$@"; }
role_sql() { owner -v post="$1" -v p1=fixture-only-password < "$SQL"; }
refuse() {
  if "$@" >/dev/null 2>&1; then echo "expected refusal: $*" >&2; exit 1; fi
}
docker exec "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U postgres -c 'CREATE ROLE erase_fixture_owner LOGIN CREATEROLE;'
docker exec "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U postgres -c 'CREATE DATABASE hoopdb OWNER erase_fixture_owner;'
role_sql false >/dev/null
role_sql false >/dev/null
[[ "$(admin -Atc "SELECT NOT rolcanlogin AND NOT rolinherit AND NOT rolsuper AND NOT rolbypassrls FROM pg_roles WHERE rolname='bulls96_session_erase_search'")" == t ]]
refuse role_sql true
[[ "$(admin -Atc "SELECT NOT rolcanlogin FROM pg_roles WHERE rolname='bulls96_session_erase_search'")" == t ]]
echo 'ok - non-superuser creates dormant role idempotently; missing schema refuses login'
owner <<'SQL'
CREATE SCHEMA search_index;
CREATE TABLE search_index.transcript_events(org_id text,workspace_id text,source text,session_id text,content text);
CREATE TABLE search_index.projection_state(org_id text,workspace_id text,source text,session_id text,canonical_session_id text,content text);
SQL
refuse role_sql true
owner <<'SQL'
ALTER TABLE search_index.transcript_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE search_index.transcript_events FORCE ROW LEVEL SECURITY;
ALTER TABLE search_index.projection_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE search_index.projection_state FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_only ON search_index.transcript_events USING(org_id=current_setting('bulls96_read.org_id',true) AND workspace_id=current_setting('bulls96_read.workspace_id',true));
CREATE POLICY tenant_only ON search_index.projection_state USING(org_id=current_setting('bulls96_read.org_id',true) AND workspace_id=current_setting('bulls96_read.workspace_id',true));
SQL
# Model an existing install whose normal pre/post ran before this role existed.
admin -c 'DROP OWNED BY bulls96_session_erase_search; DROP ROLE bulls96_session_erase_search' >/dev/null
role_sql true >/dev/null
role_sql true >/dev/null
role_sql false >/dev/null
[[ "$(admin -Atc "SELECT rolcanlogin AND NOT rolinherit AND NOT rolsuper AND NOT rolbypassrls AND NOT rolcreaterole FROM pg_roles WHERE rolname='bulls96_session_erase_search'")" == t ]]
[[ "$(admin -Atc "SELECT admin_option AND NOT inherit_option AND NOT set_option FROM pg_auth_members WHERE roleid='bulls96_session_erase_search'::regrole AND member='erase_fixture_owner'::regrole")" == t ]]
echo 'ok - RDS-style owner grants and rotates repeatably, retaining only its non-inheriting ADMIN edge'
admin -c "INSERT INTO search_index.transcript_events VALUES ('org_a','ws','s','id','secret'),('org_b','ws','s','id','neighbor');" >/dev/null
refuse docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U bulls96_session_erase_search -d hoopdb -c 'SELECT content FROM search_index.transcript_events'
refuse docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U bulls96_session_erase_search -d hoopdb -c 'CREATE TABLE search_index.forbidden(id int)'
refuse docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U bulls96_session_erase_search -d hoopdb -c 'TRUNCATE search_index.transcript_events'
refuse docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U bulls96_session_erase_search -d hoopdb -c "INSERT INTO search_index.transcript_events VALUES ('org_a','ws','s','id','payload')"
docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U bulls96_session_erase_search -d hoopdb -c 'DELETE FROM search_index.transcript_events' >/dev/null
[[ "$(admin -Atc 'SELECT count(*) FROM search_index.transcript_events')" == 2 ]]
docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U bulls96_session_erase_search -d hoopdb <<'SQL'
BEGIN;
SET LOCAL bulls96_read.org_id='org_a';
SET LOCAL bulls96_read.workspace_id='ws';
DELETE FROM search_index.transcript_events WHERE session_id='id';
COMMIT;
SQL
[[ "$(admin -Atc 'SELECT count(*) FROM search_index.transcript_events')" == 1 ]]
echo 'ok - genuine eraser login cannot read content or write; delete preserves other tenant'
owner -c 'GRANT SELECT ON search_index.transcript_events TO bulls96_session_erase_search' >/dev/null
refuse role_sql true
owner -c 'REVOKE SELECT ON search_index.transcript_events FROM bulls96_session_erase_search' >/dev/null
owner -c 'GRANT bulls96_session_erase_search TO erase_fixture_owner WITH INHERIT TRUE' >/dev/null
refuse role_sql false
owner -c 'GRANT bulls96_session_erase_search TO erase_fixture_owner WITH INHERIT FALSE' >/dev/null
owner -c 'ALTER ROLE bulls96_session_erase_search INHERIT' >/dev/null
refuse role_sql true
echo 'ok - widened privileges, creator inheritance and role attribute drift refuse bootstrap'
