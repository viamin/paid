CREATE TRIGGER enforce_supervisor_incident_status_audit
BEFORE INSERT OR UPDATE ON public.supervisor_incidents
FOR EACH ROW EXECUTE FUNCTION enforce_supervisor_incident_status_audit();
