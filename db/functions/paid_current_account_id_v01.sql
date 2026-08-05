CREATE OR REPLACE FUNCTION public.paid_current_account_id() RETURNS bigint AS $body$
  -- @spec POSTGRESQL-PERSISTENCE-007
  -- version: 1
  SELECT NULLIF(current_setting('paid.current_account_id', true), '')::bigint
$body$
LANGUAGE sql
STABLE;
