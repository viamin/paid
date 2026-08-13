CREATE OR REPLACE FUNCTION public.validate_orchestration_decision_strategy_version_scope()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NEW.strategy_version_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM strategy_versions
    INNER JOIN strategies ON strategies.id = strategy_versions.strategy_id
    WHERE strategy_versions.id = NEW.strategy_version_id
      AND (
        strategies.account_id IS NULL
        OR (
          strategies.account_id = paid_current_account_id()
          AND (
            strategies.project_id IS NULL
            OR strategies.project_id = NEW.project_id
          )
        )
      )
  ) THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'strategy_version_id must reference a global or same-tenant strategy version';
END;
$function$
