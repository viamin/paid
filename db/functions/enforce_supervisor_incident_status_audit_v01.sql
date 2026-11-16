CREATE OR REPLACE FUNCTION public.enforce_supervisor_incident_status_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status AND
     current_setting('paid.supervisor_incident_status_transition', true) IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'supervisor incident status changes must append a status_changed audit';
  END IF;

  IF TG_OP = 'INSERT' AND
     current_setting('paid.supervisor_incident_status_transition', true) IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'supervisor incident creation must append an opened audit';
  END IF;

  RETURN NEW;
END;
$function$
