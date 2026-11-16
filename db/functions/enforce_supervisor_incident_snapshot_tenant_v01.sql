CREATE OR REPLACE FUNCTION public.enforce_supervisor_incident_snapshot_tenant()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.supervisor_snapshot_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM supervisor_snapshots WHERE id = NEW.supervisor_snapshot_id AND account_id = NEW.account_id
  ) THEN
    RAISE EXCEPTION 'supervisor_snapshot_id must belong to the incident account';
  END IF;

  RETURN NEW;
END;
$function$
