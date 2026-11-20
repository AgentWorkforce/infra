\set ON_ERROR_STOP 1
-- Fresh PostgreSQL 16+ RDS activation. Run as the RDS provisioner while
-- connected to the selected, pristine HoopDb database. The provisioner is
-- used only for this transaction; the final graph has no creator edges.
BEGIN;
CREATE ROLE agent_relay_hoopdb_role_creator NOLOGIN NOINHERIT CREATEROLE NOSUPERUSER NOCREATEDB NOREPLICATION NOBYPASSRLS;
GRANT agent_relay_hoopdb_role_creator TO CURRENT_USER WITH INHERIT FALSE, SET TRUE;
SET LOCAL ROLE agent_relay_hoopdb_role_creator;

CREATE ROLE anon NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE authenticated NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE service_role NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE session_directory_search_worker NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE session_directory_search_worker SET statement_timeout = '2s';
CREATE ROLE session_token_verifier NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE bulls96_session_ingest_seeder NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE bulls96_canonical_feature_producer NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE bulls96_babysitter_retention NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE bulls96_babysitter_retention SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE bulls96_babysitter_retention SET lock_timeout = '2s';
ALTER ROLE bulls96_babysitter_retention SET statement_timeout = '5s';
CREATE ROLE bulls96_session_erase_search NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE bulls96_session_erase_search SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE bulls96_session_erase_search SET lock_timeout = '2s';
ALTER ROLE bulls96_session_erase_search SET statement_timeout = '5s';

CREATE ROLE hoopdb_owner LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'owner_password';
CREATE ROLE sessions_pipeline_runtime LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'runtime_password';
CREATE ROLE search_consumer_runtime LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'search_password';
ALTER ROLE search_consumer_runtime SET statement_timeout = '60s';
CREATE ROLE bulls96_read_api LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'read_password';
ALTER ROLE bulls96_read_api SET default_transaction_read_only = 'on';
ALTER ROLE bulls96_read_api SET statement_timeout = '2s';
CREATE ROLE bulls96_session_ingest LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'ingest_password';
ALTER ROLE bulls96_session_ingest SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE bulls96_session_ingest SET lock_timeout = '2s';
ALTER ROLE bulls96_session_ingest SET statement_timeout = '5s';
CREATE ROLE buffered_search_feed_runtime LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'buffered_password';
ALTER ROLE buffered_search_feed_runtime SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE buffered_search_feed_runtime SET lock_timeout = '2s';
ALTER ROLE buffered_search_feed_runtime SET statement_timeout = '5s';
CREATE ROLE bulls96_acquisition_installer LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'acquisition_password';
ALTER ROLE bulls96_acquisition_installer SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE bulls96_acquisition_installer SET lock_timeout = '2s';
ALTER ROLE bulls96_acquisition_installer SET statement_timeout = '5s';
CREATE ROLE bulls96_analysis_admit LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'analysis_password';
ALTER ROLE bulls96_analysis_admit SET default_transaction_read_only = 'off';
ALTER ROLE bulls96_analysis_admit SET statement_timeout = '2s';
CREATE ROLE bulls96_digest_narrative LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'digest_password';
ALTER ROLE bulls96_digest_narrative SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE bulls96_digest_narrative SET lock_timeout = '2s';
ALTER ROLE bulls96_digest_narrative SET statement_timeout = '5s';
CREATE ROLE bulls96_legacy_export_privacy LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'legacy_password';
ALTER ROLE bulls96_legacy_export_privacy SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE bulls96_legacy_export_privacy SET lock_timeout = '5s';
ALTER ROLE bulls96_legacy_export_privacy SET statement_timeout = '20s';
CREATE ROLE bulls96_privacy_eraser LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'privacy_password';
ALTER ROLE bulls96_privacy_eraser SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE bulls96_privacy_eraser SET lock_timeout = '2s';
ALTER ROLE bulls96_privacy_eraser SET statement_timeout = '5s';
CREATE ROLE bulls96_project_events LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'project_password';
ALTER ROLE bulls96_project_events SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE bulls96_project_events SET lock_timeout = '2s';
ALTER ROLE bulls96_project_events SET statement_timeout = '5s';

GRANT hoopdb_owner TO agent_relay_hoopdb_role_creator WITH INHERIT FALSE, SET TRUE;
RESET ROLE;
SELECT format('ALTER DATABASE %I OWNER TO hoopdb_owner', current_database()) \gexec
SET LOCAL ROLE hoopdb_owner;
REVOKE CREATE, TEMPORARY ON DATABASE :"DBNAME" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"DBNAME" TO sessions_pipeline_runtime,
  bulls96_read_api, bulls96_session_ingest, buffered_search_feed_runtime,
  bulls96_acquisition_installer, bulls96_analysis_admit, bulls96_digest_narrative,
  bulls96_legacy_export_privacy, bulls96_privacy_eraser, bulls96_project_events;
CREATE SCHEMA sessions;
CREATE SCHEMA search_index;
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
RESET ROLE;
DROP ROLE agent_relay_hoopdb_role_creator;
COMMIT;
