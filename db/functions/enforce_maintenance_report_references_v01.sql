CREATE OR REPLACE FUNCTION public.enforce_maintenance_report_references()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF TG_TABLE_NAME IN ('maintenance_reports', 'maintenance_findings') THEN
    IF NOT EXISTS (SELECT 1 FROM projects WHERE id = NEW.project_id AND account_id = NEW.account_id) THEN
      RAISE EXCEPTION 'maintenance project must belong to the record account' USING ERRCODE = '23503';
    END IF;
  END IF;

  IF TG_TABLE_NAME = 'maintenance_reports' THEN
    IF NOT EXISTS (SELECT 1 FROM agent_runs WHERE id = NEW.agent_run_id
        AND project_id = NEW.project_id AND goal = 'maintenance') THEN
      RAISE EXCEPTION 'maintenance run must belong to the report project' USING ERRCODE = '23503';
    END IF;
  ELSIF TG_TABLE_NAME = 'maintenance_finding_occurrences' THEN
    IF NOT EXISTS (
      SELECT 1 FROM maintenance_reports
      INNER JOIN maintenance_findings ON maintenance_findings.project_id = maintenance_reports.project_id
        AND maintenance_findings.account_id = maintenance_reports.account_id
      WHERE maintenance_reports.id = NEW.maintenance_report_id
        AND maintenance_findings.id = NEW.maintenance_finding_id
        AND maintenance_reports.account_id = NEW.account_id
    ) THEN
      RAISE EXCEPTION 'maintenance report and finding must belong to the same project and account' USING ERRCODE = '23503';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$
