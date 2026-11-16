CREATE OR REPLACE FUNCTION public.enforce_supervisor_audit_incident_tenant()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM supervisor_incidents WHERE id = NEW.supervisor_incident_id AND account_id = NEW.account_id
  ) THEN
    RAISE EXCEPTION 'supervisor_incident_id must belong to the audit account';
  END IF;

  RETURN NEW;
END;
$function$
