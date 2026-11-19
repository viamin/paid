-- Development-only administrator provisioning; invoked by bin/setup.
-- psql quotes the role, database, and setting variables at their boundaries.
BEGIN;
CREATE SCHEMA IF NOT EXISTS paid_diagnostics;
-- Refuse an existing schema owned by an untrusted application role.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_namespace
    WHERE nspname = 'paid_diagnostics' AND nspowner = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = CURRENT_USER)
  ) THEN
    RAISE EXCEPTION 'paid_diagnostics must be owned by the provisioning administrator';
  END IF;
END;
$$;
REVOKE ALL ON SCHEMA paid_diagnostics FROM PUBLIC;
REVOKE ALL ON SCHEMA paid_diagnostics FROM :"app_role";
GRANT USAGE ON SCHEMA paid_diagnostics TO :"app_role";
CREATE OR REPLACE FUNCTION paid_diagnostics.reset_query_stats()
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog
AS $$
  SELECT public.pg_stat_statements_reset(
    0::oid,
    (SELECT oid FROM pg_catalog.pg_database WHERE datname = pg_catalog.current_database()),
    0::bigint
  );
$$;
REVOKE ALL ON FUNCTION paid_diagnostics.reset_query_stats() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION paid_diagnostics.reset_query_stats() TO :"app_role";
ALTER DATABASE :"DBNAME" SET pg_stat_statements.track_planning TO :'track_planning';
COMMIT;
