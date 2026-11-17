CREATE OR REPLACE FUNCTION public.enforce_layered_review_package_references()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM agent_runs WHERE id = NEW.agent_run_id AND project_id = NEW.project_id) THEN
    RAISE EXCEPTION 'agent run must belong to the package project' USING ERRCODE = '23503';
  END IF;
  IF NEW.bound_inputs ? 'agent_run_id' AND
      (NEW.bound_inputs ->> 'agent_run_id') IS DISTINCT FROM NEW.agent_run_id::text THEN
    RAISE EXCEPTION 'bound agent run must match the package run' USING ERRCODE = '23503';
  END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(COALESCE(NEW.bound_inputs -> 'obligations', '[]'::jsonb)) input(obligation)
    WHERE NOT EXISTS (SELECT 1 FROM layered_verification_obligations
      WHERE id = (input.obligation ->> 'id')::bigint AND project_id = NEW.project_id)
  ) THEN
    RAISE EXCEPTION 'bound obligations must belong to the package project' USING ERRCODE = '23503';
  END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements_text(COALESCE(NEW.bound_inputs -> 'check_result_ids', '[]'::jsonb)) input(id)
    WHERE NOT EXISTS (
      SELECT 1 FROM layered_verification_check_results result
      INNER JOIN layered_verification_obligations obligation ON obligation.id = result.obligation_id
      LEFT JOIN agent_runs result_run ON result_run.id = result.agent_run_id
      WHERE result.id = input.id::bigint AND obligation.project_id = NEW.project_id
        AND (result.agent_run_id IS NULL OR result_run.project_id = NEW.project_id)
    )
  ) THEN
    RAISE EXCEPTION 'bound check results must belong to the package project' USING ERRCODE = '23503';
  END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements_text(COALESCE(NEW.bound_inputs -> 'approval_ids', '[]'::jsonb)) input(id)
    WHERE NOT EXISTS (
      SELECT 1 FROM layered_verification_review_approvals approval
      INNER JOIN layered_verification_review_packages package ON package.id = approval.package_id
      WHERE approval.id = input.id::bigint AND package.project_id = NEW.project_id
    )
  ) THEN
    RAISE EXCEPTION 'bound approvals must belong to the package project' USING ERRCODE = '23503';
  END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(COALESCE(NEW.bound_inputs -> 'inbox_decisions', '[]'::jsonb)) input(decision)
    WHERE NOT EXISTS (SELECT 1 FROM layered_verification_findings
      WHERE id = (input.decision ->> 'finding_id')::bigint AND project_id = NEW.project_id)
  ) THEN
    RAISE EXCEPTION 'bound Inbox findings must belong to the package project' USING ERRCODE = '23503';
  END IF;
  RETURN NEW;
END;
$function$
