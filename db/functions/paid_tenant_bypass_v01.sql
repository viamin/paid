CREATE OR REPLACE FUNCTION public.paid_tenant_bypass() RETURNS boolean AS $body$
  -- @spec POSTGRESQL-PERSISTENCE-007
  -- version: 1
  SELECT current_setting('paid.bypass_tenant_rls', true) = 'true'
$body$
LANGUAGE sql
STABLE;
