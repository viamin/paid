CREATE TRIGGER enforce_maintenance_findings_references
BEFORE INSERT OR UPDATE OF account_id, project_id ON public.maintenance_findings
FOR EACH ROW EXECUTE FUNCTION public.enforce_maintenance_report_references();
