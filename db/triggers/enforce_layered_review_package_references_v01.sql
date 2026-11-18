CREATE TRIGGER enforce_layered_review_package_references
BEFORE INSERT OR UPDATE OF project_id, agent_run_id, bound_inputs ON public.layered_verification_review_packages
FOR EACH ROW EXECUTE FUNCTION public.enforce_layered_review_package_references();
