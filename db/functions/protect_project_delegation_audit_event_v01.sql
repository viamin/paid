CREATE OR REPLACE FUNCTION public.protect_project_delegation_audit_event()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.action = 'project_delegation.posture_selected' THEN
    RAISE EXCEPTION 'project delegation posture audit events are append-only; UPDATE and DELETE are rejected';
  END IF;

  IF TG_OP = 'UPDATE' AND NEW.action = 'project_delegation.posture_selected' THEN
    RAISE EXCEPTION 'existing account activity events cannot become project delegation posture audit events';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  RETURN NEW;
END;
$function$
