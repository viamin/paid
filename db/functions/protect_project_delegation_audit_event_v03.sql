CREATE OR REPLACE FUNCTION public.protect_project_delegation_audit_event()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.action IN ('project_delegation.posture_selected', 'project_delegation.rollback')
     AND NOT (
       COALESCE(current_setting('paid.account_teardown_account_id', true), '') = OLD.account_id::text
       OR (pg_trigger_depth() > 1 AND NOT EXISTS (SELECT 1 FROM public.accounts WHERE id = OLD.account_id))
     ) THEN
    RAISE EXCEPTION 'project delegation posture audit events are append-only; UPDATE and DELETE are rejected';
  END IF;

  IF TG_OP = 'UPDATE'
     AND OLD.action NOT IN ('project_delegation.posture_selected', 'project_delegation.rollback')
     AND NEW.action IN ('project_delegation.posture_selected', 'project_delegation.rollback') THEN
    RAISE EXCEPTION 'existing account activity events cannot become project delegation posture audit events';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  RETURN NEW;
END;
$function$
