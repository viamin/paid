CREATE TRIGGER enforce_maintenance_reports_references
BEFORE INSERT OR UPDATE OF account_id, project_id, agent_run_id ON public.maintenance_reports
FOR EACH ROW EXECUTE FUNCTION public.enforce_maintenance_report_references();
