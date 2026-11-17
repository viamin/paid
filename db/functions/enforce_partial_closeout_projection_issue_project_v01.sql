CREATE OR REPLACE FUNCTION public.enforce_partial_closeout_projection_issue_project()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM issues WHERE id = NEW.issue_id AND project_id = NEW.project_id) THEN
    RAISE EXCEPTION 'projection issue must belong to the projection project' USING ERRCODE = '23503';
  END IF;
  RETURN NEW;
END;
$function$
