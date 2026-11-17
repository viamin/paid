CREATE TRIGGER validate_strategy_version_parent_reference
BEFORE INSERT OR UPDATE OF strategy_id, parent_version_id ON public.strategy_versions
FOR EACH ROW
EXECUTE FUNCTION public.validate_strategy_version_parent_reference();
