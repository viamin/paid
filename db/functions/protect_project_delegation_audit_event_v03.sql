CREATE OR REPLACE FUNCTION public.protect_project_delegation_audit_event()
  RETURNS trigger
  LANGUAGE plpgsql
AS $function$
DECLARE
  protected_actions constant text[] := ARRAY[
    'project_delegation.posture_selected',
    'project_delegation.rolled_back',
    'project_delegation.hold_placed',
    'project_delegation.hold_released'
  ];
BEGIN
  IF OLD.action = ANY(protected_actions)
     AND NOT (
       COALESCE(current_setting('paid.account_teardown_account_id', true), '') = OLD.account_id::text
       OR (pg_trigger_depth() > 1 AND NOT EXISTS (SELECT 1 FROM public.accounts WHERE id = OLD.account_id))
     ) THEN
    RAISE EXCEPTION 'project delegation audit events are append-only; UPDATE and DELETE are rejected';
  END IF;

  IF TG_OP = 'UPDATE'
     AND NOT (OLD.action = ANY(protected_actions))
     AND NEW.action = ANY(protected_actions) THEN
    RAISE EXCEPTION 'existing account activity events cannot become project delegation audit events';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  RETURN NEW;
END;
$function$
