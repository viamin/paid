CREATE OR REPLACE FUNCTION public.prevent_supervisor_incident_audit_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF TG_OP = 'DELETE' AND current_setting('paid.supervisor_incident_audit_purge', true) = 'true' THEN
    RETURN OLD;
  END IF;

  RAISE EXCEPTION 'supervisor incident audits are append-only';
END;
$function$
