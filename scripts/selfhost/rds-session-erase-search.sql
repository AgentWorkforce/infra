-- RDS adapter: executed by the CREATEROLE migration owner, never a workload.
-- pre creates only the identity; post grants after the search bootstrap exists.
\set ON_ERROR_STOP 1
BEGIN;
DO $role$
DECLARE r pg_roles%ROWTYPE;
BEGIN
 IF session_user <> current_user OR current_setting('role') <> 'none' THEN
  RAISE EXCEPTION 'erase search bootstrap requires the direct migration owner';
 END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='bulls96_session_erase_search') THEN
  CREATE ROLE bulls96_session_erase_search NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
 END IF;
 SELECT * INTO STRICT r FROM pg_roles WHERE rolname='bulls96_session_erase_search';
 IF r.rolsuper OR r.rolbypassrls OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolinherit THEN
  RAISE EXCEPTION 'erase search role attributes drifted';
 END IF;
 -- CREATEROLE on PG16+ records its creator as ADMIN, without SET/INHERIT.
 -- Keep that management edge for repeatable password rotation on RDS.
 IF current_setting('server_version_num')::int >= 160000 THEN
  IF EXISTS (SELECT 1 FROM pg_auth_members a JOIN pg_roles m ON m.oid=a.member
   WHERE (a.roleid=r.oid OR a.member=r.oid) AND NOT
    (a.roleid=r.oid AND m.rolname=current_user AND a.admin_option AND NOT a.inherit_option AND NOT a.set_option)) THEN
   RAISE EXCEPTION 'erase search role memberships drifted';
  END IF;
 ELSE
  IF EXISTS (SELECT 1 FROM pg_auth_members a JOIN pg_roles m ON m.oid=a.member
   WHERE (a.roleid=r.oid OR a.member=r.oid) AND NOT
    (a.roleid=r.oid AND m.rolname=current_user AND a.admin_option)) THEN
   RAISE EXCEPTION 'erase search role memberships drifted';
  END IF;
 END IF;
END $role$;
\if :post
DO $schema$
BEGIN
 IF (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='search_index' AND c.relname IN ('transcript_events','projection_state')
   AND c.relkind='r' AND c.relrowsecurity AND c.relforcerowsecurity
   AND c.relowner<>(SELECT oid FROM pg_roles WHERE rolname='bulls96_session_erase_search')) <> 2 THEN
  RAISE EXCEPTION 'erase search requires the completed search bootstrap with forced tenant RLS';
 END IF;
END $schema$;
GRANT USAGE ON SCHEMA search_index TO bulls96_session_erase_search;
GRANT DELETE ON search_index.transcript_events,search_index.projection_state TO bulls96_session_erase_search;
GRANT SELECT(org_id,workspace_id,source,session_id) ON search_index.transcript_events TO bulls96_session_erase_search;
GRANT SELECT(org_id,workspace_id,source,session_id,canonical_session_id) ON search_index.projection_state TO bulls96_session_erase_search;
-- Refuse widened direct/PUBLIC grants rather than silently repairing drift.
DO $acl$
BEGIN
 IF has_schema_privilege('bulls96_session_erase_search','search_index','CREATE')
 OR has_table_privilege('bulls96_session_erase_search','search_index.transcript_events','SELECT,INSERT,UPDATE,TRUNCATE,REFERENCES,TRIGGER')
 OR has_table_privilege('bulls96_session_erase_search','search_index.projection_state','SELECT,INSERT,UPDATE,TRUNCATE,REFERENCES,TRIGGER')
 OR EXISTS(SELECT 1 FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='search_index' AND c.relname IN('transcript_events','projection_state') AND a.attnum>0 AND NOT a.attisdropped
   AND (has_column_privilege('bulls96_session_erase_search',c.oid,a.attnum,'INSERT,UPDATE') OR
    (has_column_privilege('bulls96_session_erase_search',c.oid,a.attnum,'SELECT') AND a.attname NOT IN('org_id','workspace_id','source','session_id','canonical_session_id')))) THEN
  RAISE EXCEPTION 'erase search privileges drifted';
 END IF;
END $acl$;
ALTER ROLE bulls96_session_erase_search LOGIN PASSWORD :'p1';
ALTER ROLE bulls96_session_erase_search SET statement_timeout='5s';
ALTER ROLE bulls96_session_erase_search SET lock_timeout='2s';
ALTER ROLE bulls96_session_erase_search SET idle_in_transaction_session_timeout='10s';
GRANT CONNECT ON DATABASE hoopdb TO bulls96_session_erase_search;
\endif
COMMIT;
