-- Run in an isolated test database as a non-superuser, non-BYPASSRLS role.
-- Synthetic planner experiment; the transaction rolls back all fixture changes.
BEGIN;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = current_user AND (rolsuper OR rolbypassrls)) THEN
    RAISE EXCEPTION 'The probe requires a non-superuser, non-BYPASSRLS role';
  END IF;
END
$$;
CREATE SCHEMA pghero_fts_probe_20261128;
SET LOCAL search_path = pghero_fts_probe_20261128, pg_catalog;
CREATE TABLE documents (id bigint PRIMARY KEY, account_id bigint NOT NULL, search tsvector NOT NULL);
INSERT INTO documents
SELECT i, (i % 2) + 1,
  to_tsvector('english', CASE WHEN i % 1000 = 0 THEN 'needle unique' ELSE 'common corpus' END)
FROM generate_series(1, 10000) i;
CREATE INDEX documents_search ON documents USING gin(search);
ANALYZE documents;
SELECT set_config('paid.current_account_id', '1', true);
CREATE POLICY tenant_scope ON documents
  USING (account_id = current_setting('paid.current_account_id')::bigint);
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE documents FORCE ROW LEVEL SECURITY;
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
SELECT id FROM documents WHERE account_id = 1 AND search @@ plainto_tsquery('english', 'needle');
ALTER TABLE documents DISABLE ROW LEVEL SECURITY;
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
SELECT id FROM documents WHERE account_id = 1 AND search @@ plainto_tsquery('english', 'needle');
ROLLBACK;
