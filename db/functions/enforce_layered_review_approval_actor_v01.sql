CREATE OR REPLACE FUNCTION public.enforce_layered_review_approval_actor()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM layered_verification_review_packages package
    INNER JOIN projects ON projects.id = package.project_id
    INNER JOIN users ON users.account_id = projects.account_id
    WHERE package.id = NEW.package_id AND users.id = NEW.approved_by_id
  ) THEN
    RAISE EXCEPTION 'approval actor must belong to the package project account' USING ERRCODE = '23503';
  END IF;
  RETURN NEW;
END;
$function$
